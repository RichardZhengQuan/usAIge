#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build -c release

app="$root/dist/usAIge.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/.build/release/usAIge" "$app/Contents/MacOS/usAIge"
cp "$root/Sources/UsageHUD/Resources/Info.plist" "$app/Contents/Info.plist"

plutil -lint "$app/Contents/Info.plist"
test -x "$app/Contents/MacOS/usAIge"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

echo "$app"
