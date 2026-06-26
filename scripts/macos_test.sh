#!/usr/bin/env bash
# macOS testing/debugging/benchmarking/UI-review lane driver for Vocello.
#
# macOS is the dev host (no device/Mirroring/burn-in). The engine runs OUT-OF-PROCESS in
# an XPC service (com.qwenvoice.app.engine-service) — a separate process that can crash
# independently and be retired under memory pressure. Several lanes target the app AND the
# service. Build/run/release stay in scripts/build.sh; this script adds the lanes.
#
# usage:
#   scripts/macos_test.sh preflight                 # Xcode + signing + app + dSYMs + XPC bundle
#   scripts/macos_test.sh test                      # VocelloMacSmokeUITests → verdict + artifacts
#   scripts/macos_test.sh crashes [--test]          # collect + xcsym-symbolicate .ips (app + XPC service)
#   scripts/macos_test.sh debug                     # LLDB attach guidance (app + XPC service PID)
#   scripts/macos_test.sh logs                      # retained os_log → build/macos-logs/<run>.log
#   scripts/macos_test.sh profile [spec]            # xctrace/Instruments on app + XPC service
#   scripts/macos_test.sh review [--baseline]       # UI capture tour + baseline diff (vision MCP)
#   scripts/macos_test.sh xpc                       # XPC lifecycle: retirement/relaunch + crash isolation
#   scripts/macos_test.sh gate                      # pre-merge gate: inputs → build → test → crashes → verdict
#   scripts/macos_test.sh help

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"
APP_NAME="Vocello"
BUNDLE_ID="com.qwenvoice.app"
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
XPC_BUNDLE="$APP_BUNDLE/Contents/XPCServices/QwenVoiceEngineService.xpc"
DSYM_DIR="$ROOT_DIR/build/macos/dsyms"

note() { printf '\033[0;36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

ensure_app() { [[ -d "$APP_BUNDLE" ]] || "$SCRIPT_DIR/build.sh" build; }

# crashes [--test]: collect macOS .ips crash reports (app + XPC service) from
# ~/Library/Logs/DiagnosticReports and symbolicate against the preserved build dSYMs.
# `--test` SIGSEGVs a launched app to verify the capture→symbolicate lane end-to-end.
cmd_crashes() {
  local test_mode=0
  [[ "${1:-}" == "--test" ]] && test_mode=1
  local dr="$HOME/Library/Logs/DiagnosticReports"

  if (( test_mode )); then
    note "crash-lane self-test: launch + SIGSEGV the app to force a .ips…"
    ensure_app
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    /usr/bin/open -na "$APP_BUNDLE"
    local pid=""
    for _ in {1..20}; do pid="$(pgrep -xn "$APP_NAME" || true)"; [[ -n "$pid" ]] && break; sleep 0.25; done
    [[ -n "$pid" ]] || die "could not find $APP_NAME PID to crash"
    note "SIGSEGV pid $pid"
    kill -SEGV "$pid" 2>/dev/null || true
    sleep 5   # let macOS write the .ips
  fi

  local dest="$ROOT_DIR/build/macos/crashes-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dest"
  note "collecting .ips from $dr (app: Vocello*, service: QwenVoiceEngineService* / *engine-service*)"
  local n=0 f
  shopt -s nullglob
  for f in "$dr"/Vocello-*.ips "$dr"/QwenVoiceEngineService-*.ips "$dr"/*engine-service*.ips; do
    cp "$f" "$dest/" 2>/dev/null || true
    n=$((n+1))
  done
  shopt -u nullglob
  (( n == 0 )) && { note "no crash reports found."; rmdir "$dest" 2>/dev/null || true; return 0; }
  note "collected $n crash report(s) → $dest"

  [[ -d "$DSYM_DIR" ]] || { warn "no preserved dSYMs at $DSYM_DIR — run: scripts/build.sh build"; return 0; }
  note "── symbolication (via xcsym; install axiom-tools if missing) ──"
  for f in "$dest"/*.ips; do
    [[ -f "$f" ]] || continue
    if command -v xcsym >/dev/null 2>&1; then
      xcsym crash "$f" --dsym-dir "$DSYM_DIR" 2>&1 || warn "xcsym failed on $(basename "$f")"
    else
      warn "xcsym not on PATH — symbolicating $(basename "$f") needs axiom-tools:"
      warn "  xcsym crash \"$f\" --dsym-dir \"$DSYM_DIR\"   (or dispatch axiom:crash-analyzer)"
    fi
  done
}

# debug: launch the app and print LLDB attach commands for BOTH the app and the XPC
# engine service (a separate process — the macOS-unique bit). Dev builds have hardened
# runtime OFF, so LLDB attaches directly (no get-task-allow needed). The session is
# interactive. The XPC service is lazy — spawn it with a generation first if absent.
cmd_debug() {
  ensure_app
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  /usr/bin/open -na "$APP_BUNDLE"
  local app_pid=""
  for _ in {1..30}; do app_pid="$(pgrep -xn "$APP_NAME" || true)"; [[ -n "$app_pid" ]] && break; sleep 0.25; done
  [[ -n "$app_pid" ]] || die "$APP_NAME did not launch"
  note "debug: $APP_NAME running (pid $app_pid) — hardened runtime OFF, LLDB-attachable."
  note "  lldb -p $app_pid        # app"
  local svc_pid; svc_pid="$(pgrep -xn QwenVoiceEngineService || true)"
  if [[ -n "$svc_pid" ]]; then
    note "  lldb -p $svc_pid        # XPC engine service (pid $svc_pid)"
  else
    note "  XPC service not running yet — trigger a generation to spawn it, then:"
    note "    lldb -p \$(pgrep -xn QwenVoiceEngineService)"
  fi
  note "  (or XcodeBuildMCP debugging, or Xcode → Debug → Attach to Process by PID)"
  note "  retained os_log: scripts/macos_test.sh logs   (subsystem $BUNDLE_ID)"
}

# logs: retain the app + XPC service os_log (subsystem com.qwenvoice.app) to a file
# under build/macos-logs/<run>.log. Ctrl-C to stop.
cmd_logs() {
  local out="$ROOT_DIR/build/macos-logs/macos-logs-$(date +%Y%m%d-%H%M%S).log"
  mkdir -p "$(dirname "$out")"
  note "streaming os_log (subsystem $BUNDLE_ID) → $out (Ctrl-C to stop)"
  /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" 2>&1 | tee "$out"
  note "saved $out"
}

main() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    crashes) cmd_crashes "$@" ;;
    debug)   cmd_debug "$@" ;;
    logs)    cmd_logs "$@" ;;
    help|-h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
      ;;
    *) die "unknown subcommand '$sub' (try: preflight|test|crashes|debug|logs|profile|review|xpc|gate|help)" ;;
  esac
}

main "$@"
