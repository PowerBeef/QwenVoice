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

REQUIRED_QA_SURFACES=(
    "scripts/harness.py"
    "scripts/harness_lib"
    "scripts/harness_lib/command.py"
    "scripts/harness_lib/fixtures.py"
    "scripts/harness_lib/lock.py"
    "scripts/harness_lib/simulator.py"
    "scripts/harness_lib/xcresult.py"
    "QwenVoiceTests"
    "VocelloUITests"
    "VocelloiOSTests"
    "tests/Plans/QwenVoiceSource.xctestplan"
    "tests/Plans/QwenVoiceRuntime.xctestplan"
    "tests/Plans/VocelloiOSFoundation.xctestplan"
    "tests/Plans/VocelloUISmoke.xctestplan"
)

for required_surface in "${REQUIRED_QA_SURFACES[@]}"; do
    if [ ! -e "$PROJECT_DIR/$required_surface" ]; then
        echo "error: required QA surface is missing: $required_surface" >&2
        exit 1
    fi
done

PROHIBITED_SURFACES=(
    "QVoiceBenchmarkUI""Tests"
    "tests/perf"
    "tests/screenshots"
    "third_party_patches/mlx-audio-swift/""Tests"
)

for prohibited_surface in "${PROHIBITED_SURFACES[@]}"; do
    if [ -e "$PROJECT_DIR/$prohibited_surface" ]; then
        echo "error: prohibited QA surface is present: $prohibited_surface" >&2
        exit 1
    fi
done

PROHIBITED_REFERENCE_PATTERNS=(
    "QVoiceBenchmarkUI""Tests"
    "third_party_patches/mlx-audio-swift/""Tests"
    "tests/screenshots"
    "tests/perf"
    "docs/reference/testing.md"
    "QwenVoice-macos15.dmg"
    "build/QwenVoice.app"
    "CLAU""DE.md"
    "Clau""de Code"
    "claude.ai/code"
    ".claude/worktrees"
)

for removed_pattern in "${PROHIBITED_REFERENCE_PATTERNS[@]}"; do
    if command -v rg >/dev/null 2>&1; then
        if rg -n -e "$removed_pattern" "$PROJECT_DIR" \
            --hidden \
            --glob '!.git/**' \
            --glob '!build/**' \
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

echo "==> Project inputs are clean."
