#!/usr/bin/env bash
# Explicit native app UI automation. This command is never called by ordinary CI,
# deterministic gates, or release packaging.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/QwenVoice.xcodeproj"
MAC_DERIVED="$ROOT_DIR/build/DerivedData"
IOS_DERIVED="$ROOT_DIR/build/ios"
BUNDLE_ID_IOS="com.patricedery.vocello"
MAC_TAKE_MANIFEST="/tmp/vocello-bench-current-take.json"
MAC_APP_EXECUTABLE="$MAC_DERIVED/Build/Products/Release/Vocello.app/Contents/MacOS/Vocello"
MAC_ENGINE_EXECUTABLES=(
  "$MAC_DERIVED/Build/Products/Release/Vocello.app/Contents/XPCServices/QwenVoiceEngineService.xpc/Contents/MacOS/QwenVoiceEngineService"
  "$MAC_DERIVED/Build/Products/Release/QwenVoiceEngineService.xpc/Contents/MacOS/QwenVoiceEngineService"
)
. "$ROOT_DIR/scripts/lib/test_models.sh"
test_models_init "$ROOT_DIR"

note() { printf '\033[0;36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/ui_test.sh macos smoke
  scripts/ui_test.sh macos benchmark [--modes custom,design,clone] [--lengths short,medium,long] [--warm 3] [--label NOTE]
  scripts/ui_test.sh ios smoke
  scripts/ui_test.sh ios benchmark [--modes custom,design,clone] [--lengths short,medium,long] [--warm 3] [--label NOTE]

The iOS destination is the paired physical iPhone only. Simulator destinations are unsupported.
No lane retries automatically. A failed run keeps its log, xcresult, screenshots, and diagnostics.
EOF
  exit 2
}

[[ $# -ge 2 ]] || usage
platform="$1"
lane="$2"
shift 2
[[ "$platform" == "macos" || "$platform" == "ios" ]] || usage
[[ "$lane" == "smoke" || "$lane" == "benchmark" ]] || usage

modes="custom,design,clone"
lengths="short,medium,long"
warm=3
label=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --modes) modes="${2:?--modes requires a value}"; shift 2 ;;
    --modes=*) modes="${1#*=}"; shift ;;
    --lengths) lengths="${2:?--lengths requires a value}"; shift 2 ;;
    --lengths=*) lengths="${1#*=}"; shift ;;
    --warm) warm="${2:?--warm requires a value}"; shift 2 ;;
    --warm=*) warm="${1#*=}"; shift ;;
    --label) label="${2:?--label requires a value}"; shift 2 ;;
    --label=*) label="${1#*=}"; shift ;;
    -h|--help|help) usage ;;
    *) die "unknown flag: $1" ;;
  esac
done

if [[ "$lane" == "smoke" && ( "$modes" != "custom,design,clone" || "$lengths" != "short,medium,long" || "$warm" != 3 || -n "$label" ) ]]; then
  die "benchmark flags are accepted only by the benchmark lane"
fi

python3 - "$modes" "$lengths" "$warm" <<'PY' || exit $?
import sys
modes = [v.strip() for v in sys.argv[1].split(',') if v.strip()]
lengths = [v.strip() for v in sys.argv[2].split(',') if v.strip()]
try:
    warm = int(sys.argv[3])
except ValueError:
    raise SystemExit("error: --warm must be an integer")
if not modes or len(modes) != len(set(modes)) or set(modes) - {"custom", "design", "clone"}:
    raise SystemExit("error: --modes must be a unique subset of custom,design,clone")
if not lengths or len(lengths) != len(set(lengths)) or set(lengths) - {"short", "medium", "long"}:
    raise SystemExit("error: --lengths must be a unique subset of short,medium,long")
if warm < 1:
    raise SystemExit("error: --warm must be at least 1")
PY

if [[ "$platform" == "macos" && "$lane" == "benchmark" && ",${modes}," == *",clone,"* ]]; then
  mac_test_clone_fixture_current \
    || die "benchmark clone reference is stale; run: scripts/macos_test.sh models ensure"
fi

command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found"
[[ -d "$PROJECT" ]] || die "missing $PROJECT (run ./scripts/regenerate_project.sh)"

timestamp="$(date +%Y%m%d-%H%M%S)"
run_id="${platform}-xcui-${lane}-${timestamp}"
out="$ROOT_DIR/build/ui-tests/$platform/$run_id"
result="$out/result.xcresult"
mkdir -p "$out"
printf '%s\n' "${label:-$run_id}" >"$out/label.txt"

export_attachments() {
  [[ -d "$result" ]] || return 0
  rm -rf "$out/attachments"
  if ! xcrun xcresulttool export attachments --path "$result" \
      --output-path "$out/attachments" >"$out/attachments.log" 2>&1; then
    warn "could not export xcresult attachments (see $out/attachments.log)"
  fi
}

mac_crash_marker="$out/.mac-crash-marker"
touch "$mac_crash_marker"

check_mac_crash_delta() {
  local root="$HOME/Library/Logs/DiagnosticReports" new
  new="$(find "$root" \( -name 'Vocello-*.ips' -o -name 'QwenVoiceEngineService-*.ips' -o -name '*engine-service*.ips' \) -newer "$mac_crash_marker" -print 2>/dev/null || true)"
  [[ -z "$new" ]] || { printf '%s\n' "$new" >"$out/new-crashes.txt"; die "new Vocello crash report detected (see $out/new-crashes.txt)"; }
}

process_executable_path() {
  local pid="$1" path=""
  if command -v lsof >/dev/null 2>&1; then
    path="$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
  fi
  if [[ -z "$path" ]]; then
    path="$(ps -p "$pid" -o comm= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  fi
  printf '%s' "$path"
}

path_is_one_of() {
  local candidate="$1"
  shift
  local expected
  for expected in "$@"; do
    [[ "$candidate" == "$expected" ]] && return 0
  done
  return 1
}

terminate_owned_processes() {
  local name="$1"
  shift
  local -a expected=("$@") pids=()
  local pid path attempt alive candidates
  candidates="$(pgrep -x "$name" 2>/dev/null || true)"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    path="$(process_executable_path "$pid")"
    path_is_one_of "$path" "${expected[@]}" \
      || die "cannot establish exclusive $name ownership: PID $pid uses ${path:-an unknown executable}, not the exact XCUITest build product"
    pids+=("$pid")
  done <<<"$candidates"
  ((${#pids[@]} > 0)) || return 0

  kill "${pids[@]}" 2>/dev/null || true
  for attempt in {1..40}; do
    alive=false
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        path="$(process_executable_path "$pid")"
        if [[ -z "$path" ]] && ! kill -0 "$pid" 2>/dev/null; then
          continue
        fi
        path_is_one_of "$path" "${expected[@]}" \
          || die "$name PID $pid changed identity while waiting for termination"
        alive=true
      fi
    done
    $alive || return 0
    sleep 0.1
  done

  for pid in "${pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      path="$(process_executable_path "$pid")"
      if [[ -z "$path" ]] && ! kill -0 "$pid" 2>/dev/null; then
        continue
      fi
      path_is_one_of "$path" "${expected[@]}" \
        || die "$name PID $pid changed identity before forced termination"
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
  for attempt in {1..20}; do
    alive=false
    for pid in "${pids[@]}"; do
      kill -0 "$pid" 2>/dev/null && alive=true
    done
    $alive || return 0
    sleep 0.1
  done
  die "could not retire the owned $name process"
}

terminate_macos_app() {
  terminate_owned_processes Vocello "$MAC_APP_EXECUTABLE"
  terminate_owned_processes QwenVoiceEngineService "${MAC_ENGINE_EXECUTABLES[@]}"
}

cleanup_macos_run() {
  # Cleanup must never terminate a different installation of Vocello. A path
  # mismatch remains visible as a suite failure instead of being name-killed.
  terminate_macos_app
  rm -f "$MAC_TAKE_MANIFEST" "$MAC_TAKE_MANIFEST.next"
}

derive_team() {
  if [[ -n "${QWENVOICE_DEVELOPMENT_TEAM:-}" ]]; then
    printf '%s' "$QWENVOICE_DEVELOPMENT_TEAM"
    return
  fi
  security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | grep -oE 'OU=[A-Z0-9]+' | head -1 | cut -d= -f2
}

ios_probe() {
  python3 "$ROOT_DIR/scripts/lib/ios_coredevice_probe.py" probe
}

snapshot_ios_crashes() {
  local destination="$1"
  rm -rf "$destination"
  mkdir -p "$destination"
  if ! "$ROOT_DIR/scripts/ios_device.sh" pull "$destination/pull" \
      >"$destination/pull.log" 2>&1; then
    warn "could not collect the iPhone crash snapshot (see $destination/pull.log)"
    return 1
  fi
  while IFS= read -r -d '' crash; do
    relative="${crash#"$destination/pull/"}"
    hash="$(shasum -a 256 "$crash" | awk '{print $1}')"
    printf '%s  %s\n' "$hash" "$relative"
  done < <(find "$destination/pull" -type f -path '*/crashes/*' -print0 2>/dev/null) \
    | sort >"$destination/hashes.txt"
}

run_xcodebuild() {
  local -a command=("$@")
  set +e
  "${command[@]}" 2>&1 | while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line"
    if [[ "$line" == *"VOCELLO_BENCH_TAKE_MANIFEST="* ]]; then
      local encoded="${line##*VOCELLO_BENCH_TAKE_MANIFEST=}"
      if [[ "$encoded" =~ ^[A-Za-z0-9+/=]+$ ]]; then
        if printf '%s' "$encoded" | /usr/bin/base64 -D >"$MAC_TAKE_MANIFEST.next"; then
          mv -f "$MAC_TAKE_MANIFEST.next" "$MAC_TAKE_MANIFEST"
        fi
      fi
    fi
  done | tee "$out/xcodebuild.log"
  local -a pipeline_status=("${PIPESTATUS[@]}")
  local status=${pipeline_status[0]}
  set -e
  export_attachments
  return "$status"
}

validate_macos_benchmark() {
  local diagnostics="$HOME/Library/Application Support/QwenVoice-Debug/diagnostics"
  local status=1 attempt
  for attempt in {1..60}; do
    if python3 "$ROOT_DIR/scripts/check_macos_xpc_bench.py" "$diagnostics" \
        --run-id "$run_id" --modes "$modes" --lengths "$lengths" --warm "$warm" \
        >"$out/benchmark-gate.txt" 2>&1; then
      status=0
      break
    fi
    sleep 1
  done
  cat "$out/benchmark-gate.txt" >&2
  (( status == 0 )) || return 1
  python3 "$ROOT_DIR/scripts/summarize_generation_telemetry.py" "$diagnostics" \
    --label "${label:-$run_id}" --merged --show-variance >"$out/telemetry-summary.txt" 2>&1 || true
}

validate_ios_benchmark() {
  local diagnostics="$out/diagnostics"
  rm -rf "$diagnostics"
  "$ROOT_DIR/scripts/ios_device.sh" pull "$diagnostics" >/dev/null \
    || return 1
  if ! python3 "$ROOT_DIR/scripts/check_ios_ui_benchmark.py" "$diagnostics" \
      --run-id "$run_id" --modes "$modes" --lengths "$lengths" --warm "$warm" \
      | tee "$out/benchmark-gate.txt"; then
    return 1
  fi
  python3 "$ROOT_DIR/scripts/summarize_generation_telemetry.py" "$diagnostics" \
    --label "${label:-$run_id}" >"$out/telemetry-summary.txt" 2>&1 || true
  return 0
}

if [[ "$platform" == "macos" ]]; then
  terminate_macos_app
  trap cleanup_macos_run EXIT
  if [[ "$lane" == "smoke" ]]; then
    only_test="VocelloMacUITests/VocelloMacSmokeUITests/testSmokeJourney"
  else
    only_test="VocelloMacUITests/VocelloMacBenchmarkUITests/testOrderedConfigurableMatrix"
    rm -f "$MAC_TAKE_MANIFEST" "$MAC_TAKE_MANIFEST.next"
    export TEST_RUNNER_QVOICE_MAC_BENCH_RUN_ID="$run_id"
    export TEST_RUNNER_QVOICE_MAC_BENCH_MODES="$modes"
    export TEST_RUNNER_QVOICE_MAC_BENCH_LENGTHS="$lengths"
    export TEST_RUNNER_QVOICE_MAC_BENCH_WARM="$warm"
    export TEST_RUNNER_QVOICE_MAC_BENCH_LABEL="${label:-$run_id}"
  fi

  note "macOS XCUITest $lane → $out"
  run_xcodebuild xcodebuild test \
    -project "$PROJECT" -scheme VocelloMacUI -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$MAC_DERIVED" \
    -resultBundlePath "$result" -only-testing:"$only_test" \
    CODE_SIGN_IDENTITY="-" ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
    || die "macOS XCUITest failed (see $out/xcodebuild.log)"
  check_mac_crash_delta
  [[ "$lane" != "benchmark" ]] || validate_macos_benchmark \
    || die "macOS benchmark telemetry gate failed"
  terminate_macos_app
else
  probe="$(ios_probe)"
  device="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("identifier") or "")' <<<"$probe")"
  reachable="$(python3 -c 'import json,sys; print("1" if json.load(sys.stdin).get("reachable") else "0")' <<<"$probe")"
  locked="$(python3 -c 'import json,sys; print("1" if (json.load(sys.stdin).get("lock") or {}).get("deviceLocked") is True else "0")' <<<"$probe")"
  [[ -n "$device" && "$reachable" == "1" ]] \
    || die "paired iPhone is not reachable through CoreDevice; unlock it and check USB/local-network connectivity"
  [[ "$locked" == "0" ]] || die "paired iPhone is locked; unlock it and retry"
  team="$(derive_team || true)"
  [[ -n "$team" ]] || die "no Apple Development team found; set QWENVOICE_DEVELOPMENT_TEAM"
  snapshot_ios_crashes "$out/crashes-before" \
    || die "could not establish the pre-run iPhone crash snapshot"

  if [[ "$lane" == "smoke" ]]; then
    only_test="VocelloiOSUITests/VocelloiOSSmokeUITests/testPhysicalDeviceSmokeJourney"
  else
    only_test="VocelloiOSUITests/VocelloiOSBenchmarkUITests/testOrderedConfigurableMatrix"
    export TEST_RUNNER_QVOICE_IOS_BENCH_RUN_ID="$run_id"
    export TEST_RUNNER_QVOICE_IOS_BENCH_MODES="$modes"
    export TEST_RUNNER_QVOICE_IOS_BENCH_LENGTHS="$lengths"
    export TEST_RUNNER_QVOICE_IOS_BENCH_WARM="$warm"
    export TEST_RUNNER_QVOICE_IOS_BENCH_LABEL="${label:-$run_id}"
  fi

  note "physical-iPhone XCUITest $lane on $device → $out"
  run_xcodebuild xcodebuild test \
    -project "$PROJECT" -scheme VocelloiOSUI -configuration Release \
    -destination "id=$device" -derivedDataPath "$IOS_DERIVED" \
    -resultBundlePath "$result" -collect-test-diagnostics never \
    -only-testing:"$only_test" \
    -allowProvisioningUpdates DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic \
    || die "physical-iPhone XCUITest failed (see $out/xcodebuild.log)"

  snapshot_ios_crashes "$out/crashes-after" \
    || die "could not establish the post-run iPhone crash snapshot"
  new_crashes="$(comm -13 "$out/crashes-before/hashes.txt" "$out/crashes-after/hashes.txt" || true)"
  [[ -z "$new_crashes" ]] || { printf '%s\n' "$new_crashes" >"$out/new-crashes.txt"; die "new iPhone crash payload detected"; }
  [[ "$lane" != "benchmark" ]] || validate_ios_benchmark \
    || die "iOS benchmark telemetry gate failed"
fi

python3 - "$out/run.json" "$platform" "$lane" "$run_id" "$modes" "$lengths" "$warm" "${label:-$run_id}" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(json.dumps({
    "platform": sys.argv[2], "lane": sys.argv[3], "runID": sys.argv[4],
    "modes": sys.argv[5].split(','), "lengths": sys.argv[6].split(','),
    "warm": int(sys.argv[7]), "label": sys.argv[8], "status": "passed",
}, indent=2) + "\n", encoding="utf-8")
PY

note "$platform $lane PASS · $out"
