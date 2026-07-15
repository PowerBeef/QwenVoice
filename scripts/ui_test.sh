#!/usr/bin/env bash
# Explicit native app UI automation. This command is never called by ordinary CI,
# deterministic gates, or release packaging.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/build_paths.sh"
. "$ROOT_DIR/scripts/lib/build_cache.sh"
. "$ROOT_DIR/scripts/lib/required_steps.sh"
PROJECT="$ROOT_DIR/QwenVoice.xcodeproj"
MAC_DERIVED="$QVOICE_XCODE_MACOS_DERIVED"
IOS_DERIVED="$QVOICE_XCODE_IOS_DERIVED"
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

validate_benchmark_label() {
  local value="$1"
  [[ -z "$value" || "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$ ]] \
    || die "--label must be an opaque 1-96 character ID using letters, digits, dot, underscore, or hyphen"
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/ui_test.sh macos smoke
  scripts/ui_test.sh macos benchmark [--modes custom,design,clone] [--lengths short,medium,long] [--warm 3] [--label RUN_ID]
  scripts/ui_test.sh ios smoke
  scripts/ui_test.sh ios benchmark [--modes custom,design,clone] [--lengths short,medium,long] [--warm 3] [--label RUN_ID]
  scripts/ui_test.sh ios model-download

The iOS destination is the paired physical iPhone only. Simulator destinations are unsupported.
`model-download` is an opt-in isolated lifecycle proof and never runs in smoke, benchmark, CI, or release.
No lane retries automatically. A failed run keeps its log, xcresult, screenshots, and diagnostics.
RUN_ID is an opaque 1-96 character identifier using letters, digits, dot, underscore, or hyphen.
EOF
  exit 2
}

[[ $# -ge 2 ]] || usage
platform="$1"
lane="$2"
shift 2
[[ "$platform" == "macos" || "$platform" == "ios" ]] || usage
[[ "$lane" == "smoke" || "$lane" == "benchmark" || "$lane" == "model-download" ]] || usage
[[ "$lane" != "model-download" || "$platform" == "ios" ]] || usage

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
validate_benchmark_label "$label"

if [[ "$lane" != "benchmark" && ( "$modes" != "custom,design,clone" || "$lengths" != "short,medium,long" || "$warm" != 3 || -n "$label" ) ]]; then
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
ensure_project_regenerated
if [[ "$platform" == "macos" ]]; then
  ensure_spm_resolved "$QVOICE_SCRATCH_PACKAGE_RESOLUTION" \
    "$QVOICE_XCODE_SOURCE_PACKAGES" ui-macos VocelloMacUI Release \
    'platform=macOS,arch=arm64'
else
  ensure_spm_resolved "$QVOICE_SCRATCH_PACKAGE_RESOLUTION" \
    "$QVOICE_XCODE_SOURCE_PACKAGES" ui-ios VocelloiOSUI Release \
    'generic/platform=iOS'
fi

timestamp="$(date -u +%Y%m%d-%H%M%S)"
nonce="$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
run_id="${platform}-xcui-${lane}-${timestamp}-${nonce}"
out="$QVOICE_ARTIFACTS_UI_TESTS/$platform/$run_id"
result="$out/result.xcresult"
mkdir -p "$out"
step_ledger="$out/required-steps.json"
required_steps_init "$step_ledger" "ui-$platform-$lane" "$run_id"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' "$started_at" >"$out/started-at.txt"
printf '%s\n' "${label:-$run_id}" >"$out/label.txt"

write_run_metadata() {
  local status="$1" finished_at="${2:-}" exit_code="${3:-}"
  python3 - "$out/run.json" "$platform" "$lane" "$run_id" "$modes" "$lengths" \
    "$warm" "${label:-$run_id}" "$started_at" "$finished_at" "$status" "$exit_code" <<'PY'
import json, os, pathlib, sys, tempfile

path = pathlib.Path(sys.argv[1])
payload = {
    "platform": sys.argv[2], "lane": sys.argv[3], "runID": sys.argv[4],
    "modes": sys.argv[5].split(','), "lengths": sys.argv[6].split(','),
    "warm": int(sys.argv[7]), "label": sys.argv[8], "status": sys.argv[11],
    "startedAt": sys.argv[9], "finishedAt": sys.argv[10] or None,
    "exitCode": int(sys.argv[12]) if sys.argv[12] else None,
    "schemaVersion": 2,
}
path.parent.mkdir(parents=True, exist_ok=True)
descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY
}

run_finalized=0
write_run_metadata running
record_early_failure() {
  local status=$?
  trap - EXIT
  set +e
  write_run_metadata failed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status"
  exit "$status"
}
trap record_early_failure EXIT
required_step_run "$step_ledger" source-provenance \
  python3 "$ROOT_DIR/scripts/publish_benchmark_history.py" snapshot \
  --output "$out/benchmark-source.json" --crash-scope none >/dev/null \
  || die "could not capture pre-run source provenance"

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

check_ios_crash_delta() {
  snapshot_ios_crashes "$out/crashes-after" || return 1
  local new_crashes
  new_crashes="$(comm -13 "$out/crashes-before/hashes.txt" "$out/crashes-after/hashes.txt" || true)"
  [[ -z "$new_crashes" ]] \
    || { printf '%s\n' "$new_crashes" >"$out/new-crashes.txt"; return 1; }
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

cleanup_ui_run() {
  local status=$?
  trap - EXIT
  set +e
  [[ "$platform" != "macos" ]] || cleanup_macos_run
  if (( run_finalized == 0 )); then
    write_run_metadata failed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status"
  fi
  exit "$status"
}

trap cleanup_ui_run EXIT

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
  # Crash gating needs the stable hashes, not another copy of the device's complete historical
  # diagnostics tree. Exact payload retrieval remains available through ios_device.sh crashes.
  rm -rf "$destination/pull"
}

pull_ios_model_download_diagnostics() {
  local device="$1" destination="$2"
  rm -rf "$destination"
  mkdir -p "$destination"
  xcrun devicectl device copy from --device "$device" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID_IOS" \
    --source "Library/Application Support/Q-Voice/model-download-acceptance/diagnostics/model-downloads" \
    --destination "$destination" >"$out/model-download-diagnostics-pull.log" 2>&1 \
    || return 1
  python3 - "$destination" <<'PY'
import json, pathlib, sys

root = pathlib.Path(sys.argv[1])
files = sorted(root.glob("*.json"))
if not files or len(files) > 20:
    raise SystemExit(f"expected 1-20 compact diagnostic records, found {len(files)}")
if sum(path.stat().st_size for path in files) > 5 * 1024 * 1024:
    raise SystemExit("model-download diagnostics exceed the 5 MiB retention contract")
records = [json.loads(path.read_text(encoding="utf-8")) for path in files]
successes = [
    record for record in records
    if record.get("kind") == "success" and record.get("finalIntegrity") is True
]
if not successes:
    raise SystemExit("missing final-integrity success summary")
latest = max(successes, key=lambda value: value.get("capturedAtUTC", ""))
latest_time = latest.get("capturedAtUTC", "")
prior_terminal_times = sorted(
    record.get("capturedAtUTC", "") for record in records
    if record.get("kind") in {"success", "failure"}
    and record.get("capturedAtUTC", "") < latest_time
)
lower_bound = prior_terminal_times[-1] if prior_terminal_times else ""
current = [
    record for record in records
    if lower_bound < record.get("capturedAtUTC", "") <= latest_time
]
metrics = [
    record for record in current
    if record.get("kind") == "task-metrics" and record.get("relativePath")
]
expected = max(
    (record.get("totalBytes", 0) for record in current if record.get("kind") == "phase"),
    default=latest.get("expectedBytes", 0),
)
wire = sum(max(0, record.get("transferredBytes", 0)) for record in metrics)
protocols = sorted({record.get("protocolName") for record in metrics if record.get("protocolName")})
if expected <= 0 or wire < expected or not protocols:
    raise SystemExit("selected success is missing complete transfer metrics")
summary = {
    "schemaVersion": 1,
    "capturedAtUTC": latest_time,
    "finalIntegrity": True,
    "expectedBytes": expected,
    "wireBytes": wire,
    "duplicateBytes": wire - expected,
    "retryCount": latest.get("retryCount", 0),
    "protocols": protocols,
    "thermalState": latest.get("thermalState"),
    "networkSeconds": latest.get("networkSeconds"),
    "verificationSeconds": latest.get("verificationSeconds"),
    "installationSeconds": latest.get("installationSeconds"),
}
(root.parent / "validated-summary.json").write_text(
    json.dumps(summary, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
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
  local evidence="$out/benchmark-evidence.json"
  local status=1 attempt
  for attempt in {1..60}; do
    if python3 "$ROOT_DIR/scripts/check_macos_xpc_bench.py" "$diagnostics" \
        --run-id "$run_id" --modes "$modes" --lengths "$lengths" --warm "$warm" \
        --label "${label:-$run_id}" --evidence-manifest "$evidence" \
        --crash-delta-passed \
        >"$out/benchmark-gate.txt" 2>&1; then
      status=0
      break
    fi
    sleep 1
  done
  cat "$out/benchmark-gate.txt" >&2
  (( status == 0 )) || return 1
  python3 "$ROOT_DIR/scripts/summarize_generation_telemetry.py" "$diagnostics" \
    --run-id "$run_id" --evidence-manifest "$evidence" \
    --label "${label:-$run_id}" --merged --show-variance \
    >"$out/telemetry-summary.txt" 2>&1
}

validate_ios_benchmark() {
  local diagnostics="$out/diagnostics"
  local evidence="$out/benchmark-evidence.json"
  local generation_map
  generation_map="$(python3 - "$out/attachments/manifest.json" "$out/attachments" <<'PY'
import json, pathlib, sys
manifest = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
if not manifest.is_file():
    raise SystemExit("missing exported attachment manifest")
matches = []
for test in json.loads(manifest.read_text(encoding="utf-8")):
    for attachment in test.get("attachments", []):
        name = attachment.get("suggestedHumanReadableName", "")
        if name.startswith("ios-benchmark-generation-map"):
            matches.append(root / attachment["exportedFileName"])
if len(matches) != 1 or not matches[0].is_file():
    raise SystemExit(f"expected one iOS generation-map attachment, found {len(matches)}")
print(matches[0])
PY
  )" || return 1
  rm -rf "$diagnostics"
  "$ROOT_DIR/scripts/ios_device.sh" pull "$diagnostics" >/dev/null \
    || return 1
  if ! python3 "$ROOT_DIR/scripts/check_ios_ui_benchmark.py" "$diagnostics" \
      --run-id "$run_id" --modes "$modes" --lengths "$lengths" --warm "$warm" \
      --generation-map "$generation_map" \
      --label "${label:-$run_id}" --evidence-manifest "$evidence" \
      --crash-delta-passed \
      | tee "$out/benchmark-gate.txt"; then
    return 1
  fi
  python3 "$ROOT_DIR/scripts/summarize_generation_telemetry.py" "$diagnostics" \
    --run-id "$run_id" --evidence-manifest "$evidence" \
    --label "${label:-$run_id}" >"$out/telemetry-summary.txt" 2>&1
  return 0
}

validate_ios_smoke() {
  local diagnostics="$out/diagnostics"
  rm -rf "$diagnostics"
  "$ROOT_DIR/scripts/ios_device.sh" pull "$diagnostics" >/dev/null \
    || return 1
  python3 "$ROOT_DIR/scripts/check_ios_smoke_acceptance.py" "$diagnostics" \
    --run-id "$run_id" | tee "$out/smoke-gate.txt"
}

if [[ "$platform" == "macos" ]]; then
  terminate_macos_app
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
  required_step_run "$step_ledger" xcuitest run_xcodebuild xcb_run test \
    -project "$PROJECT" -scheme VocelloMacUI -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$MAC_DERIVED" \
    -clonedSourcePackagesDirPath "$QVOICE_XCODE_SOURCE_PACKAGES" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    -resultBundlePath "$result" -only-testing:"$only_test" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
    SWIFT_OPTIMIZATION_LEVEL=-O \
    || die "macOS XCUITest failed (see $out/xcodebuild.log)"
  required_step_run "$step_ledger" crash-delta check_mac_crash_delta \
    || die "new Vocello crash report detected"
  write_build_provenance "$MAC_DERIVED/last-build.json" \
    "scripts/ui_test.sh macos $lane" VocelloMacUI Release \
    "platform=macOS,arch=arm64" arm64 O ad-hoc \
    "$MAC_DERIVED" "$QVOICE_XCODE_SOURCE_PACKAGES"
  write_build_provenance "$out/last-build.json" \
    "scripts/ui_test.sh macos $lane" VocelloMacUI Release \
    "platform=macOS,arch=arm64" arm64 O ad-hoc \
    "$MAC_DERIVED" "$QVOICE_XCODE_SOURCE_PACKAGES"
  [[ "$lane" != "benchmark" ]] || required_step_run "$step_ledger" \
    benchmark-validation validate_macos_benchmark \
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
  required_step_run "$step_ledger" crash-baseline \
    snapshot_ios_crashes "$out/crashes-before" \
    || die "could not establish the pre-run iPhone crash snapshot"

  if [[ "$lane" == "smoke" ]]; then
    only_test="VocelloiOSUITests/VocelloiOSSmokeUITests/testPhysicalDeviceSmokeJourney"
    export TEST_RUNNER_QVOICE_IOS_SMOKE_RUN_ID="$run_id"
  elif [[ "$lane" == "benchmark" ]]; then
    only_test="VocelloiOSUITests/VocelloiOSBenchmarkUITests/testOrderedConfigurableMatrix"
    export TEST_RUNNER_QVOICE_IOS_BENCH_RUN_ID="$run_id"
    export TEST_RUNNER_QVOICE_IOS_BENCH_MODES="$modes"
    export TEST_RUNNER_QVOICE_IOS_BENCH_LENGTHS="$lengths"
    export TEST_RUNNER_QVOICE_IOS_BENCH_WARM="$warm"
    export TEST_RUNNER_QVOICE_IOS_BENCH_LABEL="${label:-$run_id}"
  else
    only_test="VocelloiOSUITests/VocelloiOSModelDownloadUITests/testIsolatedBackgroundDownloadAdoptionAndCleanup"
  fi

  note "physical-iPhone XCUITest $lane on $device → $out"
  required_step_run "$step_ledger" xcuitest run_xcodebuild xcb_run test \
    -project "$PROJECT" -scheme VocelloiOSUI -configuration Release \
    -destination "id=$device" -derivedDataPath "$IOS_DERIVED" \
    -clonedSourcePackagesDirPath "$QVOICE_XCODE_SOURCE_PACKAGES" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    -resultBundlePath "$result" -collect-test-diagnostics never \
    -only-testing:"$only_test" \
    -allowProvisioningUpdates DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    SWIFT_OPTIMIZATION_LEVEL=-O \
    || die "physical-iPhone XCUITest failed (see $out/xcodebuild.log)"

  if [[ "$lane" == "model-download" ]]; then
    required_step_run "$step_ledger" model-download-diagnostics \
      pull_ios_model_download_diagnostics "$device" "$out/model-download-diagnostics" \
      || die "could not collect or validate compact model-download diagnostics (see $out/model-download-diagnostics-pull.log)"
  fi

  required_step_run "$step_ledger" crash-delta check_ios_crash_delta \
    || die "could not establish a clean post-run iPhone crash delta"
  [[ "$lane" != "smoke" ]] || required_step_run "$step_ledger" \
    smoke-diagnostics validate_ios_smoke \
    || die "iOS smoke memory-pressure diagnostics gate failed"
  write_build_provenance "$IOS_DERIVED/last-build.json" \
    "scripts/ui_test.sh ios $lane" VocelloiOSUI Release "id=$device" arm64 \
    O automatic "$IOS_DERIVED" "$QVOICE_XCODE_SOURCE_PACKAGES"
  write_build_provenance "$out/last-build.json" \
    "scripts/ui_test.sh ios $lane" VocelloiOSUI Release "id=$device" arm64 \
    O automatic "$IOS_DERIVED" "$QVOICE_XCODE_SOURCE_PACKAGES"
  [[ "$lane" != "benchmark" ]] || required_step_run "$step_ledger" \
    benchmark-validation validate_ios_benchmark \
    || die "iOS benchmark telemetry gate failed"
fi

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_run_metadata passed "$finished_at" 0
run_finalized=1

if [[ "$lane" == "benchmark" ]]; then
  if ! history_record="$(required_step_run "$step_ledger" history-publication \
      python3 "$ROOT_DIR/scripts/benchmark_history.py" record --artifact-dir "$out")"; then
    die "benchmark passed, but history publication failed; evidence is preserved in $out (repair: python3 scripts/benchmark_history.py record --artifact-dir '$out')"
  fi
  note "tracked benchmark record → $history_record"
fi

# Keep the most recent passing result for each platform/lane only after this
# run is durably marked as passed (and, for benchmarks, after history
# publication). Cleanup failure must not rewrite an otherwise valid UI verdict.
retention_status=0
if "$ROOT_DIR/scripts/clean_build_caches.sh" --prune-ui-results --ui-keep 1 \
    >"$out/result-retention.log" 2>&1; then
  note "pruned superseded XCUITest results (latest passing result retained per platform/lane)"
else
  retention_status=1
  warn "could not prune superseded XCUITest results (see $out/result-retention.log)"
fi
required_step_record "$step_ledger" result-retention "$retention_status"

required_steps_finalize "$step_ledger" \
  || die "$platform $lane required-step ledger did not pass"

note "$platform $lane PASS · $out"
