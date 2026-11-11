#!/bin/bash
# Puts the built App in /Applications, replacing only an earlier copy of itself (also the old name 知之.app).
# The input method is installed from inside the App, by its 安裝 or 更新 button.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$HERE/.build/知之輸入法.app"
DEST="/Applications/知之輸入法.app"
OLD="/Applications/知之.app"
[ -d "$SOURCE" ] || "$HERE/scripts/build-app.sh"
for existing in "$OLD" "$DEST"; do
    [ -d "$existing" ] || continue
    ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$existing/Contents/Info.plist")"
    [ "$ID" = "com.jimmylc.Zhizhi" ] || { echo "refusing to replace $existing: it is $ID" >&2; exit 1; }
    pkill -x ZhizhiApp 2>/dev/null || true
    rm -rf "$existing"
done
cp -R "$SOURCE" "$DEST"
echo "Installed $DEST"
