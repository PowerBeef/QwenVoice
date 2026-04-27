#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SWAP_LIMIT_MB="${QW_RESCUE_SWAP_LIMIT_MB:-4096}"
MODE="full"

usage() {
    cat <<USAGE
Usage: $0 [--fast]

Runs the local QwenVoice rescue validation ladder serially.

Options:
  --fast    Run only project inputs, harness validate, and git diff checks.

Environment:
  QW_RESCUE_SWAP_LIMIT_MB  Maximum swap-in-use before heavy Swift/Xcode steps.
                           Defaults to 4096 MB.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --fast)
            MODE="fast"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

run_step() {
    local label="$1"
    shift
    echo "==> $label"
    (cd "$PROJECT_DIR" && "$@")
}

current_swap_mb() {
    local swap_line used value unit
    swap_line="$(sysctl vm.swapusage 2>/dev/null || true)"
    used="$(printf '%s\n' "$swap_line" | sed -nE 's/.*used = ([0-9.]+)([MG]) .*/\1 \2/p')"
    if [ -z "$used" ]; then
        echo 0
        return
    fi
    value="${used% *}"
    unit="${used##* }"
    awk -v value="$value" -v unit="$unit" 'BEGIN {
        if (unit == "G") {
            printf "%.0f\n", value * 1024
        } else {
            printf "%.0f\n", value
        }
    }'
}

print_memory_status() {
    echo "==> Memory status"
    sysctl vm.swapusage || true
    memory_pressure 2>/dev/null | sed -n '1,18p' || true
}

guard_swap_before_heavy_step() {
    local label="$1"
    local swap_mb
    print_memory_status
    swap_mb="$(current_swap_mb)"
    if [ "$swap_mb" -gt "$SWAP_LIMIT_MB" ]; then
        echo "error: refusing heavy step '$label' because swap in use is ${swap_mb} MB, above limit ${SWAP_LIMIT_MB} MB." >&2
        echo "Quit memory-heavy apps or reboot, then rerun this gate." >&2
        exit 1
    fi
}

run_step "Project inputs" "$PROJECT_DIR/scripts/check_project_inputs.sh"
run_step "Harness validate" python3 "$PROJECT_DIR/scripts/harness.py" validate
run_step "Git diff whitespace check" git diff --check

if [ "$MODE" = "fast" ]; then
    echo "==> Rescue gate fast lane passed."
    exit 0
fi

guard_swap_before_heavy_step "Swift source tests"
run_step "Swift source tests" python3 "$PROJECT_DIR/scripts/harness.py" test --layer swift

guard_swap_before_heavy_step "macOS foundation build"
run_step "macOS foundation build" "$PROJECT_DIR/scripts/build_foundation_targets.sh" macos

guard_swap_before_heavy_step "iOS foundation build"
run_step "iOS foundation build" "$PROJECT_DIR/scripts/build_foundation_targets.sh" ios

echo "==> Rescue gate full lane passed."
