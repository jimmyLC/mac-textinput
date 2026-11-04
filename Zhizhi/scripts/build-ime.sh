#!/bin/bash
# Builds Zhizhi.app (development, ad-hoc signed) into Zhizhi/.build/Zhizhi.app.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$HERE"
swift build -c release --product Zhizhi
APP="$HERE/.build/Zhizhi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Zhizhi "$APP/Contents/MacOS/Zhizhi"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/zh-Hant.lproj Resources/Base.lproj "$APP/Contents/Resources/"
cp "$ROOT/data/chinese-lexicon.tsv" "$ROOT/data/english-words.txt" "$APP/Contents/Resources/"
swift scripts/make-icon.swift assets/icon.svg "$APP/Contents/Resources/Zhizhi.tiff"
codesign --force --deep --sign - "$APP"
plutil -lint "$APP/Contents/Info.plist"
echo "Built $APP"
