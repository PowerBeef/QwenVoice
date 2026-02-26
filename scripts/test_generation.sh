#!/bin/bash
# Automated TTS generation performance test using AppleScript + file system monitoring.
#
# Exercises all automatable generation modes (Custom Voice, Voice Design,
# optionally Voice Cloning), measures wall-clock generation time, and reports
# performance metrics including real-time factor (RTF).
#
# Prerequisites:
#   - "Qwen Voice" app must be running with backend ready
#   - Terminal must have Accessibility permissions
#   - At least the Custom Voice model must be downloaded
#   - For Voice Design: Voice Design model must be downloaded
#   - For Voice Cloning: Voice Cloning model + enrolled voice required
#
# Usage:
#   cd QwenVoice
#   ./scripts/test_generation.sh
#   ./scripts/test_generation.sh --skip-cleanup   # keep generated test files

set -euo pipefail

# Force C locale for consistent decimal formatting (avoids comma separators)
export LC_NUMERIC=C

# ── Arguments ─────────────────────────────────────────────────────────────────

SKIP_CLEANUP=false
for arg in "$@"; do
    case "$arg" in
        --skip-cleanup) SKIP_CLEANUP=true ;;
        -h|--help)
            echo "Usage: $0 [--skip-cleanup]"
            echo "  --skip-cleanup   Keep generated test .wav files"
            exit 0
            ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# ── Config ──────────────────────────────────────────────────────────────────────

APP_NAME="Qwen Voice"
APP_SUPPORT_DIR="$HOME/Library/Application Support/QwenVoice"
OUTPUTS_DIR="$APP_SUPPORT_DIR/outputs"
MODELS_DIR="$APP_SUPPORT_DIR/models"
VOICES_DIR="$APP_SUPPORT_DIR/voices"

# Model folders
CUSTOM_MODEL_FOLDER="Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
DESIGN_MODEL_FOLDER="Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit"
CLONE_MODEL_FOLDER="Qwen3-TTS-12Hz-1.7B-Base-8bit"

# Timeouts (seconds)
WARMUP_TIMEOUT=120
SHORT_GEN_TIMEOUT=60
MEDIUM_GEN_TIMEOUT=90
LONG_GEN_TIMEOUT=180
DESIGN_GEN_TIMEOUT=120
CLONE_GEN_TIMEOUT=120
BACKEND_READY_TIMEOUT=30

# Test texts (fixed for reproducibility)
TEXT_SHORT="Hello, how are you today?"
TEXT_SHORT_ALT="The weather is beautiful today and I feel great."
TEXT_MEDIUM="The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. How vexingly quick daft zebras jump."
TEXT_LONG="In the heart of the ancient forest, where towering oaks whispered secrets to the wind and sunlight filtered through a canopy of emerald leaves, a narrow path wound its way through the undergrowth. Moss-covered stones lined the trail, and the air was thick with the scent of damp earth and wildflowers. A stream gurgled somewhere nearby, its melody blending with the chorus of birdsong that filled the woodland."

# Voice Design description
VOICE_DESCRIPTION="A warm, deep male voice with a British accent and gentle tone"

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

# Monotonic millisecond counter (macOS date lacks %N)
now_ms() {
    perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'
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
# Uses `entire contents` + AXIdentifier attribute matching.
click_element_by_id() {
    local identifier="$1"
    local result
    result=$(osascript -e "
tell application \"System Events\"
    tell process \"Qwen Voice\"
        set frontmost to true
        delay 0.3
        set contentArea to scroll area 1 of group 2 of splitter group 1 of group 1 of window 1
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

# Focus a text field by accessibility ID and paste text into it via clipboard
enter_text_in_field() {
    local field_id="$1"
    local text="$2"
    # Set clipboard
    osascript -e "set the clipboard to \"$(echo "$text" | sed 's/"/\\"/g')\"" 2>/dev/null || true
    # Find field, focus it (click doesn't grant keyboard focus in SwiftUI),
    # select all, paste from clipboard
    osascript -e "
tell application \"System Events\"
    tell process \"Qwen Voice\"
        set frontmost to true
        delay 0.3
        set contentArea to scroll area 1 of group 2 of splitter group 1 of group 1 of window 1
        set ec to entire contents of contentArea
        repeat with elem in ec
            try
                if value of attribute \"AXIdentifier\" of elem is \"$field_id\" then
                    set focused of elem to true
                    delay 0.3
                    keystroke \"a\" using command down
                    delay 0.1
                    keystroke \"v\" using command down
                    delay 0.5
                    return \"ok\"
                end if
            end try
        end repeat
        return \"not_found\"
    end tell
end tell
" 2>/dev/null || echo "error"
}

# Trigger generation via Cmd+Return keyboard shortcut
trigger_generate() {
    osascript -e '
tell application "System Events"
    tell process "Qwen Voice"
        set frontmost to true
        delay 0.5
        keystroke return using command down
    end tell
end tell
' 2>/dev/null || true
}

# List .wav files in a directory, sorted
list_wav_files() {
    find "$1" -maxdepth 1 -name "*.wav" -type f 2>/dev/null | sort
}

# Wait for a new .wav file to appear in a directory.
# Compares against a snapshot of files taken before generation.
# Echoes the new file path on success.
wait_for_new_wav() {
    local dir="$1"
    local timeout_s="$2"
    local before_snapshot="$3"  # newline-separated list of existing files

    local elapsed=0
    while (( elapsed < timeout_s )); do
        sleep 1
        elapsed=$((elapsed + 1))

        local current_files
        current_files=$(list_wav_files "$dir")

        # Find a file in current that wasn't in before
        local new_file=""
        while IFS= read -r f; do
            if [[ -n "$f" ]] && ! echo "$before_snapshot" | grep -qF "$f"; then
                new_file="$f"
                break
            fi
        done <<< "$current_files"

        if [[ -n "$new_file" && -f "$new_file" ]]; then
            # Wait for file size to stabilize (fully written)
            local prev_size=0
            local curr_size
            curr_size=$(stat -f%z "$new_file" 2>/dev/null || echo "0")
            while (( curr_size != prev_size )); do
                prev_size=$curr_size
                sleep 0.5
                curr_size=$(stat -f%z "$new_file" 2>/dev/null || echo "0")
            done
            echo "$new_file"
            return 0
        fi
    done
    return 1
}

# Get audio duration in seconds using afinfo (macOS built-in), rounded to 1dp
get_audio_duration() {
    local raw
    raw=$(afinfo "$1" 2>/dev/null | grep "estimated duration:" | awk '{print $3}' | head -1)
    if [[ -n "$raw" ]]; then
        awk "BEGIN {printf \"%.1f\", $raw}"
    fi
}

# Get file size in human-readable format
get_file_size_human() {
    ls -lh "$1" 2>/dev/null | awk '{print $5}'
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

# ── Metrics & Tracking ─────────────────────────────────────────────────────────

declare -a METRIC_NAMES=()
declare -a METRIC_CHARS=()
declare -a METRIC_GEN_TIMES=()
declare -a METRIC_DURATIONS=()
declare -a METRIC_RTFS=()
declare -a METRIC_SIZES=()
declare -a GENERATED_FILES=()

# ── Reusable Generation Test ────────────────────────────────────────────────────

# run_generation_test <test_name> <output_subdir> <text> <timeout>
#
# Assumes correct tab is selected and mode-specific setup (speaker, description)
# is already done. Enters text, triggers generation, waits for output file.
run_generation_test() {
    local test_name="$1"
    local output_subdir="$2"
    local text="$3"
    local timeout_s="$4"

    local output_dir="$OUTPUTS_DIR/$output_subdir"
    mkdir -p "$output_dir" 2>/dev/null || true

    # Snapshot existing files
    local before_files
    before_files=$(list_wav_files "$output_dir")

    # Enter text into the text field
    local field_result
    field_result=$(enter_text_in_field "textInput_textEditor" "$text")
    if [[ "$field_result" == "not_found" || "$field_result" == "error" ]]; then
        warn "Could not find text input field — attempting generation anyway"
    fi
    sleep 1

    # Start timer and trigger
    local char_count=${#text}
    info "Generating: \"${text:0:50}$([ ${char_count} -gt 50 ] && echo '...' || true)\" ($char_count chars, timeout: ${timeout_s}s)"
    local start_ms
    start_ms=$(now_ms)

    trigger_generate

    # Wait for new output file
    local new_file
    if new_file=$(wait_for_new_wav "$output_dir" "$timeout_s" "$before_files"); then
        local end_ms
        end_ms=$(now_ms)
        local gen_time_ms=$((end_ms - start_ms))
        local gen_time_s
        gen_time_s=$(awk "BEGIN {printf \"%.1f\", $gen_time_ms / 1000}")

        # Audio metrics
        local audio_duration
        audio_duration=$(get_audio_duration "$new_file")
        local file_size
        file_size=$(get_file_size_human "$new_file")

        # RTF = generation time / audio duration (lower = better)
        local rtf="N/A"
        if [[ -n "$audio_duration" ]] && awk "BEGIN {exit !($audio_duration > 0)}" 2>/dev/null; then
            rtf=$(awk "BEGIN {printf \"%.1f\", $gen_time_s / $audio_duration}")
        fi

        pass_test "$test_name: ${gen_time_s}s gen | ${audio_duration:-?}s audio | RTF ${rtf}x | ${file_size}"

        # Store metrics
        METRIC_NAMES+=("$test_name")
        METRIC_CHARS+=("$char_count")
        METRIC_GEN_TIMES+=("$gen_time_s")
        METRIC_DURATIONS+=("${audio_duration:-N/A}")
        METRIC_RTFS+=("$rtf")
        METRIC_SIZES+=("$file_size")
        GENERATED_FILES+=("$new_file")
    else
        fail_test "$test_name: timed out after ${timeout_s}s"

        METRIC_NAMES+=("$test_name")
        METRIC_CHARS+=("$char_count")
        METRIC_GEN_TIMES+=("TIMEOUT")
        METRIC_DURATIONS+=("N/A")
        METRIC_RTFS+=("N/A")
        METRIC_SIZES+=("N/A")
    fi

    # Brief pause between tests
    sleep 2
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

# 5. Backend ready
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
    ok "Backend ready"
else
    fail "Backend not ready after ${BACKEND_READY_TIMEOUT}s. Wait for it to start."
    exit 1
fi

# 6. Model checks
is_model_downloaded() {
    local folder="$1"
    [[ -d "$MODELS_DIR/$folder" ]]
}

if ! is_model_downloaded "$CUSTOM_MODEL_FOLDER"; then
    fail "Custom Voice model not downloaded (required). Go to Models tab to download."
    exit 1
fi
ok "Custom Voice model downloaded"

HAS_DESIGN_MODEL=false
if is_model_downloaded "$DESIGN_MODEL_FOLDER"; then
    HAS_DESIGN_MODEL=true
    info "Voice Design model downloaded — will test"
else
    warn "Voice Design model not downloaded — skipping Voice Design test"
fi

HAS_CLONE_SETUP=false
FIRST_VOICE=""
if is_model_downloaded "$CLONE_MODEL_FOLDER"; then
    FIRST_VOICE=$(find "$VOICES_DIR" -maxdepth 1 -name "*.wav" -type f 2>/dev/null | head -1)
    if [[ -n "$FIRST_VOICE" ]]; then
        HAS_CLONE_SETUP=true
        VOICE_NAME=$(basename "$FIRST_VOICE" .wav)
        info "Voice Cloning model + saved voice \"$VOICE_NAME\" found — will test"
    else
        warn "Voice Cloning model downloaded but no saved voices — skipping Voice Cloning test"
    fi
else
    warn "Voice Cloning model not downloaded — skipping Voice Cloning test"
fi

# ══════════════════════════════════════════════════════════════════════════════════
# Test 1: Custom Voice — Warmup (includes model loading)
# ══════════════════════════════════════════════════════════════════════════════════

header "Test 1: Custom Voice — Warmup"

navigate_sidebar 2
sleep 1

info "Speaker: vivian (default) | Text: ${#TEXT_SHORT} chars"
info "This test includes model loading time"

run_generation_test "CV Warmup (vivian)" "CustomVoice" "$TEXT_SHORT" "$WARMUP_TIMEOUT"

# ══════════════════════════════════════════════════════════════════════════════════
# Test 2: Custom Voice — Short Text (steady state, different speaker)
# ══════════════════════════════════════════════════════════════════════════════════

header "Test 2: Custom Voice — Short Text"

info "Switching speaker to serena..."
CLICK_RESULT=$(click_element_by_id "customVoice_speaker_serena")
if [[ "$CLICK_RESULT" != "ok" ]]; then
    warn "Could not click serena chip (got: $CLICK_RESULT) — using current speaker"
fi
sleep 0.5

run_generation_test "CV Short (serena)" "CustomVoice" "$TEXT_SHORT_ALT" "$SHORT_GEN_TIMEOUT"

# ══════════════════════════════════════════════════════════════════════════════════
# Test 3: Custom Voice — Medium Text
# ══════════════════════════════════════════════════════════════════════════════════

header "Test 3: Custom Voice — Medium Text"

info "Switching speaker to ryan..."
CLICK_RESULT=$(click_element_by_id "customVoice_speaker_ryan")
if [[ "$CLICK_RESULT" != "ok" ]]; then
    warn "Could not click ryan chip (got: $CLICK_RESULT) — using current speaker"
fi
sleep 0.5

run_generation_test "CV Medium (ryan)" "CustomVoice" "$TEXT_MEDIUM" "$MEDIUM_GEN_TIMEOUT"

# ══════════════════════════════════════════════════════════════════════════════════
# Test 4: Custom Voice — Long Text
# ══════════════════════════════════════════════════════════════════════════════════

header "Test 4: Custom Voice — Long Text"

info "Switching speaker to aiden..."
CLICK_RESULT=$(click_element_by_id "customVoice_speaker_aiden")
if [[ "$CLICK_RESULT" != "ok" ]]; then
    warn "Could not click aiden chip (got: $CLICK_RESULT) — using current speaker"
fi
sleep 0.5

run_generation_test "CV Long (aiden)" "CustomVoice" "$TEXT_LONG" "$LONG_GEN_TIMEOUT"

# ══════════════════════════════════════════════════════════════════════════════════
# Test 5: Voice Design (optional)
# ══════════════════════════════════════════════════════════════════════════════════

if [[ "$HAS_DESIGN_MODEL" == "true" ]]; then
    header "Test 5: Voice Design"

    info "Switching to Custom speaker (Voice Design mode)..."
    CLICK_RESULT=$(click_element_by_id "customVoice_speaker_custom")
    if [[ "$CLICK_RESULT" != "ok" ]]; then
        warn "Could not click Custom chip (got: $CLICK_RESULT)"
    fi
    sleep 1

    info "Entering voice description..."
    DESC_RESULT=$(enter_text_in_field "customVoice_voiceDescriptionField" "$VOICE_DESCRIPTION")
    if [[ "$DESC_RESULT" == "not_found" || "$DESC_RESULT" == "error" ]]; then
        warn "Could not find voice description field"
    fi
    sleep 0.5

    info "This test includes model switch (Custom Voice -> Voice Design)"
    run_generation_test "Voice Design" "VoiceDesign" "$TEXT_SHORT" "$DESIGN_GEN_TIMEOUT"
else
    header "Test 5: Voice Design (SKIPPED)"
    warn "Voice Design model not downloaded — test skipped"
fi

# ══════════════════════════════════════════════════════════════════════════════════
# Test 6: Voice Cloning (optional)
# ══════════════════════════════════════════════════════════════════════════════════

if [[ "$HAS_CLONE_SETUP" == "true" ]]; then
    header "Test 6: Voice Cloning"

    navigate_sidebar 3
    sleep 2  # extra time for saved voices to load

    info "Selecting saved voice \"$VOICE_NAME\"..."
    # Saved voice buttons don't have explicit accessibility IDs.
    # Search by button name matching the voice name.
    VOICE_CLICK=$(osascript -e "
tell application \"System Events\"
    tell process \"Qwen Voice\"
        set frontmost to true
        delay 0.5
        set contentArea to scroll area 1 of group 2 of splitter group 1 of group 1 of window 1
        set ec to entire contents of contentArea
        repeat with elem in ec
            try
                if role of elem is \"AXButton\" and name of elem is \"$VOICE_NAME\" then
                    click elem
                    delay 0.5
                    return \"ok\"
                end if
            end try
        end repeat
        return \"not_found\"
    end tell
end tell
" 2>/dev/null || echo "error")

    if [[ "$VOICE_CLICK" != "ok" ]]; then
        warn "Could not click saved voice \"$VOICE_NAME\" (got: $VOICE_CLICK) — attempting first button"
        # Fallback: try clicking the first button that looks like a voice card
        osascript -e '
tell application "System Events"
    tell process "Qwen Voice"
        set contentArea to scroll area 1 of group 2 of splitter group 1 of group 1 of window 1
        set ec to entire contents of contentArea
        repeat with elem in ec
            try
                if role of elem is "AXButton" then
                    set elemName to name of elem
                    -- Skip known non-voice buttons
                    if elemName is not "Batch" and elemName is not "Go to Models" and elemName does not contain "xmark" then
                        click elem
                        delay 0.5
                        exit repeat
                    end if
                end if
            end try
        end repeat
    end tell
end tell
' 2>/dev/null || true
    fi

    info "This test includes model switch (-> Voice Cloning)"
    run_generation_test "Voice Cloning" "Clones" "$TEXT_SHORT" "$CLONE_GEN_TIMEOUT"
else
    header "Test 6: Voice Cloning (SKIPPED)"
    warn "Voice Cloning model or saved voices not available — test skipped"
fi

# ══════════════════════════════════════════════════════════════════════════════════
# Cleanup
# ══════════════════════════════════════════════════════════════════════════════════

header "Cleanup"

if (( ${#GENERATED_FILES[@]} == 0 )); then
    info "No test files to remove"
elif [[ "$SKIP_CLEANUP" == "true" ]]; then
    info "--skip-cleanup: keeping ${#GENERATED_FILES[@]} generated test files"
    for f in "${GENERATED_FILES[@]}"; do
        info "  $f"
    done
else
    DELETED=0
    for f in "${GENERATED_FILES[@]}"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            DELETED=$((DELETED + 1))
        fi
    done
    if (( DELETED > 0 )); then
        pass_test "Removed $DELETED test file(s)"
    else
        info "No test files to remove"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════════
# Performance Summary
# ══════════════════════════════════════════════════════════════════════════════════

header "Performance Summary"

# Table header
printf "  ${BOLD}%-28s  %5s  %8s  %8s  %6s  %8s${RESET}\n" "Test" "Chars" "GenTime" "Duration" "RTF" "Size"
printf "  %-28s  %5s  %8s  %8s  %6s  %8s\n" "────────────────────────────" "─────" "────────" "────────" "──────" "────────"

# Table rows
for i in "${!METRIC_NAMES[@]}"; do
    local_rtf="${METRIC_RTFS[$i]}"
    if [[ "$local_rtf" != "N/A" ]]; then
        local_rtf="${local_rtf}x"
    fi
    printf "  %-28s  %5s  %7ss  %7ss  %6s  %8s\n" \
        "${METRIC_NAMES[$i]}" \
        "${METRIC_CHARS[$i]}" \
        "${METRIC_GEN_TIMES[$i]}" \
        "${METRIC_DURATIONS[$i]}" \
        "$local_rtf" \
        "${METRIC_SIZES[$i]}"
done

# Average RTF (excluding warmup)
RTF_SUM=0
RTF_COUNT=0
for i in "${!METRIC_RTFS[@]}"; do
    if (( i > 0 )) && [[ "${METRIC_RTFS[$i]}" != "N/A" ]]; then
        RTF_SUM=$(awk "BEGIN {printf \"%.1f\", $RTF_SUM + ${METRIC_RTFS[$i]}}")
        RTF_COUNT=$((RTF_COUNT + 1))
    fi
done
if (( RTF_COUNT > 0 )); then
    AVG_RTF=$(awk "BEGIN {printf \"%.1f\", $RTF_SUM / $RTF_COUNT}")
    echo ""
    echo -e "  ${BOLD}Average RTF (excl. warmup): ${AVG_RTF}x${RESET}"
fi
echo ""

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
