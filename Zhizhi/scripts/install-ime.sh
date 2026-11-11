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

# Development: reuse a model already in the Hugging Face cache. Never downloads anything.
MODELS="$HOME/Library/Application Support/Zhizhi/models"
LINK="$MODELS/Qwen2.5-1.5B-4bit"
CACHED="$(ls -d "$HOME"/.cache/huggingface/hub/models--mlx-community--Qwen2.5-1.5B-4bit/snapshots/* 2>/dev/null | head -1 || true)"
if [ ! -e "$LINK" ] && [ -n "$CACHED" ]; then
    mkdir -p "$MODELS"
    ln -s "$CACHED" "$LINK"
    echo "Linked model from the Hugging Face cache"
fi
echo "Installed $DEST"
