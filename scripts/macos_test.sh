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

# profile [spec]: Instruments/xctrace trace of an autorun generation via the `vocello` CLI
# (engine IN-PROCESS — the deterministic engine profile; the same engine code runs in the
# XPC service). The engine emits OSSignpost intervals under subsystem com.qwenvoice.app,
# category 'performance'. Default template 'Time Profiler'; override with
# QVOICE_MAC_PROFILE_TEMPLATE ('Allocations', …) and QVOICE_MAC_PROFILE_DURATION (seconds,
# default 90). Produces build/macos/profile-<ts>.trace. (To profile the XPC service
# specifically — the production path — launch the app, 'xctrace record --attach
# QwenVoiceEngineService', and generate via the UI; see macos-testing.md.)
cmd_profile() {
  local spec="${1:-custom:speed:Profile autorun.}"
  [[ "$spec" == *:* ]] || spec="custom:speed:$spec"
  local mode="${spec%%:*}"
  local rest="${spec#*:}"
  local variant="${rest%%:*}"
  local template="${QVOICE_MAC_PROFILE_TEMPLATE:-Time Profiler}"
  local duration="${QVOICE_MAC_PROFILE_DURATION:-90}"
  command -v xctrace >/dev/null 2>&1 || die "xctrace not found (install Xcode); or dispatch axiom:performance-profiler"
  [[ -x "$ROOT_DIR/build/vocello" ]] || "$SCRIPT_DIR/build.sh" cli
  local trace="$ROOT_DIR/build/macos/profile-$(date +%Y%m%d-%H%M%S).trace"
  mkdir -p "$(dirname "$trace")"
  note "profile: template='$template', ${duration}s, vocello bench (mode=$mode variant=$variant) — engine in-process"
  note "(engine OSSignpost intervals: subsystem $BUNDLE_ID, category 'performance')"
  # Start the tracer FIRST (attach mode waits for 'vocello') so it captures from launch.
  xcrun xctrace record --template "$template" --attach "vocello" \
    --time-limit "${duration}s" --output "$trace" &
  local xcpid=$!
  sleep 2
  QWENVOICE_DEBUG=1 "$ROOT_DIR/build/vocello" bench --modes "$mode" --variants "$variant" \
    --lengths medium --warm 1 --label "profile" >&2 || warn "vocello bench returned non-zero (trace may still be useful)"
  wait "$xcpid" || true
  [[ -d "$trace" ]] || die "no trace produced at $trace"
  note "trace → $trace"
  note "analyze: open in Instruments, or: xcprof analyze \"$trace\" / axiom:performance-profiler"
  note "XPC service profile (production path): launch app, 'xctrace record --attach QwenVoiceEngineService', generate via UI."
}

# preflight: one-shot readiness — Xcode, the app bundle, the embedded XPC service, and
# the preserved dSYMs. Fails fast with what's missing.
cmd_preflight() {
  local rc=0
  note "macOS preflight"
  command -v xcodebuild >/dev/null 2>&1 && note "  xcodebuild: OK" || { warn "  xcodebuild: ✗ not found"; rc=1; }
  if [[ -d "$APP_BUNDLE" ]]; then note "  app: OK $APP_BUNDLE"; else warn "  app: ✗ not built (run: scripts/build.sh build)"; rc=1; fi
  [[ -d "$XPC_BUNDLE" ]] && note "  xpc service: OK" || warn "  xpc service: ✗ not in bundle (rebuild)"
  [[ -d "$DSYM_DIR" ]] && note "  dsyms: OK $DSYM_DIR" || warn "  dsyms: ✗ none (run: scripts/build.sh build)"
  (( rc == 0 )) && note "preflight OK" || die "preflight not ready (see above)"
}

# test: run VocelloMacSmokeUITests (macOS, arm64) → a single verdict + artifacts under
# build/macos/uitest-artifacts/<run>/ (xcresult path + best-effort xcresulttool summary +
# any MAC_TEST_SCREENSHOT_DIR shots). Deep .xcresult analysis routes to axiom:test-runner.
cmd_test() {
  local run_id="mac-test-$(date +%Y%m%d-%H%M%S)"
  local artifacts="$ROOT_DIR/build/macos/uitest-artifacts/$run_id"
  mkdir -p "$artifacts"
  export MAC_TEST_SCREENSHOT_DIR="$ROOT_DIR/build/macos/uitest-screenshots"
  mkdir -p "$MAC_TEST_SCREENSHOT_DIR"
  note "test: VocelloMacSmokeUITests (macOS, arm64) → $artifacts"
  set +e
  xcodebuild test -project "$ROOT_DIR/QwenVoice.xcodeproj" -scheme QwenVoice \
    -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$ROOT_DIR/build/DerivedData" \
    > "$artifacts/test.log" 2>&1
  local st=$?
  set -e
  local xcresult; xcresult="$(find "$ROOT_DIR/build/DerivedData/Logs/Test" -name '*.xcresult' -type d 2>/dev/null | sort | tail -1 || true)"
  {
    echo "xcresult: ${xcresult:-<none>}"
    echo "exit: $st"
    if [[ -n "$xcresult" && -d "$xcresult" ]]; then
      xcrun xcresulttool get test-results summary --format json --path "$xcresult" 2>/dev/null \
        || echo "(xcresulttool summary unavailable — open the .xcresult in Xcode)"
    fi
  } >"$artifacts/verdict.json"
  cat "$artifacts/verdict.json" >&2
  [[ -d "$MAC_TEST_SCREENSHOT_DIR" ]] && cp -R "$MAC_TEST_SCREENSHOT_DIR/." "$artifacts/screenshots" 2>/dev/null || true
  if (( st == 0 )); then note "test verdict: PASS · artifacts → $artifacts";
  else warn "test verdict: FAIL (exit $st) · artifacts → $artifacts"; exit "$st"; fi
}

# review [--baseline]: run the macOS XCUITest capture tour (VocelloMacReviewTourUITests)
# over the sidebar screens, gather captures into build/macos/review-shots/<run>/, and
# (default) print each baseline pair for a vision-MCP diff; --baseline seeds the committed
# docs/macos-review-baselines/. macOS is the host (direct capture; no burn-in concern).
cmd_review() {
  local baseline_mode=0
  [[ "${1:-}" == "--baseline" ]] && baseline_mode=1
  local run_id="mac-review-$(date +%Y%m%d-%H%M%S)"
  local shots="$ROOT_DIR/build/macos/review-shots/$run_id"
  local baselines="$ROOT_DIR/docs/macos-review-baselines"
  mkdir -p "$shots" "$baselines"
  note "review: macOS capture tour (runID=$run_id)"
  set +e
  MAC_TEST_SCREENSHOT_DIR="$shots" xcodebuild test -project "$ROOT_DIR/QwenVoice.xcodeproj" \
    -scheme QwenVoice -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$ROOT_DIR/build/DerivedData" \
    -only-testing:VocelloMacUITests/VocelloMacReviewTourUITests \
    > "$shots/tour.log" 2>&1
  local st=$?
  set -e
  note "captures → $shots"
  if (( baseline_mode == 1 )); then
    if ls "$shots"/*.png >/dev/null 2>&1; then
      cp "$shots"/*.png "$baselines/"
      note "baselines seeded/updated → $baselines (review + git add + commit)"
    else
      warn "no PNGs in $shots to seed"
    fi
    return "$st"
  fi
  note "── baseline pairs (perceptual diff via vision MCP) ──"
  local any=0 png name
  for png in "$shots"/*.png; do
    [[ -f "$png" ]] || continue
    any=1
    name="$(basename "$png")"
    if [[ -f "$baselines/$name" ]]; then
      printf '  DIFF  %s\n' "$name" >&2
      printf '        actual:   %s\n' "$png" >&2
      printf '        baseline: %s\n' "$baselines/$name" >&2
    else
      printf '  NEW   %s  (no baseline — run: %s review --baseline)\n' "$name" "$0" >&2
    fi
  done
  (( any == 0 )) && warn "no captures produced (did the tour run?)"
  note "diff each pair with mcp__zai-mcp-server__ui_diff_check (expected=baseline, actual=capture), or axiom:screenshot-validator."
  (( st == 0 )) && note "review tour OK" || warn "review tour had failures (exit $st)"
  return "$st"
}

# xpc [--crash-isolation] [--watch N]: exercise the XPC engine-service lifecycle — the
# macOS-unique dimension. The service is lazy (spawns on first generation), can be retired
# under memory pressure (idle exit), and the app must survive a service crash + reconnect
# on the next generation. This verb launches the app with a short retirement dwell and
# WATCHES the service process (spawn → retire → relaunch); with --crash-isolation it
# kills a running service to prove the app survives. Triggering a generation is manual
# (the app is UI-driven) — the verb monitors + asserts the scriptable parts. Full
# procedure + the expected app-side UX (sidebar_backendStatus_crashed / transparent
# relaunch) are documented in docs/reference/macos-testing.md.
cmd_xpc() {
  local ci=0
  [[ "${1:-}" == "--crash-isolation" ]] && ci=1
  local watch="${QVOICE_MAC_XPC_WATCH:-60}"
  ensure_app
  note "xpc: launching app with a short retirement dwell (QWENVOICE_ENGINE_RETIRE_DWELL_SECONDS=8)…"
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  QWENVOICE_DEBUG=1 QWENVOICE_ENGINE_RETIRE_DWELL_SECONDS=8 /usr/bin/open -na "$APP_BUNDLE"
  note "  ⇒ trigger a generation in the app to spawn the service; this verb watches the lifecycle."
  note "  watching QwenVoiceEngineService for ${watch}s (spawn → retire → relaunch)…"
  local seen=0 prev=0 end=$(( $(date +%s) + watch )) now pid
  while (( $(date +%s) < end )); do
    now=0; pgrep -x QwenVoiceEngineService >/dev/null 2>&1 && now=1
    if (( now != prev )); then
      if (( now == 1 )); then
        pid="$(pgrep -xn QwenVoiceEngineService || echo '?')"
        note "  service: SPAWNED (pid $pid)"
        if (( ci == 1 )) && [[ "$pid" != "?" ]]; then
          note "  crash-isolation: killing service pid $pid…"
          kill -KILL "$pid" 2>/dev/null || true
          sleep 2
          if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            note "  ✓ app ($APP_NAME) survived the service kill — crash isolation holds"
          else
            warn "  ✗ app died after the service kill — crash isolation FAILED"
          fi
          note "  (the next generation relaunches the service — keep watching)"
        fi
      else
        note "  service: retired (idle exit)"
      fi
      prev=$now; seen=1
    fi
    sleep 1
  done
  (( seen )) || warn "service never spawned — trigger a generation in the app, then re-run"
  note "done. Relaunch/reconnect is proven when the service reappears after a retire/kill on the next generation."
}

main() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    crashes) cmd_crashes "$@" ;;
    debug)   cmd_debug "$@" ;;
    logs)    cmd_logs "$@" ;;
    profile) cmd_profile "$@" ;;
    preflight) cmd_preflight "$@" ;;
    test)      cmd_test "$@" ;;
    review)    cmd_review "$@" ;;
    xpc)       cmd_xpc "$@" ;;
    help|-h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
      ;;
    *) die "unknown subcommand '$sub' (try: preflight|test|crashes|debug|logs|profile|review|xpc|gate|help)" ;;
  esac
}

main "$@"
