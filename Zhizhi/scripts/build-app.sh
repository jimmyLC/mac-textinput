#!/bin/bash
# Builds the unified App with the input method inside it, into Zhizhi/.build/知之.app (development, ad-hoc signed).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
"$HERE/scripts/build-ime.sh"
swift build -c release --product ZhizhiApp

APP="$HERE/.build/知之.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ZhizhiApp "$APP/Contents/MacOS/ZhizhiApp"
cp Resources/App-Info.plist "$APP/Contents/Info.plist"
cp -R .build/Zhizhi.app "$APP/Contents/Resources/Zhizhi.app"

ICONSET="$HERE/.build/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-app-icon.swift assets/icon.svg "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Sign outward only: the input method inside keeps the signature it was built with.
codesign --force --sign - "$APP"
plutil -lint "$APP/Contents/Info.plist"
echo "Built $APP"
