#!/usr/bin/env bash
set -euo pipefail

# Publish a prebuilt static export to the dedicated usAIge directory. The relay
# and nginx configuration are managed separately by deploy-relay-vps.sh.
project_root="$(cd "$(dirname "$0")/.." && pwd)"
site_export="${SITE_EXPORT_DIR:-$project_root/site/out/project/usaige}"
remote="${SITE_SSH_TARGET:-root@pmrichq.com}"
public_url=https://pmrichq.com/project/usaige
validation_only=false
case "${1:-}" in
    "") ;;
    --validate-only) validation_only=true ;;
    *) echo "Usage: $0 [--validate-only]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "Unexpected deployment arguments" >&2; exit 2; }
command -v python3 >/dev/null
command -v node >/dev/null
temporary_dir="$(mktemp -d /tmp/usaige-site-deploy.XXXXXX)"
trap 'rm -rf "$temporary_dir"' EXIT
archive="$temporary_dir/site.tar.gz"
metadata="$temporary_dir/metadata.json"

python3 - "$site_export" "$archive" "$metadata" "$project_root/Sources/UsageHUD/Update/UpdateController.swift" <<'PYTHON'
import base64
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tarfile
from urllib.parse import unquote, urljoin, urlsplit

root, archive, metadata, native_source = map(Path, sys.argv[1:])
base_url = "https://pmrichq.com/project/usaige"
base_path = "/project/usaige/"

def fail(message):
    raise SystemExit(message)

def file_sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

if not root.is_dir() or root.is_symlink():
    fail("Expected a regular static export directory; run npm run build:vps in site first")
files = {}
for path in sorted(root.rglob("*")):
    relative = path.relative_to(root).as_posix()
    if any(part == ".DS_Store" or part.startswith("._") for part in PurePosixPath(relative).parts):
        continue
    if any(ord(char) < 32 for char in relative) or "\\" in relative:
        fail("Unsupported filename in static export")
    mode = path.lstat().st_mode
    if stat.S_ISDIR(mode):
        continue
    if not stat.S_ISREG(mode):
        fail(f"Static export contains a symlink or special file: {relative}")
    files[relative] = file_sha(path)
for name in ("index.html", "update.json"):
    if name not in files:
        fail(f"Static export is missing {name}")
manifest = json.loads((root / "update.json").read_text())
version, build = manifest.get("version"), manifest.get("build")
digest, signature = manifest.get("sha256"), manifest.get("signature")
if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    fail("Manifest version must contain three numeric components")
if type(build) is not int or build < 1:
    fail("Manifest build must be a positive integer")
if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
    fail("Manifest SHA-256 must be a lowercase hexadecimal digest")
try:
    if len(base64.b64decode(signature, validate=True)) != 64:
        fail("Manifest signature must be an Ed25519 signature")
except (TypeError, ValueError):
    fail("Manifest is missing a valid base64 signature")
if not isinstance(manifest.get("minimumSystemVersion"), str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", manifest["minimumSystemVersion"]):
    fail("Manifest is missing minimumSystemVersion")
filename = f"usAIge-{version}-alpha.dmg"
checksum_filename = filename + ".sha256"
if manifest.get("downloadURL") != f"{base_url}/{filename}":
    fail("Manifest downloadURL must use the canonical pmrichq.com release path")
if files.get(filename) != digest:
    fail("Manifest SHA-256 does not match its disk image")
if checksum_filename not in files or (root / checksum_filename).read_text().strip() != f"{digest}  {filename}":
    fail("Release checksum does not match its disk image and filename")
native = native_source.read_text()
keys = re.findall(r'pinnedPublicKeyBase64:\s*String\?\s*=\s*"([A-Za-z0-9+/=]+)"', native)
if len(keys) != 1 or len(base64.b64decode(keys[0], validate=True)) != 32:
    fail("Cannot identify the app's pinned update public key")

referenced = set()
def check_reference(value, document_url):
    if not value or value.startswith(("#", "data:", "mailto:", "tel:", "blob:")):
        return
    url = urlsplit(urljoin(document_url, value))
    if url.netloc and url.netloc != "pmrichq.com":
        return
    if url.scheme not in ("", "https") or url.username or url.password:
        fail("Invalid local asset URL in static export")
    path = unquote(url.path)
    if path == "/project/usaige":
        path += "/"
    if not path.startswith(base_path):
        fail(f"Local asset URL is outside the published base path: {path}")
    relative = path[len(base_path):]
    if not relative or relative.endswith("/"):
        relative += "index.html"
    if ".." in PurePosixPath(relative).parts or relative not in files:
        fail(f"Referenced static asset is missing: {relative}")
    referenced.add(relative)

class References(HTMLParser):
    def handle_starttag(self, tag, attributes):
        for name, value in attributes:
            if name in ("href", "src", "poster"):
                check_reference(value, base_url + "/")
            elif name in ("srcset", "imagesrcset") and value:
                for item in value.split(","):
                    check_reference(item.strip().split()[0], base_url + "/")
            elif name == "style" and value:
                for asset in re.findall(r'url\(\s*[\'\"]?([^\s)\'\"]+)', value):
                    check_reference(asset, base_url + "/")

html = (root / "index.html").read_text()
References().feed(html)
if f"v{version}" not in html or f"{base_url}/{filename}" not in html or f"{base_url}/{checksum_filename}" not in html:
    fail("Homepage version or download/checksum links do not match update.json")
if "usaige-macos.richardqz.chatgpt.site" in html:
    fail("Homepage still references the retired release host")
for relative in files:
    if relative.endswith(".css"):
        source = (root / relative).read_text()
        values = re.findall(r'url\(\s*[\'\"]?([^\s)\'\"]+)', source)
        values += re.findall(r'@import\s+[\'\"]([^\'\"]+)', source)
        for value in values:
            check_reference(value, base_url + "/" + relative)
    elif relative.endswith((".js", ".mjs")):
        source = (root / relative).read_text()
        for value in re.findall(r'(?:\bfrom\s*|\bimport\s*(?:\(\s*)?)[\'\"]([^\'\"]+)', source):
            if value.startswith(("./", "../", "/", "https://")):
                check_reference(value, base_url + "/" + relative)

# Construct the archive ourselves: regular files only, relative paths, no macOS
# extended attributes, resource forks, user/group names, or wrapping directories.
with tarfile.open(archive, "w:gz", format=tarfile.PAX_FORMAT) as output:
    for relative in files:
        path = root / relative
        info = tarfile.TarInfo(relative)
        info.size = path.stat().st_size
        info.mode = 0o644
        with path.open("rb") as stream:
            output.addfile(info, stream)
archive_sha = file_sha(archive)
metadata.write_text(json.dumps({
    "version": version, "build": build, "filename": filename,
    "manifest": manifest, "publicKey": keys[0], "files": files,
    "references": sorted(referenced), "archiveSHA256": archive_sha,
}, sort_keys=True) + "\n")
print(f"Validated static assets and disk-image checksum for usAIge {version} build {build}")
PYTHON

# Verify with the native client's public pin; never read the private release key.
node --input-type=module - "$metadata" <<'JAVASCRIPT'
import { readFileSync } from "node:fs";
import { createPublicKey, verify } from "node:crypto";
const metadata = JSON.parse(readFileSync(process.argv[2], "utf8"));
const { version, build, sha256, signature } = metadata.manifest;
const publicKey = createPublicKey({
    key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(metadata.publicKey, "base64")]),
    format: "der", type: "spki",
});
const payload = Buffer.from(`usaige-update-v2\n${version}\n${build}\n${sha256.toLowerCase()}\n`);
if (!verify(null, payload, publicKey, Buffer.from(signature, "base64"))) {
    throw new Error("Release manifest signature does not match the app's pinned key");
}
console.log("Verified update signature against the app's pinned key");
JAVASCRIPT
if [[ "$validation_only" == true ]]; then exit 0; fi

: "${SSH_IDENTITY:?Set SSH_IDENTITY to the existing pmrichq.com SSH identity file}"
[[ -f "$SSH_IDENTITY" ]] || { echo "SSH identity file is missing" >&2; exit 1; }
[[ "$remote" =~ ^[a-zA-Z0-9_.@:-]+$ && "$remote" != -* ]] || { echo "Invalid SSH target" >&2; exit 1; }
deployment_id="$(date -u +%Y%m%dT%H%M%SZ)-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
archive_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["archiveSHA256"])' "$metadata")"
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o IdentitiesOnly=yes -i "$SSH_IDENTITY")
scp "${ssh_options[@]}" "$archive" "$remote:/tmp/usaige-site-${deployment_id}.tar.gz"
scp "${ssh_options[@]}" "$metadata" "$remote:/tmp/usaige-site-${deployment_id}.json"

ssh "${ssh_options[@]}" "$remote" bash -s -- "$deployment_id" "$archive_sha" <<'REMOTE_SCRIPT'
set -euo pipefail
deployment_id="$1"
archive_sha="$2"
site_root=/var/www/usaige
archive="/tmp/usaige-site-${deployment_id}.tar.gz"
metadata="/tmp/usaige-site-${deployment_id}.json"
new_release=""
previous_target=""
activated=false
temporary_link="$site_root/.current-${deployment_id}"
rollback_link="$site_root/.rollback-${deployment_id}"
finish() {
    result=$?
    set +e
    if (( result != 0 )) && [[ "$activated" == true ]]; then
        restored=false
        if [[ -n "$previous_target" ]]; then
            if ln -s "$previous_target" "$rollback_link" && mv -Tf "$rollback_link" "$site_root/current"; then
                restored=true
            fi
        else
            if rm -f "$site_root/current"; then restored=true; fi
        fi
        if [[ "$restored" == true ]]; then
            echo "Static deployment failed; prior activation restored. Failed release: $new_release" >&2
        else
            echo "Static deployment and rollback failed; inspect $site_root/current. Failed release: $new_release" >&2
        fi
    fi
    rm -f "$temporary_link" "$rollback_link" "$archive" "$metadata"
    exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
[[ "$(id -u)" == 0 ]] || { echo "Static deployment requires the authorized root account" >&2; exit 1; }
[[ ! -L "$site_root" && ! -L "$site_root/releases" ]] || { echo "The dedicated usAIge root must contain regular directories" >&2; exit 1; }
install -d -m 0755 "$site_root" "$site_root/releases"
chown root:www-data "$site_root" "$site_root/releases"
exec 9>"$site_root/.deploy.lock"
flock -w 60 9 || { echo "Another static deployment is in progress" >&2; exit 1; }
if [[ -e "$site_root/current" || -L "$site_root/current" ]]; then
    [[ -L "$site_root/current" && -d "$site_root/current" ]] || { echo "Expected current to be a valid release symlink" >&2; exit 1; }
    previous_target="$(readlink "$site_root/current")"
    resolved_previous="$(readlink -f "$site_root/current")"
    [[ "$resolved_previous" == "$site_root/releases/"* ]] || { echo "Current site points outside the usAIge releases directory" >&2; exit 1; }
fi
printf '%s  %s\n' "$archive_sha" "$archive" | sha256sum --check --status
release_label="$(python3 - "$metadata" <<'PYTHON'
import json, re, sys
data = json.load(open(sys.argv[1]))
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", data["version"]) or type(data["build"]) is not int or data["build"] < 1:
    raise SystemExit("Invalid release metadata")
print(f"usaige-{data['version']}-build{data['build']}")
PYTHON
)"
new_release="$(mktemp -d "$site_root/releases/${deployment_id}-${release_label}.XXXXXX")"
python3 - "$archive" "$metadata" "$new_release" "$site_root/current" <<'PYTHON'
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import tarfile

archive, metadata, destination, previous = map(Path, sys.argv[1:])
data = json.loads(metadata.read_text())
files = data["files"]
def file_sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

if file_sha(archive) != data["archiveSHA256"]:
    raise SystemExit("Uploaded archive checksum does not match deployment metadata")
seen = set()
with tarfile.open(archive, "r:gz") as source:
    for member in source:
        relative = PurePosixPath(member.name)
        if not member.isfile() or relative.is_absolute() or ".." in relative.parts or member.name not in files or member.name in seen:
            raise SystemExit("Unexpected archive member")
        seen.add(member.name)
        path = destination / member.name
        path.parent.mkdir(parents=True, exist_ok=True)
        stream = source.extractfile(member)
        with stream, path.open("xb") as output:
            shutil.copyfileobj(stream, output)
        if file_sha(path) != files[member.name]:
            raise SystemExit("Extracted static asset checksum mismatch")
if seen != set(files):
    raise SystemExit("Deployment archive is missing static files")
if json.loads((destination / "update.json").read_text()) != data["manifest"]:
    raise SystemExit("Extracted update manifest changed")

# Old clients may have already downloaded a manifest with an older DMG URL.
# Copy earlier immutable DMG/checksum pairs into the new active release.
if previous.is_dir():
    previous_manifest = json.loads((previous / "update.json").read_text())
    if type(previous_manifest.get("build")) is not int or data["build"] < previous_manifest["build"]:
        raise SystemExit("Refusing to downgrade the public update feed")
    if data["build"] == previous_manifest["build"] and any(
        data["manifest"].get(key) != previous_manifest.get(key)
        for key in ("version", "sha256", "signature")
    ):
        raise SystemExit("The same update build must keep its signed artifact")
    for image in sorted(previous.glob("usAIge-*-alpha.dmg")):
        if not re.fullmatch(r"usAIge-[0-9]+\.[0-9]+\.[0-9]+-alpha\.dmg", image.name):
            raise SystemExit("Unexpected historical disk-image filename")
        checksum = image.with_name(image.name + ".sha256")
        if not stat.S_ISREG(image.lstat().st_mode) or not checksum.exists() or not stat.S_ISREG(checksum.lstat().st_mode):
            raise SystemExit("Historical downloads must be regular disk-image/checksum pairs")
        digest = file_sha(image)
        if checksum.read_text().strip() != f"{digest}  {image.name}":
            raise SystemExit("Historical disk-image checksum mismatch")
        for source in (image, checksum):
            target = destination / source.name
            if target.exists():
                if file_sha(target) != file_sha(source):
                    raise SystemExit("An existing release download cannot be replaced with different bytes")
            else:
                shutil.copyfile(source, target)
for path in destination.rglob("*"):
    path.chmod(0o755 if path.is_dir() else 0o644)
destination.chmod(0o755)
PYTHON
chown -R root:www-data "$new_release"
ln -s "releases/$(basename "$new_release")" "$temporary_link"
activated=true
mv -Tf "$temporary_link" "$site_root/current"

# Check every new file through nginx's actual TLS virtual host. Hash equality
# detects the wrong alias root, HTML fallbacks, stale assets, and changed DMGs.
python3 - "$metadata" <<'PYTHON'
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.parse import quote

data = json.loads(Path(sys.argv[1]).read_text())
base_url = "https://pmrichq.com/project/usaige"
def file_sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

with tempfile.TemporaryDirectory(prefix="usaige-site-check-") as temporary:
    output = Path(temporary) / "response"
    def fetch(relative):
        url = base_url + "/" + quote(relative, safe="/")
        response = subprocess.check_output([
            "curl", "--fail", "--silent", "--show-error", "--max-time", "60",
            "--proto", "=https", "--resolve", "pmrichq.com:443:127.0.0.1",
            "--output", str(output), "--write-out", "%{http_code}\n%{content_type}", url,
        ], text=True)
        status, content_type = response.split("\n", 1)
        if status != "200":
            raise SystemExit("Published usAIge route did not return HTTP 200")
        return content_type
    for relative, expected in data["files"].items():
        fetch("" if relative == "index.html" else relative)
        if file_sha(output) != expected:
            raise SystemExit(f"Published asset checksum mismatch: {relative}")
        if relative == "update.json" and json.loads(output.read_text()) != data["manifest"]:
            raise SystemExit("Published manifest does not match the signed release")
    content_type = fetch("api/v1/health")
    health = json.loads(output.read_text())
    if not content_type.lower().startswith("application/json") or health.get("status") != "ok" or health.get("service") != "usaige-relay":
        raise SystemExit("usAIge relay health failed after static deployment")
print(f"Verified TLS site, assets, signed update manifest, and relay health for {data['version']} build {data['build']}")
PYTHON
echo "usAIge static release $release_label activated at $new_release"
REMOTE_SCRIPT

# External DNS/network reachability is checked separately from server activation.
curl --fail --silent --show-error --max-time 30 "$public_url/update.json" --output "$temporary_dir/public-update.json"
python3 - "$metadata" "$temporary_dir/public-update.json" <<'PYTHON'
import json, sys
expected = json.load(open(sys.argv[1]))["manifest"]
actual = json.load(open(sys.argv[2]))
if actual != expected:
    raise SystemExit("External public manifest does not match the activated release")
print(f"Public update feed serves usAIge {actual['version']} build {actual['build']}")
PYTHON
curl --fail --silent --show-error --max-time 30 "$public_url/api/v1/health" --output "$temporary_dir/public-health.json"
python3 - "$temporary_dir/public-health.json" <<'PYTHON'
import json, sys
health = json.load(open(sys.argv[1]))
if health.get("status") != "ok" or health.get("service") != "usaige-relay":
    raise SystemExit("External public relay health is unavailable")
print("Public relay health is ok")
PYTHON
