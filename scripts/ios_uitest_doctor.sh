#!/usr/bin/env bash
# On-device iOS XCUITest readiness: Mac Authorization Services (Gate 1) + device reachability +
# the iPhone-side unlock handshake Apple still requires on physical hardware.
#
# This is iOS-only. macOS frontend acceptance uses Codex Computer Use and
# scripts/macos_agent_ui.sh rather than an XCTest runner.
#
# usage:
#   scripts/ios_uitest_doctor.sh
#   scripts/ios_uitest_doctor.sh --enable-gate1   # run enable_unattended_uitest.sh (sudo once)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

note() { printf '\033[0;36m==>\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[0;32m[ok]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

section_mac_gate1() {
  echo "==> Mac Gate 1 — Authorization Services for on-device iOS XCUITest"
  if ! command -v automationmodetool >/dev/null 2>&1; then
    warn "automationmodetool not found"
    return 0
  fi
  local out
  out="$(automationmodetool 2>&1 || true)"
  echo "$out" | sed 's/^/    /'
  if grep -q 'DOES NOT REQUIRE user authentication' <<<"$out"; then
    ok "no Mac login password required to enable UI Automation"
    return 0
  fi
  cat >&2 <<'EOF'
    ⚠ Gate 1 OPEN: XCTest shows “Enter password to allow automation” on this Mac each run.
      One-time fix (admin password once):
        scripts/enable_unattended_uitest.sh
      Or: scripts/ios_uitest_doctor.sh --enable-gate1
EOF
  return 1
}

section_device() {
  echo "==> Paired iPhone (CoreDevice / iPhone Mirroring)"
  if [[ ! -x "$ROOT_DIR/scripts/ios_device.sh" ]]; then
    warn "ios_device.sh missing"
    return 0
  fi
  set +e
  "$ROOT_DIR/scripts/ios_device.sh" doctor 2>&1 | sed 's/^/    /'
  local st=$?
  set -e
  (( st == 0 )) || warn "device doctor reported issues (see above)"
}

section_iphone_gates() {
  cat <<'EOF'
==> iPhone gates — Apple limits on unattended physical-device XCUITest

  Gate A — device unlocked at session start (cannot be fully removed with passcode ON)
    • XCUITest needs the iPhone awake + unlocked once when the runner attaches.
    • After the handshake succeeds, the phone may auto-lock again; mirroring keeps devicectl up.
    • Symptom: “Unable to launch … device was not unlocked”, “authentication error 12”,
      “Failed to initialize for UI testing”, French “Échec d’authentification”.

  Gate B — device passcode / Face ID (~daily on iOS 15+, Apple security requirement)
    • With a passcode enabled, Apple may prompt on the phone to authorize UI automation
      roughly once per day. There is no supported API to enter the passcode for you.
    • Options (pick one for a desk test phone):
        1. Dedicated test iPhone: remove passcode (Settings → Face ID & Passcode) — CI-farm pattern.
        2. Keep passcode: unlock the phone once before the first ui-test of the day (attended).
        3. Unattended real-engine validation without UI: scripts/ios_device.sh bench (headless autorun).

  Recommended one-time phone setup (Developer Mode already required for devicectl):
    • Settings → Privacy & Security → Developer Mode → On
    • Settings → Developer → Enable UI Automation → On (when shown)
    • Trust this Mac (USB or wireless); keep iPhone Mirroring connected on the Mac

  For agent-driven exploratory UI (not XCUITest gates): mirroir MCP — phone unlocked + Mirroring up.
EOF
}

main() {
  case "${1:-}" in
    --enable-gate1)
      exec "$ROOT_DIR/scripts/enable_unattended_uitest.sh"
      ;;
    -h|--help|help) usage ;;
    "")
      local gate1_ok=0
      section_mac_gate1 && gate1_ok=1 || true
      echo
      section_device
      echo
      section_iphone_gates
      echo
      if (( gate1_ok )); then
        note "Mac Gate 1 OK. Before ui-test: unlock iPhone once, then: scripts/ios_device.sh test"
      else
        note "Fix Mac Gate 1 first: scripts/enable_unattended_uitest.sh"
      fi
      ;;
    *)
      echo "error: unknown option '$1'" >&2
      usage
      exit 2
      ;;
  esac
}

main "$@"
