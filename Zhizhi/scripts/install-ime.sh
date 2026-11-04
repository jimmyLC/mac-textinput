#!/bin/bash
# Installs the built Zhizhi.app beside the old input method. Touches nothing else:
# it does not enable the input method or change the current input source.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Library/Input Methods/Zhizhi.app"
[ -d "$HERE/.build/Zhizhi.app" ] || "$HERE/scripts/build-ime.sh"
pkill -x Zhizhi 2>/dev/null || true
rm -rf "$DEST"
cp -R "$HERE/.build/Zhizhi.app" "$DEST"
"$DEST/Contents/MacOS/Zhizhi" --register
echo "Installed $DEST"
