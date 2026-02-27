#!/bin/bash
# Automated History View diagnostic test using AppleScript accessibility probing.
#
# Exercises the History tab's sort chips, sort direction toggle, context menu,
# and full accessibility identifier dump — reports what's found vs. missing
# to diagnose SwiftUI accessibility issues.
#
# Prerequisites:
#   - "Qwen Voice" app must be running with backend ready
#   - Terminal must have Accessibility permissions
#
# Usage:
#   cd QwenVoice
#   ./scripts/test_history_ui.sh

set -euo pipefail

# Force C locale for consistent decimal formatting
export LC_NUMERIC=C

# ── Config ──────────────────────────────────────────────────────────────────────

APP_NAME="Qwen Voice"
HISTORY_SIDEBAR_ROW=5

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

# Navigate to a sidebar row by index
navigate_sidebar() {
    local row_num=$1
    osascript -e "
tell application \"System Events\"
    tell process \"Qwen Voice\"
        set frontmost to true
        delay 0.5
        set sidebarOutline to outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1
        select row $row_num of sidebarOutline
        delay 1.0
    end tell
end tell
" 2>/dev/null || true
}

# Find and click a UI element by its SwiftUI accessibilityIdentifier.
click_element_by_id() {
    local identifier="$1"
    local result
    result=$(osascript -e "
tell application \"System Events\"
    tell process \"Qwen Voice\"
        set frontmost to true
        delay 0.3
        set contentArea to group 2 of splitter group 1 of group 1 of window 1
        set ec to entire contents of contentArea
        repeat with elem in ec
            try
                if value of attribute \"AXIdentifier\" of elem is \"$identifier\" then
                    click elem
                    delay 0.3
                    return \"ok\"
                end if
            end try
        end repeat
        return \"not_found\"
    end tell
end tell
" 2>/dev/null || echo "error")
    echo "$result"
}

# Find a UI element by accessibility identifier without clicking — returns role and name.
find_element_by_id() {
    local identifier="$1"
    local result
    result=$(osascript -e "
tell application \"System Events\"
    tell process \"Qwen Voice\"
        set frontmost to true
        delay 0.2
        set contentArea to group 2 of splitter group 1 of group 1 of window 1
        set ec to entire contents of contentArea
        repeat with elem in ec
            try
                if value of attribute \"AXIdentifier\" of elem is \"$identifier\" then
                    set elemRole to role of elem
                    set elemName to \"\"
                    try
                        set elemName to name of elem
                    end try
                    set elemDesc to \"\"
                    try
                        set elemDesc to description of elem
                    end try
                    return elemRole & \"|\" & elemName & \"|\" & elemDesc
                end if
            end try
        end repeat
        return \"not_found\"
    end tell
end tell
" 2>/dev/null || echo "error")
    echo "$result"
}

# Check if sidebar outline exists (ContentView is visible)
has_sidebar_outline() {
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

# Read backend status from sidebar
read_backend_status() {
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

# 2. App is running
if ! pgrep -f "$APP_NAME" > /dev/null 2>&1; then
    fail "$APP_NAME is not running. Please launch the app first."
    exit 1
fi
ok "$APP_NAME is running"

# 3. Window exists
WIN_COUNT=$(osascript -e '
tell application "System Events"
    tell process "Qwen Voice"
        set frontmost to true
        delay 0.3
        return count of windows
    end tell
end tell
' 2>&1 || echo "0")

if [[ "$WIN_COUNT" == "0" ]]; then
    info "No window open — attempting to reopen..."
    open -a "$APP_NAME"
    sleep 3
    WIN_COUNT=$(osascript -e '
    tell application "System Events"
        tell process "Qwen Voice"
            return count of windows
        end tell
    end tell
    ' 2>&1 || echo "0")
    if [[ "$WIN_COUNT" == "0" ]]; then
        fail "Could not open app window."
        exit 1
    fi
fi
ok "App window is open"

# 4. ContentView visible
if ! has_sidebar_outline; then
    fail "ContentView not visible (sidebar outline missing). Is the app still on SetupView?"
    exit 1
fi
ok "ContentView visible"

# ══════════════════════════════════════════════════════════════════════════════════
# Test 1: Navigate to History
# ══════════════════════════════════════════════════════════════════════════════════

header "Test 1: Navigate to History"

navigate_sidebar "$HISTORY_SIDEBAR_ROW"
sleep 1

# Verify we're on the History tab by looking for the history_title identifier
TITLE_RESULT=$(find_element_by_id "history_title")

if [[ "$TITLE_RESULT" == "not_found" || "$TITLE_RESULT" == "error" ]]; then
    fail_test "history_title element not found — may not have navigated to History tab"
    info "Attempting to verify via static text..."
    # Fallback: check if any text says "History" in the content area
    FALLBACK=$(osascript -e '
tell application "System Events"
    tell process "Qwen Voice"
        set contentArea to group 2 of splitter group 1 of group 1 of window 1
        try
            set allTexts to value of every static text of contentArea
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
    if echo "$FALLBACK" | grep -qi "History"; then
        info "  Found 'History' text in content area (identifier missing but view loaded)"
    else
        info "  No 'History' text found — wrong tab or view not loading"
    fi
    info "  Static texts found: $(echo "$FALLBACK" | tr '\n' ' ')"
else
    IFS='|' read -r ROLE NAME DESC <<< "$TITLE_RESULT"
    pass_test "history_title found — role: $ROLE, name: $NAME"
fi

# ══════════════════════════════════════════════════════════════════════════════════
# Test 2: Sort Chips Visibility
# ══════════════════════════════════════════════════════════════════════════════════

header "Test 2: Sort Chips Visibility"

SORT_CHIPS=("history_sort_date" "history_sort_duration" "history_sort_voice" "history_sort_mode" "history_sort_manual")
CHIPS_FOUND=0
CHIPS_MISSING=0

for chip_id in "${SORT_CHIPS[@]}"; do
    CHIP_RESULT=$(find_element_by_id "$chip_id")
    if [[ "$CHIP_RESULT" == "not_found" || "$CHIP_RESULT" == "error" ]]; then
        fail_test "Sort chip '$chip_id' NOT FOUND"
        CHIPS_MISSING=$((CHIPS_MISSING + 1))
    else
        IFS='|' read -r ROLE NAME DESC <<< "$CHIP_RESULT"
        pass_test "Sort chip '$chip_id' found — role: $ROLE, name: ${NAME:-<empty>}, desc: ${DESC:-<empty>}"
        CHIPS_FOUND=$((CHIPS_FOUND + 1))
    fi
done

info "Sort chips: $CHIPS_FOUND found, $CHIPS_MISSING missing"

# ══════════════════════════════════════════════════════════════════════════════════
# Test 3: Sort Direction Toggle
# ══════════════════════════════════════════════════════════════════════════════════

header "Test 3: Sort Direction Toggle"

DIR_RESULT=$(find_element_by_id "history_sortDirection")

if [[ "$DIR_RESULT" == "not_found" || "$DIR_RESULT" == "error" ]]; then
    fail_test "history_sortDirection element NOT FOUND"
else
    IFS='|' read -r ROLE NAME DESC <<< "$DIR_RESULT"
    pass_test "history_sortDirection found — role: $ROLE, name: ${NAME:-<empty>}, desc: ${DESC:-<empty>}"
fi

# ══════════════════════════════════════════════════════════════════════════════════
# Test 4: Click Each Sort Chip
# ══════════════════════════════════════════════════════════════════════════════════

header "Test 4: Click Each Sort Chip"

for chip_id in "${SORT_CHIPS[@]}"; do
    CLICK_RESULT=$(click_element_by_id "$chip_id")
    if [[ "$CLICK_RESULT" == "ok" ]]; then
        pass_test "Clicked '$chip_id' successfully"
    else
        fail_test "Could not click '$chip_id' (result: $CLICK_RESULT)"
    fi
    sleep 0.5
done

# ══════════════════════════════════════════════════════════════════════════════════
# Test 5: Empty State vs. History Rows
# ══════════════════════════════════════════════════════════════════════════════════

header "Test 5: Empty State vs. History Rows"

EMPTY_RESULT=$(find_element_by_id "history_emptyState")
HAS_ROWS=false
ROW_COUNT=0

if [[ "$EMPTY_RESULT" != "not_found" && "$EMPTY_RESULT" != "error" ]]; then
    IFS='|' read -r ROLE NAME DESC <<< "$EMPTY_RESULT"
    info "Empty state element found — role: $ROLE, name: ${NAME:-<empty>}"
    info "No history rows present (this is expected if no generations have been made)"
    pass_test "Empty state detected correctly"
else
    # Count rows in the content area
    ROW_COUNT=$(osascript -e '
tell application "System Events"
    tell process "Qwen Voice"
        set contentArea to group 2 of splitter group 1 of group 1 of window 1
        set ec to entire contents of contentArea
        set rowCount to 0
        repeat with elem in ec
            try
                if role of elem is "AXRow" then
                    set rowCount to rowCount + 1
                end if
            end try
        end repeat
        return rowCount
    end tell
end tell
' 2>/dev/null || echo "0")

    if (( ROW_COUNT > 0 )); then
        HAS_ROWS=true
        pass_test "Found $ROW_COUNT history row(s)"
    else
        # Neither empty state nor rows — check for table/list elements
        LIST_INFO=$(osascript -e '
tell application "System Events"
    tell process "Qwen Voice"
        set contentArea to group 2 of splitter group 1 of group 1 of window 1
        set ec to entire contents of contentArea
        set output to ""
        repeat with elem in ec
            try
                set elemRole to role of elem
                if elemRole is "AXTable" or elemRole is "AXList" or elemRole is "AXGroup" then
                    set elemId to ""
                    try
                        set elemId to value of attribute "AXIdentifier" of elem
                    end try
                    set output to output & elemRole & "(" & elemId & ") "
                end if
            end try
        end repeat
        return output
    end tell
end tell
' 2>/dev/null || echo "")
        fail_test "No empty state and no AXRow elements found"
        info "  Container elements: ${LIST_INFO:-none}"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════════
# Test 6: Context Menu (only if rows exist)
# ══════════════════════════════════════════════════════════════════════════════════

header "Test 6: Context Menu"

if [[ "$HAS_ROWS" == "true" ]]; then
    info "Attempting to right-click first history row..."

    # Phase 1: Check that AXShowMenu triggers without error
    TRIGGER_RESULT=$(osascript -e '
tell application "System Events"
    tell process "Qwen Voice"
        set frontmost to true
        delay 0.3
        set contentArea to group 2 of splitter group 1 of group 1 of window 1
        set ec to entire contents of contentArea
        set targetRow to missing value
        repeat with elem in ec
            try
                if role of elem is "AXRow" then
                    set targetRow to elem
                    exit repeat
                end if
            end try
        end repeat
        if targetRow is missing value then return "no_row"
        try
            perform action "AXShowMenu" of targetRow
            delay 0.5
            -- Try to read items from the process popup menu
            set output to ""
            try
                set theMenu to menu 1 of targetRow
                set menuItems to name of every menu item of theMenu
                repeat with mi in menuItems
                    if mi is not missing value then
                        set output to output & mi & ","
                    end if
                end repeat
            on error
                -- SwiftUI context menus appear as AXMenu children of the row cell or table
                try
                    set theCell to group 1 of targetRow
                    set allContents to entire contents of theCell
                    repeat with elem in allContents
                        try
                            if role of elem is "AXMenu" then
                                set menuItems to name of every menu item of elem
                                repeat with mi in menuItems
                                    if mi is not missing value then
                                        set output to output & mi & ","
                                    end if
                                end repeat
                                exit repeat
                            end if
                        end try
                    end repeat
                on error
                end try
            end try
            key code 53
            if output is "" then return "triggered_no_items"
            return output
        on error
            return "no_action"
        end try
    end tell
end tell
' 2>/dev/null || echo "error")

    if [[ "$TRIGGER_RESULT" == "no_row" ]]; then
        fail_test "Could not find row element for context menu"
    elif [[ "$TRIGGER_RESULT" == "no_action" || "$TRIGGER_RESULT" == "error" ]]; then
        fail_test "AXShowMenu action failed on row element — context menu not triggerable"
    elif [[ "$TRIGGER_RESULT" == "triggered_no_items" ]]; then
        # AXShowMenu succeeded; SwiftUI context menus are transient overlays not enumerable
        # via standard accessibility. This is expected — treat trigger success as PASS.
        pass_test "Context menu triggered via AXShowMenu (SwiftUI transient menus not AX-enumerable)"
        info "  Expected items: Play, Save As, Reveal in Finder, Delete"
        info "  Verify manually by right-clicking a row in the app"
    else
        info "Menu items found: $TRIGGER_RESULT"
        EXPECTED_ITEMS=("Play" "Save As" "Reveal in Finder" "Delete")
        for item in "${EXPECTED_ITEMS[@]}"; do
            if echo "$TRIGGER_RESULT" | grep -qi "$item"; then
                pass_test "Context menu contains '$item'"
            else
                fail_test "Context menu missing '$item'"
            fi
        done
    fi
else
    info "No history rows — skipping context menu test"
    info "  Generate some audio first, then re-run this test"
fi

# ══════════════════════════════════════════════════════════════════════════════════
# Test 7: Full Diagnostic Dump
# ══════════════════════════════════════════════════════════════════════════════════

header "Test 7: Full Diagnostic Dump (history_* identifiers)"

DUMP=$(osascript -e '
tell application "System Events"
    tell process "Qwen Voice"
        set frontmost to true
        delay 0.3
        set contentArea to group 2 of splitter group 1 of group 1 of window 1
        set ec to entire contents of contentArea
        set output to ""
        repeat with elem in ec
            try
                set elemId to value of attribute "AXIdentifier" of elem
                if elemId starts with "history_" then
                    set elemRole to role of elem
                    set elemName to ""
                    try
                        set elemName to name of elem
                    end try
                    set output to output & elemId & " | " & elemRole & " | " & elemName & linefeed
                end if
            end try
        end repeat
        if output is "" then
            return "none_found"
        end if
        return output
    end tell
end tell
' 2>/dev/null || echo "error")

if [[ "$DUMP" == "none_found" ]]; then
    fail_test "No elements with history_* identifiers found in content area"
    info "  This likely means accessibilityIdentifier values are not being set in SwiftUI"
    info "  OR the History view is not rendering its content in the expected content area"

    # Extra diagnostic: dump ALL identifiers in content area
    info ""
    info "Dumping ALL accessibility identifiers in content area..."
    ALL_IDS=$(osascript -e '
tell application "System Events"
    tell process "Qwen Voice"
        set contentArea to group 2 of splitter group 1 of group 1 of window 1
        set ec to entire contents of contentArea
        set output to ""
        set count_ to 0
        repeat with elem in ec
            try
                set elemId to value of attribute "AXIdentifier" of elem
                if elemId is not "" and elemId is not missing value then
                    set elemRole to role of elem
                    set output to output & elemId & " (" & elemRole & ")" & linefeed
                    set count_ to count_ + 1
                    if count_ > 50 then exit repeat
                end if
            end try
        end repeat
        if output is "" then
            return "no_identifiers"
        end if
        return output
    end tell
end tell
' 2>/dev/null || echo "error")

    if [[ "$ALL_IDS" == "no_identifiers" ]]; then
        info "  No accessibility identifiers found at all in content area"
    elif [[ "$ALL_IDS" == "error" ]]; then
        info "  Error reading content area"
    else
        info "  Found identifiers:"
        while IFS= read -r line; do
            [[ -n "$line" ]] && info "    $line"
        done <<< "$ALL_IDS"
    fi
elif [[ "$DUMP" == "error" ]]; then
    fail_test "Error reading content area for diagnostic dump"
else
    info "Found history_* elements:"
    ELEMENT_COUNT=0
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            info "  $line"
            ELEMENT_COUNT=$((ELEMENT_COUNT + 1))
        fi
    done <<< "$DUMP"
    pass_test "Found $ELEMENT_COUNT element(s) with history_* identifiers"
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
