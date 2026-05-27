#!/bin/bash

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
    "scripts/release.sh"
    "scripts/release_ios_testflight.sh"
    "Sources/Resources/qwenvoice_contract.json"
    "config/apple-platform-capability-matrix.json"
    "project.yml"
)

for required_surface in "${REQUIRED_SURFACES[@]}"; do
    if [ ! -e "$PROJECT_DIR/$required_surface" ]; then
        echo "error: required surface is missing: $required_surface" >&2
        exit 1
    fi
done

PROHIBITED_SURFACES=(
    "QVoiceBenchmarkUI""Tests"
    "QwenVoiceTests"
    "VocelloUITests"
    "VocelloiOSTests"
    "tests/Plans"
    "tests/fixtures"
    "tests/perf"
    "tests/screenshots"
    "third_party_patches/mlx-audio-swift/""Tests"
    "scripts/qa.sh"
    "scripts/bench_ui_generation.sh"
    "scripts/bench_instruments_trace.sh"
    "scripts/compare_perf_manifest.sh"
    "scripts/compare_ui_bench_runs.sh"
    "scripts/summarize_instruments_signposts.py"
    "scripts/perf-baseline-manifest.json"
    "scripts/perf-baseline-manifest-quality.json"
    "scripts/bootstrap_audio_review_models.sh"
    "scripts/rescue_gate.sh"
    "docs/reference/live-testing.md"
    "docs/reference/instruments-profiling.md"
    "docs/reference/backend-hardening-validation-evidence.md"
    "build/DerivedData"
    "build/foundation"
    "build/uitest"
    "build/Vocello.app"
    "build/Vocello-macos26.dmg"
    "build/release-metadata.txt"
    "build/xcodebuild-release.log"
)

for prohibited_surface in "${PROHIBITED_SURFACES[@]}"; do
    if [ -e "$PROJECT_DIR/$prohibited_surface" ]; then
        echo "error: prohibited surface is present: $prohibited_surface" >&2
        exit 1
    fi
done

PROHIBITED_REFERENCE_PATTERNS=(
    "QVoiceBenchmarkUI""Tests"
    "third_party_patches/mlx-audio-swift/""Tests"
    "tests/screenshots"
    "tests/perf"
    "docs/reference/testing\.md"
    "docs/reference/live-testing\.md"
    "docs/reference/instruments-profiling\.md"
    "docs/reference/backend-hardening-validation-evidence\.md"
    "QwenVoice-macos15.dmg"
    "build/QwenVoice.app"
    "scripts/harness\.py"
    "scripts/harness_lib"
    "scripts/run_generation_benchmark\.py"
    "scripts/run_ui_generation_benchmark\.py"
    "scripts/run_generation_quality_audit\.py"
    "scripts/run_custom_voice_ui_perf_audit\.py"
    "scripts/audit_generated_audio\.py"
    "scripts/check_qwen3_backend_only\.py"
    "scripts/check_ios_catalog\.py"
    "scripts/refresh_readme_screenshots\.py"
    "scripts/qa\.sh"
    "scripts/bench_ui_generation\.sh"
    "scripts/bench_instruments_trace\.sh"
    "scripts/compare_perf_manifest\.sh"
    "scripts/compare_ui_bench_runs\.sh"
    "scripts/summarize_instruments_signposts\.py"
    "scripts/perf-baseline-manifest"
    "scripts/bootstrap_audio_review_models\.sh"
    "scripts/rescue_gate\.sh"
    "scripts/requirements-audio-review-bootstrap\.txt"
    "scripts/requirements-perf-bootstrap\.txt"
    '\$SCRIPT_DIR/qa\.sh'
    "QW_TEST_SUPPORT"
    "UITestAutomationSupport"
    "UITestStubMacEngine"
    "UITestWindowSizeConfigurator"
    "BenchmarkRunner"
    "CustomVoiceUIPerformanceTrace"
    "BenchmarkSample"
    "GenerationRequest\\.BenchmarkOptions"
    "benchmarkOptions"
    "ChunkProbeMetadata"
    "probeMetadata"
    "QWENVOICE_UI_PERF_AUDIT"
    "QWENVOICE_AUDIO_QC_LIVE"
    "QWENVOICE_QWEN3_BENCHMARK"
    "logProbeEvent"
    "\\[Probe\\."
)

for removed_pattern in "${PROHIBITED_REFERENCE_PATTERNS[@]}"; do
    if command -v rg >/dev/null 2>&1; then
        if rg -n -e "$removed_pattern" "$PROJECT_DIR" \
            --hidden \
            --glob '!.git/**' \
            --glob '!build/**' \
            --glob '!scratch/**' \
            --glob '!**/scripts/check_project_inputs.sh' \
            >/tmp/qwenvoice_removed_reference_grep 2>/dev/null; then
            echo "error: removed test/benchmark reference is still present:" >&2
            cat /tmp/qwenvoice_removed_reference_grep >&2
            rm -f /tmp/qwenvoice_removed_reference_grep
            exit 1
        fi
    elif git -C "$PROJECT_DIR" grep -nE "$removed_pattern" -- \
        ':!:scripts/check_project_inputs.sh' \
        ':!:build/**' \
        >/tmp/qwenvoice_removed_reference_grep 2>/dev/null; then
        echo "error: removed test/benchmark reference is still present:" >&2
        cat /tmp/qwenvoice_removed_reference_grep >&2
        rm -f /tmp/qwenvoice_removed_reference_grep
        exit 1
    fi
    rm -f /tmp/qwenvoice_removed_reference_grep
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

"$SCRIPT_DIR/check_backend_resource_contract.sh" --project
"$SCRIPT_DIR/check_qwen3_backend_only.sh"

echo "==> Project inputs are clean."
