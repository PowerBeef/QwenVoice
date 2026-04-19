#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

APP_PATH="${1:-$PROJECT_DIR/build/QwenVoice.app}"
DMG_BASENAME="${2:-Vocello-macos26}"
DISPLAY_NAME="${QWENVOICE_DMG_DISPLAY_NAME:-Vocello}"
DMG_OUTPUT="$PROJECT_DIR/build/${DMG_BASENAME}.dmg"

echo "=== Vocello: Create DMG ==="
echo ""

if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at $APP_PATH" >&2
    echo "Usage: $0 [/path/to/QwenVoice.app|/path/to/Vocello.app] [dmg_basename]" >&2
    exit 1
fi

if [[ "$DMG_BASENAME" == *"/"* ]]; then
    echo "Error: DMG basename must not contain path separators: $DMG_BASENAME" >&2
    exit 1
fi

mkdir -p "$PROJECT_DIR/build"
rm -f "$DMG_OUTPUT"

echo "[1/3] Creating DMG staging directory..."
STAGING_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

cp -a "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "[2/3] Building compressed DMG..."
hdiutil create \
    -volname "$DISPLAY_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDBZ \
    "$DMG_OUTPUT"

echo "[3/3] DMG created"
echo ""
echo "  DMG: $DMG_OUTPUT"
