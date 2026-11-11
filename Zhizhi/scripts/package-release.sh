#!/bin/bash
# Packages the built App into Zhizhi-macos.dmg and prints its releases.json entry.
# Usage: scripts/package-release.sh   (build first with scripts/build-app.sh; output goes to .build/release/)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HERE/.build/知之輸入法.app"
[ -d "$APP" ] || { echo "build the App first: scripts/build-app.sh" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUT="$HERE/.build/release/v$VERSION"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
rm -rf "$OUT"; mkdir -p "$OUT"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "知之輸入法" -srcfolder "$STAGE" -ov -format UDZO "$OUT/Zhizhi-macos.dmg"
codesign --verify --deep --strict "$APP"
BYTES="$(stat -f %z "$OUT/Zhizhi-macos.dmg")"
SHA="$(shasum -a 256 "$OUT/Zhizhi-macos.dmg" | cut -d' ' -f1)"
echo "$SHA  Zhizhi-macos.dmg" > "$OUT/SHA256SUMS.txt"
cat <<JSON
"v$VERSION": { "Zhizhi-macos.dmg": { "name": "Zhizhi-macos.dmg", "bytes": $BYTES, "sha256": "$SHA" } }
JSON
echo "file: $OUT/Zhizhi-macos.dmg" >&2
