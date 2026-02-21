#!/bin/bash
# Run QwenVoice XCUITests from the command line.
#
# Usage:
#   ./scripts/run_tests.sh                      # Run all UI tests
#   ./scripts/run_tests.sh SidebarNavigation     # Run one test class
#   ./scripts/run_tests.sh --list                # List available test classes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT="$PROJECT_DIR/QwenVoice.xcodeproj"
SCHEME="QwenVoiceUITests"

# List mode
if [[ "${1:-}" == "--list" ]]; then
    echo "Available test classes:"
    for f in "$PROJECT_DIR/QwenVoiceUITests/"*Tests.swift; do
        basename "$f" .swift
    done
    exit 0
fi

# Build filter for specific test class
FILTER=""
if [[ -n "${1:-}" ]]; then
    CLASS="${1}Tests"
    # Check class exists
    if [[ ! -f "$PROJECT_DIR/QwenVoiceUITests/${CLASS}.swift" ]]; then
        # Try with Tests suffix already present
        CLASS="$1"
        if [[ ! -f "$PROJECT_DIR/QwenVoiceUITests/${CLASS}.swift" ]]; then
            echo "ERROR: Test class '$1' not found."
            echo "Run with --list to see available classes."
            exit 1
        fi
    fi
    FILTER="-only-testing:QwenVoiceUITests/$CLASS"
    echo "==> Running tests: $CLASS"
else
    echo "==> Running all UI tests"
fi

# Run tests
TMPFILE=$(mktemp /tmp/qwenvoice_test_output.XXXXXX)
trap "rm -f $TMPFILE" EXIT

set +e
xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination 'platform=macOS' \
    $FILTER \
    2>&1 | tee "$TMPFILE"
EXIT_CODE=${PIPESTATUS[0]}
set -e

echo ""
echo "========================================="
echo "           TEST RESULTS SUMMARY"
echo "========================================="

# Parse results
PASSED=0
FAILED=0
SKIPPED=0
TOTAL=0

while IFS= read -r line; do
    if echo "$line" | grep -q "Test Case.*passed"; then
        PASSED=$((PASSED + 1))
        TOTAL=$((TOTAL + 1))
        TEST_NAME=$(echo "$line" | sed "s/.*'-\[//" | sed "s/\]'.*//" | tr ' ' '.')
        echo "PASS: $TEST_NAME"
    elif echo "$line" | grep -q "Test Case.*failed"; then
        FAILED=$((FAILED + 1))
        TOTAL=$((TOTAL + 1))
        TEST_NAME=$(echo "$line" | sed "s/.*'-\[//" | sed "s/\]'.*//" | tr ' ' '.')
        echo "FAIL: $TEST_NAME"
    elif echo "$line" | grep -q "Test Case.*skipped"; then
        SKIPPED=$((SKIPPED + 1))
        TOTAL=$((TOTAL + 1))
        TEST_NAME=$(echo "$line" | sed "s/.*'-\[//" | sed "s/\]'.*//" | tr ' ' '.')
        echo "SKIP: $TEST_NAME"
    fi
done < "$TMPFILE"

echo ""
echo "RESULTS: $TOTAL total | $PASSED passed | $FAILED failed | $SKIPPED skipped"
echo ""

exit $EXIT_CODE
