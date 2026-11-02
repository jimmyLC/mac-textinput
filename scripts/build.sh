#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/scripts/prepare_upstream.py"
xcodebuild -project "$ROOT/.build/McBopomofo/McBopomofo.xcodeproj" \
  -scheme McBopomofo -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$ROOT/.build/DerivedData" CODE_SIGNING_ALLOWED=NO build
mkdir -p "$ROOT/.build/products"
rm -rf "$ROOT/.build/products/ZhuyinLM.app"
ditto "$ROOT/.build/DerivedData/Build/Products/Debug/McBopomofo.app" "$ROOT/.build/products/ZhuyinLM.app"
codesign --force --deep --sign - "$ROOT/.build/products/ZhuyinLM.app"
codesign --verify --deep --strict "$ROOT/.build/products/ZhuyinLM.app"
python3 "$ROOT/scripts/check_build.py"
printf 'Development build: %s\n' "$ROOT/.build/products/ZhuyinLM.app"
