# Physical-iPhone CoreDevice readiness probe.
# Verdicts:
#   READY                0  — paired device is reachable for development
#   DEVICE_UNREACHABLE  14  — CoreDevice cannot reach the paired device

# shellcheck shell=bash

DEVICE_STATE_PROBE_PY="${ROOT_DIR:?}/scripts/lib/ios_coredevice_probe.py"

probe_device_state() {
  local dev="${1:-}" core_json reachable
  core_json="$(python3 "$DEVICE_STATE_PROBE_PY" probe ${dev:+--device "$dev"})"
  reachable="$(python3 -c 'import json,sys; print("1" if json.load(sys.stdin).get("reachable") else "0")' <<<"$core_json")"
  if [[ "$reachable" == "1" ]]; then
    printf '%s\n' "READY|paired physical iPhone is reachable"
  else
    printf '%s\n' "DEVICE_UNREACHABLE|resume the connection, then unlock and trust the paired iPhone"
  fi
}

probe_device_state_json() {
  local dev="${1:-}" core_json line verdict detail
  core_json="$(python3 "$DEVICE_STATE_PROBE_PY" probe ${dev:+--device "$dev"})"
  line="$(probe_device_state "$dev")"
  verdict="${line%%|*}"
  detail="${line#*|}"
  DEVICE_STATE_CORE="$core_json" DEVICE_STATE_VERDICT="$verdict" \
  DEVICE_STATE_DETAIL="$detail" python3 <<'PY'
import json, os
core = json.loads(os.environ["DEVICE_STATE_CORE"])
verdict = os.environ["DEVICE_STATE_VERDICT"]
print(json.dumps({
    "verdict": verdict,
    "detail": os.environ["DEVICE_STATE_DETAIL"],
    "confidence": "high",
    "advice": (
        "safe to run physical-device operations" if verdict == "READY"
        else "resume the connection, then unlock and trust the paired iPhone"
    ),
    "probeVersion": 4,
    "signals": {"coredevice": core},
}, indent=2))
PY
}

device_state_exit_code() {
  case "$1" in
    READY) echo 0 ;;
    DEVICE_UNREACHABLE) echo 14 ;;
    *) echo 1 ;;
  esac
}

device_state_advice() {
  case "$1" in
    READY) echo "safe to run physical-device operations" ;;
    DEVICE_UNREACHABLE) echo "resume the connection, then unlock and trust the paired iPhone" ;;
    *) echo "check the paired physical iPhone" ;;
  esac
}

probe_device_state_watch() {
  local dev="${1:-}" interval="${2:-2}" count="${3:-3}"
  local i verdict last="" samples=0 final_line=""
  for (( i = 0; i < count; i++ )); do
    final_line="$(probe_device_state "$dev")"
    verdict="${final_line%%|*}"
    if [[ "$verdict" == "$last" ]]; then samples=$((samples + 1)); else last="$verdict"; samples=1; fi
    (( i + 1 < count )) && sleep "$interval"
  done
  printf '%s\n' "$final_line"
  (( samples >= 2 )) || return 1
  return "$(device_state_exit_code "$verdict")"
}

guard_device_state() {
  local dev="${1:-}" line verdict
  line="$(probe_device_state "$dev")"
  verdict="${line%%|*}"
  [[ "$verdict" == "READY" ]] && return 0
  printf '\033[0;31m[device-state]\033[0m %s — %s (%s)\n' \
    "$verdict" "$(device_state_advice "$verdict")" "${line#*|}" >&2
  return "$(device_state_exit_code "$verdict")"
}
