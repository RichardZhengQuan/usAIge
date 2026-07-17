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
work="$(mktemp -d "${TMPDIR:-/tmp}/usaige-dmg-work.XXXXXX")"
rw_dmg="$work/$name-rw.dmg"
mounted=false

detach_mount() {
    if ! hdiutil detach "$mount" -quiet; then
        hdiutil detach "$mount" -force -quiet
    fi
    mounted=false
}

cleanup() {
    if $mounted; then
        detach_mount || true
    fi
    rm -rf "$stage" "$mount" "$work"
}
trap cleanup EXIT

ditto "$root/dist/usAIge.app" "$stage/usAIge.app"
xattr -cr "$stage/usAIge.app"
# Use a native Finder alias instead of a bare symbolic link. Finder can render
# the symlink as an empty placeholder inside a dark-mode disk image, while the
# alias carries the target's Applications-folder icon metadata with it.
osascript \
    -e "tell application \"Finder\" to make new alias file at POSIX file \"$stage\" to POSIX file \"/Applications\" with properties {name:\"Applications\"}" \
    >/dev/null
swift "$root/scripts/prepare-dmg-assets.swift" \
    "$stage/Applications" \
    "$stage/.background/install.png"
chflags hidden "$stage/.background"
rm -f "$dmg" "$checksum"

hdiutil create \
    -volname usAIge \
    -srcfolder "$stage" \
    -ov \
    -format UDRW \
    "$rw_dmg"

hdiutil attach -readwrite -noverify -noautoopen -mountpoint "$mount" "$rw_dmg" -quiet
mounted=true
osascript \
    -e "tell application \"Finder\"" \
    -e "set dmgFolder to POSIX file \"$mount\" as alias" \
    -e "open dmgFolder" \
    -e "set dmgWindow to container window of dmgFolder" \
    -e "set current view of dmgWindow to icon view" \
    -e "set toolbar visible of dmgWindow to false" \
    -e "set statusbar visible of dmgWindow to false" \
    -e "set pathbar visible of dmgWindow to false" \
    -e "set bounds of dmgWindow to {160, 140, 820, 540}" \
    -e "set arrangement of icon view options of dmgWindow to not arranged" \
    -e "set icon size of icon view options of dmgWindow to 96" \
    -e "set text size of icon view options of dmgWindow to 14" \
    -e "set label position of icon view options of dmgWindow to bottom" \
    -e "set background picture of icon view options of dmgWindow to file \".background:install.png\" of dmgFolder" \
    -e "set position of item \"usAIge.app\" of dmgFolder to {165, 205}" \
    -e "set position of item \"Applications\" of dmgFolder to {495, 205}" \
    -e "update dmgFolder without registering applications" \
    -e "delay 1" \
    -e "close dmgWindow" \
    -e "end tell"
sync
detach_mount

hdiutil convert "$rw_dmg" -ov -format UDZO -o "$dmg" -quiet

hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$dmg" -quiet
mounted=true
test -x "$mount/usAIge.app/Contents/MacOS/usAIge"
test -f "$mount/Applications"
[[ "$(file -b "$mount/Applications")" == "MacOS Alias file" ]]
xattr -p com.apple.FinderInfo "$mount/Applications" >/dev/null
xattr -p com.apple.ResourceFork "$mount/Applications" >/dev/null
test -f "$mount/.background/install.png"
test -f "$mount/.DS_Store"
resolved_applications="$(osascript \
    -e "tell application \"Finder\" to set targetAlias to (original item of alias file POSIX file \"$mount/Applications\") as alias" \
    -e 'POSIX path of targetAlias')"
[[ "$resolved_applications" == "/Applications/" ]]
plutil -lint "$mount/usAIge.app/Contents/Info.plist"
codesign --verify --deep --strict "$mount/usAIge.app"
detach_mount

(
    cd dist
    shasum -a 256 "$name.dmg" > "$name.dmg.sha256"
)

site_public="$root/site/public"
if [[ -d "$site_public" ]]; then
    digest="$(shasum -a 256 "$dmg" | awk '{print $1}')"
    cp "$dmg" "$site_public/$name.dmg"
    cp "$checksum" "$site_public/$name.dmg.sha256"
    /usr/bin/printf '{\n  "version": "%s",\n  "build": %s,\n  "minimumSystemVersion": "%s",\n  "downloadURL": "https://pmrichq.com/project/usaige/%s.dmg",\n  "sha256": "%s"\n}\n' \
        "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/UsageHUD/Resources/Info.plist)" \
        "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Sources/UsageHUD/Resources/Info.plist)" \
        "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Sources/UsageHUD/Resources/Info.plist)" \
        "$name" \
        "$digest" \
        > "$site_public/update.json"
fi

echo "$dmg"
echo "$checksum"
