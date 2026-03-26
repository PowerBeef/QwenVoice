#!/bin/bash
set -euo pipefail

# Unified release script: bundles dependencies, builds Release .app, creates .dmg
# Usage:
#   ./scripts/release.sh              Full pipeline
#   ./scripts/release.sh --skip-deps  Skip Python/ffmpeg bundling (fast rebuild)
#   ./scripts/release.sh --skip-build Skip xcodebuild (repackage existing build)
#   ./scripts/release.sh --ui-profile liquid|legacy
#   ./scripts/release.sh --output-name <dmg_basename>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE_NAME="QwenVoice"
TOTAL_START=$(date +%s)

SKIP_DEPS=false
SKIP_BUILD=false
UI_PROFILE="legacy"
OUTPUT_NAME="QwenVoice"

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-deps)
            SKIP_DEPS=true
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --ui-profile)
            if [ $# -lt 2 ]; then
                echo "Error: --ui-profile requires a value (liquid|legacy)"
                exit 1
            fi
            UI_PROFILE="$2"
            shift 2
            ;;
        --output-name)
            if [ $# -lt 2 ]; then
                echo "Error: --output-name requires a value"
                exit 1
            fi
            OUTPUT_NAME="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--skip-deps] [--skip-build] [--ui-profile liquid|legacy] [--output-name <basename>]"
            exit 1
            ;;
    esac
done

case "$UI_PROFILE" in
    liquid)
        UI_SWIFT_DEFINE="QW_UI_LIQUID"
        ;;
    legacy)
        UI_SWIFT_DEFINE="QW_UI_LEGACY_GLASS"
        ;;
    *)
        echo "Error: unsupported --ui-profile '$UI_PROFILE' (expected liquid|legacy)"
        exit 1
        ;;
esac

if [[ "$OUTPUT_NAME" == *"/"* ]]; then
    echo "Error: --output-name must not contain path separators"
    exit 1
fi

step_time() {
    local start=$1
    local end=$(date +%s)
    echo "$((end - start))s"
}

release_fail() {
    echo "Error: $*" >&2
    exit 1
}

echo "=== QwenVoice: Release Build ==="
echo ""
if $SKIP_DEPS; then echo "  (skipping dependency bundling)"; fi
if $SKIP_BUILD; then echo "  (skipping xcodebuild)"; fi
echo "  ui profile: $UI_PROFILE ($UI_SWIFT_DEFINE)"
echo "  dmg output: $OUTPUT_NAME.dmg"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Bundle Python
# ---------------------------------------------------------------------------
STEP_START=$(date +%s)
if $SKIP_DEPS; then
    echo "[1/8] Bundle Python — skipped (--skip-deps)"
else
    echo "[1/8] Bundling Python..."
    "$SCRIPT_DIR/bundle_python.sh"
    echo ""
    echo "[1/8] Bundle Python — done ($(step_time $STEP_START))"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 2: Bundle ffmpeg
# ---------------------------------------------------------------------------
STEP_START=$(date +%s)
if $SKIP_DEPS; then
    echo "[2/8] Bundle ffmpeg — skipped (--skip-deps)"
else
    echo "[2/8] Bundling ffmpeg..."
    "$SCRIPT_DIR/bundle_ffmpeg.sh"
    echo ""
    echo "[2/8] Bundle ffmpeg — done ($(step_time $STEP_START))"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 3: Build Release
# ---------------------------------------------------------------------------
STEP_START=$(date +%s)
if $SKIP_BUILD; then
    echo "[3/8] Build Release — skipped (--skip-build)"
else
    # Clean build directory (only when actually building)
    if ! $SKIP_DEPS; then
        rm -rf "$BUILD_DIR"
    fi
    mkdir -p "$BUILD_DIR"

    echo "[3/8] Regenerating Xcode project..."
    "$SCRIPT_DIR/regenerate_project.sh"
    echo ""

    echo "[3/8] Building Release with xcodebuild..."
    cd "$PROJECT_DIR"
    xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice \
        -configuration Release \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS="$UI_SWIFT_DEFINE" \
        build | tail -5

    echo ""
    echo "[3/8] Build Release — done ($(step_time $STEP_START))"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 4: Copy .app from DerivedData
# ---------------------------------------------------------------------------
STEP_START=$(date +%s)
echo "[4/8] Copying .app from DerivedData..."

if $SKIP_BUILD; then
    # When skipping build, the .app should already be in build/
    if [ ! -d "$BUILD_DIR/$APP_BUNDLE_NAME.app" ]; then
        echo "Error: No .app found at $BUILD_DIR/$APP_BUNDLE_NAME.app"
        echo "Run without --skip-build first."
        exit 1
    fi
        echo "[4/8] Copy .app — skipped (using existing build/$APP_BUNDLE_NAME.app)"
else
    # Resolve BUILT_PRODUCTS_DIR from xcodebuild
    cd "$PROJECT_DIR"
    BUILT_PRODUCTS_DIR=$(xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice \
        -configuration Release \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS="$UI_SWIFT_DEFINE" \
        -showBuildSettings 2>/dev/null \
        | grep '^\s*BUILT_PRODUCTS_DIR' \
        | sed 's/.*= //')

    if [ -z "$BUILT_PRODUCTS_DIR" ]; then
        echo "Error: Could not determine BUILT_PRODUCTS_DIR from xcodebuild"
        exit 1
    fi

    APP_SOURCE="$BUILT_PRODUCTS_DIR/$APP_BUNDLE_NAME.app"
    if [ ! -d "$APP_SOURCE" ]; then
        echo "Error: Built .app not found at: $APP_SOURCE"
        exit 1
    fi

    mkdir -p "$BUILD_DIR"
    rm -rf "$BUILD_DIR/$APP_BUNDLE_NAME.app"
    cp -a "$APP_SOURCE" "$BUILD_DIR/$APP_BUNDLE_NAME.app"
fi

# Inject bundled Python and ffmpeg into the .app (excluded from Xcode build to avoid conflicts)
RESOURCES_SRC="$PROJECT_DIR/Sources/Resources"
APP_RESOURCES="$BUILD_DIR/$APP_BUNDLE_NAME.app/Contents/Resources"

if [ -d "$RESOURCES_SRC/python" ]; then
    echo "[4/8] Copying bundled Python into .app..."
    rm -rf "$APP_RESOURCES/python"
    cp -a "$RESOURCES_SRC/python" "$APP_RESOURCES/python"
else
    release_fail "Bundled Python missing at $RESOURCES_SRC/python"
fi

if [ -f "$RESOURCES_SRC/ffmpeg" ]; then
    echo "[4/8] Copying bundled ffmpeg into .app..."
    cp -f "$RESOURCES_SRC/ffmpeg" "$APP_RESOURCES/ffmpeg"
else
    release_fail "Bundled ffmpeg missing at $RESOURCES_SRC/ffmpeg"
fi

echo "[4/8] Removing build-only resource artifacts..."
rm -rf "$APP_RESOURCES/vendor" 2>/dev/null || true
find "$APP_RESOURCES" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$APP_RESOURCES" -name "*.pyc" -delete 2>/dev/null || true
find "$APP_RESOURCES" -name "*.whl" -delete 2>/dev/null || true

[ -d "$APP_RESOURCES/python" ] || release_fail "Packaged app is missing Contents/Resources/python"
[ -f "$APP_RESOURCES/python/.qwenvoice-runtime-manifest.json" ] || release_fail "Packaged app is missing the bundled runtime manifest"
[ -x "$APP_RESOURCES/ffmpeg" ] || release_fail "Packaged app is missing an executable bundled ffmpeg binary"
if [ ! -f "$APP_RESOURCES/server.py" ] && [ ! -f "$APP_RESOURCES/backend/server.py" ]; then
    release_fail "Packaged app is missing the bundled backend entrypoint"
fi

echo "[4/8] Copy .app + deps — done ($(step_time $STEP_START))"
echo ""

# ---------------------------------------------------------------------------
# Step 5: Re-sign final app bundle
# ---------------------------------------------------------------------------
STEP_START=$(date +%s)
echo "[5/8] Re-signing final app bundle..."

if [ -f "$APP_RESOURCES/ffmpeg" ]; then
    codesign --force --sign - "$APP_RESOURCES/ffmpeg"
fi

for py_bin in "$APP_RESOURCES"/python/bin/python3.*; do
    if [ -f "$py_bin" ] && [ -x "$py_bin" ]; then
        codesign --force --sign - "$py_bin"
    fi
done

while IFS= read -r -d '' native_file; do
    codesign --force --sign - "$native_file"
done < <(find "$APP_RESOURCES/python" -type f \( -name "*.so" -o -name "*.dylib" \) -print0 2>/dev/null)

codesign --force --sign - \
    --deep \
    --options runtime \
    --preserve-metadata=entitlements,requirements,flags \
    "$BUILD_DIR/$APP_BUNDLE_NAME.app"

echo ""

echo "Verifying code signature..."
codesign -v --deep --strict "$BUILD_DIR/$APP_BUNDLE_NAME.app"
echo "Code signature verified."

echo ""
echo "[5/8] Re-sign final app bundle — done ($(step_time $STEP_START))"
echo ""

# ---------------------------------------------------------------------------
# Step 6: Verify bundle
# ---------------------------------------------------------------------------
STEP_START=$(date +%s)
echo "[6/8] Verifying bundled runtime..."
"$SCRIPT_DIR/verify_release_bundle.sh" "$BUILD_DIR/$APP_BUNDLE_NAME.app"
echo ""
echo "[6/8] Verify bundle — done ($(step_time $STEP_START))"
echo ""

# ---------------------------------------------------------------------------
# Step 7: Create DMG
# ---------------------------------------------------------------------------
STEP_START=$(date +%s)
echo "[7/8] Creating DMG..."
DMG_NAME="$OUTPUT_NAME" "$SCRIPT_DIR/create_dmg.sh" "$BUILD_DIR/$APP_BUNDLE_NAME.app"
echo ""
echo "[7/8] Create DMG — done ($(step_time $STEP_START))"
echo ""

# ---------------------------------------------------------------------------
# Step 8: Report
# ---------------------------------------------------------------------------
TOTAL_ELAPSED=$(( $(date +%s) - TOTAL_START ))
DMG_PATH="$BUILD_DIR/${OUTPUT_NAME}.dmg"
DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
APP_SIZE=$(du -sh "$BUILD_DIR/$APP_BUNDLE_NAME.app" | cut -f1)

APP_BINARY="$BUILD_DIR/$APP_BUNDLE_NAME.app/Contents/MacOS/$APP_BUNDLE_NAME"
extract_otool_field() {
    local field="$1"
    otool -l "$APP_BINARY" | awk -v key="$field" '
        $1 == "cmd" && $2 == "LC_BUILD_VERSION" { in_block = 1; next }
        in_block && $1 == key { print $2; exit }
    '
}

APP_MINOS="$(extract_otool_field minos)"
SDK_VERSION="$(extract_otool_field sdk)"
if [ -z "$APP_MINOS" ] || [ -z "$SDK_VERSION" ]; then
    echo "Error: failed to extract app minOS/SDK from $APP_BINARY"
    exit 1
fi

XCODE_VERSION="$(xcodebuild -version | awk 'NR==1 {print $2}')"
if [ -z "$XCODE_VERSION" ]; then
    echo "Error: failed to detect Xcode version"
    exit 1
fi

COMMIT_SHA="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || true)"
if [ -z "$COMMIT_SHA" ]; then
    COMMIT_SHA="unknown"
fi

MANIFEST_PATH="$BUILD_DIR/$APP_BUNDLE_NAME.app/Contents/Resources/python/.qwenvoice-runtime-manifest.json"
if [ ! -f "$MANIFEST_PATH" ]; then
    echo "Error: release manifest missing at $MANIFEST_PATH"
    exit 1
fi

CORE_VERSIONS="$(
python3 - "$MANIFEST_PATH" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
fields = [
    "mlx_version",
    "mlx_metal_version",
    "mlx_lm_version",
    "mlx_audio_version",
    "transformers_version",
]
for field in fields:
    value = manifest.get(field)
    if not value:
        raise SystemExit(f"Missing {field} in runtime manifest")
    print(f"{field}={value}")
PY
)"

METADATA_PATH="$BUILD_DIR/release-metadata.txt"
{
    echo "commit_sha=$COMMIT_SHA"
    echo "ui_profile=$UI_PROFILE"
    echo "xcode_version=$XCODE_VERSION"
    echo "sdk_version=$SDK_VERSION"
    echo "app_minos=$APP_MINOS"
    echo "dmg_name=$OUTPUT_NAME.dmg"
    echo "built_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf '%s\n' "$CORE_VERSIONS"
} > "$METADATA_PATH"

echo "[8/8] Release complete!"
echo ""
echo "  App:  $BUILD_DIR/$APP_BUNDLE_NAME.app  ($APP_SIZE)"
echo "  DMG:  $DMG_PATH  ($DMG_SIZE)"
echo "  Metadata: $METADATA_PATH"
echo ""
echo "  Total time: ${TOTAL_ELAPSED}s"
echo ""
echo "To test:"
echo "  open '$BUILD_DIR/$APP_BUNDLE_NAME.app'"
echo "  open '$DMG_PATH'"
