#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/search_helpers.sh"

if [ $# -ne 1 ]; then
    echo "Usage: $0 <runner>" >&2
    echo "Example: $0 macos-15" >&2
    exit 1
fi

RUNNER_ID="$1"
PROJECT_YML="project.yml"
DEFAULT_DEFINE="SWIFT_ACTIVE_COMPILATION_CONDITIONS: QW_UI_LIQUID"
LEGACY_DEFINE="SWIFT_ACTIVE_COMPILATION_CONDITIONS: QW_UI_LEGACY_GLASS"

if [ ! -f "$PROJECT_YML" ]; then
    echo "error: could not find $PROJECT_YML" >&2
    exit 1
fi

case "$RUNNER_ID" in
    macos-15)
        if search_regex_in_file "^\\s*${LEGACY_DEFINE}$" "$PROJECT_YML"; then
            echo "project.yml already configured for QW_UI_LEGACY_GLASS"
            exit 0
        fi
        if ! search_regex_in_file "^\\s*${DEFAULT_DEFINE}$" "$PROJECT_YML"; then
            echo "error: expected default liquid UI compile flag in $PROJECT_YML" >&2
            exit 1
        fi
        sed -i '' "s/${DEFAULT_DEFINE}/${LEGACY_DEFINE}/" "$PROJECT_YML"
        echo "Patched project.yml to use QW_UI_LEGACY_GLASS for macOS 15 CI"
        ;;
    macos-26)
        echo "Keeping default QW_UI_LIQUID profile for macOS 26 CI"
        ;;
    *)
        echo "error: unsupported runner '$RUNNER_ID'" >&2
        exit 1
        ;;
esac
