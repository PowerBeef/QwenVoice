#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s backend_tests -p 'test_*.py'
