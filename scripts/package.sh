#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

echo "Packaging TranslateAnywhere..."

# Rebuild everything for Release
echo "[1/4] Building third-party (if needed)..."
"$SCRIPT_DIR/build_thirdparty_universal.sh"

echo "[2/4] Building core (Release)..."
"$SCRIPT_DIR/build_core_universal.sh"

echo "[3/4] Building app (Release, universal2)..."
xcodebuild -project "$ROOT/App/TranslateAnywhere.xcodeproj" \
    -scheme TranslateAnywhere \
    -configuration Release \
    -arch arm64 -arch x86_64 \
    ONLY_ACTIVE_ARCH=NO \
    build

# Find the app
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "TranslateAnywhere.app" -path "*/Release/*" -maxdepth 5 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    echo "ERROR: Could not find built app"
    exit 1
fi

echo "=== App binary ==="
lipo -info "$APP_PATH/Contents/MacOS/TranslateAnywhere"

echo "[4/4] Creating DMG..."
mkdir -p "$ROOT/dist"
DMG_PATH="$ROOT/dist/TranslateAnywhere.dmg"
rm -f "$DMG_PATH"

STAGING="$ROOT/dist/staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "TranslateAnywhere" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING"
echo ""
echo "DMG created: $DMG_PATH"
ls -lh "$DMG_PATH"
