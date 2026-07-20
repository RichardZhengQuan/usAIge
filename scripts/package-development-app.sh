#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-}"
build="${2:-}"

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || [[ ! "$build" =~ '^[0-9]+$' ]]; then
    echo "usage: $0 <semantic-version> <build-number>" >&2
    exit 64
fi

"$root/scripts/package-app.sh"

app="$root/dist/usAIge.app"
plist="$app/Contents/Info.plist"
release_notes="$app/Contents/Resources/ReleaseNotes.json"
temporary_notes="$(mktemp "${TMPDIR:-/tmp}/usaige-development-notes.XXXXXX")"
trap 'rm -f "$temporary_notes"' EXIT

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$plist"
/usr/bin/jq \
    --arg version "$version" \
    --argjson build "$build" \
    '.version = $version
     | .build = $build
     | .releaseNotes.summary |= gsub("Version [0-9]+\\.[0-9]+\\.[0-9]+"; "Version \($version)")' \
    "$release_notes" > "$temporary_notes"
mv "$temporary_notes" "$release_notes"

xattr -cr "$app"
codesign --force --sign - "$app"
xattr -cr "$app"
codesign --verify --deep --strict "$app"

echo "$app"
