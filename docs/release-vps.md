# Publishing a macOS release on pmrichq.com

The macOS release has two public destinations: the GitHub release assets and
the website/update feed at `https://pmrichq.com/project/usaige/`. Publishing the
static website uses the dedicated `/var/www/usaige/` tree on the existing VPS.
The relay service has its own deployment script and persistent SQLite database;
see [relay-vps.md](relay-vps.md).

## Prepare the release

Update the app's version/build in `Sources/UsageHUD/Resources/Info.plist`, bundled release
notes, the homepage release links/version, and their release assertions before
building. For this release the next version is **0.2.17**, build **39**. The
update controller compares build numbers, so each subsequent release must
increase the build.

From the repository root, package the actual app and disk image:

```sh
./scripts/package-dmg.sh
```

The packager builds the release executable, assembles and verifies the app's
code signature, creates `dist/usAIge-<version>-alpha.dmg`, writes its SHA-256
sidecar, and copies both into `site/public/`. It also generates
`site/public/update.json`. The existing private Ed25519 release key lives in
`~/.config/usaige/update-signing-key` with mode `0600`; the packager signs the
manifest when that key is available. Keep that private key out of the repository,
archives, logs, and VPS. An unsigned package must not be published to the update
feed. The deploy script rejects a missing or invalid signature.

The signature covers these exact UTF-8 bytes, including the final newline:

```text
usaige-update-v2
<version>
<build>
<lowercase SHA-256 of the DMG>
```

The download URL is excluded from the signature; the DMG digest pins the actual
artifact. `site/scripts/export-vps.mjs` can rewrite a former release URL to
`https://pmrichq.com/project/usaige/` while preserving the signature. The app's
existing pinned public key must continue to verify it. Do not rotate the key
as part of a routine release.

Build and validate the static export from `site/`:

```sh
npm ci
npm test
npm run lint
```

`npm test` builds the website, exports it, and runs the rendered HTML and relay
tests. The publishable root is **`site/out/project/usaige/`**. Its contents belong
directly beneath the Nginx alias; uploading the wrapper `out/` directory produces
incorrect routes.

## Validate and deploy the static site

From the repository root, check the prebuilt export without SSH or deployment:

```sh
bash scripts/deploy-site-vps.sh --validate-only
```

This checks the version/build fields, canonical download URL, DMG digest,
checksum sidecar, homepage version/download links, local HTML/CSS/module asset
references, and every exported file. It cryptographically verifies the signed
manifest using Node's built-in Ed25519 support and the native app's pinned
public key. It reads no private release key. Symlinks and special files are
rejected; macOS `.DS_Store`, resource forks, and extended attributes are excluded
from the upload archive.

Use the existing SSH identity for the authorized server:

```sh
SSH_IDENTITY=/absolute/path/to/existing-pmrichq-key bash scripts/deploy-site-vps.sh
```

`SITE_EXPORT_DIR` can select another prebuilt export directory. `SITE_SSH_TARGET`
defaults to `root@pmrichq.com`. SSH uses batch mode, the specified identity, and
existing host-key verification. The local validator needs Node.js and Python
**3.8 or newer**. The VPS needs Python 3.8+, `curl`, and `flock`.

The script uploads a file-only archive and validation metadata to temporary VPS
paths, verifies their checksums, and safely extracts a unique release under
`/var/www/usaige/releases/<UTC timestamp>-<id>-usaige-<version>-build<build>.<suffix>/`.
Files are root-owned with group `www-data`, directories have mode `0755`, and
regular files have mode `0644`. A deployment lock prevents concurrent static
activation. The script copies valid earlier `usAIge-*-alpha.dmg` and `.sha256`
pairs into the new release, preserving download URLs already held by older
clients. It rejects a lower update build and replacement of an existing release
filename with different bytes. Existing release directories remain available
for rollback.

Activation atomically replaces `/var/www/usaige/current` with a symlink to the
new release. The existing Nginx configuration already aliases
`/project/usaige/` to that directory; this script changes no Nginx configuration.
It checks every uploaded file through local TLS with the real `pmrichq.com`
hostname, compares the served hashes and manifest, and requires healthy JSON
from `/project/usaige/api/v1/health`. A failed server-side check restores the
previous site symlink; on a first deployment it removes the failed current link.
The failed release remains for inspection.

After server activation, a separate external request must return the exact
signed manifest, and the public relay health request must succeed. An external
DNS/network failure causes the command to fail while leaving the locally
verified server release active. Check network routing before deciding to roll
back that release.

The script does not prune releases. Keep historical downloads reachable when
planning disk cleanup; old versions of the app can hold earlier manifest URLs.

## Publish GitHub assets and verify the release

After the PR is merged and required checks pass, create the tag/release against
the exact merged commit. Use a release body file to preserve prose and newlines.
For version 0.2.17, the native assets are:

```text
dist/usAIge-0.2.17-alpha.dmg
dist/usAIge-0.2.17-alpha.dmg.sha256
```

If attaching a website archive as a release asset, archive the contents of
`site/out/project/usaige/` and include its own SHA-256 sidecar. A GitHub release
does not activate the VPS website/update feed; run the static deployment script
for that publication step.

Verify the GitHub release tag commit and asset digests, the public homepage
version/download/checksum links, the public signed `update.json`, the actual
downloaded DMG hash, and relay health. Retain the exact version/build, commit,
release URL, activated VPS directory, and verification results as evidence.
The current packaging process uses an ad-hoc macOS signature; publication does
not establish Developer ID notarization or an installed-client update test.
