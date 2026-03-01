#!/bin/bash
# Tiered QwenVoice UI test runner with cached build-for-testing support.
#
# Usage:
#   ./scripts/run_tests.sh
#   ./scripts/run_tests.sh --suite ui
#   ./scripts/run_tests.sh --class SidebarNavigation
#   ./scripts/run_tests.sh --test CustomVoiceViewTests/testCustomVoiceScreenCoreLayout
#   ./scripts/run_tests.sh --list

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT="$PROJECT_DIR/QwenVoice.xcodeproj"
SCHEME="QwenVoiceUITests"
TEST_BUNDLE_ID="QwenVoiceUITests"
DESTINATION="platform=macOS"
TEST_DIR="$PROJECT_DIR/QwenVoiceUITests"
BUILD_ROOT="$PROJECT_DIR/build/test"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
RESULTS_ROOT="$BUILD_ROOT/results"
CACHE_FINGERPRINT_FILE="$BUILD_ROOT/source_fingerprint.txt"
LAST_FAILED_FILE="$BUILD_ROOT/last_failed_tests.txt"

SUITE="smoke"
CLASS_NAME=""
TEST_NAME=""
LIST_ONLY=false
FORCE_BUILD=false
NO_BUILD=false
RERUN_FAILED=false
SHARD_SPEC=""
RESULT_DIR_OVERRIDE=""
DEBUG_ON_FAIL=false
JSON_SUMMARY=false
PROBE_NAME=""

FILTERS=()
FAILED_TESTS=()
SLOW_TMP=""
BUILD_STATUS="reused"
SUMMARY_JSON_PATH=""
SUMMARY_TXT_PATH=""
SLOW_REPORT_PATH=""
RUN_RESULT_DIR=""
RESULT_BUNDLE=""
XCODEBUILD_LOG=""

usage() {
    cat <<'EOF'
Usage:
  ./scripts/run_tests.sh
  ./scripts/run_tests.sh --suite smoke|ui|integration|all|debug
  ./scripts/run_tests.sh --class <ClassName>
  ./scripts/run_tests.sh --test <ClassName/testMethod>
  ./scripts/run_tests.sh --list
  ./scripts/run_tests.sh --build
  ./scripts/run_tests.sh --no-build
  ./scripts/run_tests.sh --rerun-failed
  ./scripts/run_tests.sh --shard <index>/<count>
  ./scripts/run_tests.sh --result-dir <path>
  ./scripts/run_tests.sh --debug-on-fail
  ./scripts/run_tests.sh --json-summary
  ./scripts/run_tests.sh --probe launch-speed|generation-perf|history-accessibility|generation-benchmark

Notes:
  - Default suite is "smoke".
  - Backward compatibility is preserved for:
      ./scripts/run_tests.sh SidebarNavigation
EOF
}

if [[ "${1:-}" == "--probe" && "${2:-}" == "generation-benchmark" ]]; then
    shift 2
    exec "$SCRIPT_DIR/run_generation_benchmark.sh" "$@"
fi

append_filter() {
    FILTERS[${#FILTERS[@]}]="$1"
}

list_test_classes() {
    echo "Available test classes:"
    for f in "$TEST_DIR/"*Tests.swift; do
        basename "$f" .swift
    done
}

normalize_class_name() {
    local input="$1"
    local candidate="$input"

    if [[ -f "$TEST_DIR/$candidate.swift" ]]; then
        echo "$candidate"
        return 0
    fi

    if [[ "$candidate" != *Tests ]]; then
        candidate="${candidate}Tests"
        if [[ -f "$TEST_DIR/$candidate.swift" ]]; then
            echo "$candidate"
            return 0
        fi
    fi

    return 1
}

normalize_test_identifier() {
    local input="$1"
    local class_part method_part class_name

    if [[ "$input" == "$TEST_BUNDLE_ID/"* ]]; then
        echo "$input"
        return 0
    fi

    if [[ "$input" != */* ]]; then
        echo ""
        return 1
    fi

    class_part="${input%%/*}"
    method_part="${input#*/}"
    class_name="$(normalize_class_name "$class_part")" || return 1
    echo "$TEST_BUNDLE_ID/$class_name/$method_part"
}

collect_suite_filters() {
    local suite_name="$1"

    case "$suite_name" in
        smoke)
            append_filter "$TEST_BUNDLE_ID/SidebarNavigationTests/testSidebarNavigationAcrossAllSections"
            append_filter "$TEST_BUNDLE_ID/CustomVoiceViewTests/testCustomVoiceScreenCoreLayout"
            append_filter "$TEST_BUNDLE_ID/VoiceCloningViewTests/testVoiceCloningScreenCoreLayout"
            append_filter "$TEST_BUNDLE_ID/PreferencesViewTests/testPreferencesScreenAvailability"
            append_filter "$TEST_BUNDLE_ID/ModelsViewTests/testModelsScreenAvailability"
            append_filter "$TEST_BUNDLE_ID/HistoryViewTests/testHistoryScreenAvailability"
            append_filter "$TEST_BUNDLE_ID/VoicesViewTests/testVoicesScreenAvailability"
            ;;
        ui)
            append_filter "$TEST_BUNDLE_ID/SidebarNavigationTests"
            append_filter "$TEST_BUNDLE_ID/CustomVoiceViewTests"
            append_filter "$TEST_BUNDLE_ID/VoiceCloningViewTests"
            append_filter "$TEST_BUNDLE_ID/PreferencesViewTests"
            append_filter "$TEST_BUNDLE_ID/ModelsViewTests"
            append_filter "$TEST_BUNDLE_ID/HistoryViewTests"
            append_filter "$TEST_BUNDLE_ID/VoicesViewTests"
            ;;
        integration)
            append_filter "$TEST_BUNDLE_ID/GenerationFlowTests"
            ;;
        all)
            collect_suite_filters "ui"
            collect_suite_filters "integration"
            ;;
        debug)
            append_filter "$TEST_BUNDLE_ID/DebugHierarchyTests"
            ;;
        *)
            echo "ERROR: Unknown suite '$suite_name'." >&2
            usage >&2
            exit 1
            ;;
    esac
}

collect_probe_filters() {
    case "$PROBE_NAME" in
        launch-speed)
            SUITE="integration"
            append_filter "$TEST_BUNDLE_ID/DebugHierarchyTests/testAppWindowAndDefaultScreen"
            ;;
        generation-perf)
            SUITE="integration"
            append_filter "$TEST_BUNDLE_ID/GenerationFlowTests/testFullCustomVoiceGeneration"
            ;;
        history-accessibility)
            SUITE="debug"
            append_filter "$TEST_BUNDLE_ID/DebugHierarchyTests/testHistoryScreenIdentifiers"
            ;;
        *)
            echo "ERROR: Unknown probe '$PROBE_NAME'." >&2
            exit 1
            ;;
    esac
}

compute_source_fingerprint() {
    (
        find "$PROJECT_DIR/Sources" "$PROJECT_DIR/QwenVoiceUITests" -type f \
            \( -name '*.swift' -o -name '*.py' -o -name '*.txt' \) -print0
        printf '%s\0' "$PROJECT_DIR/project.yml" "$PROJECT_DIR/QwenVoice.xcodeproj/project.pbxproj"
    ) | xargs -0 shasum 2>/dev/null | shasum | awk '{print $1}'
}

find_xctestrun_file() {
    if [[ ! -d "$DERIVED_DATA/Build/Products" ]]; then
        return 0
    fi
    find "$DERIVED_DATA/Build/Products" -name '*.xctestrun' -type f 2>/dev/null | head -1 || true
}

ensure_build_cache() {
    local current_fingerprint cached_fingerprint xctestrun_file

    mkdir -p "$BUILD_ROOT"

    current_fingerprint="$(compute_source_fingerprint)"
    cached_fingerprint=""
    if [[ -f "$CACHE_FINGERPRINT_FILE" ]]; then
        cached_fingerprint="$(tr -d '[:space:]' < "$CACHE_FINGERPRINT_FILE")"
    fi
    xctestrun_file="$(find_xctestrun_file)"

    if [[ "$NO_BUILD" == "true" ]]; then
        if [[ -z "$xctestrun_file" ]]; then
            echo "ERROR: No cached build available in $DERIVED_DATA. Remove --no-build or run with --build." >&2
            exit 1
        fi
        BUILD_STATUS="reused"
        return
    fi

    if [[ "$FORCE_BUILD" == "true" || -z "$xctestrun_file" || "$current_fingerprint" != "$cached_fingerprint" ]]; then
        BUILD_STATUS="rebuilt"
        mkdir -p "$DERIVED_DATA"
        xcodebuild build-for-testing \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -destination "$DESTINATION" \
            -derivedDataPath "$DERIVED_DATA"
        printf '%s\n' "$current_fingerprint" > "$CACHE_FINGERPRINT_FILE"
    else
        BUILD_STATUS="reused"
    fi
}

prepare_result_paths() {
    local timestamp latest_link

    timestamp="$(date '+%Y%m%d-%H%M%S')"
    if [[ -n "$RESULT_DIR_OVERRIDE" ]]; then
        RUN_RESULT_DIR="$RESULT_DIR_OVERRIDE"
    else
        RUN_RESULT_DIR="$RESULTS_ROOT/$timestamp"
    fi

    mkdir -p "$RUN_RESULT_DIR"
    RESULT_BUNDLE="$RUN_RESULT_DIR/TestResults.xcresult"
    rm -rf "$RESULT_BUNDLE"
    XCODEBUILD_LOG="$RUN_RESULT_DIR/xcodebuild.log"
    SUMMARY_JSON_PATH="$RUN_RESULT_DIR/summary.json"
    SUMMARY_TXT_PATH="$RUN_RESULT_DIR/summary.txt"
    SLOW_REPORT_PATH="$RUN_RESULT_DIR/slow-tests.txt"
    SLOW_TMP="$RUN_RESULT_DIR/.slow-tests.tmp"
    : > "$SLOW_TMP"

    if [[ -z "$RESULT_DIR_OVERRIDE" ]]; then
        mkdir -p "$RESULTS_ROOT"
        latest_link="$RESULTS_ROOT/latest"
        rm -rf "$latest_link"
        ln -s "$RUN_RESULT_DIR" "$latest_link"
    fi
}

apply_shard_if_requested() {
    local shard_index shard_count i selected=()

    if [[ -z "$SHARD_SPEC" ]]; then
        return
    fi

    if [[ "$SHARD_SPEC" != */* ]]; then
        echo "ERROR: Invalid shard '$SHARD_SPEC'. Expected <index>/<count>." >&2
        exit 1
    fi

    shard_index="${SHARD_SPEC%%/*}"
    shard_count="${SHARD_SPEC#*/}"

    if ! [[ "$shard_index" =~ ^[0-9]+$ && "$shard_count" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Invalid shard '$SHARD_SPEC'. Expected numeric values." >&2
        exit 1
    fi
    if [[ "$shard_index" -lt 1 || "$shard_index" -gt "$shard_count" ]]; then
        echo "ERROR: Shard index must be within 1..$shard_count." >&2
        exit 1
    fi

    for (( i = 0; i < ${#FILTERS[@]}; i++ )); do
        if (( i % shard_count == shard_index - 1 )); then
            selected[${#selected[@]}]="${FILTERS[$i]}"
        fi
    done

    FILTERS=("${selected[@]}")
}

collect_requested_filters() {
    local normalized_class normalized_test

    if [[ "$RERUN_FAILED" == "true" ]]; then
        if [[ ! -s "$LAST_FAILED_FILE" ]]; then
            echo "ERROR: No failed test cache found at $LAST_FAILED_FILE." >&2
            exit 1
        fi
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            append_filter "$line"
        done < "$LAST_FAILED_FILE"
        return
    fi

    if [[ -n "$PROBE_NAME" ]]; then
        collect_probe_filters
        return
    fi

    if [[ -n "$TEST_NAME" ]]; then
        normalized_test="$(normalize_test_identifier "$TEST_NAME")" || {
            echo "ERROR: Test '$TEST_NAME' not found. Use ClassName/testMethod." >&2
            exit 1
        }
        append_filter "$normalized_test"
        return
    fi

    if [[ -n "$CLASS_NAME" ]]; then
        normalized_class="$(normalize_class_name "$CLASS_NAME")" || {
            echo "ERROR: Test class '$CLASS_NAME' not found. Run with --list to see available classes." >&2
            exit 1
        }
        append_filter "$TEST_BUNDLE_ID/$normalized_class"
        return
    fi

    collect_suite_filters "$SUITE"
}

write_failed_cache() {
    mkdir -p "$BUILD_ROOT"
    : > "$LAST_FAILED_FILE"
    if [[ "${#FAILED_TESTS[@]}" -eq 0 ]]; then
        return
    fi
    local i
    for (( i = 0; i < ${#FAILED_TESTS[@]}; i++ )); do
        printf '%s\n' "${FAILED_TESTS[$i]}" >> "$LAST_FAILED_FILE"
    done
}

parse_and_summarize_log() {
    local passed=0 failed=0 skipped=0 total=0 line
    local test_class test_name status duration test_id
    local overall_status="passed"

    while IFS= read -r line; do
        if [[ "$line" =~ Test\ Case\ \'-\[([^[:space:]]+)[[:space:]]+([^]]+)\]\'[[:space:]]+(passed|failed|skipped)[[:space:]]+\(([0-9.]+)[[:space:]]+seconds\) ]]; then
            test_class="${BASH_REMATCH[1]}"
            test_name="${BASH_REMATCH[2]}"
            status="${BASH_REMATCH[3]}"
            duration="${BASH_REMATCH[4]}"
            test_id="$TEST_BUNDLE_ID/$test_class/$test_name"
            total=$((total + 1))

            case "$status" in
                passed)
                    passed=$((passed + 1))
                    ;;
                failed)
                    failed=$((failed + 1))
                    FAILED_TESTS[${#FAILED_TESTS[@]}]="$test_id"
                    overall_status="failed"
                    ;;
                skipped)
                    skipped=$((skipped + 1))
                    ;;
            esac

            printf "%s %s\n" "$duration" "$test_id" >> "$SLOW_TMP"
        fi
    done < "$XCODEBUILD_LOG"

    if [[ -s "$SLOW_TMP" ]]; then
        sort -nr "$SLOW_TMP" | awk '{printf "%.3fs %s\n", $1, $2}' > "$SLOW_REPORT_PATH"
    else
        : > "$SLOW_REPORT_PATH"
    fi
    rm -f "$SLOW_TMP"

    write_failed_cache

    local failed_json="[]"
    if [[ "${#FAILED_TESTS[@]}" -gt 0 ]]; then
        local buffer="[" i
        for (( i = 0; i < ${#FAILED_TESTS[@]}; i++ )); do
            if (( i > 0 )); then
                buffer="$buffer,"
            fi
            buffer="$buffer\"${FAILED_TESTS[$i]}\""
        done
        buffer="$buffer]"
        failed_json="$buffer"
    fi

    cat > "$SUMMARY_TXT_PATH" <<EOF
Suite: $SUITE
Build cache: $BUILD_STATUS
Total: $total
Passed: $passed
Failed: $failed
Skipped: $skipped
Result bundle: $RESULT_BUNDLE
Log: $XCODEBUILD_LOG
Failed tests file: $LAST_FAILED_FILE
Slow tests: $SLOW_REPORT_PATH
EOF

    cat > "$SUMMARY_JSON_PATH" <<EOF
{
  "suite": "$SUITE",
  "build_cache": "$BUILD_STATUS",
  "total": $total,
  "passed": $passed,
  "failed": $failed,
  "skipped": $skipped,
  "result_bundle": "$RESULT_BUNDLE",
  "log": "$XCODEBUILD_LOG",
  "failed_tests_file": "$LAST_FAILED_FILE",
  "slow_tests_file": "$SLOW_REPORT_PATH",
  "failed_tests": $failed_json
}
EOF

    if [[ "$JSON_SUMMARY" == "true" ]]; then
        cat "$SUMMARY_JSON_PATH"
    fi

    echo ""
    echo "========================================="
    echo "           TEST RESULTS SUMMARY"
    echo "========================================="
    cat "$SUMMARY_TXT_PATH"
    echo ""
    if [[ -s "$SLOW_REPORT_PATH" ]]; then
        echo "Slowest tests:"
        sed -n '1,5p' "$SLOW_REPORT_PATH"
        echo ""
    fi
}

extract_debug_metadata() {
    if [[ "$DEBUG_ON_FAIL" != "true" && "$SUITE" != "integration" && "$SUITE" != "debug" ]]; then
        return
    fi

    if [[ ! -d "$RESULT_BUNDLE" ]]; then
        return
    fi

    if xcrun xcresulttool get --legacy --path "$RESULT_BUNDLE" --format json > "$RUN_RESULT_DIR/xcresult.json" 2>/dev/null; then
        :
    fi
}

run_tests() {
    local xctestrun_file command_status=0
    local debug_env="$DEBUG_ON_FAIL"
    local -a command

    xctestrun_file="$(find_xctestrun_file)"
    if [[ -z "$xctestrun_file" ]]; then
        echo "ERROR: Could not locate an .xctestrun file under $DERIVED_DATA." >&2
        exit 1
    fi

    command=(
        xcodebuild test-without-building
        -xctestrun "$xctestrun_file"
        -destination "$DESTINATION"
        -resultBundlePath "$RESULT_BUNDLE"
    )

    local i
    for (( i = 0; i < ${#FILTERS[@]}; i++ )); do
        command+=("-only-testing:${FILTERS[$i]}")
    done

    echo "==> Suite: $SUITE"
    echo "==> Build cache: $BUILD_STATUS"
    if [[ "${#FILTERS[@]}" -gt 0 ]]; then
        echo "==> Filters:"
        for (( i = 0; i < ${#FILTERS[@]}; i++ )); do
            echo "    - ${FILTERS[$i]}"
        done
    fi
    echo "==> Results: $RUN_RESULT_DIR"

    if [[ "$SUITE" == "integration" || "$SUITE" == "debug" ]]; then
        debug_env="true"
    fi

    set +e
    QWENVOICE_DEBUG_ON_FAIL="$debug_env" "${command[@]}" 2>&1 | tee "$XCODEBUILD_LOG"
    command_status=${PIPESTATUS[0]}
    set -e

    parse_and_summarize_log
    extract_debug_metadata
    return "$command_status"
}

# Backward-compatible shorthand: ./scripts/run_tests.sh SidebarNavigation
if [[ "${1:-}" != "" && "${1#-}" == "$1" ]]; then
    CLASS_NAME="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --suite)
            SUITE="${2:-}"
            shift 2
            ;;
        --class)
            CLASS_NAME="${2:-}"
            shift 2
            ;;
        --test)
            TEST_NAME="${2:-}"
            shift 2
            ;;
        --list)
            LIST_ONLY=true
            shift
            ;;
        --build)
            FORCE_BUILD=true
            shift
            ;;
        --no-build)
            NO_BUILD=true
            shift
            ;;
        --rerun-failed)
            RERUN_FAILED=true
            shift
            ;;
        --shard)
            SHARD_SPEC="${2:-}"
            shift 2
            ;;
        --result-dir)
            RESULT_DIR_OVERRIDE="${2:-}"
            shift 2
            ;;
        --debug-on-fail)
            DEBUG_ON_FAIL=true
            shift
            ;;
        --json-summary)
            JSON_SUMMARY=true
            shift
            ;;
        --probe)
            PROBE_NAME="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument '$1'." >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "$LIST_ONLY" == "true" ]]; then
    list_test_classes
    exit 0
fi

if [[ "$NO_BUILD" == "true" && "$FORCE_BUILD" == "true" ]]; then
    echo "ERROR: --build and --no-build cannot be used together." >&2
    exit 1
fi

collect_requested_filters
apply_shard_if_requested

if [[ "${#FILTERS[@]}" -eq 0 ]]; then
    echo "ERROR: No tests selected after applying filters." >&2
    exit 1
fi

ensure_build_cache
prepare_result_paths

if ! run_tests; then
    exit 1
fi
