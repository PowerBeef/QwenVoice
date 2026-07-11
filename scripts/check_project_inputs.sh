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
    "scripts/build_foundation_targets.sh"
    "scripts/ui_test.sh"
    "scripts/check_test_workflows.sh"
    "scripts/check_ios_ui_benchmark.py"
    "scripts/test_check_macos_xpc_bench.py"
    "scripts/test_check_ios_ui_benchmark.py"
    "scripts/test_check_language_output.py"
    "scripts/release.sh"
    "Sources/Resources/qwenvoice_contract.json"
    "config/apple-platform-capability-matrix.json"
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

if grep -n "QW_TEST_SUPPORT" "$PROJECT_DIR/project.yml" | grep -n "Release" >/dev/null 2>&1; then
    echo "error: QW_TEST_SUPPORT must not be configured for Release builds." >&2
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
# human-readable summaries under benchmarks/, each <= 256 KB, never raw *.jsonl
# (raw diagnostics belong on disk / gitignored, not in git history). The retired
# harness and banned-symbol checks above still apply everywhere.
BENCHMARKS_DIR="$PROJECT_DIR/benchmarks"
if [ -d "$BENCHMARKS_DIR" ]; then
    BENCH_MAX_BYTES=$((256 * 1024))
    if find "$BENCHMARKS_DIR" -type f -name '*.jsonl' -print -quit | grep -q .; then
        echo "error: raw *.jsonl must not be committed under benchmarks/ (commit a compact summary; raw diagnostics are gitignored)." >&2
        find "$BENCHMARKS_DIR" -type f -name '*.jsonl' >&2
        exit 1
    fi
    while IFS= read -r oversized; do
        echo "error: committed benchmark log exceeds 256 KB cap: ${oversized#"$PROJECT_DIR/"}" >&2
        echo "Commit a compact summary instead (the summarizer table / a small JSON), not full logs." >&2
        exit 1
    done < <(find "$BENCHMARKS_DIR" -type f -size +"${BENCH_MAX_BYTES}"c)
fi

"$SCRIPT_DIR/check_backend_resource_contract.sh" --project
"$SCRIPT_DIR/check_qwen3_backend_only.sh"
"$SCRIPT_DIR/check_test_workflows.sh"

echo "==> Project inputs are clean."
