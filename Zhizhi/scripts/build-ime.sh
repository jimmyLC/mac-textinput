#!/bin/bash
# Builds Zhizhi.app (development, signed with a fixed local identity when one exists (scripts/sign-identity.sh), else ad-hoc) into Zhizhi/.build/Zhizhi.app.
set -euo pipefail
SIGN_ID="$("$(dirname "$0")/sign-identity.sh")"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$HERE"
swift build -c release --product Zhizhi
APP="$HERE/.build/Zhizhi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Zhizhi "$APP/Contents/MacOS/Zhizhi"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Every build gets its own number, so the App can tell whether the installed copy is older.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M%S)" "$APP/Contents/Info.plist"
cp -R Resources/zh-Hant.lproj Resources/Base.lproj "$APP/Contents/Resources/"
cp "$ROOT/data/chinese-lexicon.tsv" "$ROOT/data/english-words.txt" "$APP/Contents/Resources/"
# Word pairs (from Chinese Wikipedia, CC BY-SA 4.0) packed for a fast load.
swift build -c release --product zhizhi-eval
.build/release/zhizhi-eval "$ROOT" pairs "$APP/Contents/Resources/chinese-pairs.bin"
swift scripts/make-icon.swift assets/icon.svg "$APP/Contents/Resources/Zhizhi.tiff"

# The local-AI helper needs Xcode, which compiles MLX's GPU shaders. Typing works without it.
PRODUCTS="$HERE/AI/.build/xc/Build/Products/Release"
if (cd AI && xcodebuild -scheme ZhizhiAI -configuration Release -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath .build/xc -skipPackagePluginValidation -quiet build) && [ -x "$PRODUCTS/zhizhi-ai" ]; then
    mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/licenses"
    cp "$PRODUCTS/zhizhi-ai" "$APP/Contents/Helpers/"
    cp -R "$PRODUCTS/mlx-swift_Cmlx.bundle" "$APP/Contents/Helpers/"
    for package in mlx-swift swift-transformers; do
        cp "$HERE/AI/.build/checkouts/$package/LICENSE"* "$APP/Contents/Resources/licenses/$package-LICENSE.txt" 2>/dev/null || true
    done
    cp THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/licenses/"
    codesign --force --sign "$SIGN_ID" "$APP/Contents/Helpers/zhizhi-ai"
else
    echo "warning: local-AI helper not built; the input method will work without AI corrections" >&2
fi

codesign --force --deep --sign "$SIGN_ID" "$APP"
plutil -lint "$APP/Contents/Info.plist"
echo "Built $APP"
