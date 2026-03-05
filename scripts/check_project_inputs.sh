#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PBXPROJ="$PROJECT_DIR/QwenVoice.xcodeproj/project.pbxproj"

if [ ! -f "$PBXPROJ" ]; then
    echo "error: missing project file at $PBXPROJ" >&2
    exit 1
fi

echo "==> Validating checked-in project inputs..."

if grep -nE '(__pycache__|\.pyc)' "$PBXPROJ" >/dev/null 2>&1; then
    echo "error: project references local-only Python cache files." >&2
    echo "Remove __pycache__/*.pyc references from QwenVoice.xcodeproj before committing." >&2
    grep -nE '(__pycache__|\.pyc)' "$PBXPROJ" >&2 || true
    exit 1
fi

echo "==> Project inputs are clean."
