#!/bin/bash
set -euo pipefail

# Unified release script: bundles dependencies, builds Release .app, creates .dmg
# Usage:
#   ./scripts/release.sh              Full pipeline
#   ./scripts/release.sh --skip-deps  Skip Python/ffmpeg bundling (fast rebuild)
#   ./scripts/release.sh --skip-build Skip xcodebuild (repackage existing build)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
TOTAL_START=$(date +%s)

SKIP_DEPS=false
SKIP_BUILD=false

for arg in "$@"; do
    case "$arg" in
        --skip-deps)  SKIP_DEPS=true ;;
        --skip-build) SKIP_BUILD=true ;;
        *)
            echo "Unknown option: $arg"
            echo "Usage: $0 [--skip-deps] [--skip-build]"
            exit 1
            ;;
    esac
done

step_time() {
    local start=$1
    local end=$(date +%s)
    echo "$((end - start))s"
}

echo "=== Qwen Voice: Release Build ==="
echo ""
if $SKIP_DEPS; then echo "  (skipping dependency bundling)"; fi
if $SKIP_BUILD; then echo "  (skipping xcodebuild)"; fi
echo ""

# ---------------------------------------------------------------------------
# Step 1: Bundle Python
# ---------------------------------------------------------------------------
STEP_START=$(date +%s)
if $SKIP_DEPS; then
    echo "[1/6] Bundle Python — skipped (--skip-deps)"
else
    echo "[1/6] Bundling Python..."
    "$SCRIPT_DIR/bundle_python.sh"
    echo ""
    echo "[1/6] Bundle Python — done ($(step_time $STEP_START))"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 2: Bundle ffmpeg
# ---------------------------------------------------------------------------
STEP_START=$(date +%s)
if $SKIP_DEPS; then
    echo "[2/6] Bundle ffmpeg — skipped (--skip-deps)"
else
    echo "[2/6] Bundling ffmpeg..."
    "$SCRIPT_DIR/bundle_ffmpeg.sh"
    echo ""
    echo "[2/6] Bundle ffmpeg — done ($(step_time $STEP_START))"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 3: Build Release
# ---------------------------------------------------------------------------
STEP_START=$(date +%s)
if $SKIP_BUILD; then
    echo "[3/6] Build Release — skipped (--skip-build)"
else
    # Clean build directory (only when actually building)
    if ! $SKIP_DEPS; then
        rm -rf "$BUILD_DIR"
    fi
    mkdir -p "$BUILD_DIR"

    echo "[3/6] Regenerating Xcode project..."
    "$SCRIPT_DIR/regenerate_project.sh"
    echo ""

    echo "[3/6] Building Release with xcodebuild..."
    cd "$PROJECT_DIR"
    xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice \
        -configuration Release \
        CODE_SIGN_IDENTITY="-" \
        build | tail -5

    echo ""
    echo "[3/6] Build Release — done ($(step_time $STEP_START))"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 4: Copy .app from DerivedData
# ---------------------------------------------------------------------------
STEP_START=$(date +%s)
echo "[4/6] Copying .app from DerivedData..."

if $SKIP_BUILD; then
    # When skipping build, the .app should already be in build/
    if [ ! -d "$BUILD_DIR/Qwen Voice.app" ]; then
        echo "Error: No .app found at $BUILD_DIR/Qwen Voice.app"
        echo "Run without --skip-build first."
        exit 1
    fi
    echo "[4/6] Copy .app — skipped (using existing build/Qwen Voice.app)"
else
    # Resolve BUILT_PRODUCTS_DIR from xcodebuild
    cd "$PROJECT_DIR"
    BUILT_PRODUCTS_DIR=$(xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice \
        -configuration Release \
        -showBuildSettings 2>/dev/null \
        | grep '^\s*BUILT_PRODUCTS_DIR' \
        | sed 's/.*= //')

    if [ -z "$BUILT_PRODUCTS_DIR" ]; then
        echo "Error: Could not determine BUILT_PRODUCTS_DIR from xcodebuild"
        exit 1
    fi

    APP_SOURCE="$BUILT_PRODUCTS_DIR/Qwen Voice.app"
    if [ ! -d "$APP_SOURCE" ]; then
        echo "Error: Built .app not found at: $APP_SOURCE"
        exit 1
    fi

    mkdir -p "$BUILD_DIR"
    rm -rf "$BUILD_DIR/Qwen Voice.app"
    cp -a "$APP_SOURCE" "$BUILD_DIR/Qwen Voice.app"
    echo "[4/6] Copy .app — done ($(step_time $STEP_START))"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 5: Create DMG
# ---------------------------------------------------------------------------
STEP_START=$(date +%s)
echo "[5/6] Creating DMG..."
"$SCRIPT_DIR/create_dmg.sh" "$BUILD_DIR/Qwen Voice.app"
echo ""
echo "[5/6] Create DMG — done ($(step_time $STEP_START))"
echo ""

# ---------------------------------------------------------------------------
# Step 6: Report
# ---------------------------------------------------------------------------
TOTAL_ELAPSED=$(( $(date +%s) - TOTAL_START ))
DMG_PATH="$BUILD_DIR/QwenVoice.dmg"
DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
APP_SIZE=$(du -sh "$BUILD_DIR/Qwen Voice.app" | cut -f1)

echo "[6/6] Release complete!"
echo ""
echo "  App:  $BUILD_DIR/Qwen Voice.app  ($APP_SIZE)"
echo "  DMG:  $DMG_PATH  ($DMG_SIZE)"
echo ""
echo "  Total time: ${TOTAL_ELAPSED}s"
echo ""
echo "To test:"
echo "  open '$BUILD_DIR/Qwen Voice.app'"
echo "  open '$DMG_PATH'"
