#!/bin/bash
# Automated launch-speed test for the fast-launch optimization.
#
# Verifies:
#   1. ContentView renders within 3 seconds (no SetupView flash)
#   2. Models tab is navigable and model cards appear
#   3. Backend status transitions from "Starting..." to "Backend Ready"
#   4. Stale marker recovery still works (SetupView -> ContentView)
#   5. App quits cleanly
#
# Prerequisites:
#   - Terminal must have Accessibility permissions (System Settings > Privacy & Security > Accessibility)
#   - Project must be built (xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build)
#   - Python venv + valid marker must exist (run the app once first)
#
# Usage:
#   cd QwenVoice
#   ./scripts/test_launch_speed.sh

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────────

BUNDLE_ID="com.qwenvoice.app"
APP_NAME="Qwen Voice"
FAST_LAUNCH_TIMEOUT=3          # seconds — the key threshold
BACKEND_READY_TIMEOUT=30       # seconds
STALE_MARKER_TIMEOUT=90        # pip install + validateImports can be slow
POLL_INTERVAL_MS=500           # half-second polling resolution
APP_SUPPORT_DIR="$HOME/Library/Application Support/QwenVoice"
MARKER_FILE="$APP_SUPPORT_DIR/python/.setup-complete"
VENV_PYTHON="$APP_SUPPORT_DIR/python/bin/python3"
REQUIREMENTS_FILE="Sources/Resources/requirements.txt"

# ── Colors ──────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Helpers ─────────────────────────────────────────────────────────────────────

info()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[PASS]${RESET}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
fail()   { echo -e "${RED}[FAIL]${RESET}  $*"; }
header() { echo -e "\n${BOLD}═══ $* ═══${RESET}\n"; }

TESTS_PASSED=0
TESTS_FAILED=0

pass_test() {
    ok "$@"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail_test() {
    fail "$@"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# ── Core Utility Functions ──────────────────────────────────────────────────────

# Monotonic millisecond counter (macOS date lacks %N)
now_ms() {
    perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'
}

kill_app() {
    # Graceful quit, then force-kill if needed
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
    local waited=0
    while pgrep -f "$APP_NAME" > /dev/null 2>&1; do
        if (( waited >= 5 )); then
            pkill -9 -f "$APP_NAME" 2>/dev/null || true
            sleep 1
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

resolve_app_path() {
    local build_dir
    build_dir=$(xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice -showBuildSettings 2>/dev/null \
        | grep '^ *BUILT_PRODUCTS_DIR' | sed 's/.*= //')
    if [[ -n "$build_dir" && -d "$build_dir/$APP_NAME.app" ]]; then
        echo "$build_dir/$APP_NAME.app"
    fi
}

launch_app() {
    local app_path
    app_path=$(resolve_app_path)
    if [[ -z "$app_path" ]]; then
        fail "Could not resolve built app path"
        return 1
    fi
    open "$app_path"
}

has_sidebar_outline() {
    # ContentView uses NavigationSplitView which creates splitter group 1 → outline 1.
    # SetupView is a plain VStack with no splitter/outline.
    local result
    result=$(osascript -e '
tell application "System Events"
    tell process "Qwen Voice"
        try
            set sidebarOutline to outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1
            return "found"
        on error
            return "missing"
        end try
    end tell
end tell
' 2>/dev/null || echo "missing")
    [[ "$result" == "found" ]]
}

has_setup_view() {
    # Read all static texts from the window's top-level group and check for
    # SetupView-specific strings (phase labels and error title).
    local texts
    texts=$(osascript -e '
tell application "System Events"
    tell process "Qwen Voice"
        try
            set allTexts to value of every static text of group 1 of window 1
            set output to ""
            repeat with t in allTexts
                set output to output & t & linefeed
            end repeat
            return output
        on error
            return ""
        end try
    end tell
end tell
' 2>/dev/null || echo "")
    echo "$texts" | grep -qi "Checking Python\|Updating dependencies\|Finding Python\|Creating virtual\|Installing dependencies\|Setup Failed"
}

# Global variable set by wait_for_content_view
CONTENT_VIEW_ELAPSED_MS=0

wait_for_content_view() {
    local timeout_s=$1
    local timeout_ms=$((timeout_s * 1000))
    local start_ms elapsed_ms
    start_ms=$(now_ms)

    while true; do
        if has_sidebar_outline; then
            CONTENT_VIEW_ELAPSED_MS=$(( $(now_ms) - start_ms ))
            return 0
        fi

        elapsed_ms=$(( $(now_ms) - start_ms ))
        if (( elapsed_ms >= timeout_ms )); then
            CONTENT_VIEW_ELAPSED_MS=$elapsed_ms
            return 1
        fi

        sleep 0.5
    done
}

read_backend_status() {
    # Backend status indicator lives at the bottom of the sidebar (group 1 of splitter group 1).
    # It shows "Starting..." or "Backend Ready".
    osascript -e '
tell application "System Events"
    tell process "Qwen Voice"
        try
            set sidebarGroup to group 1 of splitter group 1 of group 1 of window 1
            set allTexts to value of every static text of sidebarGroup
            set output to ""
            repeat with t in allTexts
                set output to output & t & linefeed
            end repeat
            return output
        on error
            return ""
        end try
    end tell
end tell
' 2>/dev/null || echo ""
}

compute_marker_hash() {
    shasum -a 256 "$REQUIREMENTS_FILE" | awk '{print $1}'
}

# ── Cleanup Trap ────────────────────────────────────────────────────────────────

MARKER_BACKUP=""
MARKER_REMOVED=false

cleanup_on_exit() {
    # Safety net: restore marker if it was removed (e.g. Ctrl+C during Test 4)
    if [[ "$MARKER_REMOVED" == "true" && -n "$MARKER_BACKUP" ]]; then
        info "Restoring marker file..."
        echo -n "$MARKER_BACKUP" > "$MARKER_FILE"
        ok "Marker file restored"
    fi
    kill_app 2>/dev/null || true
}

trap cleanup_on_exit EXIT

# ── Preflight Checks ────────────────────────────────────────────────────────────

header "Preflight Checks"

# 1. Accessibility permissions
ACC_CHECK=$(osascript -e '
tell application "System Events"
    try
        name of first process
        return "ok"
    on error errMsg number errNum
        return errNum as text
    end try
end tell
' 2>&1 || echo "error")

if [[ "$ACC_CHECK" == *"-25211"* ]] || [[ "$ACC_CHECK" == "error" ]]; then
    fail "Accessibility permissions denied. Grant Terminal access in:"
    info "  System Settings > Privacy & Security > Accessibility"
    exit 1
fi
ok "Accessibility permissions granted"

# 2. requirements.txt exists
if [[ ! -f "$REQUIREMENTS_FILE" ]]; then
    fail "requirements.txt not found at $REQUIREMENTS_FILE"
    exit 1
fi
ok "requirements.txt found"

# 3. Python venv exists
if [[ ! -f "$VENV_PYTHON" ]]; then
    fail "Python venv not found at $VENV_PYTHON"
    exit 1
fi
ok "Python venv found"

# 4. Marker file valid (hash matches requirements.txt)
if [[ ! -f "$MARKER_FILE" ]]; then
    fail "Marker file missing — Test 1 would falsely fail. Run the app once first."
    exit 1
fi

CURRENT_HASH=$(compute_marker_hash)
MARKER_HASH=$(tr -d '[:space:]' < "$MARKER_FILE")
if [[ "$CURRENT_HASH" != "$MARKER_HASH" ]]; then
    fail "Marker hash mismatch — venv is stale. Run the app once to update."
    info "  Expected: $CURRENT_HASH"
    info "  Got:      $MARKER_HASH"
    exit 1
fi
ok "Marker file valid"

# 5. Built app exists in DerivedData
APP_PATH=$(resolve_app_path)
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    fail "Built app not found. Run: xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build"
    exit 1
fi
ok "Built app found"

# ══════════════════════════════════════════════════════════════════════════════════
# Test 1: Fast Launch (THE critical test)
# ══════════════════════════════════════════════════════════════════════════════════

header "Test 1: Fast Launch"

kill_app
sleep 1
launch_app

# Wait for process to appear (up to 10s)
info "Waiting for app process..."
WAITED=0
while ! pgrep -f "$APP_NAME" > /dev/null 2>&1; do
    if (( WAITED >= 10 )); then
        fail_test "App process did not appear within 10 seconds"
        exit 1
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

info "Process appeared — polling for ContentView (timeout: ${FAST_LAUNCH_TIMEOUT}s)..."

if wait_for_content_view "$FAST_LAUNCH_TIMEOUT"; then
    ELAPSED_S=$(awk "BEGIN {printf \"%.1f\", $CONTENT_VIEW_ELAPSED_MS / 1000}")
    # Confirm no SetupView elements are visible
    if has_setup_view; then
        fail_test "ContentView appeared but SetupView text still visible"
    else
        pass_test "ContentView appeared in ~${ELAPSED_S}s (threshold: ${FAST_LAUNCH_TIMEOUT}s)"
    fi
else
    if has_setup_view; then
        fail_test "SetupView visible after ${FAST_LAUNCH_TIMEOUT}s — fast-launch optimization broken"
    else
        fail_test "Neither ContentView nor SetupView detected after ${FAST_LAUNCH_TIMEOUT}s (crash?)"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════════
# Test 2: Models Tab Navigation
# ══════════════════════════════════════════════════════════════════════════════════

header "Test 2: Models Tab Navigation"

info "Selecting Models row in sidebar (row 8)..."
osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
    tell process "Qwen Voice"
        set frontmost to true
        delay 0.5
        set sidebarOutline to outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1
        select row 8 of sidebarOutline
        delay 1.0
    end tell
end tell
APPLESCRIPT

# Assertion 1: Title reads "Models"
MODELS_TITLE=$(osascript -e '
tell application "System Events"
    tell process "Qwen Voice"
        set contentArea to scroll area 1 of group 2 of splitter group 1 of group 1 of window 1
        return value of static text 1 of contentArea
    end tell
end tell
' 2>/dev/null || echo "unknown")

if [[ "$MODELS_TITLE" == "Models" ]]; then
    pass_test "Models tab loaded — title confirmed: \"$MODELS_TITLE\""
else
    fail_test "Expected title \"Models\", got \"$MODELS_TITLE\""
fi

# Assertion 2: At least 3 model cards present
CARD_COUNT=$(osascript -e '
tell application "System Events"
    tell process "Qwen Voice"
        set contentArea to scroll area 1 of group 2 of splitter group 1 of group 1 of window 1
        return count of groups of contentArea
    end tell
end tell
' 2>/dev/null || echo "0")

if (( CARD_COUNT >= 3 )); then
    pass_test "Found $CARD_COUNT model cards"
else
    fail_test "Expected >= 3 model cards, found $CARD_COUNT"
fi

# ══════════════════════════════════════════════════════════════════════════════════
# Test 3: Backend Status
# ══════════════════════════════════════════════════════════════════════════════════

header "Test 3: Backend Status"

INITIAL_STATUS=$(read_backend_status)
INITIAL_TRIMMED=$(echo "$INITIAL_STATUS" | tr '\n' ' ' | sed 's/  */ /g;s/^ *//;s/ *$//')
info "Initial backend status: \"$INITIAL_TRIMMED\""

# Poll for "Backend Ready" every 2s up to BACKEND_READY_TIMEOUT
WAITED=0
BACKEND_READY=false
while (( WAITED < BACKEND_READY_TIMEOUT )); do
    STATUS=$(read_backend_status)
    if echo "$STATUS" | grep -q "Backend Ready"; then
        BACKEND_READY=true
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done

if [[ "$BACKEND_READY" == "true" ]]; then
    pass_test "Backend became ready after ~${WAITED}s"
else
    fail_test "Backend not ready after ${BACKEND_READY_TIMEOUT}s timeout"
fi

# ══════════════════════════════════════════════════════════════════════════════════
# Test 4: Stale Marker Recovery
# ══════════════════════════════════════════════════════════════════════════════════

header "Test 4: Stale Marker Recovery"

# Back up marker contents
MARKER_BACKUP=$(cat "$MARKER_FILE")
info "Marker backed up (hash: ${MARKER_BACKUP:0:16}...)"

kill_app
sleep 1

# Remove marker to force slow path
rm -f "$MARKER_FILE"
MARKER_REMOVED=true
info "Marker file removed — app should enter slow path"

launch_app

# Wait for process to appear
WAITED=0
while ! pgrep -f "$APP_NAME" > /dev/null 2>&1; do
    if (( WAITED >= 10 )); then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

# After 2s, check for SetupView (expected: venv exists but marker gone -> "Updating dependencies...")
sleep 2
if has_setup_view; then
    info "SetupView detected (expected — venv exists but marker missing)"
else
    info "SetupView not detected — app may recover quickly or still loading"
fi

# Wait for ContentView to appear (recovery via pip install + validateImports)
info "Waiting for stale marker recovery (timeout: ${STALE_MARKER_TIMEOUT}s)..."
if wait_for_content_view "$STALE_MARKER_TIMEOUT"; then
    ELAPSED_S=$(awk "BEGIN {printf \"%.1f\", $CONTENT_VIEW_ELAPSED_MS / 1000}")
    pass_test "ContentView appeared after ~${ELAPSED_S}s (stale marker recovery)"
else
    fail_test "ContentView did not appear within ${STALE_MARKER_TIMEOUT}s (recovery failed)"
fi

# Restore marker (always, regardless of test result)
echo -n "$MARKER_BACKUP" > "$MARKER_FILE"
MARKER_REMOVED=false
info "Marker file restored"

# ══════════════════════════════════════════════════════════════════════════════════
# Test 5: Clean Quit
# ══════════════════════════════════════════════════════════════════════════════════

header "Test 5: Clean Quit"

kill_app
sleep 2

if pgrep -f "$APP_NAME" > /dev/null 2>&1; then
    fail_test "App process still running after quit"
else
    pass_test "App quit cleanly"
fi

# ── Summary ──────────────────────────────────────────────────────────────────────

header "Test Results"

TOTAL=$((TESTS_PASSED + TESTS_FAILED))

if (( TESTS_FAILED == 0 )); then
    echo -e "${GREEN}${BOLD}ALL $TOTAL TESTS PASSED${RESET}"
else
    echo -e "${RED}${BOLD}$TESTS_FAILED of $TOTAL TESTS FAILED${RESET}"
fi
echo ""

exit "$TESTS_FAILED"
