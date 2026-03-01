#!/bin/bash
# Safely regenerate the Xcode project from project.yml.
# XcodeGen overwrites the entitlements file, so we back it up and restore it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

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

echo "==> Done. Project regenerated at QwenVoice.xcodeproj"
