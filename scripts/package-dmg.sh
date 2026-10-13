#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

headless=false
template=""
while (( $# > 0 )); do
    case "$1" in
        --headless) headless=true; shift ;;
        --template)
            (( $# >= 2 )) || { echo "--template requires an existing trusted DMG" >&2; exit 2; }
            template="$2"; shift 2 ;;
        --help)
            echo "Usage: $0 [--headless --template /path/to/trusted-previous.dmg]"
            exit 0 ;;
        *) echo "Unknown packaging argument: $1" >&2; exit 2 ;;
    esac
done
if $headless; then
    [[ -n "$template" && -f "$template" ]] || { echo "Headless packaging requires --template with a trusted existing DMG" >&2; exit 2; }
    template="${template:A}"
elif [[ -n "$template" ]]; then
    echo "--template requires --headless" >&2
    exit 2
fi

app="${USAIGE_APP_OUTPUT_PATH:-$root/dist/usAIge.app}"
"$root/scripts/package-app.sh"
app="${app:A}"
test -x "$app/Contents/MacOS/usAIge"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/UsageHUD/Resources/Info.plist)-alpha"
name="usAIge-$version"
release_notes_file="$root/Sources/UsageHUD/Resources/ReleaseNotes.json"
[[ "$(/usr/bin/jq -r '.version' "$release_notes_file")-alpha" == "$version" ]]
[[ "$(/usr/bin/jq -r '.build' "$release_notes_file")" == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Sources/UsageHUD/Resources/Info.plist)" ]]
dmg="$root/dist/$name.dmg"
checksum="$dmg.sha256"
stage="$(mktemp -d "${TMPDIR:-/tmp}/usaige-dmg.XXXXXX")"
mount="$(mktemp -d "${TMPDIR:-/tmp}/usaige-mount.XXXXXX")"
work="$(mktemp -d "${TMPDIR:-/tmp}/usaige-dmg-work.XXXXXX")"
rw_dmg="$work/$name-rw.dmg"
verified_dmg="$work/$name.dmg"
swift_helper_arguments=(-module-cache-path "${SWIFT_MODULECACHE_PATH:-$work/swift-module-cache}")
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

if $headless; then
    # Snapshot the template before touching the final output, even if the
    # template path happens to be the final release filename.
    hdiutil convert "$template" -ov -format UDRW -o "$rw_dmg" -quiet
    hdiutil attach -readwrite -nobrowse -noautoopen -mountpoint "$mount" "$rw_dmg" -quiet
    mounted=true
    test -f "$mount/.background/install.png"
    test -f "$mount/.DS_Store"
    test -f "$mount/Applications"
    python3 "$root/scripts/stage-dmg-app.py" "$app" "$mount/usAIge.app"
    xattr -cr "$mount/usAIge.app"
    test -x "$mount/usAIge.app/Contents/MacOS/usAIge"
    cmp "$app/Contents/MacOS/usAIge" "$mount/usAIge.app/Contents/MacOS/usAIge"
else
python3 "$root/scripts/stage-dmg-app.py" "$app" "$stage/usAIge.app"
test -x "$stage/usAIge.app/Contents/MacOS/usAIge"
xattr -cr "$stage/usAIge.app"
# Use a native Finder alias instead of a bare symbolic link. Finder can render
# the symlink as an empty placeholder inside a dark-mode disk image, while the
# alias carries the target's Applications-folder icon metadata with it.
osascript \
    -e "tell application \"Finder\" to make new alias file at POSIX file \"$stage\" to POSIX file \"/Applications\" with properties {name:\"Applications\"}" \
    >/dev/null
swift "${swift_helper_arguments[@]}" "$root/scripts/prepare-dmg-assets.swift" \
    "$stage/Applications" \
    "$stage/.background/install.png"
chflags hidden "$stage/.background"
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
fi
sync
detach_mount

hdiutil convert "$rw_dmg" -ov -format UDZO -o "$verified_dmg" -quiet

hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount" "$verified_dmg" -quiet
mounted=true
test -x "$mount/usAIge.app/Contents/MacOS/usAIge"
cmp "$app/Contents/MacOS/usAIge" "$mount/usAIge.app/Contents/MacOS/usAIge"
test -f "$mount/Applications"
[[ "$(file -b "$mount/Applications")" == "MacOS Alias file" ]]
xattr -p com.apple.FinderInfo "$mount/Applications" >/dev/null
xattr -p com.apple.ResourceFork "$mount/Applications" >/dev/null
test -f "$mount/.background/install.png"
test -f "$mount/.DS_Store"
resolved_applications="$(swift "${swift_helper_arguments[@]}" "$root/scripts/resolve-dmg-alias.swift" "$mount/Applications")"
[[ "$resolved_applications" == "/Applications/" ]]
plutil -lint "$mount/usAIge.app/Contents/Info.plist"
codesign --verify --deep --strict "$mount/usAIge.app"
detach_mount
mv -f "$verified_dmg" "$dmg"

(
    cd dist
    shasum -a 256 "$name.dmg" > "$name.dmg.sha256"
)

site_public="$root/site/public"
if [[ -d "$site_public" ]]; then
    digest="$(shasum -a 256 "$dmg" | awk '{print $1}')"
    release_notes="$(/usr/bin/jq -c '.releaseNotes' "$release_notes_file")"
    cp "$dmg" "$site_public/$name.dmg"
    cp "$checksum" "$site_public/$name.dmg.sha256"
    /usr/bin/printf '{\n  "version": "%s",\n  "build": %s,\n  "minimumSystemVersion": "%s",\n  "downloadURL": "https://pmrichq.com/project/usaige/%s.dmg",\n  "sha256": "%s",\n  "releaseNotes": %s\n}\n' \
        "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/UsageHUD/Resources/Info.plist)" \
        "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Sources/UsageHUD/Resources/Info.plist)" \
        "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Sources/UsageHUD/Resources/Info.plist)" \
        "$name" \
        "$digest" \
        "$release_notes" \
        > "$site_public/update.json"
    signing_key="$HOME/.config/usaige/update-signing-key"
    if [[ -f "$signing_key" ]]; then
        swift "${swift_helper_arguments[@]}" "$root/scripts/sign-update-manifest.swift" "$site_public/update.json"
    else
        echo "warning: no update signing key at $signing_key; update.json is unsigned" >&2
        echo "         run scripts/generate-update-signing-key.swift once on the release Mac" >&2
    fi
    # Only the current release ships in the repo; the previous DMG is removed
    # so the tree does not grow by one disk image per release.
    find "$site_public" -maxdepth 1 -name 'usAIge-*-alpha.dmg*' ! -name "$name.dmg*" -delete
fi

echo "$dmg"
echo "$checksum"
