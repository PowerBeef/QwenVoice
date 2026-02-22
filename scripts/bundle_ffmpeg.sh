#!/bin/bash
set -euo pipefail

# Bundle a static ffmpeg arm64 binary into the app's Resources/
# Target: QwenVoice.app/Contents/Resources/ffmpeg

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESOURCES_DIR="$PROJECT_DIR/QwenVoice/Resources"

FFMPEG_URL="https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip"
DOWNLOAD_DIR="/tmp/qwenvoice-ffmpeg-build"

echo "=== Qwen Voice: Bundle ffmpeg ==="
echo ""

mkdir -p "$DOWNLOAD_DIR"

# Step 1: Download
ZIPFILE="$DOWNLOAD_DIR/ffmpeg.zip"
if [ ! -f "$ZIPFILE" ]; then
    echo "[1/3] Downloading static ffmpeg (arm64)..."
    if ! curl --fail --retry 3 --retry-delay 5 -L -o "$ZIPFILE" "$FFMPEG_URL"; then
        rm -f "$ZIPFILE"
        echo "Error: Failed to download ffmpeg after retries"
        exit 1
    fi
    # Sanity check: ffmpeg zip should be >1MB
    ZIPFILE_SIZE=$(stat -f%z "$ZIPFILE" 2>/dev/null || echo 0)
    if [ "$ZIPFILE_SIZE" -lt 1048576 ]; then
        rm -f "$ZIPFILE"
        echo "Error: Downloaded ffmpeg zip is too small (${ZIPFILE_SIZE} bytes) — likely a failed download"
        exit 1
    fi
else
    echo "[1/3] Using cached ffmpeg download"
fi

# Step 2: Extract
echo "[2/3] Extracting ffmpeg..."
unzip -o -q "$ZIPFILE" -d "$DOWNLOAD_DIR"
FFMPEG_BIN=$(find "$DOWNLOAD_DIR" -name "ffmpeg" -type f | head -1)

if [ -z "$FFMPEG_BIN" ]; then
    echo "Error: ffmpeg binary not found in archive"
    echo ""
    echo "Alternative: copy your system ffmpeg:"
    echo "  cp \$(which ffmpeg) '$RESOURCES_DIR/ffmpeg'"
    exit 1
fi

cp "$FFMPEG_BIN" "$RESOURCES_DIR/ffmpeg"
chmod +x "$RESOURCES_DIR/ffmpeg"

# Step 3: Verify and report
FFMPEG_SIZE=$(du -sh "$RESOURCES_DIR/ffmpeg" | cut -f1)
echo "[3/3] Done!"
echo ""
echo "ffmpeg binary: $RESOURCES_DIR/ffmpeg"
echo "Size: $FFMPEG_SIZE"

# Verify it runs
if "$RESOURCES_DIR/ffmpeg" -version > /dev/null 2>&1; then
    FFMPEG_VERSION=$("$RESOURCES_DIR/ffmpeg" -version | head -1)
    echo "Version: $FFMPEG_VERSION"
else
    echo "Warning: ffmpeg binary may not be compatible with this architecture"
fi

echo ""
echo "To sign for distribution:"
echo "  codesign --force --sign 'Developer ID Application: YOUR_NAME' --options runtime '$RESOURCES_DIR/ffmpeg'"
