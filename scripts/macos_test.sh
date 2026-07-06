#!/usr/bin/env bash
# macOS testing/debugging/benchmarking/UI-review lane driver for Vocello.
#
# macOS is the dev host (no device/Mirroring/burn-in). The engine runs OUT-OF-PROCESS in
# an XPC service (com.qwenvoice.app.engine-service) — a separate process that can crash
# independently and be retired under memory pressure. Several lanes target the app AND the
# service. Build/run/release stay in scripts/build.sh; this script adds the lanes.
#
# usage:
#   scripts/macos_test.sh preflight [--strict-models]  # Xcode + app + dSYMs + XPC + model status
#   scripts/macos_test.sh uitest-doctor [--open-accessibility]  # UI automation readiness (Gate 1–3)
#   scripts/macos_test.sh bench-ui [--modes …] [--lengths …] [--warm 3] [--label …] [--profile] [--keep]
#   scripts/macos_test.sh core-test                 # VocelloCoreTests (language semantics, no models)
#   scripts/macos_test.sh lang-bench [--subset quick|full] [--label "note"]
#                                                 # headless macOS language-hint matrix (vocello CLI)
#   scripts/macos_test.sh test                      # models ensure → VocelloMacSmokeUITests (~12 tests)
#   scripts/macos_test.sh journey                   # VocelloMacHumanJourneyUITests (phase-A flows)
#   scripts/macos_test.sh crashes [--test]          # collect + xcsym-symbolicate .ips (app + XPC service)
#   scripts/macos_test.sh debug                     # LLDB attach guidance (app + XPC service PID)
#   scripts/macos_test.sh logs                      # retained os_log → build/macos-logs/<run>.log
#   scripts/macos_test.sh profile [spec]            # models ensure → xctrace vocello bench
#   scripts/macos_test.sh review [--baseline] [--subset resting|full]  # catalog captures + baseline diff
#   scripts/macos_test.sh xpc                       # XPC lifecycle: retirement/relaunch + crash isolation
#   scripts/macos_test.sh gate                      # models → inputs → build_foundation → test → crashes
#                                                    # optional: QWENVOICE_GATE_BENCH=1 adds bounded vocello bench
#   scripts/macos_test.sh models check|ensure|install  # test model fixture (Speed variant)
#   scripts/macos_test.sh help

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"
. "$SCRIPT_DIR/lib/test_models.sh"
. "$SCRIPT_DIR/lib/uitest_signing.sh"
. "$SCRIPT_DIR/lib/xcresult_shots.sh"
test_models_init "$ROOT_DIR"
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

# Stable Apple Development signing for macOS UI tests (runner + app under test).
cmd_uitest_doctor() {
  exec "$SCRIPT_DIR/macos_uitest_doctor.sh" "$@"
}

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
  note "── symbolication (via xcsym when on PATH; else user-axiom axiom_xcsym_crash) ──"
  for f in "$dest"/*.ips; do
    [[ -f "$f" ]] || continue
    if command -v xcsym >/dev/null 2>&1; then
      xcsym crash "$f" --dsym-dir "$DSYM_DIR" 2>&1 || warn "xcsym failed on $(basename "$f")"
    else
      warn "xcsym not on PATH — use user-axiom MCP tool axiom_xcsym_crash, or:"
      warn "  xcsym crash \"$f\" --dsym-dir \"$DSYM_DIR\"   (or axiom_get_agent crash-analyzer)"
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
  local allow_bench_fail=0
  if [[ "${1:-}" == "--allow-bench-fail" ]]; then
    allow_bench_fail=1
    shift
  fi
  if [[ "${QVOICE_MAC_PROFILE_ALLOW_BENCH_FAIL:-0}" == "1" ]]; then
    allow_bench_fail=1
  fi
  local spec="${1:-custom:speed:Profile autorun.}"
  [[ "$spec" == *:* ]] || spec="custom:speed:$spec"
  local mode="${spec%%:*}"
  local rest="${spec#*:}"
  local variant="${rest%%:*}"
  local template="${QVOICE_MAC_PROFILE_TEMPLATE:-Time Profiler}"
  local duration="${QVOICE_MAC_PROFILE_DURATION:-90}"
  command -v xctrace >/dev/null 2>&1 || die "xctrace not found (install Xcode); or user-axiom axiom_xcprof_analyze / axiom_get_agent performance-profiler"
  ensure_mac_test_models --require
  local trace="$ROOT_DIR/build/macos/profile-$(date +%Y%m%d-%H%M%S).trace"
  mkdir -p "$(dirname "$trace")"
  note "profile: template='$template', ${duration}s, vocello bench (mode=$mode variant=$variant) — engine in-process"
  note "(engine OSSignpost intervals: subsystem $BUNDLE_ID, category 'performance')"
  # Start the tracer FIRST (attach mode waits for 'vocello') so it captures from launch.
  xcrun xctrace record --template "$template" --attach "vocello" \
    --time-limit "${duration}s" --output "$trace" &
  local xcpid=$!
  sleep 2
  local bench_rc=0
  QWENVOICE_DEBUG=1 "$ROOT_DIR/build/vocello" bench --modes "$mode" --variants "$variant" \
    --lengths medium --warm 1 --label "profile" >&2 || bench_rc=$?
  if (( bench_rc != 0 )); then
    if (( allow_bench_fail )); then
      warn "vocello bench returned non-zero (exit $bench_rc; trace may still be useful)"
    else
      die "vocello bench failed (exit $bench_rc); set QVOICE_MAC_PROFILE_ALLOW_BENCH_FAIL=1 or pass --allow-bench-fail to continue"
    fi
  fi
  wait "$xcpid" || true
  [[ -d "$trace" ]] || die "no trace produced at $trace"
  note "trace → $trace"
  note "analyze: open in Instruments, or: axiom_xcprof_analyze / axiom_get_agent performance-profiler / xcprof analyze \"$trace\""
  note "XPC service profile (production path): launch app, 'xctrace record --attach QwenVoiceEngineService', generate via UI."
}

# preflight: one-shot readiness — Xcode, the app bundle, the embedded XPC service,
# the preserved dSYMs, and the Speed model. Fails fast with what's missing.
cmd_preflight() {
  local rc=0
  local strict_models=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict-models) strict_models=1; shift ;;
      *) die "unknown preflight flag: $1 (try --strict-models)" ;;
    esac
  done
  note "macOS preflight"
  command -v xcodebuild >/dev/null 2>&1 && note "  xcodebuild: OK" || { warn "  xcodebuild: ✗ not found"; rc=1; }
  if [[ -d "$APP_BUNDLE" ]]; then note "  app: OK $APP_BUNDLE"; else warn "  app: ✗ not built (run: scripts/build.sh build)"; rc=1; fi
  [[ -d "$XPC_BUNDLE" ]] && note "  xpc service: OK" || warn "  xpc service: ✗ not in bundle (rebuild)"
  [[ -d "$DSYM_DIR" ]] && note "  dsyms: OK $DSYM_DIR" || warn "  dsyms: ✗ none (run: scripts/build.sh build)"
  if (( strict_models == 1 )); then
    check_mac_test_models --strict || rc=1
  else
    check_mac_test_models || warn "  models: not ready for generation lanes (run: $0 models ensure)"
  fi
  (( rc == 0 )) && note "preflight OK" || die "preflight not ready (see above)"
}

cmd_models() {
  local sub="${1:-check}"
  shift || true
  case "$sub" in
    check)
      check_mac_test_models || {
        note "Install once: $0 models ensure  (or $0 models install for canonical only)"
        note "Last resort: Vocello.app → Settings → Model Downloads"
        return 1
      }
      ;;
    ensure)
      ensure_mac_test_models --require
      ;;
    install)
      ensure_vocello_cli
      local id="${1:-pro_custom_speed}"
      note "installing $id into canonical store (shared with the app)…"
      "$TEST_MODELS_VOCELLO" models install "$id"
      link_debug_models_from_canonical || true
      ;;
    help|-h|--help)
      cat >&2 <<EOF
models — test fixture for macOS real-engine lanes

  $0 models check     read-only status (debug context, matches UI smoke)
  $0 models ensure    install if missing + link QwenVoice-Debug/models → canonical + clone voice
  $0 models install [id]   headless download via vocello (default: pro_custom_speed)

Escape: QVOICE_SKIP_MODEL_ENSURE=1  QVOICE_TEST_MODELS_NO_NETWORK=1
EOF
      ;;
    *)
      die "unknown models subcommand '$sub' (try: check|ensure|install|help)"
      ;;
  esac
}

# core-test: VocelloCoreTests (language semantics, no models).
cmd_core_test() {
  note "core-test: VocelloCoreTests (QwenVoiceCore language semantics, no models)"
  set +e
  xcodebuild test -project "$ROOT_DIR/QwenVoice.xcodeproj" -scheme QwenVoice \
    -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$ROOT_DIR/build/DerivedData" \
    CODE_SIGN_IDENTITY="-" \
    -only-testing:VocelloCoreTests \
    > "$ROOT_DIR/build/macos/core-test.log" 2>&1
  local st=$?
  set -e
  if (( st == 0 )); then
    note "core-test PASS"
  else
    warn "core-test FAIL (see build/macos/core-test.log)"
  fi
  return "$st"
}

cmd_lang_bench() {
  local subset="full" label=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subset) subset="${2:-full}"; shift 2 ;;
      --subset=*) subset="${1#*=}"; shift ;;
      --label) label="${2:-}"; shift 2 ;;
      --label=*) label="${1#*=}"; shift ;;
      *) die "unknown lang-bench arg '$1' (try --subset quick|full --label \"note\")" ;;
    esac
  done
  [[ "$subset" == "quick" || "$subset" == "full" ]] || die "--subset must be quick or full"

  local matrix="$ROOT_DIR/config/language-bench-matrix.json"
  local corpus="$ROOT_DIR/config/language-bench-corpus.json"
  [[ -f "$matrix" && -f "$corpus" ]] || die "missing language bench config"

  ensure_mac_test_models --require
  "$SCRIPT_DIR/build.sh" cli >/dev/null

  local run_id="mac-lang-bench-$(date +%Y%m%d-%H%M%S)"
  local artifacts="$ROOT_DIR/build/macos/lang-bench-$run_id"
  local diag_root
  diag_root="${HOME}/Library/Application Support/QwenVoice-Debug/diagnostics"
  mkdir -p "$artifacts"

  export QWENVOICE_DEBUG=1
  export QVOICE_MAC_BENCH_RUN_ID="$run_id"
  note "lang-bench: runID=$run_id subset=$subset (macOS in-process CLI)"

  local cell_json cell_count=0 cell_fail=0 voice_brief="A clear, steady narrator with a natural conversational tone."
  while IFS= read -r cell_json; do
    [[ -n "$cell_json" ]] || continue
    cell_count=$((cell_count + 1))
    local cell_id mode ui_hint text lang_args
    cell_id="$(CELL="$cell_json" python3 -c 'import json,os; print(json.loads(os.environ["CELL"])["id"])')"
    mode="$(CELL="$cell_json" python3 -c 'import json,os; print(json.loads(os.environ["CELL"])["mode"])')"
    ui_hint="$(CELL="$cell_json" python3 -c 'import json,os; print(json.loads(os.environ["CELL"]).get("uiHint","auto"))')"
    text="$(CELL="$cell_json" python3 -c 'import json,os; print(json.loads(os.environ["CELL"])["script"], end="")')"
    export QVOICE_MAC_BENCH_CELL="$cell_id"
    lang_args=()
    if [[ "$ui_hint" != "auto" ]]; then
      lang_args=(--language "$ui_hint")
    fi
    note "lang-bench cell $cell_count: $cell_id ($mode, uiHint=$ui_hint)"
    set +e
    if [[ "$mode" == "design" ]]; then
      "$ROOT_DIR/build/vocello" generate --mode design --variant speed \
        --voice-brief "$voice_brief" --text "$text" "${lang_args[@]}" \
        >>"$artifacts/generate.log" 2>&1
    else
      "$ROOT_DIR/build/vocello" generate --mode custom --variant speed \
        --text "$text" "${lang_args[@]}" \
        >>"$artifacts/generate.log" 2>&1
    fi
    st=$?
    set -e
    if (( st != 0 )); then
      warn "lang-bench cell $cell_id: vocello generate exit $st"
      cell_fail=$((cell_fail + 1))
    fi
  done < <(python3 - "$matrix" "$corpus" "$subset" <<'PY'
import json, sys
matrix_path, corpus_path, subset = sys.argv[1:4]
cells = json.load(open(matrix_path))["cells"]
if subset == "quick":
    cells = [c for c in cells if c.get("quick")]
corpus = {e["id"]: e["script"] for e in json.load(open(corpus_path))["languages"]}
for cell in cells:
    cell = dict(cell)
    cell["script"] = corpus[cell["scriptLang"]]
    print(json.dumps(cell, ensure_ascii=False))
PY
)

  unset QVOICE_MAC_BENCH_RUN_ID QVOICE_MAC_BENCH_CELL

  [[ "$cell_count" -gt 0 ]] || die "lang-bench: no cells for subset=$subset"

  local hint_st=0
  python3 "$ROOT_DIR/scripts/check_language_hints.py" "$diag_root" \
    --run-id "$run_id" --matrix "$matrix" --corpus "$corpus" --subset "$subset" \
    | tee "$artifacts/hint-gate.txt" || hint_st=$?

  python3 "$ROOT_DIR/scripts/summarize_generation_telemetry.py" "$diag_root" \
    ${label:+--label "$label"} >"$artifacts/summary.txt" 2>&1 || true

  {
    echo "lang-bench runID=$run_id subset=$subset cells=$cell_count generate_fail=$cell_fail"
    echo "hint_gate=$([[ $hint_st -eq 0 ]] && echo PASS || echo FAIL)"
  } | tee "$artifacts/verdict.txt"

  if (( cell_fail > 0 || hint_st != 0 )); then
    die "lang-bench FAIL · $artifacts"
  fi
  note "lang-bench PASS · $artifacts"
}

# test: run VocelloMacSmokeUITests (macOS, arm64) → a single verdict + artifacts under
# build/macos/uitest-artifacts/<run>/ (xcresult path + best-effort xcresulttool summary +
# any MAC_TEST_SCREENSHOT_DIR shots). Deep .xcresult analysis: user-axiom axiom_get_agent test-runner.
cmd_test() {
  local run_id="mac-test-$(date +%Y%m%d-%H%M%S)"
  local artifacts="$ROOT_DIR/build/macos/uitest-artifacts/$run_id"
  mkdir -p "$artifacts"
  export MAC_TEST_SCREENSHOT_DIR="$ROOT_DIR/build/macos/uitest-screenshots"
  mkdir -p "$MAC_TEST_SCREENSHOT_DIR"
  ensure_mac_test_models --require
  export QVOICE_REQUIRE_TEST_MODELS=1
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x QwenVoiceEngineService >/dev/null 2>&1 || true
  note "test: VocelloMacSmokeUITests (macOS, arm64) → $artifacts"
  load_uitest_signing_args
  local identity
  identity="$(uitest_resolve_signing_identity)"
  if [[ "$identity" != "-" ]]; then
    note "uitest signing: $identity"
  else
    warn "uitest signing: ad-hoc (TCC grants may not survive rebuilds)"
  fi
  set +e
  xcodebuild test -project "$ROOT_DIR/QwenVoice.xcodeproj" -scheme QwenVoice \
    -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$ROOT_DIR/build/DerivedData" \
    "${UITEST_XCODEBUILD_SIGNING_ARGS[@]}" \
    -only-testing:VocelloMacUITests/VocelloMacSmokeUITests \
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

# bench-ui: full-matrix macOS XPC UI benchmark (VocelloMacBenchUITests) + merged summarizer + gate.
cmd_bench_ui() {
  local modes="custom,design,clone" lengths="short,medium,long" warm=3 label="" profile=0
  local skip_doctor=0 keep=0
  local profile_template="${QVOICE_MAC_PROFILE_TEMPLATE:-Time Profiler}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --modes) modes="${2:-}"; shift 2 ;;
      --modes=*) modes="${1#*=}"; shift ;;
      --lengths) lengths="${2:-}"; shift 2 ;;
      --lengths=*) lengths="${1#*=}"; shift ;;
      --warm) warm="${2:-3}"; shift 2 ;;
      --warm=*) warm="${1#*=}"; shift ;;
      --label) label="${2:-}"; shift 2 ;;
      --label=*) label="${1#*=}"; shift ;;
      --profile) profile=1; shift ;;
      --profile-template) profile_template="${2:-Time Profiler}"; shift 2 ;;
      --profile-template=*) profile_template="${1#*=}"; shift ;;
      --skip-uitest-doctor) skip_doctor=1; shift ;;
      --keep) keep=1; shift ;;
      -h|--help|help)
        cat <<'EOF'
bench-ui — macOS XPC UI benchmark (supplementary integration lane)

  scripts/macos_test.sh bench-ui [--modes custom,design,clone] [--lengths short,medium,long]
      [--warm 3] [--label NOTE] [--profile] [--profile-template "Time Profiler"]
      [--skip-uitest-doctor] [--keep]

Dev iteration (3 takes):
  scripts/macos_test.sh bench-ui --warm 1 --lengths medium --modes custom --label smoke

Full release matrix (29 takes, Speed):
  scripts/macos_test.sh bench-ui --label xpc-bench-full
EOF
        return 0
        ;;
      *) die "unknown bench-ui flag '$1' (try --help)" ;;
    esac
  done

  if (( skip_doctor == 0 )); then
    note "bench-ui step 0: uitest doctor"
    "$SCRIPT_DIR/macos_uitest_doctor.sh" || true
    if command -v automationmodetool >/dev/null 2>&1 \
        && automationmodetool 2>&1 | grep -q 'requires user authentication'; then
      die "UI Automation still requires a password each run — fix Gate 1:
  sudo /usr/bin/automationmodetool enable-automationmode-without-authentication
(or pass --skip-uitest-doctor if you accept the prompt)"
    fi
  fi

  local run_id="xpc-bench-$(date +%Y%m%d-%H%M%S)"
  local artifacts="$ROOT_DIR/build/macos/bench-ui-$run_id"
  local diag="$HOME/Library/Application Support/QwenVoice-Debug/diagnostics"
  mkdir -p "$artifacts"
  [[ -n "$label" ]] || label="$run_id"

  ensure_mac_test_models --require
  export QVOICE_REQUIRE_TEST_MODELS=1

  if (( keep == 0 )) && [[ -d "$diag" ]]; then
    note "bench-ui: clearing prior diagnostics in $diag"
    rm -rf "$diag"
    mkdir -p "$diag/engine" "$diag/engine-service" "$diag/app"
  fi

  printf '{"modes":"%s","lengths":"%s","warm":%s}\n' "$modes" "$lengths" "$warm" \
    > /tmp/vocello-bench-matrix.json
  note "bench-ui: matrix → /tmp/vocello-bench-matrix.json (modes=$modes lengths=$lengths warm=$warm)"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$artifacts/run-start-iso.txt"

  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x QwenVoiceEngineService >/dev/null 2>&1 || true
  sleep 1

  local profile_app_pid="" profile_svc_pid=""
  if (( profile )); then
    note "bench-ui: dual-process profile ($profile_template) — poll for Vocello + QwenVoiceEngineService"
    (
      for _ in {1..120}; do
        local apid; apid="$(pgrep -xn "$APP_NAME" || true)"
        if [[ -n "$apid" ]]; then
          xctrace record --template "$profile_template" --attach "$apid" \
            --output "$artifacts/vocello.trace" \
            > "$artifacts/profile-app.log" 2>&1 &
          echo $! > "$artifacts/profile-app.pid"
          break
        fi
        sleep 2
      done
    ) &
    (
      for _ in {1..120}; do
        local spid; spid="$(pgrep -xn QwenVoiceEngineService || true)"
        if [[ -n "$spid" ]]; then
          xctrace record --template "$profile_template" --attach "$spid" \
            --output "$artifacts/engine-service.trace" \
            > "$artifacts/profile-service.log" 2>&1 &
          echo $! > "$artifacts/profile-service.pid"
          break
        fi
        sleep 5
      done
    ) &
  fi

  load_uitest_signing_args
  note "bench-ui: VocelloMacBenchUITests (modes=$modes lengths=$lengths warm=$warm) → $artifacts"
  set +e
  QWENVOICE_DEBUG=1 \
  QWENVOICE_SUPPRESS_WARMUP=1 \
  QWENVOICE_UI_TEST_HOOKS=1 \
  QVOICE_MAC_BENCH_RUN_ID="$run_id" \
  QVOICE_MAC_BENCH_MODES="$modes" \
  QVOICE_MAC_BENCH_LENGTHS="$lengths" \
  QVOICE_MAC_BENCH_WARM="$warm" \
  QVOICE_MAC_BENCH_LABEL="$label" \
  xcodebuild test -project "$ROOT_DIR/QwenVoice.xcodeproj" -scheme QwenVoice \
    -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$ROOT_DIR/build/DerivedData" \
    "${UITEST_XCODEBUILD_SIGNING_ARGS[@]}" \
    -only-testing:VocelloMacUITests/VocelloMacBenchUITests/testFullMatrix \
    > "$artifacts/bench-ui.log" 2>&1
  local st=$?
  set -e

  note "bench-ui: waiting for final telemetry merge…"
  sleep 3

  if [[ -f "$artifacts/profile-app.pid" ]]; then
    profile_app_pid="$(cat "$artifacts/profile-app.pid" 2>/dev/null || true)"
    kill "$profile_app_pid" 2>/dev/null || true
    wait "$profile_app_pid" 2>/dev/null || true
  fi
  if [[ -f "$artifacts/profile-service.pid" ]]; then
    profile_svc_pid="$(cat "$artifacts/profile-service.pid" 2>/dev/null || true)"
    kill "$profile_svc_pid" 2>/dev/null || true
    wait "$profile_svc_pid" 2>/dev/null || true
  fi

  local xcresult; xcresult="$(find "$ROOT_DIR/build/DerivedData/Logs/Test" -name '*.xcresult' -type d 2>/dev/null | sort | tail -1 || true)"
  echo "xcresult: ${xcresult:-<none>}" | tee "$artifacts/verdict.txt"
  echo "xcodebuild exit: $st" | tee -a "$artifacts/verdict.txt"

  note "bench-ui: summarizer (--merged)"
  python3 "$ROOT_DIR/scripts/summarize_generation_telemetry.py" "$diag" \
    --label "$label" --merged --show-variance \
    | tee "$artifacts/summary.log" || warn "summarizer failed or found no rows"

  note "bench-ui: XPC gate"
  local gate_st=0
  local since_iso=""
  [[ -f "$artifacts/run-start-iso.txt" ]] && since_iso="$(tr -d '\n' < "$artifacts/run-start-iso.txt")"
  python3 "$ROOT_DIR/scripts/check_macos_xpc_bench.py" "$diag" \
    --modes "$modes" --lengths "$lengths" --warm "$warm" \
    --run-id "$run_id" \
    ${since_iso:+--since-recorded "$since_iso"} \
    | tee -a "$artifacts/verdict.txt" || gate_st=$?

  if (( st == 0 && gate_st == 0 )); then
    note "bench-ui PASS · $artifacts"
  else
    warn "bench-ui FAIL (xcodebuild=$st gate=$gate_st) · $artifacts"
    exit 1
  fi
}

# review [--baseline] [--subset resting|full]: catalog-driven captures (VocelloMacReviewUITests)
cmd_review() {
  local baseline_mode=0 subset="full"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --baseline) baseline_mode=1; shift ;;
      --subset) subset="${2:-full}"; shift 2 ;;
      --subset=*) subset="${1#*=}"; shift ;;
      *) die "unknown review flag '$1' (try --baseline or --subset resting|full)" ;;
    esac
  done
  local run_id="mac-review-$(date +%Y%m%d-%H%M%S)"
  local shots="$ROOT_DIR/build/macos/review-shots/$run_id"
  local baselines="$ROOT_DIR/docs/macos-review-baselines"
  mkdir -p "$shots" "$baselines"
  note "review: macOS capture catalog (subset=$subset runID=$run_id)"
  load_uitest_signing_args
  set +e
  # TEST_RUNNER_ prefix: xcodebuild strips it and passes the var into the test-runner
  # process (plain env vars do NOT propagate). Keep the un-prefixed vars for older habits.
  MAC_TEST_SCREENSHOT_DIR="$shots" \
  QVOICE_MAC_REVIEW_SUBSET="$subset" \
  TEST_RUNNER_MAC_TEST_SCREENSHOT_DIR="$shots" \
  TEST_RUNNER_QVOICE_MAC_REVIEW_SUBSET="$subset" \
  xcodebuild test -project "$ROOT_DIR/QwenVoice.xcodeproj" \
    -scheme QwenVoice -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$ROOT_DIR/build/DerivedData" \
    "${UITEST_XCODEBUILD_SIGNING_ARGS[@]}" \
    -only-testing:VocelloMacUITests/VocelloMacReviewUITests \
    > "$shots/tour.log" 2>&1
  local st=$?
  set -e
  # Fallback: recover captures from the .xcresult attachments (always present even
  # when the runner could not write PNGs to disk).
  if ! ls "$shots"/*.png >/dev/null 2>&1; then
    local xcresult
    xcresult="$(find "$ROOT_DIR/build/DerivedData/Logs/Test" -name '*.xcresult' -type d 2>/dev/null | sort | tail -1 || true)"
    if [[ -n "$xcresult" ]]; then
      export_xcresult_shots "$xcresult" "$shots" "review-" >/dev/null 2>&1 \
        && note "captures recovered from xcresult attachments" \
        || true
    fi
  fi
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
  note "diff each pair with user-axiom axiom_get_agent screenshot-validator or a manual visual pass (expected=baseline, actual=capture)."
  (( st == 0 )) && note "review OK" || warn "review had failures (exit $st)"
  return "$st"
}

cmd_journey() {
  local run_id="mac-journey-$(date +%Y%m%d-%H%M%S)"
  local artifacts="$ROOT_DIR/build/macos/journey-artifacts/$run_id"
  mkdir -p "$artifacts"
  ensure_mac_test_models --require
  export QVOICE_REQUIRE_TEST_MODELS=1
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x QwenVoiceEngineService >/dev/null 2>&1 || true
  note "journey: VocelloMacHumanJourneyUITests → $artifacts"
  load_uitest_signing_args
  set +e
  xcodebuild test -project "$ROOT_DIR/QwenVoice.xcodeproj" -scheme QwenVoice \
    -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$ROOT_DIR/build/DerivedData" \
    "${UITEST_XCODEBUILD_SIGNING_ARGS[@]}" \
    -only-testing:VocelloMacUITests/VocelloMacHumanJourneyUITests \
    > "$artifacts/journey.log" 2>&1
  local st=$?
  set -e
  local xcresult; xcresult="$(find "$ROOT_DIR/build/DerivedData/Logs/Test" -name '*.xcresult' -type d 2>/dev/null | sort | tail -1 || true)"
  echo "xcresult: ${xcresult:-<none>}" > "$artifacts/verdict.txt"
  echo "exit: $st" >> "$artifacts/verdict.txt"
  cat "$artifacts/verdict.txt" >&2
  (( st == 0 )) && note "journey PASS · $artifacts" || { warn "journey FAIL · $artifacts"; exit "$st"; }
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
          note "  crash-isolation: killing service pid $pid ..."
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

# gate: one-command macOS pre-merge gate — check_project_inputs → build_foundation macos
# → test (VocelloMacSmokeUITests) → crashes (post-run check) → single verdict +
# build/macos/gate-<run>/. Optional bounded engine bench when QWENVOICE_GATE_BENCH=1.
# Deeper dives (bench/profile/review/xpc) are separate verbs.

GATE_BENCH_BASELINE="$ROOT_DIR/benchmarks/baselines/mac-gate-bench.json"

run_gate_bench() {
  local gate_dir="$1"
  local log="$gate_dir/bench.log"
  note "gate bench: custom/speed/medium warm×1 (engine in-process)"
  "$ROOT_DIR/scripts/build.sh" cli >>"$log" 2>&1 || return 1
  local diag
  diag="$(python3 - <<'PY'
import os
print(os.path.expanduser("~/Library/Application Support/QwenVoice-Debug/diagnostics"))
PY
)"
  # Timestamp marker to isolate THIS run's rows for audioQC + baseline compare.
  # (The engine JSONL is size-capped and auto-prunes oldest-first, so line-count
  # deltas are unreliable — filter by recordedAt instead.)
  local engine_jsonl="$diag/engine/generations.jsonl"
  local since_utc
  since_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  QWENVOICE_DEBUG=1 "$ROOT_DIR/build/vocello" bench --modes custom --variants speed \
    --lengths medium --warm 1 --label "mac-gate-bench" --force >>"$log" 2>&1 || return 1

  # Isolate the new rows into a private diagnostics tree for deterministic analysis.
  local run_diag="$gate_dir/bench-diag"
  mkdir -p "$run_diag/engine"
  [[ -f "$engine_jsonl" ]] || { echo "gate bench: no engine/generations.jsonl" >>"$log"; return 1; }
  SINCE="$since_utc" python3 - "$engine_jsonl" > "$run_diag/engine/generations.jsonl" <<'PY'
import json, os, sys
since = os.environ["SINCE"]
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        continue
    if (row.get("recordedAt") or "") >= since:
        print(line)
PY
  [[ -s "$run_diag/engine/generations.jsonl" ]] || { echo "gate bench: bench produced no new telemetry rows" >>"$log"; return 1; }

  python3 "$ROOT_DIR/scripts/summarize_generation_telemetry.py" "$run_diag" --label "mac-gate-bench" >>"$log" 2>&1 || return 1

  # audioQC must pass on every row of THIS run.
  python3 - "$run_diag/engine/generations.jsonl" <<'PY' >>"$log" 2>&1 || return 1
import json, sys
fails = []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    row = json.loads(line)
    qc = (row.get("audioQC") or {}).get("verdict")
    if qc == "fail":
        fails.append(row.get("generationID", "?"))
if fails:
    print(f"gate bench: audioQC fail on {len(fails)} row(s): {', '.join(fails)}", file=sys.stderr)
    sys.exit(1)
print("gate bench: audioQC pass on all rows")
PY

  # Regression compare vs the committed baseline (exit 2 on >5% regression).
  if [[ -f "$GATE_BENCH_BASELINE" ]]; then
    if ! python3 "$ROOT_DIR/scripts/summarize_generation_telemetry.py" "$run_diag" \
        --compare-baseline "$GATE_BENCH_BASELINE" >>"$log" 2>&1; then
      echo "gate bench: REGRESSION vs $GATE_BENCH_BASELINE (see bench.log)" >>"$log"
      return 1
    fi
    echo "gate bench: no regression vs $(basename "$GATE_BENCH_BASELINE")" >>"$log"
  else
    echo "gate bench: no committed baseline at $GATE_BENCH_BASELINE — compare skipped" >>"$log"
    echo "  (seed one: run the gate bench, then summarize_generation_telemetry.py <run-diag> --save-baseline $GATE_BENCH_BASELINE)" >>"$log"
  fi
  return 0
}

cmd_gate() {
  local run_id="mac-gate-$(date +%Y%m%d-%H%M%S)"
  local gate_dir="$ROOT_DIR/build/macos/gate-$run_id"
  local verdict="$gate_dir/verdict.txt"
  mkdir -p "$gate_dir"
  local overall=0
  local gate_bench=0
  [[ "${QWENVOICE_GATE_BENCH:-0}" == "1" ]] && gate_bench=1
  local total_steps=6
  (( gate_bench )) && total_steps=7
  { echo "Vocello macOS gate — $run_id"; echo; } | tee "$verdict"

  # Marker for the gate-fatal crash-delta check: only .ips files newer than this
  # (i.e. crashes that happen DURING the gate run) fail the gate.
  local crash_marker="$gate_dir/.crash-marker"
  touch "$crash_marker"

  note "gate step 0/$total_steps: ensure test models (pro_custom_speed in debug context)"
  if ensure_mac_test_models --require >>"$gate_dir/models.log" 2>&1; then
    echo "models: PASS" | tee -a "$verdict"
  else
    echo "models: FAIL (see models.log)" | tee -a "$verdict"; overall=1
  fi

  note "gate step 1/$total_steps: check_project_inputs"
  if "$SCRIPT_DIR/check_project_inputs.sh" >>"$gate_dir/inputs.log" 2>&1; then
    echo "check_project_inputs: PASS" | tee -a "$verdict"
  else echo "check_project_inputs: FAIL" | tee -a "$verdict"; overall=1; fi

  note "gate step 2/$total_steps: build_foundation_targets macos"
  if "$SCRIPT_DIR/build_foundation_targets.sh" macos >>"$gate_dir/build.log" 2>&1; then
    echo "build_foundation macos: PASS" | tee -a "$verdict"
  else echo "build_foundation macos: FAIL" | tee -a "$verdict"; overall=1; fi

  note "gate step 3/$total_steps: core-test (VocelloCoreTests)"
  if ( cmd_core_test ) >>"$gate_dir/core-test.log" 2>&1; then
    echo "core-test: PASS" | tee -a "$verdict"
  else echo "core-test: FAIL" | tee -a "$verdict"; overall=1; fi

  note "gate step 4/$total_steps: test (VocelloMacSmokeUITests)"
  if ( cmd_test ) >>"$gate_dir/test.log" 2>&1; then
    echo "test: PASS" | tee -a "$verdict"
  else echo "test: FAIL" | tee -a "$verdict"; overall=1; fi

  note "gate step 5/$total_steps: crashes (GATE-FATAL on new .ips during this run)"
  if ( cmd_crashes ) >>"$gate_dir/crashes.log" 2>&1; then
    local dr="$HOME/Library/Logs/DiagnosticReports"
    local new_ips
    new_ips="$(find "$dr" \( -name 'Vocello-*.ips' -o -name 'QwenVoiceEngineService-*.ips' -o -name '*engine-service*.ips' \) -newer "$crash_marker" 2>/dev/null || true)"
    if [[ -n "$new_ips" ]]; then
      echo "crashes: FAIL — new .ips during this gate run:" | tee -a "$verdict"
      echo "$new_ips" | sed 's/^/    /' | tee -a "$verdict"
      overall=1
    else
      echo "crashes: PASS (no new .ips)" | tee -a "$verdict"
    fi
  else
    echo "crashes: FAIL (check errored — see crashes.log)" | tee -a "$verdict"
    overall=1
  fi

  if (( gate_bench )); then
    note "gate step 6/$total_steps: bounded vocello bench (QWENVOICE_GATE_BENCH=1)"
    if run_gate_bench "$gate_dir"; then
      echo "bench: PASS (see bench.log)" | tee -a "$verdict"
    else
      echo "bench: FAIL (see bench.log)" | tee -a "$verdict"; overall=1
    fi
  fi

  echo | tee -a "$verdict"
  if (( overall == 0 )); then
    echo "GATE: PASS" | tee -a "$verdict"; note "gate PASS · $gate_dir"
  else
    echo "GATE: FAIL" | tee -a "$verdict"; note "gate FAIL · $gate_dir"
  fi
  cat "$verdict" >&2
  exit "$overall"
}

main() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    crashes) cmd_crashes "$@" ;;
    debug)   cmd_debug "$@" ;;
    logs)    cmd_logs "$@" ;;
    profile) cmd_profile "$@" ;;
    preflight) cmd_preflight "$@" ;;
    core-test) cmd_core_test "$@" ;;
    lang-bench) cmd_lang_bench "$@" ;;
    test)      cmd_test "$@" ;;
    journey)   cmd_journey "$@" ;;
    bench-ui)  cmd_bench_ui "$@" ;;
    review)    cmd_review "$@" ;;
    xpc)       cmd_xpc "$@" ;;
    gate)      cmd_gate "$@" ;;
    models)    cmd_models "$@" ;;
    uitest-doctor) cmd_uitest_doctor "$@" ;;
    help|-h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
      ;;
    *) die "unknown subcommand '$sub' (try: preflight|core-test|lang-bench|test|journey|bench-ui|crashes|debug|logs|profile|review|xpc|gate|models|uitest-doctor|help)" ;;
  esac
}

main "$@"
