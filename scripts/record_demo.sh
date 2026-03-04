#!/opt/homebrew/bin/bash
# record_demo.sh — Record a full promotional demo of QwenVoice v1.1.0 for X
#
# Shows the complete flow: select speaker & emotion, type text, generate audio,
# listen to playback with waveform, then switch to History.
#
# Output: build/demo.mp4 (1280×720, H.264, yuv420p, silent video)
#
# Prerequisites:
#   - "QwenVoice" app running, Custom Voice tab visible, window not obscured
#   - Custom Voice model downloaded and loaded
#   - Terminal has Accessibility + Screen Recording permissions
#   - Window tall enough to show all controls without scrolling (~700pt+)
#
# Usage:
#   ./scripts/record_demo.sh              # Record demo
#   ./scripts/record_demo.sh --dry-run    # Show click positions without recording

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
RAW_FILE="/tmp/qwenvoice_demo_raw.mov"
OUTPUT_FILE="$BUILD_DIR/demo.mp4"
DEMO_TEXT="The weather is beautiful today and I feel amazing!"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# ── Find ffmpeg ───────────────────────────────────────────────────────────────

FFMPEG="$PROJECT_DIR/Sources/Resources/ffmpeg"
if [ ! -x "$FFMPEG" ]; then
    FFMPEG="$(command -v ffmpeg 2>/dev/null || true)"
    if [[ -z "$FFMPEG" ]]; then
        echo "ERROR: ffmpeg not found (checked Sources/Resources/ffmpeg and PATH)"
        exit 1
    fi
fi
FFPROBE="$(command -v ffprobe 2>/dev/null || true)"
echo "ffmpeg: $FFMPEG"

# ── Pre-flight checks ────────────────────────────────────────────────────────

if ! pgrep -x "QwenVoice" >/dev/null 2>&1; then
    echo "ERROR: QwenVoice is not running. Launch the app first."
    exit 1
fi

osascript -e 'tell application "QwenVoice" to activate'
sleep 0.5

# Window geometry (points)
read -r WIN_X WIN_Y WIN_W WIN_H <<< "$(osascript -e '
tell application "System Events"
    tell process "QwenVoice"
        set {x, y} to position of window 1
        set {w, h} to size of window 1
        return (x as text) & " " & (y as text) & " " & (w as text) & " " & (h as text)
    end tell
end tell')"
echo "Window: origin=($WIN_X,$WIN_Y) size=${WIN_W}x${WIN_H}"

if (( WIN_W < 900 || WIN_H < 650 )); then
    echo "WARNING: Window is small (${WIN_W}x${WIN_H}). Resize to at least 1000x700 for best results."
fi

# ── Sidebar navigation helper ──────────────────────────────────────────────────
# NavigationSplitView selection requires selecting the row in the NSOutlineView
# directly — coordinate-based clicks don't reliably trigger the SwiftUI binding.

select_sidebar_row() {
    local target_id="$1"
    local row_num
    row_num=$(osascript -l JavaScript <<ROWEOF
(() => {
    const se = Application('System Events');
    const proc = se.processes['QwenVoice'];
    const outline = proc.windows[0].groups[0].splitterGroups[0].groups[0].scrollAreas[0].outlines[0];
    const rows = outline.rows();
    for (let i = 0; i < rows.length; i++) {
        try {
            const all = rows[i].entireContents();
            for (let j = 0; j < all.length; j++) {
                try {
                    const axId = all[j].attributes.byName('AXIdentifier').value();
                    if (axId === '${target_id}') return (i + 1).toString();
                } catch(e) {}
            }
        } catch(e) {}
    }
    return 'NOT_FOUND';
})();
ROWEOF
    )
    if [[ "$row_num" == "NOT_FOUND" ]]; then
        echo "  WARNING: Sidebar row for $target_id not found"
        return 1
    fi
    osascript -e "tell application \"System Events\" to tell process \"QwenVoice\" to tell outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1 to select row ${row_num}"
    sleep 0.8
    echo "  Selected sidebar: $target_id (row $row_num)"
}

# ── Ensure Custom Voice tab is active before scanning ─────────────────────────

echo "Switching to Custom Voice tab..."
select_sidebar_row "sidebar_customVoice"

# ── Discover UI element positions via accessibility identifiers ───────────────

echo "Scanning accessibility tree for UI elements..."
ELEMENT_DATA=$(osascript -l JavaScript <<'JSEOF'
(() => {
    const se = Application('System Events');
    const proc = se.processes['QwenVoice'];
    const win = proc.windows[0];

    const targets = [
        'customVoice_speaker_ryan',
        'customVoice_speaker_serena',
        'customVoice_emotion_neutral',
        'customVoice_emotion_happy',
        'customVoice_speed_fast',
        'customVoice_speed_normal',
        'textInput_textEditor',
        'textInput_generateButton',
    ];
    const found = {};

    try {
        const all = win.entireContents();
        for (let i = 0; i < all.length; i++) {
            try {
                const el = all[i];
                let axId;
                try { axId = el.attributes.byName('AXIdentifier').value(); } catch(e) { continue; }
                if (axId && targets.includes(axId) && !found[axId]) {
                    const pos = el.position();
                    const sz  = el.size();
                    found[axId] = Math.round(pos[0] + sz[0] / 2) + ',' + Math.round(pos[1] + sz[1] / 2);
                }
            } catch(e) { /* skip inaccessible elements */ }
        }
    } catch(e) {
        return 'SCAN_ERROR:' + e.message;
    }

    const lines = [];
    for (const id of targets) {
        lines.push(id + '=' + (found[id] || 'NOT_FOUND'));
    }
    return lines.join('\n');
})();
JSEOF
)

if [[ "$ELEMENT_DATA" == SCAN_ERROR* ]]; then
    echo "ERROR: Accessibility scan failed — ${ELEMENT_DATA#SCAN_ERROR:}"
    echo "Ensure Terminal has Accessibility permission in System Settings."
    exit 1
fi

# Parse discovered positions
declare -A CLICK_POS
ALL_FOUND=true
while IFS='=' read -r id coords; do
    [[ -z "$id" ]] && continue
    if [[ "$coords" == "NOT_FOUND" ]]; then
        echo "  MISSING: $id"
        ALL_FOUND=false
    else
        CLICK_POS[$id]="$coords"
        echo "  $id → ($coords)"
    fi
done <<< "$ELEMENT_DATA"

if ! $ALL_FOUND; then
    echo ""
    echo "Some UI elements were not found. Check that:"
    echo "  1. Custom Voice tab is the active tab"
    echo "  2. Window is tall enough to show Speaker, Emotion, and Speed controls"
    echo "  3. Terminal has Accessibility permission"
    exit 1
fi
echo "All elements found."

# ── Click helper (smooth mouse move + click) ─────────────────────────────────

click_element() {
    local id="$1"
    local coords="${CLICK_POS[$id]}"
    local x="${coords%%,*}"
    local y="${coords##*,}"

    if $DRY_RUN; then
        echo "  CLICK $id at ($x, $y)"
        return
    fi

    echo "  -> $id"
    osascript -l JavaScript <<MOVEEOF
ObjC.import('CoreGraphics');
const dest = {x: ${x}, y: ${y}};
const cur = $.CGEventGetLocation($.CGEventCreate($.nil));
const steps = 20;
for (let i = 1; i <= steps; i++) {
    const t = i / steps;
    const px = cur.x + (dest.x - cur.x) * t;
    const py = cur.y + (dest.y - cur.y) * t;
    const ev = $.CGEventCreateMouseEvent($.nil, $.kCGEventMouseMoved, {x: px, y: py}, 0);
    $.CGEventPost($.kCGHIDEventTap, ev);
    delay(0.015);
}
delay(0.25);
const down = $.CGEventCreateMouseEvent($.nil, $.kCGEventLeftMouseDown, dest, 0);
const up   = $.CGEventCreateMouseEvent($.nil, $.kCGEventLeftMouseUp, dest, 0);
$.CGEventPost($.kCGHIDEventTap, down);
delay(0.05);
$.CGEventPost($.kCGHIDEventTap, up);
MOVEEOF
}

# ── Type text helper (character by character with realistic cadence) ──────────

type_text() {
    local text="$1"

    if $DRY_RUN; then
        echo "  TYPE: \"$text\""
        return
    fi

    # Type word by word with pauses for a natural typing feel
    local words
    read -ra words <<< "$text"
    for (( i=0; i<${#words[@]}; i++ )); do
        local word="${words[$i]}"
        # Add space before word (except the first)
        if (( i > 0 )); then
            osascript -e 'tell application "System Events" to keystroke " "'
            sleep 0.08
        fi
        osascript -e "tell application \"System Events\" to keystroke \"${word}\""
        sleep $(echo "0.1 + 0.02 * ${#word}" | bc)
    done
}

# ── Wait for sidebar player to appear (generation complete) ───────────────────

wait_for_player() {
    local max_wait=${1:-30}
    local elapsed=0

    if $DRY_RUN; then
        echo "  WAIT for sidebarPlayer_bar (up to ${max_wait}s)"
        return
    fi

    echo "  Waiting for audio generation (up to ${max_wait}s)..."
    while (( elapsed < max_wait )); do
        local found
        found=$(osascript -l JavaScript <<'WAITEOF'
(() => {
    const se = Application('System Events');
    const proc = se.processes['QwenVoice'];
    const win = proc.windows[0];
    try {
        const all = win.entireContents();
        for (let i = 0; i < all.length; i++) {
            try {
                const axId = all[i].attributes.byName('AXIdentifier').value();
                if (axId === 'sidebarPlayer_bar') return 'YES';
            } catch(e) {}
        }
    } catch(e) {}
    return 'NO';
})();
WAITEOF
        )
        if [[ "$found" == "YES" ]]; then
            echo "  Player appeared after ~${elapsed}s"
            return 0
        fi
        sleep 1
        ((elapsed++))
    done
    echo "  WARNING: Player did not appear within ${max_wait}s"
    return 1
}

# ── Dry-run mode ──────────────────────────────────────────────────────────────

if $DRY_RUN; then
    echo ""
    echo "==> Planned demo sequence:"
    echo ""
    echo "  PRE-RECORDING: Reset to ryan + neutral"
    click_element "customVoice_speaker_ryan"
    click_element "customVoice_emotion_neutral"
    echo ""
    echo "  [0s]  Start recording — clean Custom Voice UI"
    echo "  [3s]  Click speaker: serena"
    click_element "customVoice_speaker_serena"
    echo "  [5s]  Click emotion: Happy"
    click_element "customVoice_emotion_happy"
    echo "  [7s]  Click speed: Fast"
    click_element "customVoice_speed_fast"
    echo "  [9s]  Click text input"
    click_element "textInput_textEditor"
    echo "  [10s] Type: \"$DEMO_TEXT\""
    type_text "$DEMO_TEXT"
    echo "  [13s] Click generate button"
    click_element "textInput_generateButton"
    echo "  [14s] Wait for generation..."
    wait_for_player 30
    echo "  [~25s] Audio plays (auto-play), hold 8s"
    echo "  [~33s] Switch to History tab (via select_sidebar_row)"
    echo "  [~38s] Hold History for 5s"
    echo "  [~43s] Stop recording"
    echo ""
    echo "All elements found. Ready to record (run without --dry-run)."
    exit 0
fi

# ── Reset UI to known state (before recording) ───────────────────────────────

echo ""
echo "Resetting UI to clean state..."
osascript -e 'tell application "QwenVoice" to activate'
sleep 0.3

# Click Custom Voice tab first to ensure we're on it
select_sidebar_row "sidebar_customVoice"

# Select ryan (default) + neutral emotion + normal speed
click_element "customVoice_speaker_ryan"
sleep 0.3
click_element "customVoice_emotion_neutral"
sleep 0.3
click_element "customVoice_speed_normal"
sleep 0.3

# Clear any existing text in the text editor
click_element "textInput_textEditor"
sleep 0.2
osascript -e 'tell application "System Events" to keystroke "a" using command down'
sleep 0.1
osascript -e 'tell application "System Events" to key code 51' # Delete
sleep 0.5

echo "UI reset complete."

# ── Determine screen capture device ──────────────────────────────────────────

SCREEN_DEVICE=$("$FFMPEG" -f avfoundation -list_devices true -i "" 2>&1 | \
    grep -i "Capture screen 0" | grep -oE '\[([0-9]+)\]' | head -1 | tr -d '[]' || echo "1")
echo "Screen capture device index: $SCREEN_DEVICE"

# ── Cleanup on exit ──────────────────────────────────────────────────────────

FFMPEG_PID=""
cleanup() {
    if [[ -n "$FFMPEG_PID" ]] && kill -0 "$FFMPEG_PID" 2>/dev/null; then
        kill -INT "$FFMPEG_PID" 2>/dev/null || true
        wait "$FFMPEG_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Start recording ──────────────────────────────────────────────────────────

mkdir -p "$BUILD_DIR"
rm -f "$RAW_FILE"

# Park cursor in the content area center before recording starts
CENTER_X=$((WIN_X + WIN_W * 2 / 3))
CENTER_Y=$((WIN_Y + WIN_H / 2))
osascript -l JavaScript -e "
ObjC.import('CoreGraphics');
const ev = $.CGEventCreateMouseEvent($.nil, $.kCGEventMouseMoved, {x: ${CENTER_X}, y: ${CENTER_Y}}, 0);
$.CGEventPost($.kCGHIDEventTap, ev);
"

echo ""
echo "Starting screen recording (90s max)..."
"$FFMPEG" -y -f avfoundation -framerate 30 -capture_cursor 1 \
    -i "${SCREEN_DEVICE}:none" -t 90 \
    "$RAW_FILE" >/dev/null 2>/tmp/ffmpeg_record.log &
FFMPEG_PID=$!
sleep 2

if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
    echo "ERROR: ffmpeg failed to start. Log:"
    cat /tmp/ffmpeg_record.log
    exit 1
fi
echo "Recording started (PID $FFMPEG_PID)"
osascript -e 'tell application "QwenVoice" to activate'

# ── Scene 1: Clean Custom Voice UI (3s) ──────────────────────────────────────

echo ""
echo "==> Scene 1: Clean Custom Voice UI (3s)"
sleep 3

# ── Scene 2: Select speaker serena ───────────────────────────────────────────

echo "==> Scene 2: Select speaker serena"
click_element "customVoice_speaker_serena"
sleep 2

# ── Scene 3: Select emotion Happy ────────────────────────────────────────────

echo "==> Scene 3: Select emotion Happy"
click_element "customVoice_emotion_happy"
sleep 2

# ── Scene 4: Select speed Fast ───────────────────────────────────────────────

echo "==> Scene 4: Select speed Fast"
click_element "customVoice_speed_fast"
sleep 2

# ── Scene 5: Click text input and type ────────────────────────────────────────

echo "==> Scene 5: Type demo text"
click_element "textInput_textEditor"
sleep 0.5
type_text "$DEMO_TEXT"
sleep 1.5

# ── Scene 6: Click Generate and wait ─────────────────────────────────────────

echo "==> Scene 6: Generate audio"
click_element "textInput_generateButton"
sleep 1

# Wait for the sidebar player to appear (= generation done + auto-play started)
if wait_for_player 40; then
    echo "==> Audio is playing!"
    # Let the audio play for 8 seconds so the waveform animation is visible
    sleep 8
else
    echo "==> Generation may have failed, continuing anyway..."
    sleep 3
fi

# ── Scene 7: Switch to History ────────────────────────────────────────────────

echo "==> Scene 7: History tab"
select_sidebar_row "sidebar_history"
sleep 5

echo "==> Automation complete"

# ── Stop recording ───────────────────────────────────────────────────────────

echo ""
echo "Stopping recording..."
kill -INT "$FFMPEG_PID" 2>/dev/null || true
wait "$FFMPEG_PID" 2>/dev/null || true
FFMPEG_PID=""

if [ ! -f "$RAW_FILE" ]; then
    echo "ERROR: Raw recording not found at $RAW_FILE"
    exit 1
fi
echo "Raw recording: $(du -h "$RAW_FILE" | cut -f1)"

# ── Post-process: crop to window, encode to 1280x720 H.264 ──────────────────

echo ""
echo "Post-processing..."

# Detect Retina scale factor
RETINA_SCALE=$(osascript -l JavaScript -e '
ObjC.import("AppKit");
Math.round($.NSScreen.mainScreen.backingScaleFactor);
' 2>/dev/null || echo "2")
echo "Retina scale: ${RETINA_SCALE}x"

# Crop region in pixels (screen coordinates × Retina scale)
CROP_W=$((WIN_W * RETINA_SCALE))
CROP_H=$((WIN_H * RETINA_SCALE))
CROP_X=$((WIN_X * RETINA_SCALE))
CROP_Y=$((WIN_Y * RETINA_SCALE))
echo "Crop: ${CROP_W}x${CROP_H} at (${CROP_X},${CROP_Y}) pixels"

# Crop window area → scale to fit 1280x720 → pad with dark background
"$FFMPEG" -y -i "$RAW_FILE" \
    -vf "crop=${CROP_W}:${CROP_H}:${CROP_X}:${CROP_Y},\
scale=1280:720:force_original_aspect_ratio=decrease,\
pad=1280:720:(ow-iw)/2:(oh-ih)/2:color=0x1a1a2e" \
    -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p \
    -an -movflags +faststart \
    -r 30 \
    "$OUTPUT_FILE" 2>/tmp/ffmpeg_encode.log

if [ ! -f "$OUTPUT_FILE" ]; then
    echo "ERROR: Encoding failed. Log:"
    cat /tmp/ffmpeg_encode.log
    exit 1
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "==> $OUTPUT_FILE"
echo "    Size: $(du -h "$OUTPUT_FILE" | cut -f1)"

if [[ -n "$FFPROBE" ]]; then
    echo "    Specs: $("$FFPROBE" -v quiet -show_entries stream=codec_name,width,height,r_frame_rate,duration \
        -of compact=p=0 "$OUTPUT_FILE" 2>/dev/null || echo "(ffprobe unavailable)")"
fi

rm -f "$RAW_FILE"
echo ""
echo "Done! Upload to X (Twitter)."
