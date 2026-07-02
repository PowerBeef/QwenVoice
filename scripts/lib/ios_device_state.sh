# iOS device-state probe — detects run-dooming interference before/during
# on-device lanes so tests and benches abort in seconds with a named cause
# instead of timing out.
#
# Verdicts (exit codes for `ios_device.sh device-state`):
#   MIRROR_ACTIVE        0  — mirroring session live; no interference detected
#   PHONE_IN_USE        10  — user unlocked / is using the iPhone (mirror paused)
#   CALL_ACTIVE         11  — call UI visible on the mirrored screen
#   MIRROR_CONNECTING   12  — mirroring app up but session not established
#   MIRROR_DISCONNECTED 13  — mirroring app/window missing
#   DEVICE_UNREACHABLE  14  — devicectl cannot reach the device at all
#
# Detection is visual (screenshot + Vision OCR, fr+en) because the Mirroring
# window exposes NO accessibility content — see scripts/lib/mirror_state_ocr.swift.
# `screencapture -l <windowID>` captures the window even when occluded or in the
# background, so probing never steals focus.
#
# Sourced by scripts/ios_device.sh. Requires: Screen Recording permission for the
# calling terminal (same as `ios_device.sh shot`), Xcode CLT (swiftc, first run only).

# shellcheck shell=bash

DEVICE_STATE_HELPER_SRC="${ROOT_DIR:?}/scripts/lib/mirror_state_ocr.swift"
DEVICE_STATE_HELPER_BIN="$ROOT_DIR/build/cache/mirror_state_ocr"

device_state_helper() {
  if [[ ! -x "$DEVICE_STATE_HELPER_BIN" || "$DEVICE_STATE_HELPER_SRC" -nt "$DEVICE_STATE_HELPER_BIN" ]]; then
    mkdir -p "$(dirname "$DEVICE_STATE_HELPER_BIN")"
    if ! xcrun swiftc -O -o "$DEVICE_STATE_HELPER_BIN" "$DEVICE_STATE_HELPER_SRC" \
        -framework AppKit -framework Vision 2>/dev/null; then
      return 1
    fi
  fi
  printf '%s' "$DEVICE_STATE_HELPER_BIN"
}

# Classify OCR text lines (lowercased, one per line on stdin) into a verdict.
# Conservative keyword sets: better to miss a call than to false-positive on
# app content. French first (dev machine locale), English fallback.
# Text travels via env var — the heredoc already occupies python's stdin.
_device_state_classify_text() {
  MIRROR_TEXT="$(cat)" python3 <<'PY'
import os, sys

text = os.environ.get("MIRROR_TEXT", "")

IN_USE = [
    "en cours d'utilisation", "en cours d’utilisation",  # FR: "iPhone en cours d'utilisation"
    "iphone in use", "is in use",
    "verrouillez votre iphone",   # FR: "lock your iPhone to continue"
    "lock your iphone",
]
CONNECTING = [
    "connexion", "connecting",
    "se connecter", "connect to", "réessayer", "try again",
    "impossible de se connecter", "unable to connect",
    "reprendre", "resume",        # paused session offering resume
]
CALL = [
    "appel entrant", "incoming call",
    "touchez pour revenir", "tap to return to call",
    "raccrocher", "end call",
    "appel en cours", "call in progress",
    "refuser", "decline",
]

def hit(keys):
    return next((k for k in keys if k in text), None)

for verdict, keys in (("PHONE_IN_USE", IN_USE), ("CALL_ACTIVE", CALL), ("MIRROR_CONNECTING", CONNECTING)):
    k = hit(keys)
    if k:
        print(f"{verdict}|matched '{k}'")
        sys.exit(0)
print("MIRROR_ACTIVE|no interference keywords")
PY
}

# probe_device_state [device-id] — prints "VERDICT|detail" on stdout.
# Fast path order: app running? window present? OCR classify. The optional
# device-id adds a devicectl reachability check when everything looks down.
probe_device_state() {
  local dev="${1:-}"

  if ! pgrep -fq "iPhone Mirroring" 2>/dev/null; then
    # No mirroring process. Distinguish "device also unreachable" when we can.
    if [[ -n "$dev" ]] && ! xcrun devicectl list devices 2>/dev/null | grep -qi "available"; then
      printf 'DEVICE_UNREACHABLE|iPhone Mirroring not running and devicectl sees no available device\n'
      return 0
    fi
    printf 'MIRROR_DISCONNECTED|iPhone Mirroring app is not running\n'
    return 0
  fi

  local helper
  if ! helper="$(device_state_helper)"; then
    printf 'MIRROR_ACTIVE|probe degraded: could not build OCR helper (swiftc missing?)\n'
    return 0
  fi

  local window_id
  if ! window_id="$("$helper" window-id 2>/dev/null)"; then
    printf 'MIRROR_DISCONNECTED|Mirroring app running but no window on screen\n'
    return 0
  fi

  local shot
  shot="$(mktemp -t mirror-state).png"
  if ! screencapture -x -o -l "$window_id" "$shot" 2>/dev/null || [[ ! -s "$shot" ]]; then
    rm -f "$shot"
    printf 'MIRROR_ACTIVE|probe degraded: screencapture failed (Screen Recording permission?)\n'
    return 0
  fi

  local verdict
  verdict="$("$helper" ocr "$shot" 2>/dev/null | _device_state_classify_text)"
  rm -f "$shot"
  printf '%s\n' "${verdict:-MIRROR_ACTIVE|probe degraded: OCR produced no classification}"
}

device_state_exit_code() {
  case "$1" in
    MIRROR_ACTIVE)       echo 0 ;;
    PHONE_IN_USE)        echo 10 ;;
    CALL_ACTIVE)         echo 11 ;;
    MIRROR_CONNECTING)   echo 12 ;;
    MIRROR_DISCONNECTED) echo 13 ;;
    DEVICE_UNREACHABLE)  echo 14 ;;
    *)                   echo 1 ;;
  esac
}

device_state_advice() {
  case "$1" in
    MIRROR_ACTIVE)       echo "no interference — safe to run device lanes" ;;
    PHONE_IN_USE)        echo "you are using the iPhone — lock it and keep it nearby, then re-run" ;;
    CALL_ACTIVE)         echo "a call is in progress on the iPhone — finish/decline it, then re-run" ;;
    MIRROR_CONNECTING)   echo "iPhone Mirroring session not established — lock the phone and wait for the mirror to connect (ios_device.sh mirror)" ;;
    MIRROR_DISCONNECTED) echo "iPhone Mirroring is not running — start it (ios_device.sh mirror)" ;;
    DEVICE_UNREACHABLE)  echo "device unreachable — connect/trust the iPhone and start Mirroring (ios_device.sh mirror)" ;;
  esac
}

# Convenience for lane guards: returns 0 (and prints nothing) when the state is
# safe to proceed, else prints the verdict line + advice to stderr and returns
# the verdict's exit code. `--allow-connecting` treats MIRROR_CONNECTING as safe
# (ensure_mirror handles the wait itself).
guard_device_state() {
  local allow_connecting=0 dev=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --allow-connecting) allow_connecting=1; shift ;;
      *) dev="$1"; shift ;;
    esac
  done
  local line verdict detail
  line="$(probe_device_state "$dev")"
  verdict="${line%%|*}"
  detail="${line#*|}"
  case "$verdict" in
    MIRROR_ACTIVE) return 0 ;;
    MIRROR_CONNECTING)
      (( allow_connecting )) && return 0
      ;;
  esac
  printf '\033[0;31m[device-state]\033[0m %s — %s (%s)\n' \
    "$verdict" "$(device_state_advice "$verdict")" "$detail" >&2
  return "$(device_state_exit_code "$verdict")"
}
