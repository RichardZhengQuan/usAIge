#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

app="${USAIGE_APP_OUTPUT_PATH:-$root/dist/usAIge.app}"
[[ "$app" == *.app && ! -L "$app" ]] || { echo "App output must be a nonsymlink .app directory" >&2; exit 2; }
app="${app:A}"
if [[ "$app" == "$root/"* && "$app" != "$root/dist/"* ]] || [[ "$app" == /Applications/* || "$app" == /System/* ]]; then
    echo "App output must be a build directory outside repository sources and installed apps" >&2
    exit 2
fi
[[ ! -e "$app" || -d "$app" ]] || { echo "App output is not a directory" >&2; exit 2; }

build_arguments=(build -c release)
build_root="$root/.build"
if [[ -n "${USAIGE_SWIFT_SCRATCH_PATH:-}" ]]; then
    build_root="${USAIGE_SWIFT_SCRATCH_PATH:A}"
    build_arguments+=(--scratch-path "$build_root")
fi
if [[ -n "${USAIGE_SWIFT_CACHE_PATH:-}" ]]; then
    build_arguments+=(--cache-path "${USAIGE_SWIFT_CACHE_PATH:A}")
fi
if [[ -n "${USAIGE_SWIFT_SCRATCH_PATH:-}${USAIGE_SWIFT_CACHE_PATH:-}" ]]; then
    build_arguments+=(--disable-sandbox)
fi
swift "${build_arguments[@]}"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/ThirdPartyNotices"
cp "$build_root/release/usAIge" "$app/Contents/MacOS/usAIge"
cp "$root/Sources/UsageHUD/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Sources/UsageHUD/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$root/Sources/UsageHUD/Resources/ReleaseNotes.json" "$app/Contents/Resources/ReleaseNotes.json"
cp -R "$root/Sources/UsageHUD/Resources/ToolMarks" "$app/Contents/Resources/ToolMarks"
cp "$root/Sources/CZstd/LICENSE.txt" "$app/Contents/Resources/ThirdPartyNotices/Zstandard.txt"

plutil -lint "$app/Contents/Info.plist"
test -x "$app/Contents/MacOS/usAIge"
test -s "$app/Contents/Resources/AppIcon.icns"
test -s "$app/Contents/Resources/ReleaseNotes.json"
test -s "$app/Contents/Resources/ThirdPartyNotices/Zstandard.txt"
for mark in claude cursor grok; do test -s "$app/Contents/Resources/ToolMarks/$mark.png"; done
xattr -cr "$app"
codesign --force --sign - "$app"
xattr -cr "$app"
codesign --verify --deep --strict "$app"

echo "$app"
