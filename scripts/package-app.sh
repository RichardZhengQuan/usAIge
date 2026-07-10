#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build -c release

app="$root/dist/Usage HUD.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/.build/release/UsageHUD" "$app/Contents/MacOS/UsageHUD"
cp "$root/Sources/UsageHUD/Resources/Info.plist" "$app/Contents/Info.plist"

plutil -lint "$app/Contents/Info.plist"
test -x "$app/Contents/MacOS/UsageHUD"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

echo "$app"
