#!/usr/bin/env bash
# Classified, policy-driven build cleanup. With no cleanup mode this command is
# read-only and reports the owned cache/scratch/artifact/distribution inventory.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT_DIR/scripts/build_cleanup.py" "$@"
