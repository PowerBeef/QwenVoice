#!/usr/bin/env bash
# Orchestrates the iOS MLX/memory proof phases documented in
# docs/reference/ios-device-proof-matrix.md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PHASE="help"
RUN_ID=""
EXTRA_ARGS=()

usage() {
  cat <<'EOF'
Usage: scripts/ios_device_proof_matrix.sh --phase <name> [options]

Phases:
  preflight   doctor + iOS catalog check (no device build)
  baseline    unentitled: doctor, build, verify-entitlements (no increased-memory flag)
  entitled    entitled: build + verify with --enable-increased-memory-limit
  stress      Debug stress: start with --force-band guarded (then critical manually)

Options:
  --run-id <id>   Run directory name under build/Debug/ios-device/runs/
  -h, --help      Show this help

Examples:
  scripts/ios_device_proof_matrix.sh --phase preflight
  scripts/ios_device_proof_matrix.sh --phase baseline --run-id entitlement-request-evidence
  scripts/ios_device_proof_matrix.sh --phase entitled --run-id memory-entitled-baseline
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)
      PHASE="${2:-}"
      shift 2
      ;;
    --run-id)
      RUN_ID="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

run_id_for_phase() {
  if [[ -n "$RUN_ID" ]]; then
    echo "$RUN_ID"
    return
  fi
  case "$PHASE" in
    preflight) echo "proof-preflight-$(date -u +%Y%m%dT%H%M%SZ)" ;;
    baseline) echo "entitlement-request-evidence" ;;
    entitled) echo "memory-entitled-baseline" ;;
    stress) echo "proof-stress-$(date -u +%Y%m%dT%H%M%SZ)" ;;
    *) echo "proof-$(date -u +%Y%m%dT%H%M%SZ)" ;;
  esac
}

doctor_device_state() {
  if command -v xcrun >/dev/null 2>&1; then
    xcrun devicectl list devices 2>/dev/null | head -20 || true
  fi
}

ios_device() {
  if ((${#EXTRA_ARGS[@]} > 0)); then
    ./scripts/ios_device.sh "$@" "${EXTRA_ARGS[@]}"
  else
    ./scripts/ios_device.sh "$@"
  fi
}

case "$PHASE" in
  preflight)
    RID="$(run_id_for_phase)"
    echo "=== Phase: preflight (run-id=$RID) ==="
    ios_device doctor --run-id "$RID"
    ./scripts/check_ios_catalog.sh
    doctor_device_state
    echo ""
    echo "Next: fix device availability if state is unavailable, then:"
    echo "  scripts/ios_device_proof_matrix.sh --phase baseline"
    ;;
  baseline)
    RID="$(run_id_for_phase)"
    echo "=== Phase: baseline / unentitled (run-id=$RID) ==="
    ios_device doctor --run-id "$RID"
    if ios_device build --run-id "$RID"; then
      ios_device verify-entitlements --run-id "$RID"
      echo ""
      echo "Optional UI proof: install/launch via ios_device.sh start, then generate once and pull."
      echo "  scripts/ios_device.sh start --run-id ${RID}-ui"
      echo "  scripts/ios_device.sh pull --run-id ${RID}-ui"
    else
      echo "Build failed — see $ROOT/build/Debug/ios-device/runs/$RID/xcodebuild-device.log"
      doctor_device_state
      exit 1
    fi
    ;;
  entitled)
    RID="$(run_id_for_phase)"
    echo "=== Phase: entitled (run-id=$RID) ==="
    echo "Requires Apple approval + profiles with increased-memory-limit."
    if ios_device build --enable-increased-memory-limit --run-id "$RID"; then
      ios_device verify-entitlements --enable-increased-memory-limit --run-id "$RID"
      echo ""
      echo "Next: Custom → Design → Clone on device, then pull diagnostics:"
      echo "  scripts/ios_device.sh start --run-id $RID --enable-increased-memory-limit"
      echo "  scripts/ios_device.sh pull --run-id $RID"
    else
      echo "Entitled build failed — entitlement likely not in provisioning yet."
      exit 1
    fi
    ;;
  stress)
    RID="$(run_id_for_phase)"
    echo "=== Phase: stress (run-id=$RID) ==="
    ios_device start --force-band guarded --run-id "$RID"
    echo "Repeat with --force-band critical if needed (Debug probes)."
    ;;
  help|"")
    usage
    exit 0
    ;;
  *)
    echo "Unknown phase: $PHASE" >&2
    usage
    exit 1
    ;;
esac
