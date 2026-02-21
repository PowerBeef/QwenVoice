#!/bin/bash
set -euo pipefail

# Create a distributable .dmg for Qwen Voice
# Expects the .app to be already built and signed

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

APP_NAME="Qwen Voice"
APP_PATH="${1:-$PROJECT_DIR/build/${APP_NAME}.app}"
DMG_NAME="QwenVoice"
DMG_OUTPUT="$PROJECT_DIR/build/${DMG_NAME}.dmg"
DMG_TEMP="$PROJECT_DIR/build/${DMG_NAME}-temp.dmg"
VOLUME_NAME="$APP_NAME"
DMG_SIZE="500m"

echo "=== Qwen Voice: Create DMG ==="
echo ""

# Verify app exists
if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at: $APP_PATH"
    echo ""
    echo "Usage: $0 [path/to/Qwen Voice.app]"
    echo ""
    echo "Build the app first:"
    echo "  xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice -configuration Release -archivePath build/QwenVoice.xcarchive archive"
    echo "  xcodebuild -exportArchive -archivePath build/QwenVoice.xcarchive -exportOptionsPlist ExportOptions.plist -exportPath build/"
    exit 1
fi

mkdir -p "$PROJECT_DIR/build"

# Clean up previous
rm -f "$DMG_OUTPUT" "$DMG_TEMP"

echo "[1/4] Creating temporary DMG..."
# Create a temporary DMG
STAGING_DIR=$(mktemp -d)
cp -a "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "[2/4] Building DMG..."
hdiutil create -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov -format UDBZ \
    "$DMG_OUTPUT"

echo "[3/4] Cleaning up..."
rm -rf "$STAGING_DIR"

# Step 4: Report
DMG_SIZE_ACTUAL=$(du -sh "$DMG_OUTPUT" | cut -f1)
echo "[4/4] Done!"
echo ""
echo "DMG created: $DMG_OUTPUT"
echo "Size: $DMG_SIZE_ACTUAL"
echo ""
echo "To notarize for distribution:"
echo "  xcrun notarytool submit '$DMG_OUTPUT' --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --password YOUR_APP_PASSWORD --wait"
echo "  xcrun stapler staple '$DMG_OUTPUT'"
