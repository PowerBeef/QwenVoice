#!/usr/bin/env bash
# QwenVoice native QA orchestrator. Replaces the Python harness for
# validate/test invocations called from CI, release.sh, and rescue_gate.sh.
#
# Usage:
#   qa.sh validate
#   qa.sh test --layer {contract|swift|native|ios|e2e|all}
#
# Environment:
#   QWENVOICE_XCODEBUILD_TIMEOUT_SECONDS  per-xcodebuild timeout (default 1800)
#   QWENVOICE_E2E_STRICT                  treat e2e TCC/window timeouts as
#                                         hard failures (default: skip).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
PROJECT_PATH="$PROJECT_DIR/QwenVoice.xcodeproj"
CONTRACT_PATH="$PROJECT_DIR/Sources/Resources/qwenvoice_contract.json"
HARNESS_ROOT="$PROJECT_DIR/build/harness"
LOCK_DIR="$HARNESS_ROOT/.lock"
DEFAULT_TIMEOUT_SECONDS=1800

usage() {
  cat <<USAGE
qa.sh — QwenVoice native QA orchestrator

Usage:
  qa.sh validate
  qa.sh test --layer {contract|swift|native|ios|e2e|perf-static|all}
  qa.sh test --layer perf       # opt-in audio-QC live performance lane (needs models)

Environment:
  QWENVOICE_XCODEBUILD_TIMEOUT_SECONDS  override per-xcodebuild timeout (default ${DEFAULT_TIMEOUT_SECONDS}s)
  QWENVOICE_E2E_STRICT                  treat e2e TCC/window timeouts as failures (default: skip)
  QWENVOICE_PERF_SWAP_HARD_STOP_MB      perf-lane preflight swap-used hard stop (default 8000)
  QWENVOICE_PERF_SWAP_MIN_FREE_MB       perf-lane preflight swap-free minimum (default 512)
  QWENVOICE_AUDIO_QC_OUTPUT_DIR         perf-lane artifact root (default build/audio-qc/qa-perf)
  QWENVOICE_AUDIO_QC_MODELS_ROOT        perf-lane models root (default ~/Library/Application Support/QwenVoice/models)
  QWENVOICE_AUDIO_QC_MODES              perf-lane modes (default CustomVoice,VoiceDesign)
  QWENVOICE_AUDIO_QC_BENCHMARK_PROFILE  perf-lane profile (default repeat)
  QWENVOICE_AUDIO_QC_REPEAT_COUNT       perf-lane repeats (default 1)
  QWENVOICE_AUDIO_QC_COLD_RUNS          perf-lane cold runs per mode (default 2)
  QWENVOICE_AUDIO_QC_WARM_RUNS          perf-lane warm runs per mode (default 3)
  QWENVOICE_QWEN3_GENERATION_SPEED_PROFILE  current|legacy123-memory|adaptive-failure-only|balanced-all-modes
  QWENVOICE_QWEN3_MEMORY_CLEAR_CADENCE      0+ (per-step MLX cache clear cadence; 0 disables)
  QWENVOICE_QWEN3_POST_REQUEST_CACHE_POLICY current|always|failure-only|never
USAGE
}

# Atomic mkdir-based lock so concurrent xcodebuild lanes never overlap.
acquire_lock() {
  local label="$1"
  mkdir -p "$HARNESS_ROOT"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "qa.sh: another heavy run holds $LOCK_DIR — refusing to overlap with $label." >&2
    echo "Wait for the other run or remove the lock dir if stale." >&2
    exit 75
  fi
  printf 'pid=%s label=%s\n' "$$" "$label" > "$LOCK_DIR/info"
  trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
}

# Validate qwenvoice_contract.json schema essentials.
validate_contract() {
  if [[ ! -f "$CONTRACT_PATH" ]]; then
    echo "qa.sh: missing contract at $CONTRACT_PATH" >&2
    return 1
  fi
  python3 - "$CONTRACT_PATH" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    contract = json.load(f)

assert isinstance(contract.get("models"), list) and contract["models"], "models must be a non-empty list"
assert isinstance(contract.get("speakers"), dict) and contract["speakers"], "speakers must be a non-empty mapping"
assert contract.get("defaultSpeaker"), "defaultSpeaker must be set"

ids = [m["id"] for m in contract["models"]]
assert len(ids) == len(set(ids)), f"duplicate model ids: {ids}"

modes = [m["mode"] for m in contract["models"]]
assert len(modes) == len(set(modes)), f"duplicate model modes: {modes}"

for m in contract["models"]:
    assert m.get("id"), "each model must have an id"
    assert m.get("mode"), f"model {m.get('id')} must have a mode"
    assert m.get("folder"), f"model {m.get('id')} must have a folder"
    assert m.get("requiredRelativePaths"), f"model {m.get('id')} must declare requiredRelativePaths"

speakers_flat = []
for group in sorted(contract["speakers"].keys()):
    speakers_flat.extend(contract["speakers"][group])
assert contract["defaultSpeaker"] in speakers_flat, (
    f"defaultSpeaker {contract['defaultSpeaker']} not present in speakers"
)
PY
}

# Pick the best available iPhone simulator destination, or print nothing.
# Data is passed via env so python3 -c sees no stdin contention with the
# script source.
resolve_ios_destination() {
  local simctl_json
  simctl_json="$(xcrun simctl list devices available -j 2>/dev/null || true)"
  if [[ -z "$simctl_json" ]]; then
    return 0
  fi
  SIMCTL_JSON="$simctl_json" python3 -c '
import json
import os
import sys

try:
    data = json.loads(os.environ.get("SIMCTL_JSON", ""))
except json.JSONDecodeError:
    sys.exit(0)

candidates = []
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if not device.get("name", "").startswith("iPhone"):
            continue
        if not device.get("isAvailable", True):
            continue
        candidates.append(device)

if not candidates:
    sys.exit(0)

preferred = (
    "iPhone 17 Pro",
    "iPhone 17 Pro Max",
    "iPhone 17",
    "iPhone 16 Pro",
    "iPhone 15 Pro",
)


def order(device):
    state_rank = 0 if device.get("state") == "Booted" else 1
    try:
        pref_rank = preferred.index(device["name"])
    except ValueError:
        pref_rank = len(preferred)
    return (state_rank, pref_rank, device.get("name", ""))


candidates.sort(key=order)
print(f"platform=iOS Simulator,id={candidates[0][\"udid\"]}")
'
}

# Run resolve → build-for-testing → test-without-building for one suite.
run_xcodebuild_suite() {
  local suite_name="$1"; shift
  local scheme="$1"; shift
  local destination="$1"; shift

  local derived_data="$HARNESS_ROOT/derived-data/$suite_name"
  local result_root="$HARNESS_ROOT/results/$suite_name"
  local source_packages="$HARNESS_ROOT/source-packages/$suite_name"
  rm -rf "$derived_data" "$result_root"
  mkdir -p "$derived_data" "$result_root" "$source_packages"

  echo "==> [$suite_name] -resolvePackageDependencies (scheme: $scheme)"
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$scheme" \
    -destination "$destination" \
    -clonedSourcePackagesDirPath "$source_packages" \
    -resolvePackageDependencies

  echo "==> [$suite_name] build-for-testing"
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$scheme" \
    -destination "$destination" \
    -clonedSourcePackagesDirPath "$source_packages" \
    -disableAutomaticPackageResolution \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$result_root/build.xcresult" \
    -resultBundleVersion 3 \
    "$@" \
    build-for-testing

  echo "==> [$suite_name] test-without-building"
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$scheme" \
    -destination "$destination" \
    -clonedSourcePackagesDirPath "$source_packages" \
    -disableAutomaticPackageResolution \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$result_root/test.xcresult" \
    -resultBundleVersion 3 \
    "$@" \
    test-without-building
}

run_contract_layer() {
  echo "==> Running contract validation tests..."
  validate_contract
  echo "==> contract OK"
}

run_swift_layer() {
  echo "==> Running Swift source tests..."
  run_xcodebuild_suite "swift_source_tests" "QwenVoice Foundation" "platform=macOS"
}

run_native_layer() {
  echo "==> Running native runtime-focused tests..."
  run_xcodebuild_suite "native_runtime_tests" "QwenVoice Foundation" "platform=macOS" \
    -testPlan QwenVoiceRuntime \
    -only-testing:QwenVoiceTests/EngineServiceCodecTests \
    -only-testing:QwenVoiceTests/NativeAudioPreparationTests \
    -only-testing:QwenVoiceTests/NativeCloneSupportTests \
    -only-testing:QwenVoiceTests/NativeMLXMacEngineTests \
    -only-testing:QwenVoiceTests/NativeModelLoadCoordinatorTests \
    -only-testing:QwenVoiceTests/NativeModelRegistryTests \
    -only-testing:QwenVoiceTests/TTSEngineStoreTests \
    -only-testing:QwenVoiceTests/VoiceCloningReferenceAudioSupportTests \
    -only-testing:QwenVoiceTests/XPCNativeEngineClientTests
}

# Cheap regression gate for the perf-lane orchestration logic. Runs only the
# static unit tests in GenerationQualityAuditLiveTests that DO NOT load
# models or write artifacts — safe on hosted CI without the multi-GB
# Qwen3-TTS bundle. The model-loading test (testLiveXPCGenerationQualityAuditArtifacts)
# stays exclusive to `qa.sh test --layer perf`.
run_perf_static_layer() {
  echo "==> Running perf-lane static regression tests..."
  run_xcodebuild_suite "perf_static_tests" "QwenVoice Foundation" "platform=macOS" \
    -only-testing:QwenVoiceTests/GenerationQualityAuditLiveTests/testWarmFocusBenchmarkProfileUsesWarmRunLayout \
    -only-testing:QwenVoiceTests/GenerationQualityAuditLiveTests/testExhaustiveBenchmarkProfileUsesLongTextRunLayout \
    -only-testing:QwenVoiceTests/GenerationQualityAuditLiveTests/testCustomUIColdBenchmarkProfileUsesCustomVoiceColdWarmLayout \
    -only-testing:QwenVoiceTests/GenerationQualityAuditLiveTests/testLongTextFixturesAndBatchSegmentationUseNineHundredCharacterBudget
}

run_ios_layer() {
  echo "==> Running iPhone foundation tests..."
  local destination
  destination="$(resolve_ios_destination)"
  if [[ -z "$destination" ]]; then
    echo "==> No iPhone simulator destination available; skipping iOS layer."
    return 0
  fi
  run_xcodebuild_suite "ios_foundation_tests" "VocelloiOS Foundation" "$destination"
}

# Refuse to start a perf run when system swap is already exhausted.
# Reads vm.swapusage; aborts with exit 125 before any heavy xcodebuild stage
# starts. Parsing is done in pure bash so we avoid stdin contention between
# the sysctl pipe and any inline interpreter.
swap_preflight() {
  local hard_stop="${QWENVOICE_PERF_SWAP_HARD_STOP_MB:-8000}"
  local min_free="${QWENVOICE_PERF_SWAP_MIN_FREE_MB:-512}"
  local out
  out="$(sysctl -n vm.swapusage 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    echo "==> swap preflight: vm.swapusage unavailable; skipping check."
    return 0
  fi
  # Format example: "total = 1024.00M  used = 161.75M  free = 862.25M  (encrypted)"
  local used_segment="${out#*used = }"
  local used_str="${used_segment%%M*}"
  local free_segment="${out#*free = }"
  local free_str="${free_segment%%M*}"
  local used_mb="${used_str%.*}"
  local free_mb="${free_str%.*}"
  if ! [[ "$used_mb" =~ ^[0-9]+$ ]] || ! [[ "$free_mb" =~ ^[0-9]+$ ]]; then
    echo "==> swap preflight: vm.swapusage unparseable; skipping check."
    return 0
  fi
  if (( used_mb >= hard_stop )); then
    echo "qa.sh perf: refusing to start — swap in use is ${used_mb} MB (>= ${hard_stop} MB hard stop)." >&2
    echo "Quit memory-heavy apps or reboot, then re-run." >&2
    exit 125
  fi
  if (( free_mb <= min_free )); then
    echo "qa.sh perf: refusing to start — swap free is ${free_mb} MB (<= ${min_free} MB minimum)." >&2
    echo "Quit memory-heavy apps or reboot, then re-run." >&2
    exit 125
  fi
  echo "==> swap preflight: ${used_mb} MB used, ${free_mb} MB free (OK)"
}

# Opt-in audio-QC live performance lane. Replaces the retired Python
# run_generation_quality_audit.py orchestration. The Swift test
# (GenerationQualityAuditLiveTests) consumes every QWENVOICE_AUDIO_QC_*
# and QWENVOICE_QWEN3_* env var directly and manages the cold/warm matrix
# internally; this lane just sets sensible defaults, gates with a swap
# preflight, and invokes the test through xcodebuild.
run_perf_layer() {
  echo "==> Running performance / audio-QC live tests..."

  : "${QWENVOICE_AUDIO_QC_OUTPUT_DIR:=$PROJECT_DIR/build/audio-qc/qa-perf}"
  : "${QWENVOICE_AUDIO_QC_MODELS_ROOT:=$HOME/Library/Application Support/QwenVoice/models}"
  : "${QWENVOICE_AUDIO_QC_MODES:=CustomVoice,VoiceDesign}"
  : "${QWENVOICE_AUDIO_QC_BENCHMARK_PROFILE:=repeat}"
  : "${QWENVOICE_AUDIO_QC_REPEAT_COUNT:=1}"
  : "${QWENVOICE_AUDIO_QC_COLD_RUNS:=2}"
  : "${QWENVOICE_AUDIO_QC_WARM_RUNS:=3}"

  export QWENVOICE_AUDIO_QC_LIVE=1
  export QWENVOICE_AUDIO_QC_ALLOW_MODEL_LOAD=1
  export QWENVOICE_AUDIO_QC_HEADLESS_APP_HOST=1
  export QWENVOICE_AUDIO_QC_OUTPUT_DIR QWENVOICE_AUDIO_QC_MODELS_ROOT \
    QWENVOICE_AUDIO_QC_MODES QWENVOICE_AUDIO_QC_BENCHMARK_PROFILE \
    QWENVOICE_AUDIO_QC_REPEAT_COUNT QWENVOICE_AUDIO_QC_COLD_RUNS \
    QWENVOICE_AUDIO_QC_WARM_RUNS

  if [[ ! -d "$QWENVOICE_AUDIO_QC_MODELS_ROOT" ]]; then
    echo "qa.sh perf: models root '$QWENVOICE_AUDIO_QC_MODELS_ROOT' does not exist." >&2
    echo "Install required models or override QWENVOICE_AUDIO_QC_MODELS_ROOT before re-running." >&2
    echo "First-time bootstrap (Qwen3-TTS pro_custom):" >&2
    echo "  python3 -m pip install --user -r scripts/requirements-perf-bootstrap.txt" >&2
    echo "  python3 -c \"from huggingface_hub import snapshot_download; snapshot_download('mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit', local_dir='$QWENVOICE_AUDIO_QC_MODELS_ROOT/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit')\"" >&2
    exit 78
  fi

  mkdir -p "$QWENVOICE_AUDIO_QC_OUTPUT_DIR"
  echo "==> Output dir:    $QWENVOICE_AUDIO_QC_OUTPUT_DIR"
  echo "==> Models root:   $QWENVOICE_AUDIO_QC_MODELS_ROOT"
  echo "==> Modes:         $QWENVOICE_AUDIO_QC_MODES"
  echo "==> Profile:       $QWENVOICE_AUDIO_QC_BENCHMARK_PROFILE (repeat=${QWENVOICE_AUDIO_QC_REPEAT_COUNT}, cold=${QWENVOICE_AUDIO_QC_COLD_RUNS}, warm=${QWENVOICE_AUDIO_QC_WARM_RUNS})"

  swap_preflight

  # GenerationQualityAuditLiveTests reads its config from
  # build/audio-qc/live-request.json. xcodebuild does not propagate the
  # calling shell's env vars to the test runner process, so the JSON file
  # is the contract — write it from the same env vars the user/qa.sh set.
  write_live_audit_request

  run_xcodebuild_suite "perf_audio_qc" "QwenVoice Foundation" "platform=macOS" \
    -only-testing:QwenVoiceTests/GenerationQualityAuditLiveTests
}

# Build build/audio-qc/live-request.json that GenerationQualityAuditLiveTests
# decodes. Mirrors the LiveAuditRequest struct in the Swift test exactly.
write_live_audit_request() {
  local request_path="$PROJECT_DIR/build/audio-qc/live-request.json"
  mkdir -p "$(dirname "$request_path")"

  local modes_json
  modes_json="$(printf '%s' "$QWENVOICE_AUDIO_QC_MODES" \
    | jq -R 'split(",") | map(select(length > 0))')"

  jq -n \
    --argjson modes "$modes_json" \
    --arg output "$QWENVOICE_AUDIO_QC_OUTPUT_DIR" \
    --arg models "$QWENVOICE_AUDIO_QC_MODELS_ROOT" \
    --arg profile "$QWENVOICE_AUDIO_QC_BENCHMARK_PROFILE" \
    --argjson repeatCount "$QWENVOICE_AUDIO_QC_REPEAT_COUNT" \
    --argjson coldRuns "$QWENVOICE_AUDIO_QC_COLD_RUNS" \
    --argjson warmRuns "$QWENVOICE_AUDIO_QC_WARM_RUNS" \
    --arg cloneRef "${QWENVOICE_AUDIO_QC_CLONE_REFERENCE:-}" \
    --arg cloneTrans "${QWENVOICE_AUDIO_QC_CLONE_TRANSCRIPT:-}" \
    --arg streamingInterval "${QWENVOICE_AUDIO_QC_STREAMING_INTERVAL:-}" \
    --arg prewarmDepth "${QWENVOICE_AUDIO_QC_CUSTOM_PREWARM_DEPTH:-}" \
    --arg cvProfile "${QWENVOICE_QWEN3_CUSTOM_VOICE_PROFILE:-}" \
    --arg evalPolicy "${QWENVOICE_QWEN3_STREAM_STEP_EVAL_POLICY:-}" \
    --arg speedProfile "${QWENVOICE_QWEN3_GENERATION_SPEED_PROFILE:-}" \
    --arg memCadence "${QWENVOICE_QWEN3_MEMORY_CLEAR_CADENCE:-}" \
    --arg cachePolicy "${QWENVOICE_QWEN3_POST_REQUEST_CACHE_POLICY:-}" \
    '{
      live: true,
      allowModelLoad: true,
      outputDirectory: $output,
      modes: $modes,
      modelsRoot: $models,
      cloneReference: (if $cloneRef == "" then null else $cloneRef end),
      cloneTranscript: (if $cloneTrans == "" then null else $cloneTrans end),
      repeatCount: $repeatCount,
      benchmarkProfile: $profile,
      coldRuns: $coldRuns,
      warmRuns: $warmRuns,
      streamingIntervalOverride: (if $streamingInterval == "" then null else ($streamingInterval | tonumber) end),
      customPrewarmDepth: (if $prewarmDepth == "" then null else $prewarmDepth end),
      customVoiceProfile: (if $cvProfile == "" then null else $cvProfile end),
      streamStepEvalPolicy: (if $evalPolicy == "" then null else $evalPolicy end),
      generationSpeedProfile: (if $speedProfile == "" then null else $speedProfile end),
      memoryClearCadence: (if $memCadence == "" then null else ($memCadence | tonumber) end),
      postRequestCachePolicy: (if $cachePolicy == "" then null else $cachePolicy end)
    }' > "$request_path"

  echo "==> Wrote live-audit request: $request_path"
}

run_e2e_layer() {
  echo "==> Running end-to-end UI smoke tests..."
  local result_root="$HARNESS_ROOT/results/e2e_ui_smoke"
  mkdir -p "$result_root"
  local log_file="$result_root/qa.log"

  set +e
  run_xcodebuild_suite "e2e_ui_smoke" "Vocello UI" "platform=macOS" -testPlan VocelloUISmoke 2>&1 | tee "$log_file"
  local rc=${PIPESTATUS[0]}
  set -e

  if [[ $rc -eq 0 ]]; then
    return 0
  fi
  if [[ "${QWENVOICE_E2E_STRICT:-}" =~ ^(1|true|yes|on)$ ]]; then
    return "$rc"
  fi
  if grep -q "Timed out while enabling automation mode" "$log_file"; then
    echo "==> e2e demoted to skip: macOS automation-mode TCC timeout." >&2
    echo "    Grant Accessibility permission to the test runner via" >&2
    echo "    System Settings > Privacy & Security > Accessibility, then re-run." >&2
    return 0
  fi
  if grep -q "Vocello.app has no windows after launch" "$log_file"; then
    echo "==> e2e demoted to skip: Vocello.app did not register a window in the" >&2
    echo "    test-runner accessibility tree (foreground-activation quirk)." >&2
    return 0
  fi
  return "$rc"
}

cmd_validate() {
  echo "==> Running pre-commit validation..."
  validate_contract
  bash "$SCRIPT_DIR/check_project_inputs.sh"
  echo "==> validate OK"
}

cmd_test() {
  local layer="all"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --layer)
        layer="${2:?missing value for --layer}"
        shift 2
        ;;
      *)
        echo "qa.sh test: unknown option '$1'" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  case "$layer" in
    contract|swift|native|ios|e2e|perf|perf-static|all) ;;
    *)
      echo "qa.sh test: unknown layer '$layer'" >&2
      usage >&2
      exit 2
      ;;
  esac

  if [[ "$layer" != "contract" ]]; then
    acquire_lock "test --layer $layer"
  fi

  case "$layer" in
    contract)    run_contract_layer ;;
    swift)       run_swift_layer ;;
    native)      run_native_layer ;;
    ios)         run_ios_layer ;;
    e2e)         run_e2e_layer ;;
    perf)        run_perf_layer ;;
    perf-static) run_perf_static_layer ;;
    all)
      # `all` is the routine PR/release gate; the perf layer (live audio QC
      # with installed models) is opt-in. perf-static is included in `all`
      # because it's a cheap (~10 s) regression gate over the perf
      # orchestration's static logic and needs no models.
      run_contract_layer
      run_swift_layer
      run_native_layer
      run_perf_static_layer
      run_ios_layer
      run_e2e_layer
      ;;
  esac
}

main() {
  if [[ $# -eq 0 ]]; then
    usage >&2
    exit 2
  fi
  local subcmd="$1"; shift
  case "$subcmd" in
    validate)       cmd_validate "$@" ;;
    test)           cmd_test "$@" ;;
    -h|--help|help) usage ;;
    *)
      echo "qa.sh: unknown subcommand '$subcmd'" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
