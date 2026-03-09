#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT="$PROJECT_DIR/QwenVoice.xcodeproj"
SCHEME="QwenVoiceTests"
RUN_ROOT="$PROJECT_DIR/build/full-automation/$(date '+%Y%m%d-%H%M%S')"
DESTINATION="platform=macOS,arch=arm64"
CURRENT_STAGE=""

mkdir -p "$RUN_ROOT"

resolve_destination() {
    local resolved_id

    resolved_id="$(
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>/dev/null \
            | sed -n 's/.*{ platform:macOS, arch:arm64, id:\([^,]*\), name:My Mac }.*/\1/p' \
            | head -1
    )"

    if [[ -n "$resolved_id" ]]; then
        DESTINATION="platform=macOS,id=$resolved_id,arch=arm64"
    fi
}

print_failure_hint() {
    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        return
    fi

    echo ""
    echo "Automation failed during stage: $CURRENT_STAGE" >&2
    if [[ -d "$RUN_ROOT/$CURRENT_STAGE" ]]; then
        echo "Stage artifacts: $RUN_ROOT/$CURRENT_STAGE" >&2
    fi
    if [[ -L "$PROJECT_DIR/build/test/results/latest" ]]; then
        echo "Latest UI results: $(readlink "$PROJECT_DIR/build/test/results/latest")" >&2
    fi
}

run_stage() {
    local stage="$1"
    shift
    CURRENT_STAGE="$stage"
    echo ""
    echo "==> [$stage]"
    "$@"
}

trap print_failure_hint EXIT

resolve_destination

run_stage check-project-inputs "$PROJECT_DIR/scripts/check_project_inputs.sh"
run_stage backend-tests "$PROJECT_DIR/scripts/run_backend_tests.sh"

mkdir -p "$RUN_ROOT/unit-tests"
run_stage unit-tests bash -lc "
  set -euo pipefail
  xcodebuild test \
    -project '$PROJECT' \
    -scheme '$SCHEME' \
    -destination '$DESTINATION' \
    -only-testing:QwenVoiceTests \
    -resultBundlePath '$RUN_ROOT/unit-tests/TestResults.xcresult' \
    2>&1 | tee '$RUN_ROOT/unit-tests/xcodebuild.log'
"

run_stage debug-suite "$PROJECT_DIR/scripts/run_tests.sh" --suite debug --json-summary --result-dir "$RUN_ROOT/debug-suite"
run_stage all-suite "$PROJECT_DIR/scripts/run_tests.sh" --suite all --json-summary --result-dir "$RUN_ROOT/all-suite"
run_stage feature-matrix "$PROJECT_DIR/scripts/run_tests.sh" --suite feature-matrix --json-summary --result-dir "$RUN_ROOT/feature-matrix"

CURRENT_STAGE=""
echo ""
echo "Full app automation completed successfully."
echo "Artifacts: $RUN_ROOT"
