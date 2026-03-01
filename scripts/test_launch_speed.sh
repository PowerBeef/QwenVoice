#!/bin/bash
# Deprecated wrapper. Use:
#   ./scripts/run_tests.sh --suite integration --probe launch-speed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

exec "$SCRIPT_DIR/run_tests.sh" --suite integration --probe launch-speed "$@"
