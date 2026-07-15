#!/usr/bin/env bash
# Safely regenerate the Xcode project from project.yml.
# XcodeGen overwrites the entitlements file, so we back it up and restore it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen is required to regenerate the project." >&2
    echo "Install it with: brew install xcodegen" >&2
    exit 1
fi

ENTITLEMENTS="Sources/QwenVoice.entitlements"
BACKUP="/tmp/QwenVoice.entitlements.backup.$$"

cleanup() {
    if [ -f "$BACKUP" ]; then
        echo "==> Restoring entitlements..."
        cp "$BACKUP" "$ENTITLEMENTS"
        rm -f "$BACKUP"
    fi
}
trap cleanup EXIT

echo "==> Backing up entitlements..."
cp "$ENTITLEMENTS" "$BACKUP"

echo "==> Running xcodegen..."
xcodegen generate

# XcodeGen 2.45.4 cannot directly generate schemes for the CLI tool or the
# app-host-free iOS unit-test product. Render both shared schemes from generated target IDs so
# every Xcode invocation can still use an explicit managed DerivedData path.
python3 "$SCRIPT_DIR/generate_cli_scheme.py"
python3 "$SCRIPT_DIR/generate_ios_logic_scheme.py"

bash "$SCRIPT_DIR/check_project_inputs.sh"

echo "==> Done. Project regenerated at QwenVoice.xcodeproj"
