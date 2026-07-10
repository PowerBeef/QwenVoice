#!/usr/bin/env bash
# Deterministic lifecycle and evidence interface for Codex Computer Use on macOS.
#
# Computer Use performs every frontend action. This script never clicks, types,
# or infers UI success. It launches the exact built app and validates history,
# WAV output, typed middle/backend telemetry, reports, and attestations.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT_DIR/scripts/lib/macos_agent_ui.py" "$@"
