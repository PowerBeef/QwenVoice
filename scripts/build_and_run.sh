#!/usr/bin/env bash
# Legacy entrypoint, superseded by scripts/build.sh. Kept as a thin shim so
# existing references / muscle memory keep working. Forwards the mode flag
# (run | --debug | --logs | --telemetry | --verify) to `build.sh run`.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build.sh" run "$@"
