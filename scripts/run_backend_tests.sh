#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUNDLED_PYTHON="$PROJECT_DIR/Sources/Resources/python/bin/python3"

cd "$PROJECT_DIR"

PYTHON_BIN="${QWENVOICE_BACKEND_TEST_PYTHON:-python3}"
if [[ -x "$BUNDLED_PYTHON" ]]; then
  PYTHON_BIN="$BUNDLED_PYTHON"
fi

PYTHONDONTWRITEBYTECODE=1 QWENVOICE_BACKEND_TEST_PYTHON="$PYTHON_BIN" "$PYTHON_BIN" -m unittest discover -s backend_tests -p 'test_*.py'
