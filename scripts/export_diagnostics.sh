#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib/build_paths.sh
. "$SCRIPT_DIR/lib/build_paths.sh"
TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
OUTPUT_BASENAME="${1:-qwenvoice-diagnostics-$TIMESTAMP}"

case "$OUTPUT_BASENAME" in
    ""|.|..|*/*)
        echo "error: diagnostic export name must be a basename without path separators" >&2
        exit 1
        ;;
esac
OUTPUT_ROOT="$QVOICE_ARTIFACTS_DIAGNOSTICS/$OUTPUT_BASENAME"

mkdir -p "$OUTPUT_ROOT"

{
    echo "timestamp_utc=$TIMESTAMP"
    echo "project_dir=$PROJECT_DIR"
    echo "uname=$(uname -a)"
    xcodebuild -version 2>/dev/null || true
    xcode-select -p 2>/dev/null || true
} > "$OUTPUT_ROOT/environment.txt"

"$PROJECT_DIR/scripts/check_project_inputs.sh" > "$OUTPUT_ROOT/project-inputs.txt" 2> "$OUTPUT_ROOT/project-inputs.stderr" || true

cp "$PROJECT_DIR/config/apple-platform-capability-matrix.json" "$OUTPUT_ROOT/" 2>/dev/null || true
cp "$PROJECT_DIR/Sources/Resources/qwenvoice_contract.json" "$OUTPUT_ROOT/" 2>/dev/null || true

if [ -f "$QVOICE_DIST_MACOS/release-metadata.txt" ]; then
    cp "$QVOICE_DIST_MACOS/release-metadata.txt" "$OUTPUT_ROOT/"
fi

/usr/bin/log show \
    --last 30m \
    --style compact \
    --predicate 'subsystem == "com.qwenvoice.app" OR subsystem == "com.qwenvoice.engine-service" OR subsystem == "com.patricedery.vocello"' \
    > "$OUTPUT_ROOT/unified-log-last-30m.txt" 2> "$OUTPUT_ROOT/unified-log.stderr" || true

tar -C "$(dirname "$OUTPUT_ROOT")" -czf "$OUTPUT_ROOT.tar.gz" "$(basename "$OUTPUT_ROOT")"
echo "$OUTPUT_ROOT.tar.gz"
