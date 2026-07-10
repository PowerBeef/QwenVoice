#!/usr/bin/env bash
# One-time Mac host setup: remove the login-password prompt when XCTest enables UI Automation
# (Authorization Services Gate 1). This is now used only by on-device iOS XCUITest; macOS
# frontend acceptance uses Codex Computer Use instead of XCTest UI Automation.
#
# Requires admin once (sudo). Persists across reboots. Does not grant Accessibility/TCC and
# does not bypass the iPhone unlock / device-passcode handshake (see ios_uitest_doctor.sh).
#
# usage:
#   scripts/enable_unattended_uitest.sh
#   scripts/enable_unattended_uitest.sh --check   # status only, no sudo

set -euo pipefail

note() { printf '\033[0;36m==>\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[0;32m[ok]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

check_only=0
[[ "${1:-}" == "--check" ]] && check_only=1

if ! command -v automationmodetool >/dev/null 2>&1; then
  die "automationmodetool not found (needs Xcode CLT / Xcode.app)"
fi

out="$(automationmodetool 2>&1 || true)"
echo "$out" | sed 's/^/    /'

if grep -q 'DOES NOT REQUIRE user authentication' <<<"$out"; then
  ok "Gate 1 already closed — XCTest will not ask for your Mac login password"
  exit 0
fi

if (( check_only )); then
  warn "Gate 1 OPEN — run without --check to fix (sudo admin password once):"
  echo "    scripts/enable_unattended_uitest.sh" >&2
  exit 1
fi

note "Enabling UI Automation mode without authentication (admin password once)…"
if ! sudo /usr/bin/automationmodetool enable-automationmode-without-authentication; then
  die "automationmodetool failed — re-run in Terminal and enter your Mac login password when prompted"
fi

out="$(automationmodetool 2>&1 || true)"
if grep -q 'DOES NOT REQUIRE user authentication' <<<"$out"; then
  ok "Gate 1 closed — Mac password prompt removed for UI Automation"
  echo "$out" | sed 's/^/    /'
  note "Next: scripts/ios_uitest_doctor.sh (physical-device XCUITest only). macOS frontend QA uses Codex Computer Use."
  exit 0
fi

warn "automationmodetool ran but Gate 1 may still be open:"
echo "$out" | sed 's/^/    /'
exit 1
