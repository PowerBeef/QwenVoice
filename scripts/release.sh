#!/bin/bash
set -euo pipefail

# Unified release script: bundles dependencies, builds Release .app, creates .dmg
# Usage:
#   ./scripts/release.sh              Full pipeline
#   ./scripts/release.sh --skip-deps  Skip Python/ffmpeg bundling (fast rebuild)
#   ./scripts/release.sh --skip-build Skip xcodebuild (repackage existing build)
#   ./scripts/release.sh --ui-profile liquid|legacy
#   ./scripts/release.sh --output-name <dmg_basename>
#   ./scripts/release.sh --signing-mode ad-hoc|developer-id
#   ./scripts/release.sh --signing-identity "Developer ID Application: ..."
#   ./scripts/release.sh --codesign-keychain /path/to/keychain-db

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE_NAME="QwenVoice"
EMBEDDED_RUNTIME_ENTITLEMENTS="$PROJECT_DIR/Sources/QwenVoiceEmbeddedRuntime.entitlements"
TOTAL_START=$(date +%s)

SKIP_DEPS=false
SKIP_BUILD=false
UI_PROFILE="legacy"
OUTPUT_NAME="QwenVoice"
SIGNING_MODE="${QWENVOICE_SIGNING_MODE:-ad-hoc}"
SIGNING_IDENTITY="${QWENVOICE_SIGNING_IDENTITY:-}"
CODESIGN_KEYCHAIN="${QWENVOICE_CODESIGN_KEYCHAIN:-}"

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
        --signing-mode)
            if [ $# -lt 2 ]; then
                echo "Error: --signing-mode requires a value (ad-hoc|developer-id)"
                exit 1
            fi
            SIGNING_MODE="$2"
            shift 2
            ;;
        --signing-identity)
            if [ $# -lt 2 ]; then
                echo "Error: --signing-identity requires a value"
                exit 1
            fi
            SIGNING_IDENTITY="$2"
            shift 2
            ;;
        --codesign-keychain)
            if [ $# -lt 2 ]; then
                echo "Error: --codesign-keychain requires a value"
                exit 1
            fi
            CODESIGN_KEYCHAIN="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--skip-deps] [--skip-build] [--ui-profile liquid|legacy] [--output-name <basename>] [--signing-mode ad-hoc|developer-id] [--signing-identity <identity>] [--codesign-keychain <path>]"
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

case "$SIGNING_MODE" in
    ad-hoc)
        ACTIVE_SIGNING_IDENTITY="-"
        ;;
    developer-id)
        if [ -z "$SIGNING_IDENTITY" ]; then
            echo "Error: --signing-identity is required when --signing-mode developer-id"
            exit 1
        fi
        ACTIVE_SIGNING_IDENTITY="$SIGNING_IDENTITY"
        ;;
    *)
        echo "Error: unsupported --signing-mode '$SIGNING_MODE' (expected ad-hoc|developer-id)"
        exit 1
        ;;
esac

if [ -n "$CODESIGN_KEYCHAIN" ] && [ ! -f "$CODESIGN_KEYCHAIN" ]; then
    echo "Error: --codesign-keychain path does not exist: $CODESIGN_KEYCHAIN"
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

is_macho_file() {
    local target="$1"
    file -b "$target" 2>/dev/null | grep -q "Mach-O"
}

run_codesign() {
    local target="$1"
    shift

    local args=(codesign --force --sign "$ACTIVE_SIGNING_IDENTITY")
    if [ -n "$CODESIGN_KEYCHAIN" ]; then
        args+=(--keychain "$CODESIGN_KEYCHAIN")
    fi
    if [ "$SIGNING_MODE" = "developer-id" ]; then
        args+=(--timestamp)
    fi
    args+=("$@" "$target")
    "${args[@]}"
}

sign_macho_executable() {
    local target="$1"
    shift || true
    [ -f "$target" ] || return 0
    [ -x "$target" ] || return 0
    is_macho_file "$target" || return 0
    run_codesign "$target" "$@"
}

sign_macho_library() {
    local target="$1"
    shift || true
    [ -f "$target" ] || return 0
    is_macho_file "$target" || return 0
    run_codesign "$target" "$@"
}

echo "=== QwenVoice: Release Build ==="
echo ""
if $SKIP_DEPS; then echo "  (skipping dependency bundling)"; fi
if $SKIP_BUILD; then echo "  (skipping xcodebuild)"; fi
echo "  ui profile: $UI_PROFILE ($UI_SWIFT_DEFINE)"
echo "  dmg output: $OUTPUT_NAME.dmg"
echo "  signing: $SIGNING_MODE"
if [ "$SIGNING_MODE" = "developer-id" ]; then
    echo "  signing identity: $SIGNING_IDENTITY"
fi
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
    XCODEBUILD_LOG="$BUILD_DIR/xcodebuild-release.log"
    rm -f "$XCODEBUILD_LOG"

    set +e
    xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice \
        -configuration Release \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS="$UI_SWIFT_DEFINE" \
        build 2>&1 | tee "$XCODEBUILD_LOG"
    XCODEBUILD_STATUS=${PIPESTATUS[0]}
    set -e

    if [ "$XCODEBUILD_STATUS" -ne 0 ]; then
        echo ""
        echo "xcodebuild failed with exit code $XCODEBUILD_STATUS"
        echo "Diagnostic summary from $XCODEBUILD_LOG:"
        if ! grep -E \
            '(^|[^[:alnum:]_])(error:|warning:)|\\.swift:[0-9]+:[0-9]+:|CompileSwift|SwiftCompile|\\*\\* BUILD FAILED \\*\\*|The following build commands failed' \
            "$XCODEBUILD_LOG" | tail -n 200; then
            tail -n 200 "$XCODEBUILD_LOG" || true
        fi
        exit "$XCODEBUILD_STATUS"
    fi

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
"$SCRIPT_DIR/check_backend_resource_contract.sh" --app-bundle "$BUILD_DIR/$APP_BUNDLE_NAME.app"

echo "[4/8] Copy .app + deps — done ($(step_time $STEP_START))"
echo ""

# ---------------------------------------------------------------------------
# Step 5: Re-sign final app bundle
# ---------------------------------------------------------------------------
STEP_START=$(date +%s)
echo "[5/8] Signing bundled executables and final app bundle..."

[ -f "$EMBEDDED_RUNTIME_ENTITLEMENTS" ] || release_fail "Missing embedded runtime entitlements: $EMBEDDED_RUNTIME_ENTITLEMENTS"

if [ -f "$APP_RESOURCES/ffmpeg" ]; then
    sign_macho_executable "$APP_RESOURCES/ffmpeg" --options runtime
fi

while IFS= read -r -d '' py_bin; do
    sign_macho_executable \
        "$py_bin" \
        --options runtime \
        --force-library-entitlements \
        --entitlements "$EMBEDDED_RUNTIME_ENTITLEMENTS"
done < <(find "$APP_RESOURCES/python/bin" -type f -print0 2>/dev/null)

while IFS= read -r -d '' native_file; do
    sign_macho_library "$native_file"
done < <(find "$APP_RESOURCES/python" -type f \( -name "*.so" -o -name "*.dylib" \) -print0 2>/dev/null)

run_codesign "$BUILD_DIR/$APP_BUNDLE_NAME.app" \
    --options runtime \
    --entitlements "$PROJECT_DIR/Sources/QwenVoice.entitlements"

echo ""

echo "Verifying code signature..."
codesign -v --deep --strict "$BUILD_DIR/$APP_BUNDLE_NAME.app"
echo "Code signature verified."

echo ""
echo "[5/8] Sign final app bundle — done ($(step_time $STEP_START))"
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

DMG_PATH="$BUILD_DIR/${OUTPUT_NAME}.dmg"
[ -f "$DMG_PATH" ] || release_fail "Created DMG is missing: $DMG_PATH"

echo "Signing DMG container..."
run_codesign "$DMG_PATH"

echo "Verifying DMG signature..."
codesign --verify --verbose=4 "$DMG_PATH"
echo ""
echo "[7/8] Create DMG — done ($(step_time $STEP_START))"
echo ""

# ---------------------------------------------------------------------------
# Step 8: Report
# ---------------------------------------------------------------------------
TOTAL_ELAPSED=$(( $(date +%s) - TOTAL_START ))
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
    "mlx_wheel_tag",
    "mlx_metal_wheel_tag",
    "mlx_core_minos",
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
