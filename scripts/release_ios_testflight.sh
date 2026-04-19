#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_FILE="$PROJECT_DIR/QwenVoice.xcodeproj"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/VocelloiOS-TestFlight.xcarchive"
EXPORT_DIR="$BUILD_DIR/vocello_ios_testflight_export"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/vocello_ios_testflight_export_options.plist"
METADATA_PATH="$BUILD_DIR/vocello_ios_testflight_release_metadata.txt"
SCHEME="VocelloiOS"
CONFIGURATION="Release"
TEAM_ID="${QVOICE_IOS_TEAM_ID:-FK2D8X36G2}"
BUNDLE_ID="com.qvoice.ios"
CATALOG_URL="${QVOICE_IOS_MODEL_CATALOG_URL:-https://downloads.qvoice.app/ios/catalog/v1/models.json}"
DESTINATION_MODE="export"
SKIP_CATALOG_CHECK=false
SKIP_ARCHIVE=false

usage() {
    cat <<EOF
Usage: $0 [--skip-catalog-check] [--skip-archive] [--upload]

Build a Release iPhone archive and export a TestFlight-ready package.

Options:
  --skip-catalog-check  Skip hosted catalog verification before archiving.
  --skip-archive        Reuse the existing archive at $ARCHIVE_PATH.
  --upload              Upload to App Store Connect instead of exporting a local IPA.

Environment:
  QVOICE_IOS_TEAM_ID                 Override the export team ID (default: $TEAM_ID)
  QVOICE_IOS_MODEL_CATALOG_URL       Override the catalog URL used for the preflight check
  APP_STORE_CONNECT_API_KEY_PATH     Optional App Store Connect API key path
  APP_STORE_CONNECT_API_KEY_ID       Required with APP_STORE_CONNECT_API_KEY_PATH
  APP_STORE_CONNECT_ISSUER_ID        Required with APP_STORE_CONNECT_API_KEY_PATH
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-catalog-check)
            SKIP_CATALOG_CHECK=true
            shift
            ;;
        --skip-archive)
            SKIP_ARCHIVE=true
            shift
            ;;
        --upload)
            DESTINATION_MODE="upload"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

mkdir -p "$BUILD_DIR"

step_time() {
    local start="$1"
    local end
    end="$(date +%s)"
    echo "$((end - start))s"
}

has_distribution_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep -E 'Apple Distribution|iOS Distribution' >/dev/null
}

print_signing_guidance() {
    cat <<EOF
Release export requires App Store distribution signing for $BUNDLE_ID.

Checklist:
  1. Xcode -> Settings -> Accounts: sign into the Apple Developer team that owns $TEAM_ID.
  2. Install or create an Apple Distribution certificate in the login keychain.
  3. Make sure App Store / TestFlight provisioning exists for $BUNDLE_ID.
  4. Re-run this script, or use --skip-archive if $ARCHIVE_PATH is still current.
EOF
}

write_export_options() {
    cat > "$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>destination</key>
    <string>$DESTINATION_MODE</string>
    <key>distributionBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
    <key>method</key>
    <string>app-store-connect</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>testFlightInternalTestingOnly</key>
    <true/>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
EOF
}

AUTH_ARGS=()
if [ -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" ]; then
    AUTH_ARGS=(
        -authenticationKeyPath "$APP_STORE_CONNECT_API_KEY_PATH"
        -authenticationKeyID "${APP_STORE_CONNECT_API_KEY_ID:?APP_STORE_CONNECT_API_KEY_ID is required with APP_STORE_CONNECT_API_KEY_PATH}"
        -authenticationKeyIssuerID "${APP_STORE_CONNECT_ISSUER_ID:?APP_STORE_CONNECT_ISSUER_ID is required with APP_STORE_CONNECT_API_KEY_PATH}"
    )
fi

echo "=== Vocello iPhone: TestFlight Build ==="
echo "  mode: $DESTINATION_MODE"
echo "  archive: $ARCHIVE_PATH"
echo "  export: $EXPORT_DIR"
echo "  catalog: $CATALOG_URL"
echo ""

STEP_START="$(date +%s)"
echo "[1/6] Regenerating Xcode project..."
"$SCRIPT_DIR/regenerate_project.sh"
echo "[1/6] Regenerate project — done ($(step_time "$STEP_START"))"
echo ""

STEP_START="$(date +%s)"
if $SKIP_CATALOG_CHECK; then
    echo "[2/6] Hosted catalog check — skipped"
else
    echo "[2/6] Validating hosted iPhone catalog..."
    python3 "$SCRIPT_DIR/check_ios_catalog.py" --url "$CATALOG_URL"
    echo "[2/6] Hosted catalog check — done ($(step_time "$STEP_START"))"
fi
echo ""

STEP_START="$(date +%s)"
if $SKIP_ARCHIVE; then
    if [ ! -d "$ARCHIVE_PATH" ]; then
        echo "Error: --skip-archive requested, but no archive exists at $ARCHIVE_PATH" >&2
        exit 1
    fi
    echo "[3/6] Archive Release iPhone build — skipped"
else
    echo "[3/6] Archiving Release iPhone build..."
    rm -rf "$ARCHIVE_PATH"
    xcodebuild -project "$PROJECT_FILE" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "generic/platform=iOS" \
        -archivePath "$ARCHIVE_PATH" \
        -allowProvisioningUpdates \
        "${AUTH_ARGS[@]}" \
        archive
    echo "[3/6] Archive Release iPhone build — done ($(step_time "$STEP_START"))"
fi
echo ""

STEP_START="$(date +%s)"
echo "[4/6] Checking distribution signing prerequisites..."
if has_distribution_identity; then
    echo "[4/6] Distribution signing preflight — found Apple Distribution identity ($(step_time "$STEP_START"))"
else
    echo "[4/6] Distribution signing preflight — no Apple Distribution identity found ($(step_time "$STEP_START"))"
    print_signing_guidance
fi
echo ""

STEP_START="$(date +%s)"
echo "[5/6] Exporting TestFlight package..."
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
write_export_options

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    -allowProvisioningUpdates \
    "${AUTH_ARGS[@]}" || {
        echo ""
        echo "TestFlight export failed."
        print_signing_guidance
        exit 1
    }

echo "[5/6] Export TestFlight package — done ($(step_time "$STEP_START"))"
echo ""

STEP_START="$(date +%s)"
echo "[6/6] Writing release metadata..."
SHOW_BUILD_SETTINGS="$(xcodebuild -project "$PROJECT_FILE" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null)"
MARKETING_VERSION="$(printf '%s\n' "$SHOW_BUILD_SETTINGS" | awk -F' = ' '/MARKETING_VERSION/ {print $2; exit}')"
CURRENT_PROJECT_VERSION="$(printf '%s\n' "$SHOW_BUILD_SETTINGS" | awk -F' = ' '/CURRENT_PROJECT_VERSION/ {print $2; exit}')"
COMMIT_SHA="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || true)"
[ -n "$COMMIT_SHA" ] || COMMIT_SHA="unknown"
IPA_PATH="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' -print -quit || true)"

{
    echo "commit_sha=$COMMIT_SHA"
    echo "scheme=$SCHEME"
    echo "configuration=$CONFIGURATION"
    echo "bundle_id=$BUNDLE_ID"
    echo "team_id=$TEAM_ID"
    echo "marketing_version=$MARKETING_VERSION"
    echo "build_number=$CURRENT_PROJECT_VERSION"
    echo "catalog_url=$CATALOG_URL"
    echo "destination_mode=$DESTINATION_MODE"
    echo "archive_path=$ARCHIVE_PATH"
    echo "export_path=$EXPORT_DIR"
    echo "ipa_path=${IPA_PATH:-none}"
    echo "built_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "testflight_internal_only=true"
} > "$METADATA_PATH"

echo "[6/6] Write release metadata — done ($(step_time "$STEP_START"))"
echo ""

echo "Vocello iPhone release build complete."
echo "  Archive:  $ARCHIVE_PATH"
echo "  Export:   $EXPORT_DIR"
if [ -n "${IPA_PATH:-}" ]; then
    echo "  IPA:      $IPA_PATH"
fi
echo "  Metadata: $METADATA_PATH"
echo ""
if [ "$DESTINATION_MODE" = "export" ]; then
    echo "Next:"
    echo "  1. Upload the archive or IPA to App Store Connect with Xcode Organizer or Transporter."
    echo "  2. Add the build to the Internal Testing group in TestFlight."
    echo "  3. Install it from TestFlight on an iPhone 15 Pro or newer that is not connected to Xcode."
else
    echo "The build was exported with destination=upload. Confirm it appears in App Store Connect -> TestFlight."
fi
