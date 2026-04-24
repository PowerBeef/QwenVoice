#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
OUTPUT_ROOT="${1:-$PROJECT_DIR/build/diagnostics/qwenvoice-diagnostics-$TIMESTAMP}"

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

if [ -f "$PROJECT_DIR/build/release-metadata.txt" ]; then
    cp "$PROJECT_DIR/build/release-metadata.txt" "$OUTPUT_ROOT/"
fi

/usr/bin/log show \
    --last 30m \
    --style compact \
    --predicate 'subsystem == "com.qwenvoice.app" OR subsystem == "com.qwenvoice.engine-service" OR subsystem == "com.qvoice.ios"' \
    > "$OUTPUT_ROOT/unified-log-last-30m.txt" 2> "$OUTPUT_ROOT/unified-log.stderr" || true

tar -C "$(dirname "$OUTPUT_ROOT")" -czf "$OUTPUT_ROOT.tar.gz" "$(basename "$OUTPUT_ROOT")"
echo "$OUTPUT_ROOT.tar.gz"
