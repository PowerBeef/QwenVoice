#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_FILE="$PROJECT_DIR/QwenVoice.xcodeproj"
SCHEME="QwenVoice"
CONFIGURATION="Release"
BUILD_DIR="$PROJECT_DIR/build"
DEFAULT_OUTPUT_NAME="Vocello-macos26"
TOTAL_START="$(date +%s)"

SKIP_BUILD=false
OUTPUT_NAME="$DEFAULT_OUTPUT_NAME"
SIGNING_MODE="${QWENVOICE_SIGNING_MODE:-ad-hoc}"
SIGNING_IDENTITY="${QWENVOICE_SIGNING_IDENTITY:-}"
CODESIGN_KEYCHAIN="${QWENVOICE_CODESIGN_KEYCHAIN:-}"

release_fail() {
    echo "Error: $*" >&2
    exit 1
}

usage() {
    cat >&2 <<EOF
Usage: $0 [--skip-build] [--output-name <basename>] [--signing-mode ad-hoc|developer-id] [--signing-identity <identity>] [--codesign-keychain <path>]

Build the macOS Release app, sign it, package it into a DMG, and emit release metadata.
EOF
    exit 1
}

step_time() {
    local start="$1"
    local end
    end="$(date +%s)"
    echo "$((end - start))s"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --output-name)
            [ $# -ge 2 ] || usage
            OUTPUT_NAME="$2"
            shift 2
            ;;
        --signing-mode)
            [ $# -ge 2 ] || usage
            SIGNING_MODE="$2"
            shift 2
            ;;
        --signing-identity)
            [ $# -ge 2 ] || usage
            SIGNING_IDENTITY="$2"
            shift 2
            ;;
        --codesign-keychain)
            [ $# -ge 2 ] || usage
            CODESIGN_KEYCHAIN="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

if [[ "$OUTPUT_NAME" == *"/"* ]]; then
    release_fail "--output-name must not contain path separators"
fi

case "$SIGNING_MODE" in
    ad-hoc)
        ACTIVE_SIGNING_IDENTITY="-"
        ;;
    developer-id)
        [ -n "$SIGNING_IDENTITY" ] || release_fail "--signing-identity is required for developer-id signing"
        ACTIVE_SIGNING_IDENTITY="$SIGNING_IDENTITY"
        ;;
    *)
        release_fail "Unsupported --signing-mode '$SIGNING_MODE' (expected ad-hoc or developer-id)"
        ;;
esac

if [ -n "$CODESIGN_KEYCHAIN" ] && [ ! -f "$CODESIGN_KEYCHAIN" ]; then
    release_fail "--codesign-keychain path does not exist: $CODESIGN_KEYCHAIN"
fi

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

read_build_setting() {
    local file_path="$1"
    local key="$2"
    python3 - "$file_path" "$key" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
key = sys.argv[2]
for line in text.splitlines():
    if " = " not in line:
        continue
    lhs, rhs = line.split(" = ", 1)
    if lhs.strip() == key:
        print(rhs.strip())
        break
PY
}

resolve_build_metadata() {
    local settings_path="$1"
    BUILT_PRODUCTS_DIR="$(read_build_setting "$settings_path" BUILT_PRODUCTS_DIR)"
    WRAPPER_NAME="$(read_build_setting "$settings_path" WRAPPER_NAME)"
    EXECUTABLE_NAME="$(read_build_setting "$settings_path" EXECUTABLE_NAME)"
    MARKETING_VERSION="$(read_build_setting "$settings_path" MARKETING_VERSION)"
    CURRENT_PROJECT_VERSION="$(read_build_setting "$settings_path" CURRENT_PROJECT_VERSION)"

    [ -n "$BUILT_PRODUCTS_DIR" ] || release_fail "Could not determine BUILT_PRODUCTS_DIR"
    [ -n "$WRAPPER_NAME" ] || release_fail "Could not determine WRAPPER_NAME"
    [ -n "$EXECUTABLE_NAME" ] || release_fail "Could not determine EXECUTABLE_NAME"
}

echo "=== Vocello: macOS Release Build ==="
echo ""
echo "  scheme: $SCHEME"
echo "  output DMG: $OUTPUT_NAME.dmg"
echo "  signing: $SIGNING_MODE"
if [ "$SIGNING_MODE" = "developer-id" ]; then
    echo "  signing identity: $SIGNING_IDENTITY"
fi
echo ""

mkdir -p "$BUILD_DIR"
SHOW_BUILD_SETTINGS_LOG="$BUILD_DIR/release-build-settings.log"

STEP_START="$(date +%s)"
echo "[1/6] Regenerating Xcode project..."
"$SCRIPT_DIR/regenerate_project.sh"
echo "[1/6] Regenerate project — done ($(step_time "$STEP_START"))"
echo ""

STEP_START="$(date +%s)"
if $SKIP_BUILD; then
    echo "[2/6] Build Release — skipped"
else
    echo "[2/6] Building macOS Release app..."
    rm -f "$BUILD_DIR/xcodebuild-release.log"
    set +e
    xcodebuild -project "$PROJECT_FILE" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "platform=macOS,arch=arm64" \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
        ONLY_ACTIVE_ARCH=YES \
        ARCHS=arm64 \
        build 2>&1 | tee "$BUILD_DIR/xcodebuild-release.log"
    XCODEBUILD_STATUS=${PIPESTATUS[0]}
    set -e
    if [ "$XCODEBUILD_STATUS" -ne 0 ]; then
        release_fail "xcodebuild failed (see $BUILD_DIR/xcodebuild-release.log)"
    fi
fi
echo "[2/6] Build Release — done ($(step_time "$STEP_START"))"
echo ""

STEP_START="$(date +%s)"
echo "[3/6] Resolving and copying built app..."
xcodebuild -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS,arch=arm64" \
    -showBuildSettings > "$SHOW_BUILD_SETTINGS_LOG"
resolve_build_metadata "$SHOW_BUILD_SETTINGS_LOG"

APP_SOURCE="$BUILT_PRODUCTS_DIR/$WRAPPER_NAME"
[ -d "$APP_SOURCE" ] || release_fail "Built app not found at $APP_SOURCE"

APP_PATH="$BUILD_DIR/$WRAPPER_NAME"
rm -rf "$APP_PATH"
cp -a "$APP_SOURCE" "$APP_PATH"

APP_RESOURCES="$APP_PATH/Contents/Resources"
rm -rf "$APP_RESOURCES/backend" "$APP_RESOURCES/python" "$APP_RESOURCES/vendor" 2>/dev/null || true
rm -f "$APP_RESOURCES/ffmpeg" 2>/dev/null || true
find "$APP_RESOURCES" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$APP_RESOURCES" -name "*.pyc" -delete 2>/dev/null || true
find "$APP_RESOURCES" -name "*.whl" -delete 2>/dev/null || true
"$SCRIPT_DIR/check_backend_resource_contract.sh" --app-bundle "$APP_PATH" >/dev/null
echo "[3/6] App copied to $APP_PATH ($(step_time "$STEP_START"))"
echo ""

STEP_START="$(date +%s)"
echo "[4/6] Signing and verifying the final app bundle..."
run_codesign "$APP_PATH" \
    --options runtime \
    --entitlements "$PROJECT_DIR/Sources/QwenVoice.entitlements"
codesign --verify --deep --strict "$APP_PATH"
"$SCRIPT_DIR/verify_release_bundle.sh" "$APP_PATH"
echo "[4/6] Final app bundle verified ($(step_time "$STEP_START"))"
echo ""

STEP_START="$(date +%s)"
echo "[5/6] Creating and signing the DMG..."
"$SCRIPT_DIR/create_dmg.sh" "$APP_PATH" "$OUTPUT_NAME"
DMG_PATH="$BUILD_DIR/${OUTPUT_NAME}.dmg"
[ -f "$DMG_PATH" ] || release_fail "Created DMG is missing: $DMG_PATH"
run_codesign "$DMG_PATH"
codesign --verify --verbose=4 "$DMG_PATH"
echo "[5/6] DMG ready at $DMG_PATH ($(step_time "$STEP_START"))"
echo ""

STEP_START="$(date +%s)"
echo "[6/6] Writing release metadata..."
APP_BINARY="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
extract_otool_field() {
    local field="$1"
    otool -l "$APP_BINARY" | awk -v key="$field" '
        $1 == "cmd" && $2 == "LC_BUILD_VERSION" { in_block = 1; next }
        in_block && $1 == key { print $2; exit }
    '
}

APP_MINOS="$(extract_otool_field minos)"
SDK_VERSION="$(extract_otool_field sdk)"
[ -n "$APP_MINOS" ] || release_fail "Failed to extract app minOS from $APP_BINARY"
[ -n "$SDK_VERSION" ] || release_fail "Failed to extract SDK version from $APP_BINARY"

XCODE_VERSION="$(xcodebuild -version | awk 'NR==1 {print $2}')"
COMMIT_SHA="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || true)"
[ -n "$COMMIT_SHA" ] || COMMIT_SHA="unknown"

METADATA_PATH="$BUILD_DIR/release-metadata.txt"
{
    echo "commit_sha=$COMMIT_SHA"
    echo "release_mode=macos-github"
    echo "release_brand=Vocello"
    echo "xcode_version=$XCODE_VERSION"
    echo "sdk_version=$SDK_VERSION"
    echo "app_minos=$APP_MINOS"
    echo "marketing_version=$MARKETING_VERSION"
    echo "build_number=$CURRENT_PROJECT_VERSION"
    echo "dmg_name=$OUTPUT_NAME.dmg"
    echo "app_wrapper_name=$WRAPPER_NAME"
    echo "app_executable_name=$EXECUTABLE_NAME"
    echo "built_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
} > "$METADATA_PATH"
echo "[6/6] Release metadata written to $METADATA_PATH ($(step_time "$STEP_START"))"
echo ""

TOTAL_ELAPSED="$(( $(date +%s) - TOTAL_START ))"
echo "Vocello macOS release build complete."
echo "  App:      $APP_PATH"
echo "  DMG:      $DMG_PATH"
echo "  Metadata: $METADATA_PATH"
echo "  Total:    ${TOTAL_ELAPSED}s"
