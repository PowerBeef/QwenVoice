#!/bin/bash
# Fully automated backend-first generation benchmark wrapper.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

find_python() {
    if command -v python3 >/dev/null 2>&1; then
        command -v python3
        return 0
    fi

    local candidate
    for candidate in \
        /opt/homebrew/bin/python3.13 \
        /opt/homebrew/bin/python3.12 \
        /opt/homebrew/bin/python3.11 \
        /opt/homebrew/bin/python3 \
        /usr/local/bin/python3.13 \
        /usr/local/bin/python3.12 \
        /usr/local/bin/python3.11 \
        /usr/local/bin/python3
    do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

PYTHON_BIN="$(find_python)" || {
    echo "ERROR: Could not find a usable python3 interpreter to launch the benchmark wrapper." >&2
    exit 1
}

exec "$PYTHON_BIN" "$SCRIPT_DIR/benchmark_generation.py" "$@"
