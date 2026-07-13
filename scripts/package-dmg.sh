#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

"$root/scripts/package-app.sh"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/UsageHUD/Resources/Info.plist)-alpha"
name="usAIge-$version"
dmg="$root/dist/$name.dmg"
checksum="$dmg.sha256"
stage="$(mktemp -d "${TMPDIR:-/tmp}/usaige-dmg.XXXXXX")"
mount="$(mktemp -d "${TMPDIR:-/tmp}/usaige-mount.XXXXXX")"
mounted=false

cleanup() {
    if $mounted; then
        hdiutil detach "$mount" -quiet || true
    fi
    rm -rf "$stage" "$mount"
}
trap cleanup EXIT

ditto "$root/dist/usAIge.app" "$stage/usAIge.app"
xattr -cr "$stage/usAIge.app"
ln -s /Applications "$stage/Applications"
rm -f "$dmg" "$checksum"

hdiutil create \
    -volname usAIge \
    -srcfolder "$stage" \
    -ov \
    -format UDZO \
    "$dmg"

hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$dmg" -quiet
mounted=true
test -x "$mount/usAIge.app/Contents/MacOS/usAIge"
test -L "$mount/Applications"
plutil -lint "$mount/usAIge.app/Contents/Info.plist"
codesign --verify --deep --strict "$mount/usAIge.app"
hdiutil detach "$mount" -quiet
mounted=false

(
    cd dist
    shasum -a 256 "$name.dmg" > "$name.dmg.sha256"
)

echo "$dmg"
echo "$checksum"
