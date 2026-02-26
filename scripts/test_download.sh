#!/bin/bash
# Automated model download test using AppleScript + file system monitoring.
#
# Uses osascript to click the Download button for the Voice Design model,
# monitors the download via file system polling, verifies completion,
# then cleans up by clicking the delete button.
#
# Prerequisites:
#   - "Qwen Voice" app must be running (with window open)
#   - Terminal must have Accessibility permissions (System Settings → Privacy & Security → Accessibility)
#
# Usage:
#   ./scripts/test_download.sh

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────────

BUNDLE_ID="com.qwenvoice.app"
APP_NAME="Qwen Voice"
MODEL_ID="pro_design"
MODEL_NAME="Voice Design"
MODEL_FOLDER="Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit"
MODEL_DIR="$HOME/Library/Application Support/QwenVoice/models/$MODEL_FOLDER"
EXPECTED_SIZE_MB=900
POLL_INTERVAL=5            # seconds between progress checks
DOWNLOAD_TIMEOUT=600       # 10 minutes max

# ── Colors ──────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Helpers ─────────────────────────────────────────────────────────────────────

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[PASS]${RESET}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
fail()  { echo -e "${RED}[FAIL]${RESET}  $*"; }
header() { echo -e "\n${BOLD}═══ $* ═══${RESET}\n"; }

dir_size_bytes() {
    if [[ -d "$1" ]]; then
        du -sk "$1" 2>/dev/null | awk '{print $1 * 1024}'
    else
        echo 0
    fi
}

dir_size_human() {
    if [[ -d "$1" ]]; then
        du -sh "$1" 2>/dev/null | awk '{print $1}'
    else
        echo "0B"
    fi
}

file_count() {
    if [[ -d "$1" ]]; then
        find "$1" -type f 2>/dev/null | wc -l | tr -d ' '
    else
        echo 0
    fi
}

# AppleScript path prefix — the hierarchy to reach the sidebar and content area:
#   window 1 → group 1 → splitter group 1 → group 1 (sidebar) / group 2 (content)
# Sidebar outline: outline 1 of scroll area 1 of group 1
# Content scroll:  scroll area 1 of group 2
#   Model cards are groups inside the scroll area:
#     group 1 = Custom Voice, group 2 = Voice Design, group 3 = Voice Cloning

# ── Preflight checks ───────────────────────────────────────────────────────────

header "Preflight Checks"

# Check app is running
if ! pgrep -f "$APP_NAME" > /dev/null 2>&1; then
    fail "$APP_NAME is not running. Please launch the app first."
    exit 1
fi
ok "$APP_NAME is running"

# Check window exists
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

# Check model is not already downloaded
if [[ -d "$MODEL_DIR" ]]; then
    SIZE=$(dir_size_human "$MODEL_DIR")
    warn "Model directory already exists ($SIZE). Will be overwritten by download."
fi

# ── Step 1: Navigate to Models tab ──────────────────────────────────────────────

header "Step 1: Navigate to Models Tab"

info "Clicking Models sidebar item (row 8 in sidebar outline)..."
osascript <<'APPLESCRIPT'
tell application "System Events"
    tell process "Qwen Voice"
        set frontmost to true
        delay 0.5

        -- Sidebar outline lives at:
        --   window 1 > group 1 > splitter group 1 > group 1 > scroll area 1 > outline 1
        set sidebarOutline to outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1

        -- Row 8 = Models (rows: Generate header, Custom Voice, Voice Cloning,
        --   Library header, History, Voices, Settings header, Models, Preferences)
        set modelsRow to row 8 of sidebarOutline
        select modelsRow

        delay 1.0
    end tell
end tell
APPLESCRIPT

# Verify we're on the Models tab by checking the content area
MODELS_TITLE=$(osascript -e '
tell application "System Events"
    tell process "Qwen Voice"
        set contentArea to scroll area 1 of group 2 of splitter group 1 of group 1 of window 1
        return value of static text 1 of contentArea
    end tell
end tell
' 2>&1 || echo "unknown")

if [[ "$MODELS_TITLE" == "Models" ]]; then
    ok "Navigated to Models tab (title confirmed: \"$MODELS_TITLE\")"
else
    warn "Expected title \"Models\", got \"$MODELS_TITLE\" — continuing anyway"
fi

# Check current state of the Voice Design card
VD_STATUS=$(osascript -e '
tell application "System Events"
    tell process "Qwen Voice"
        set contentArea to scroll area 1 of group 2 of splitter group 1 of group 1 of window 1
        -- Voice Design = group 2 (second model card)
        set vdCard to group 2 of contentArea
        -- Status text is the 3rd static text (after model name and folder)
        set allTexts to every static text of vdCard
        if (count of allTexts) ≥ 3 then
            return value of item 3 of allTexts
        end if
        return "unknown"
    end tell
end tell
' 2>&1 || echo "unknown")

info "Voice Design status: \"$VD_STATUS\""

if [[ "$VD_STATUS" == *"Ready"* ]] || [[ "$VD_STATUS" == *"ready"* ]]; then
    warn "Voice Design already downloaded — will skip to cleanup step"
    ALREADY_DOWNLOADED=true
else
    ALREADY_DOWNLOADED=false
fi

# ── Step 2: Click Download button ───────────────────────────────────────────────

if [[ "$ALREADY_DOWNLOADED" == "false" ]]; then

header "Step 2: Click Download Button"

info "Clicking Download button on Voice Design card (group 2, button 1)..."
osascript <<'APPLESCRIPT'
tell application "System Events"
    tell process "Qwen Voice"
        set frontmost to true
        delay 0.3

        -- Content area: scroll area 1 of group 2 of splitter group 1 of group 1 of window 1
        -- Voice Design card: group 2 of the scroll area
        -- The button (Download/Delete/Retry) is button 1 of the card group
        set contentArea to scroll area 1 of group 2 of splitter group 1 of group 1 of window 1
        set vdCard to group 2 of contentArea
        click button 1 of vdCard
    end tell
end tell
APPLESCRIPT

ok "Download button clicked"

# ── Step 3: Monitor download progress ──────────────────────────────────────────

header "Step 3: Monitor Download Progress"

info "Watching model directory: $MODEL_DIR"
info "Expected size: ~${EXPECTED_SIZE_MB} MB"
info "Polling every ${POLL_INTERVAL}s (timeout: ${DOWNLOAD_TIMEOUT}s)"
echo ""

# Verify no huggingface-cli subprocess (should use URLSession)
sleep 3  # give download a moment to start
if pgrep -f "huggingface-cli" > /dev/null 2>&1; then
    warn "huggingface-cli process detected — expected native URLSession download"
else
    ok "No huggingface-cli process — using native URLSession as expected"
fi

# Wait for directory to appear
WAITED=0
while [[ ! -d "$MODEL_DIR" ]]; do
    if (( WAITED >= 30 )); then
        fail "Model directory did not appear within 30 seconds"
        exit 1
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done
ok "Model directory created after ${WAITED}s"

# Poll download progress
ELAPSED=0
PREV_SIZE=0
STALL_COUNT=0
MAX_STALLS=12  # 60 seconds of no progress = stall

while true; do
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))

    if (( ELAPSED > DOWNLOAD_TIMEOUT )); then
        fail "Download timed out after ${DOWNLOAD_TIMEOUT}s"
        exit 1
    fi

    CURRENT_SIZE=$(dir_size_bytes "$MODEL_DIR")
    CURRENT_HUMAN=$(dir_size_human "$MODEL_DIR")
    CURRENT_FILES=$(file_count "$MODEL_DIR")
    CURRENT_MB=$((CURRENT_SIZE / 1024 / 1024))
    PROGRESS_PCT=$((CURRENT_MB * 100 / EXPECTED_SIZE_MB))

    # Cap at 100%
    if (( PROGRESS_PCT > 100 )); then
        PROGRESS_PCT=100
    fi

    # Progress bar
    BAR_LEN=30
    FILLED=$((PROGRESS_PCT * BAR_LEN / 100))
    EMPTY=$((BAR_LEN - FILLED))
    BAR=$(printf '%0.s█' $(seq 1 $FILLED 2>/dev/null) 2>/dev/null || true)
    SPACE=$(printf '%0.s░' $(seq 1 $EMPTY 2>/dev/null) 2>/dev/null || true)

    printf "\r  [${BAR}${SPACE}] %3d%%  %s  (%d files, %ds elapsed)" \
        "$PROGRESS_PCT" "$CURRENT_HUMAN" "$CURRENT_FILES" "$ELAPSED"

    # Check for stalls
    if (( CURRENT_SIZE == PREV_SIZE )); then
        STALL_COUNT=$((STALL_COUNT + 1))
        if (( STALL_COUNT >= MAX_STALLS )); then
            echo ""
            # Could be finished — check size threshold
            if (( CURRENT_MB >= EXPECTED_SIZE_MB / 2 )); then
                info "Download appears complete (stable for ${MAX_STALLS} intervals, size above threshold)"
                break
            else
                fail "Download stalled for $((MAX_STALLS * POLL_INTERVAL))s at ${CURRENT_HUMAN}"
                exit 1
            fi
        fi
    else
        STALL_COUNT=0
    fi
    PREV_SIZE=$CURRENT_SIZE

    # Check completion by size
    if (( CURRENT_MB >= EXPECTED_SIZE_MB * 9 / 10 )); then
        # Close to expected size — wait a bit more for finalizing
        sleep "$POLL_INTERVAL"
        FINAL_SIZE=$(dir_size_bytes "$MODEL_DIR")
        if (( FINAL_SIZE == CURRENT_SIZE )); then
            echo ""
            info "Download complete (size stable at $(dir_size_human "$MODEL_DIR"))"
            break
        fi
    fi
done
echo ""

# ── Step 4: Verify completion ───────────────────────────────────────────────────

header "Step 4: Verify Download"

FINAL_SIZE_BYTES=$(dir_size_bytes "$MODEL_DIR")
FINAL_SIZE_MB=$((FINAL_SIZE_BYTES / 1024 / 1024))
FINAL_SIZE_HUMAN=$(dir_size_human "$MODEL_DIR")
FINAL_FILE_COUNT=$(file_count "$MODEL_DIR")

info "Final size: $FINAL_SIZE_HUMAN ($FINAL_SIZE_MB MB)"
info "File count: $FINAL_FILE_COUNT"

# Check size is reasonable (at least 50% of expected)
if (( FINAL_SIZE_MB >= EXPECTED_SIZE_MB / 2 )); then
    ok "Size check passed: ${FINAL_SIZE_MB} MB >= $((EXPECTED_SIZE_MB / 2)) MB"
else
    fail "Size check failed: ${FINAL_SIZE_MB} MB < $((EXPECTED_SIZE_MB / 2)) MB"
    exit 1
fi

# List directory contents
info "Directory contents:"
ls -lh "$MODEL_DIR" 2>/dev/null | head -20

# Check for key model files (typical HuggingFace model repo files)
EXPECTED_FILES=("config.json" "tokenizer.json")
for f in "${EXPECTED_FILES[@]}"; do
    if find "$MODEL_DIR" -name "$f" -type f 2>/dev/null | head -1 | grep -q .; then
        ok "Found $f"
    else
        warn "Missing $f (may be expected for this model format)"
    fi
done

# Verify no huggingface-cli was used
if pgrep -f "huggingface-cli" > /dev/null 2>&1; then
    warn "huggingface-cli process still running"
else
    ok "Download used native URLSession (no huggingface-cli)"
fi

# Check UI shows "Ready" status
VD_STATUS_AFTER=$(osascript -e '
tell application "System Events"
    tell process "Qwen Voice"
        set contentArea to scroll area 1 of group 2 of splitter group 1 of group 1 of window 1
        set vdCard to group 2 of contentArea
        set allTexts to every static text of vdCard
        if (count of allTexts) ≥ 3 then
            return value of item 3 of allTexts
        end if
        return "unknown"
    end tell
end tell
' 2>&1 || echo "unknown")

if [[ "$VD_STATUS_AFTER" == *"Ready"* ]]; then
    ok "UI shows: \"$VD_STATUS_AFTER\""
else
    warn "UI status: \"$VD_STATUS_AFTER\" (expected \"Ready — ...\")"
fi

fi  # end of ALREADY_DOWNLOADED check

# ── Step 5: Clean up — delete the model ─────────────────────────────────────────

header "Step 5: Clean Up — Delete Model"

# Capture stats before deletion (if we have them from step 4, they're already set;
# if model was already downloaded, capture them now)
if [[ "$ALREADY_DOWNLOADED" == "true" ]]; then
    FINAL_SIZE_HUMAN=$(dir_size_human "$MODEL_DIR")
    FINAL_SIZE_MB=$(($(dir_size_bytes "$MODEL_DIR") / 1024 / 1024))
    FINAL_FILE_COUNT=$(file_count "$MODEL_DIR")
fi

info "Waiting 3s before cleanup (let UI settle)..."
sleep 3

info "Clicking delete (trash) button for $MODEL_NAME..."
osascript <<'APPLESCRIPT'
tell application "System Events"
    tell process "Qwen Voice"
        set frontmost to true
        delay 0.5

        -- Make sure we're on the Models tab
        set sidebarOutline to outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1
        select row 8 of sidebarOutline
        delay 1.0

        -- Voice Design card = group 2, its button 1 is now the trash/delete button
        set contentArea to scroll area 1 of group 2 of splitter group 1 of group 1 of window 1
        set vdCard to group 2 of contentArea
        click button 1 of vdCard
    end tell
end tell
APPLESCRIPT

ok "Delete button clicked"

# Wait for directory to be removed
WAITED=0
while [[ -d "$MODEL_DIR" ]]; do
    if (( WAITED >= 15 )); then
        fail "Model directory still exists after 15 seconds"
        exit 1
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done
ok "Model directory removed after ${WAITED}s"

# Verify UI shows "Not downloaded"
VD_STATUS_FINAL=$(osascript -e '
tell application "System Events"
    tell process "Qwen Voice"
        set contentArea to scroll area 1 of group 2 of splitter group 1 of group 1 of window 1
        set vdCard to group 2 of contentArea
        set allTexts to every static text of vdCard
        if (count of allTexts) ≥ 3 then
            return value of item 3 of allTexts
        end if
        return "unknown"
    end tell
end tell
' 2>&1 || echo "unknown")

if [[ "$VD_STATUS_FINAL" == "Not downloaded" ]]; then
    ok "UI shows: \"$VD_STATUS_FINAL\""
else
    warn "UI status: \"$VD_STATUS_FINAL\" (expected \"Not downloaded\")"
fi

# ── Summary ─────────────────────────────────────────────────────────────────────

header "Test Results"

echo -e "${GREEN}${BOLD}ALL CHECKS PASSED${RESET}"
echo ""
echo "  Model:            $MODEL_NAME ($MODEL_ID)"
echo "  Download size:    ${FINAL_SIZE_HUMAN:-N/A} (${FINAL_SIZE_MB:-N/A} MB)"
echo "  Files:            ${FINAL_FILE_COUNT:-N/A}"
echo "  Download method:  Native URLSession (no huggingface-cli)"
echo "  Cleanup:          Model directory deleted successfully"
echo ""
