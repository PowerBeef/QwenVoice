#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PBXPROJ="$PROJECT_DIR/QwenVoice.xcodeproj/project.pbxproj"

if [ ! -f "$PBXPROJ" ]; then
    echo "error: missing project file at $PBXPROJ" >&2
    exit 1
fi

echo "==> Validating checked-in project inputs..."

REQUIRED_SURFACES=(
    "scripts/check_qwen3_backend_only.sh"
    "scripts/check_backend_resource_contract.sh"
    "scripts/regenerate_project.sh"
    "scripts/generate_cli_scheme.py"
    "scripts/build_foundation_targets.sh"
    "scripts/build_output_policy.py"
    "scripts/documentation_contract.py"
    "scripts/vendor_runtime_contract.py"
    "scripts/build_cleanup.py"
    "scripts/clean_build_caches.sh"
    "scripts/lib/build_paths.sh"
    "scripts/lib/build_cache.sh"
    "scripts/lib/profile_trace_retention.py"
    "scripts/ui_test.sh"
    "scripts/check_test_workflows.sh"
    "scripts/validate_backend_risk_spine.py"
    "scripts/check_ios_ui_benchmark.py"
    "scripts/benchmark_memory.py"
    "scripts/benchmark_history.py"
    "scripts/publish_benchmark_history.py"
    "scripts/ios_memory_field_report.py"
    "scripts/language_bench_evidence.py"
    "scripts/check_ios_speech_assets.py"
    "scripts/test_language_bench_evidence.py"
    "scripts/test_check_ios_speech_assets.py"
    "scripts/test_check_language_hints.py"
    "scripts/test_check_macos_xpc_bench.py"
    "scripts/test_check_ios_ui_benchmark.py"
    "scripts/test_check_language_output.py"
    "scripts/tests/test_build_output_policy.py"
    "scripts/tests/test_documentation_contract.py"
    "scripts/tests/test_vendor_runtime_contract.py"
    "scripts/tests/test_build_routing_contract.py"
    "scripts/tests/test_generate_cli_scheme.py"
    "scripts/tests/test_clean_build_caches.py"
    "scripts/tests/test_profile_trace_retention.py"
    "scripts/release.sh"
    "Sources/Resources/qwenvoice_contract.json"
    "benchmarks/hardware-profiles.json"
    "benchmarks/schema-v1.json"
    "benchmarks/schema-v2.json"
    "benchmarks/HISTORY.md"
    "benchmarks/LEGACY_HISTORY.md"
    "config/language-bench-diagnostic-cohort.json"
    "config/memory-qualification-policy.json"
    "config/build-output-policy.json"
    "config/documentation-contract.json"
    "config/public-product-facts.json"
    "config/xcode-schemes/VocelloCLI.xcscheme.template"
    "config/apple-platform-capability-matrix.json"
    "third_party_patches/mlx-audio-swift/VENDOR_MANIFEST.json"
    "third_party_patches/mlx-audio-swift/UPSTREAM_BASELINE.json"
    "third_party_patches/mlx-audio-swift/PATCHES.json"
    "Tests/UIAutomationSupport"
    "Tests/VocelloMacUITests"
    "Tests/VocelloiOSUITests"
    ".xcodebuildmcp/config.yaml"
    "project.yml"
)

for required_surface in "${REQUIRED_SURFACES[@]}"; do
    if [ ! -e "$PROJECT_DIR/$required_surface" ]; then
        echo "error: required surface is missing: $required_surface" >&2
        exit 1
    fi
done

# Validate the machine-readable generated-output contract before any producer,
# cleanup, or higher-level workflow check can rely on its paths.
python3 "$SCRIPT_DIR/build_output_policy.py" validate
python3 "$SCRIPT_DIR/generate_cli_scheme.py" --check

# iOS device tooling and explicit XCUITest are first-class. `scripts/ios_device.sh` owns
# physical-device operations; `scripts/ui_test.sh` is the sole app-UI entry point.
# The owned Qwen3 runtime now has one curated direct test target. Broad upstream
# multi-model tests remain prohibited; only this exact directory is allowed.
VENDOR_TEST_ROOT="$PROJECT_DIR/third_party_patches/mlx-audio-swift/Tests"
if [ -d "$VENDOR_TEST_ROOT" ]; then
    unexpected_vendor_test="$(find "$VENDOR_TEST_ROOT" -mindepth 1 -maxdepth 1 \
        ! -name Qwen3RuntimeTests -print -quit)"
    if [ -n "$unexpected_vendor_test" ]; then
        echo "error: unapproved vendored test surface: ${unexpected_vendor_test#"$PROJECT_DIR/"}" >&2
        exit 1
    fi
fi
# NOTE: benchmarking, output-quality, AND physical-device XCUITest surfaces are first-class
# here (runtime telemetry, scripts/summarize_generation_telemetry.py, benchmarks/,
# in-engine audioQC, scripts/ios_device.sh, and the isolated UI-test targets). Committed
# benchmark/QC summaries are allowed (bounded by the benchmarks/ cap below).

# General hygiene bans only (kept): vendored upstream tests, stale macOS-15 product /
# old build-path names, and the Python-script variants (the "no Python backend"
# standing decision — the .sh versions are canonical). UI-stack consistency is
# enforced separately by check_test_workflows.sh.
PROHIBITED_REFERENCE_PATTERNS=(
    "third_party_patches/mlx-audio-swift/Tests/(MLXAudioTTSTests|MLXAudioCodecsTests)"
    "QwenVoice-macos15.dmg"
    "build/QwenVoice.app"
    "scripts/check_qwen3_backend_only\.py"
    "scripts/check_ios_catalog\.py"
    "scripts/refresh_readme_screenshots\.py"
)

for removed_pattern in "${PROHIBITED_REFERENCE_PATTERNS[@]}"; do
    if command -v rg >/dev/null 2>&1; then
        if rg -n -e "$removed_pattern" "$PROJECT_DIR" \
            --hidden \
            --glob '!.git/**' \
            --glob '!build/**' \
            --glob '!scratch/**' \
            --glob '!**/scripts/check_project_inputs.sh' \
            --glob '!**/scripts/check_test_workflows.sh' \
            >/tmp/qwenvoice_removed_reference_grep 2>/dev/null; then
            echo "error: removed test/benchmark reference is still present:" >&2
            cat /tmp/qwenvoice_removed_reference_grep >&2
            rm -f /tmp/qwenvoice_removed_reference_grep
            exit 1
        fi
    elif git -C "$PROJECT_DIR" grep -nE "$removed_pattern" -- \
        ':!:scripts/check_project_inputs.sh' \
        ':!:scripts/check_test_workflows.sh' \
        ':!:build/**' \
        >/tmp/qwenvoice_removed_reference_grep 2>/dev/null; then
        echo "error: removed test/benchmark reference is still present:" >&2
        cat /tmp/qwenvoice_removed_reference_grep >&2
        rm -f /tmp/qwenvoice_removed_reference_grep
        exit 1
    fi
    rm -f /tmp/qwenvoice_removed_reference_grep
done

XCODE_MCP_CONFIG="$PROJECT_DIR/.xcodebuildmcp/config.yaml"
if grep -niE 'simulator|ui-automation|ios-sim|^[[:space:]]*(deviceId|device_id|udid):' "$XCODE_MCP_CONFIG" >/tmp/qwenvoice_xcode_mcp_forbidden; then
    echo "error: .xcodebuildmcp/config.yaml contains a prohibited destination, workflow, or committed device identifier:" >&2
    cat /tmp/qwenvoice_xcode_mcp_forbidden >&2
    rm -f /tmp/qwenvoice_xcode_mcp_forbidden
    exit 1
fi
rm -f /tmp/qwenvoice_xcode_mcp_forbidden

actual_workflows="$(sed -n '/^enabledWorkflows:/,/^activeSessionDefaultsProfile:/p' "$XCODE_MCP_CONFIG" \
    | sed -n 's/^[[:space:]]*-[[:space:]]*\([^#[:space:]]*\).*/\1/p' | sort | tr '\n' ' ')"
expected_workflows="debugging device macos project-discovery "
if [ "$actual_workflows" != "$expected_workflows" ]; then
    echo "error: unexpected XcodeBuildMCP workflows: $actual_workflows" >&2
    echo "expected: $expected_workflows" >&2
    exit 1
fi

for profile in macos ios-device; do
    grep -qE "^[[:space:]]{2}${profile}:$" "$XCODE_MCP_CONFIG" \
        || { echo "error: missing XcodeBuildMCP profile: $profile" >&2; exit 1; }
done

GENERATION_PREWARM_PATH="$PROJECT_DIR/Sources/Views/Generate"
if [ -d "$GENERATION_PREWARM_PATH" ]; then
    if command -v rg >/dev/null 2>&1; then
        if rg -n -e "prewarmModelIfNeeded" "$GENERATION_PREWARM_PATH" \
            --glob '*.swift' \
            >/tmp/qwenvoice_generation_prewarm_grep 2>/dev/null; then
            echo "error: generation views must not start model prewarm directly:" >&2
            cat /tmp/qwenvoice_generation_prewarm_grep >&2
            rm -f /tmp/qwenvoice_generation_prewarm_grep
            exit 1
        fi
    elif git -C "$PROJECT_DIR" grep -n "prewarmModelIfNeeded" -- Sources/Views/Generate \
        >/tmp/qwenvoice_generation_prewarm_grep 2>/dev/null; then
        echo "error: generation views must not start model prewarm directly:" >&2
        cat /tmp/qwenvoice_generation_prewarm_grep >&2
        rm -f /tmp/qwenvoice_generation_prewarm_grep
        exit 1
    fi
    rm -f /tmp/qwenvoice_generation_prewarm_grep
fi

CONTENT_VIEW_PATH="$PROJECT_DIR/Sources/ContentView.swift"
if [ -f "$CONTENT_VIEW_PATH" ]; then
    sed -n '/struct ContentView: View/,/private struct CustomVoiceScreenHost/p' "$CONTENT_VIEW_PATH" \
        >/tmp/qwenvoice_content_router_region
    if grep -n -e "@EnvironmentObject.*AudioPlayerViewModel" /tmp/qwenvoice_content_router_region \
        >/tmp/qwenvoice_content_router_audio_grep 2>/dev/null; then
        echo "error: ContentView routing must not observe AudioPlayerViewModel directly:" >&2
        cat /tmp/qwenvoice_content_router_audio_grep >&2
        rm -f /tmp/qwenvoice_content_router_region /tmp/qwenvoice_content_router_audio_grep
        exit 1
    fi
    rm -f /tmp/qwenvoice_content_router_region /tmp/qwenvoice_content_router_audio_grep
fi

SIDEBAR_VIEW_PATH="$PROJECT_DIR/Sources/Views/Sidebar/SidebarView.swift"
if [ -f "$SIDEBAR_VIEW_PATH" ]; then
    sed -n '/struct SidebarView: View/,/private struct SidebarFooterRegion/p' "$SIDEBAR_VIEW_PATH" \
        >/tmp/qwenvoice_sidebar_list_region
    if grep -n -e "@EnvironmentObject.*AudioPlayerViewModel" /tmp/qwenvoice_sidebar_list_region \
        >/tmp/qwenvoice_sidebar_list_audio_grep 2>/dev/null; then
        echo "error: SidebarView list routing must not observe AudioPlayerViewModel directly:" >&2
        cat /tmp/qwenvoice_sidebar_list_audio_grep >&2
        rm -f /tmp/qwenvoice_sidebar_list_region /tmp/qwenvoice_sidebar_list_audio_grep
        exit 1
    fi
    rm -f /tmp/qwenvoice_sidebar_list_region /tmp/qwenvoice_sidebar_list_audio_grep
fi

if grep -n "QW_TEST_SUPPORT" "$PROJECT_DIR/project.yml" >/dev/null 2>&1; then
    echo "error: QW_TEST_SUPPORT must not be configured in the single shippable project." >&2
    grep -n "QW_TEST_SUPPORT" "$PROJECT_DIR/project.yml" >&2 || true
    exit 1
fi

if grep -nE 'path = .*(__pycache__|\.pyc)' "$PBXPROJ" >/dev/null 2>&1; then
    echo "error: project references local-only Python cache files." >&2
    echo "Remove __pycache__/*.pyc references from QwenVoice.xcodeproj before committing." >&2
    grep -nE 'path = .*(__pycache__|\.pyc)' "$PBXPROJ" >&2 || true
    exit 1
fi

if [ -d "$PROJECT_DIR/Assets.xcassets" ]; then
    echo "error: retired repo-root Assets.xcassets directory is present." >&2
    echo "Keep the asset catalog under Sources/Assets.xcassets and remove the stale root directory." >&2
    exit 1
fi

# Committed benchmark logs are permitted but must stay bounded: only compact
# human-readable summaries under benchmarks/, each <= 256 KB. Raw telemetry,
# audio, screenshots, trace/crash logs, and result/profile bundles belong under
# ignored local artifact roots, never in benchmark history. The Python registry
# validator additionally enforces the exact benchmarks/runs/<kind>/<run-id>.json
# layout so renaming raw evidence cannot bypass CI.
BENCHMARKS_DIR="$PROJECT_DIR/benchmarks"
if [ -d "$BENCHMARKS_DIR" ]; then
    BENCH_MAX_BYTES=$((256 * 1024))
    raw_benchmark_artifacts="$(find "$BENCHMARKS_DIR" \
      \( -type f \( \
        -iname '*.jsonl' -o -iname '*.ndjson' -o -iname '*.jsonlines' \
        -o -iname '*.log' -o -iname '*.ips' -o -iname '*.tracev3' \
        -o -iname '*.wav' -o -iname '*.wave' -o -iname '*.aif' -o -iname '*.aiff' \
        -o -iname '*.caf' -o -iname '*.flac' -o -iname '*.mp3' -o -iname '*.m4a' \
        -o -iname '*.ogg' -o -iname '*.opus' \
        -o -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' \
        -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.tif' -o -iname '*.tiff' \
        -o -iname '*.webp' -o -iname '*.bmp' \
        -o -iname '*.xcresult' -o -iname '*.trace' -o -iname '*.xcarchive' -o -iname '*.dsym' \
      \) -o -type d \( \
        -iname '*.xcresult' -o -iname '*.trace' -o -iname '*.xcarchive' -o -iname '*.dsym' \
      \) \) -print)"
    if [ -n "$raw_benchmark_artifacts" ]; then
        echo "error: raw benchmark telemetry, audio, screenshots, logs, and bundles must remain untracked:" >&2
        printf '%s\n' "$raw_benchmark_artifacts" >&2
        exit 1
    fi
    while IFS= read -r oversized; do
        echo "error: committed benchmark log exceeds 256 KB cap: ${oversized#"$PROJECT_DIR/"}" >&2
        echo "Commit a compact summary instead (the summarizer table / a small JSON), not full logs." >&2
        exit 1
    done < <(find "$BENCHMARKS_DIR" -type f -size +"${BENCH_MAX_BYTES}"c)
fi

# The compact registry is deterministic and privacy-validated in ordinary CI.
# These checks inspect tracked summaries only; they never execute a benchmark,
# access models, or require a physical device.
python3 "$SCRIPT_DIR/benchmark_history.py" validate --all
python3 "$SCRIPT_DIR/benchmark_history.py" rebuild-index --check
python3 "$SCRIPT_DIR/vendor_runtime_contract.py" validate
python3 "$SCRIPT_DIR/documentation_contract.py"

"$SCRIPT_DIR/check_backend_resource_contract.sh" --project
"$SCRIPT_DIR/check_qwen3_backend_only.sh"
python3 "$SCRIPT_DIR/validate_backend_risk_spine.py" --root "$PROJECT_DIR"
"$SCRIPT_DIR/check_test_workflows.sh"

echo "==> Project inputs are clean."
