#!/usr/bin/env bash
# Foundation for autonomous UI-driven testing of the Vocello Debug build.
#
# A Codex session uses the computer-use MCP to drive Vocello like a
# person; this script provides the deterministic pieces that don't make
# sense to do via screenshots — launch, state reset, AXIdentifier lookup,
# log tailing, DB queries, artifact directory creation.
#
# usage: scripts/uitest.sh <command> [options]   (see `help`)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"

APP_NAME="Vocello"
DEBUG_APP_BUNDLE="$ROOT_DIR/build/Debug/$APP_NAME.app"
DEBUG_DATA_DIR="$HOME/Library/Application Support/QwenVoice-Debug"
HISTORY_DB="$DEBUG_DATA_DIR/history.sqlite"
CONTRACT_JSON="$ROOT_DIR/Sources/Resources/qwenvoice_contract.json"
BASELINES_JSON="$ROOT_DIR/docs/reference/benchmark-baselines.json"
BENCH_LOG_PREDICATE='subsystem == "com.qwenvoice.app"'

# shellcheck source=lib/build_cache.sh
. "$SCRIPT_DIR/lib/build_cache.sh"

usage() {
    cat <<EOF
usage: scripts/uitest.sh <command> [options]

commands:
  prep                  Launch the Debug build into a fresh window. Quits any running
                        Vocello first, errors out if the Debug build is not present.
                        Prints the PID.

  reset [--include-voices|--full]
                        Quit Vocello, then bring runtime state to a known baseline.
                        Default: clear the generations table from history.sqlite and
                          delete every file under outputs/<mode>/.
                        --include-voices also rm -rfs the voices/ subdirectory.
                        --full rm -rfs the entire persistent Debug data folder
                          (exceptional; forces model re-download on next launch).

  locate <ax-id>        Look up a SwiftUI accessibilityIdentifier in Vocello's front
                        window and print "cx cy w h" — center coordinates and size —
                        in macOS logical-points space. See docs/reference/ui-test-surface.md
                        for the screenshot-pixel scaling caveat. Exits non-zero if not found.

  screen-size           Print the screen's logical-point dimensions as "W H". Use with
                        the locate output to scale to your screenshot's image pixels.

  scaled-locate <ax-id> <image-w> <image-h>
                        Full-screen screenshot coordinate helper. Pre-scales
                        locate's logical-point output to a full-screen
                        screenshot's image-pixel space. Use only with tools
                        that return full-screen screenshots with known image
                        dimensions; Codex get_app_state returns a key-window
                        screenshot, so prefer window-locate there.

  window-locate <ax-id> [image-w image-h]
                        Codex key-window coordinate helper. Looks up an AX id,
                        subtracts Vocello's front-window origin, and prints
                        "cx cy w h" relative to the window. If image dimensions
                        are supplied from mcp__computer_use__.get_app_state,
                        the output is scaled into that screenshot's pixel space.

  bench-step <mode> <variant> <coldwarm> <bucket> --artifacts-dir <dir> [--timeout <s>]
                        One-shot wrapper for the per-sample loop. Reads the previous
                        T0 from /tmp/uitest_bench_t0, calls bench-wait, then bench-record,
                        then writes a fresh T0 back for the next sample. Removes the
                        skip-the-record footgun. Default --timeout is 90s for warm
                        and 180s for cold; pass explicitly to override.

  activate              Bring Vocello to the front. Use as a mid-test recovery step when
                        a system dialog or notification has stolen focus, or before a
                        click sequence to guarantee Vocello receives the input.

  logs [--predicate <p>]
                        Tail \`log stream --info --style compact\` for Vocello, defaulting
                        to predicate: subsystem == "com.qwenvoice.app".

  db <sql>              Run a read-only SELECT against history.sqlite and print CSV.

  artifacts-dir         Create build/Debug/uitest/<timestamp>/ and print its absolute path.

  smoke-check [<mode>]  Confirm prerequisites for generation. mode ∈ {custom, design,
                        clone}; defaults to custom. Custom/Design checks for installed
                        model variants; Clone additionally requires at least one saved
                        voice. Exit 0 if ready, 1 with a clear message otherwise.

  bench-wait [--since <ts>] [--timeout <sec>]
                        Block until a Final File Ready signpost appears after <ts>
                        (defaults: now; 90 s). Prints the matching event timestamp.

  bench-record <mode> <variant> <coldwarm> <bucket> --artifacts-dir <dir>
                        Append one sample's signpost timings + DB row + audio file
                        size to <dir>/bench-samples.jsonl. mode ∈ {custom, design,
                        clone}, variant ∈ {speed, quality}, coldwarm ∈ {cold, warm},
                        bucket ∈ {short, medium, long}.

  streaming-preview-check [--since <ts>] [--timeout <sec>] [--artifacts-dir <dir>]
                        Wait for Final File Ready, then assert the live preview
                        was healthy: Live Engine Play and Autoplay Start happened
                        before Final File Ready, no Live Preview Underrun / Chunk Gap
                        signposts fired, and the latest DB row points at a valid WAV.

  bench-summarize <artifacts-dir>
                        Group <dir>/bench-samples.jsonl by (mode, variant, coldwarm,
                        bucket), compute count/mean/median/p95/min/max/stdev per
                        metric, write <dir>/bench-result.json.

  bench-compare <artifacts-dir> [--baseline <path>]
                        Diff <dir>/bench-result.json against the committed baseline
                        (default docs/reference/benchmark-baselines.json). Emits a
                        Markdown table; exits 1 if any metric exceeds ±15 %.

  bench-update-baselines [--from <bench-result.json>]
                        Overwrite docs/reference/benchmark-baselines.json with the
                        summary from a bench-result.json (default: most recent under
                        build/Debug/uitest/). Review \`git diff\` before committing.

  verify-generation <mode> --artifacts-dir <dir> --since <ts> [--timeout <s>] [--text <text>]
                        Post-generate verification used by the smoke runbooks:
                        wait for Final File Ready, find the new WAV under the
                        mode's output subfolder (CustomVoice|VoiceDesign|Clones),
                        verify the latest history.sqlite row matches, and write
                        <dir>/result.json with the canonical pass/fail shape.
                        Default --timeout is 90 s for custom/design, 120 s for
                        clone. --text is optional and stored verbatim in the
                        result.json for cross-run comparison.

  help                  Show this message.
EOF
}

cmd_prep() {
    if [ ! -d "$DEBUG_APP_BUNDLE" ]; then
        echo "error: Debug build not found at $DEBUG_APP_BUNDLE" >&2
        echo "       run: scripts/build.sh debug" >&2
        exit 1
    fi
    quit_app_if_running
    /usr/bin/open -na "$DEBUG_APP_BUNDLE"
    local pid=""
    for _ in {1..40}; do
        pid="$(pgrep -x "$APP_NAME" | head -n 1)"
        if [ -n "$pid" ]; then
            break
        fi
        sleep 0.25
    done
    if [ -z "$pid" ]; then
        echo "error: $APP_NAME did not appear in the process list after launch" >&2
        exit 1
    fi
    # Give SwiftUI a beat to lay out the first window.
    sleep 1
    # Explicit activate guarantees Vocello is frontmost — useful when a system
    # notification or another app stole focus immediately after launch.
    /usr/bin/osascript -e 'tell application "Vocello" to activate' >/dev/null 2>&1 || true
    echo "$pid"
}

cmd_reset() {
    local mode="default"
    case "${1:-}" in
        "") ;;
        --include-voices) mode="include-voices" ;;
        --full)           mode="full" ;;
        *)
            echo "error: unknown reset option '$1'" >&2
            usage
            exit 2
            ;;
    esac

    quit_app_if_running

    if [ "$mode" = "full" ]; then
        if [ -d "$DEBUG_DATA_DIR" ]; then
            echo "==> Removing $DEBUG_DATA_DIR"
            rm -rf "$DEBUG_DATA_DIR"
        else
            echo "==> Nothing to remove ($DEBUG_DATA_DIR does not exist)"
        fi
        return 0
    fi

    if [ -f "$HISTORY_DB" ]; then
        echo "==> Clearing generations table in $HISTORY_DB"
        /usr/bin/sqlite3 "$HISTORY_DB" "DELETE FROM generations;" 2>/dev/null || \
            echo "warn: could not clear generations (table missing or db locked)" >&2
    fi

    local outputs_dir="$DEBUG_DATA_DIR/outputs"
    if [ -d "$outputs_dir" ]; then
        echo "==> Deleting files under $outputs_dir"
        /usr/bin/find "$outputs_dir" -type f -delete
    fi

    if [ "$mode" = "include-voices" ]; then
        local voices_dir="$DEBUG_DATA_DIR/voices"
        if [ -d "$voices_dir" ]; then
            echo "==> Removing $voices_dir"
            rm -rf "$voices_dir"
        fi
    fi
}

cmd_locate() {
    local ax_id="${1:-}"
    if [ -z "$ax_id" ]; then
        echo "error: locate requires an accessibility identifier" >&2
        echo "usage: scripts/uitest.sh locate <ax-id>" >&2
        exit 2
    fi

    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        echo "error: $APP_NAME is not running — run \`scripts/uitest.sh prep\` first" >&2
        exit 1
    fi

    /usr/bin/osascript - "$ax_id" <<'APPLESCRIPT'
on run argv
    set targetID to item 1 of argv
    tell application "System Events"
        tell process "Vocello"
            try
                set frontWin to front window
            on error
                error "no front window for Vocello" number 2
            end try
            set everything to entire contents of frontWin
            repeat with itm in everything
                try
                    if (value of attribute "AXIdentifier" of itm) is targetID then
                        set pos to position of itm
                        set sz to size of itm
                        set cx to (item 1 of pos) + ((item 1 of sz) div 2)
                        set cy to (item 2 of pos) + ((item 2 of sz) div 2)
                        return (cx as text) & " " & (cy as text) & " " & ((item 1 of sz) as text) & " " & ((item 2 of sz) as text)
                    end if
                end try
            end repeat
            error ("accessibility identifier not found: " & targetID) number 3
        end tell
    end tell
end run
APPLESCRIPT
}

cmd_logs() {
    local predicate='subsystem == "com.qwenvoice.app"'
    if [ "${1:-}" = "--predicate" ]; then
        if [ $# -lt 2 ]; then
            echo "error: --predicate requires a value" >&2
            exit 2
        fi
        predicate="$2"
    fi
    # --signpost is required to capture OSSignposter events. The app's key
    # generation milestones (Final File Ready, Autoplay Start, Preview To
    # First Chunk) are signposts under category "performance" — they do
    # NOT appear in a plain `log stream --info` stream.
    exec /usr/bin/log stream --info --signpost --style compact --predicate "$predicate"
}

cmd_db() {
    local sql="${1:-}"
    if [ -z "$sql" ]; then
        echo "error: db requires a SQL statement" >&2
        echo "usage: scripts/uitest.sh db \"SELECT ...\"" >&2
        exit 2
    fi
    if [ ! -f "$HISTORY_DB" ]; then
        echo "error: history.sqlite not found at $HISTORY_DB" >&2
        echo "       launch the app once to materialize the DB" >&2
        exit 1
    fi
    /usr/bin/sqlite3 -readonly -separator , "$HISTORY_DB" "$sql"
}

cmd_activate() {
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        echo "error: $APP_NAME is not running — run \`scripts/uitest.sh prep\` first" >&2
        exit 1
    fi
    /usr/bin/osascript -e 'tell application "Vocello" to activate' >/dev/null 2>&1
}

cmd_scaled_locate() {
    local ax_id="${1:-}"
    local image_w="${2:-}"
    local image_h="${3:-}"
    if [ -z "$ax_id" ] || [ -z "$image_w" ] || [ -z "$image_h" ]; then
        echo "error: scaled-locate requires <ax-id> <image-w> <image-h>" >&2
        echo "usage: scripts/uitest.sh scaled-locate <ax-id> <screenshot-width> <screenshot-height>" >&2
        echo "       <image-w/h> are the pixel dimensions of your full-screen screenshot" >&2
        exit 2
    fi
    local raw
    raw="$(cmd_locate "$ax_id")" || return $?
    local screen
    screen="$(cmd_screen_size)" || return $?
    SCALED_RAW="$raw" SCALED_SCREEN="$screen" \
        SCALED_W="$image_w" SCALED_H="$image_h" \
        /usr/bin/python3 -c '
import os, sys
raw = os.environ["SCALED_RAW"].split()
screen = os.environ["SCALED_SCREEN"].split()
if len(raw) != 4 or len(screen) != 2:
    print(f"error: bad locate/screen output: raw={raw} screen={screen}", file=sys.stderr)
    sys.exit(1)
cx, cy, w, h = (int(x) for x in raw)
sw, sh = (int(x) for x in screen)
iw = int(os.environ["SCALED_W"])
ih = int(os.environ["SCALED_H"])
sx = int(round(cx * iw / sw))
sy = int(round(cy * ih / sh))
sxw = int(round(w * iw / sw))
sxh = int(round(h * ih / sh))
print(f"{sx} {sy} {sxw} {sxh}")
'
}

cmd_window_locate() {
    local ax_id="${1:-}"
    local image_w="${2:-}"
    local image_h="${3:-}"
    if [ -z "$ax_id" ]; then
        echo "error: window-locate requires an accessibility identifier" >&2
        echo "usage: scripts/uitest.sh window-locate <ax-id> [screenshot-width screenshot-height]" >&2
        exit 2
    fi
    if { [ -n "$image_w" ] && [ -z "$image_h" ]; } || { [ -z "$image_w" ] && [ -n "$image_h" ]; }; then
        echo "error: window-locate image dimensions must be provided together" >&2
        echo "usage: scripts/uitest.sh window-locate <ax-id> [screenshot-width screenshot-height]" >&2
        exit 2
    fi

    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        echo "error: $APP_NAME is not running — run \`scripts/uitest.sh prep\` first" >&2
        exit 1
    fi

    local raw
    raw="$(/usr/bin/osascript - "$ax_id" <<'APPLESCRIPT'
on run argv
    set targetID to item 1 of argv
    tell application "System Events"
        tell process "Vocello"
            try
                set frontWin to front window
            on error
                error "no front window for Vocello" number 2
            end try
            set winPos to position of frontWin
            set winSize to size of frontWin
            set everything to entire contents of frontWin
            repeat with itm in everything
                try
                    if (value of attribute "AXIdentifier" of itm) is targetID then
                        set itemPos to position of itm
                        set itemSize to size of itm
                        set cx to ((item 1 of itemPos) + ((item 1 of itemSize) div 2)) - (item 1 of winPos)
                        set cy to ((item 2 of itemPos) + ((item 2 of itemSize) div 2)) - (item 2 of winPos)
                        return (cx as text) & " " & (cy as text) & " " & ((item 1 of itemSize) as text) & " " & ((item 2 of itemSize) as text) & " " & ((item 1 of winSize) as text) & " " & ((item 2 of winSize) as text)
                    end if
                end try
            end repeat
            error ("accessibility identifier not found: " & targetID) number 3
        end tell
    end tell
end run
APPLESCRIPT
)" || return $?

    if [ -z "$image_w" ] && [ -z "$image_h" ]; then
        /usr/bin/awk '{print $1, $2, $3, $4}' <<<"$raw"
        return 0
    fi

    WINDOW_LOCATE_RAW="$raw" WINDOW_LOCATE_W="$image_w" WINDOW_LOCATE_H="$image_h" \
        /usr/bin/python3 -c '
import os, sys
raw = os.environ["WINDOW_LOCATE_RAW"].split()
if len(raw) != 6:
    print(f"error: bad window-locate output: {raw}", file=sys.stderr)
    sys.exit(1)
cx, cy, w, h, ww, wh = (int(x) for x in raw)
iw = int(os.environ["WINDOW_LOCATE_W"])
ih = int(os.environ["WINDOW_LOCATE_H"])
sx = int(round(cx * iw / ww))
sy = int(round(cy * ih / wh))
sxw = int(round(w * iw / ww))
sxh = int(round(h * ih / wh))
print(f"{sx} {sy} {sxw} {sxh}")
'
}

T0_FILE="/tmp/uitest_bench_t0"

# Encapsulates the post-generate verification sequence that every smoke
# runbook used to inline: wait for Final File Ready → find the matching
# WAV under the mode's output subfolder → query history.sqlite for the
# matching row → write <art>/result.json with the canonical shape.
cmd_verify_generation() {
    local mode="" artifacts_dir="" since="" timeout="" text=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --artifacts-dir) artifacts_dir="$2"; shift 2 ;;
            --since)         since="$2"; shift 2 ;;
            --timeout)       timeout="$2"; shift 2 ;;
            --text)          text="$2"; shift 2 ;;
            custom|design|clone)
                [ -z "$mode" ] && mode="$1" || { echo "error: mode set twice" >&2; exit 2; }
                shift ;;
            *) echo "error: unknown arg '$1'" >&2; exit 2 ;;
        esac
    done
    [ -n "$mode" ] || { echo "error: verify-generation requires <mode>" >&2; exit 2; }
    [ -n "$artifacts_dir" ] || { echo "error: verify-generation requires --artifacts-dir" >&2; exit 2; }
    [ -n "$since" ] || { echo "error: verify-generation requires --since" >&2; exit 2; }
    [ -d "$artifacts_dir" ] || { echo "error: --artifacts-dir not a directory: $artifacts_dir" >&2; exit 2; }
    if [ -z "$timeout" ]; then
        case "$mode" in clone) timeout=120 ;; *) timeout=90 ;; esac
    fi

    # Mode → output subfolder. Source-of-truth: Sources/Models/TTSModel.swift
    # `outputSubfolder` accessor; these PascalCase values are stable.
    local subfolder
    case "$mode" in
        custom) subfolder="CustomVoice" ;;
        design) subfolder="VoiceDesign" ;;
        clone)  subfolder="Clones" ;;
    esac
    local outputs_dir="$DEBUG_DATA_DIR/outputs/$subfolder"

    # Step 1: wait for Final File Ready.
    local final_ts
    if ! final_ts="$(cmd_bench_wait --since "$since" --timeout "$timeout" 2>&1)"; then
        ARTIFACTS_DIR="$artifacts_dir" MODE="$mode" TEXT="$text" \
            SINCE="$since" REASON="$final_ts" \
            /usr/bin/python3 - <<'PY' || true
import json, os, pathlib, datetime as dt
out = {
    "pass": False,
    "mode": os.environ["MODE"],
    "reason": os.environ["REASON"].replace("error: ", "", 1),
    "since": os.environ["SINCE"],
    "text": os.environ.get("TEXT") or None,
    "timestamp": dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
}
pathlib.Path(os.environ["ARTIFACTS_DIR"], "result.json").write_text(json.dumps(out, indent=2) + "\n")
PY
        echo "FAIL: $final_ts" >&2
        return 1
    fi

    # Step 2: find the latest WAV in the mode's output subfolder created
    # after the artifact directory itself (which was created before the
    # generation kicked off).
    local audio_path
    audio_path="$(/usr/bin/find "$outputs_dir" -type f -name '*.wav' -newer "$artifacts_dir" 2>/dev/null | /usr/bin/sort -r | /usr/bin/head -1 || true)"

    # Step 3 + 4: verify DB row + write result.json + summarize. One Python
    # heredoc handles the rest since the JSON shape is non-trivial.
    ARTIFACTS_DIR="$artifacts_dir" MODE="$mode" SUBFOLDER="$subfolder" \
        AUDIO_PATH="$audio_path" FINAL_TS="$final_ts" \
        TEXT="$text" SINCE="$since" DB="$HISTORY_DB" \
        /usr/bin/python3 - <<'PY'
import json, os, pathlib, sqlite3, sys, datetime as dt

art = pathlib.Path(os.environ["ARTIFACTS_DIR"])
mode = os.environ["MODE"]
subfolder = os.environ["SUBFOLDER"]
audio_path = os.environ["AUDIO_PATH"] or None
final_ts = os.environ["FINAL_TS"]
text = os.environ.get("TEXT") or None
db = os.environ["DB"]

def write(out):
    (art / "result.json").write_text(json.dumps(out, indent=2) + "\n")

if not audio_path or not os.path.isfile(audio_path) or os.path.getsize(audio_path) == 0:
    write({
        "pass": False,
        "mode": mode,
        "reason": f"no new WAV under outputs/{subfolder}/ after the bench-wait",
        "final_file_ready_ts": final_ts,
        "text": text,
        "timestamp": dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    })
    print(f"FAIL: no new WAV under outputs/{subfolder}/", file=sys.stderr)
    sys.exit(1)

audio_bytes = os.path.getsize(audio_path)

con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
row = con.execute(
    "SELECT id, mode, audioPath, duration FROM generations "
    "ORDER BY createdAt DESC LIMIT 1"
).fetchone()
con.close()

if row is None:
    write({
        "pass": False,
        "mode": mode,
        "reason": "history.sqlite has no rows",
        "final_file_ready_ts": final_ts,
        "audio_path": audio_path,
        "audio_bytes": audio_bytes,
        "text": text,
        "timestamp": dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    })
    print("FAIL: history.sqlite has no rows", file=sys.stderr)
    sys.exit(1)

db_id, db_mode, db_audio_path, db_duration = row

if db_audio_path != audio_path:
    write({
        "pass": False,
        "mode": mode,
        "reason": f"latest DB row's audioPath does not match the new WAV (db={db_audio_path}, file={audio_path})",
        "final_file_ready_ts": final_ts,
        "audio_path": audio_path,
        "audio_bytes": audio_bytes,
        "db_id": db_id,
        "db_audio_path": db_audio_path,
        "text": text,
        "timestamp": dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    })
    print(f"FAIL: DB row points at {db_audio_path}, but file system has {audio_path}", file=sys.stderr)
    sys.exit(1)

if not db_duration or db_duration <= 0:
    write({
        "pass": False,
        "mode": mode,
        "reason": f"db_duration is null or non-positive ({db_duration})",
        "final_file_ready_ts": final_ts,
        "audio_path": audio_path,
        "audio_bytes": audio_bytes,
        "db_id": db_id,
        "db_duration": db_duration,
        "text": text,
        "timestamp": dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    })
    print(f"FAIL: db_duration={db_duration}", file=sys.stderr)
    sys.exit(1)

write({
    "pass": True,
    "mode": mode,
    "final_file_ready_ts": final_ts,
    "audio_path": audio_path,
    "audio_bytes": audio_bytes,
    "db_id": db_id,
    "db_mode": db_mode,
    "db_duration": db_duration,
    "text": text,
    "timestamp": dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
})
print(f"ok: {mode} pass=true final={final_ts} audio={audio_path} ({audio_bytes} B) db_id={db_id} db_duration={db_duration}")
PY
}

cmd_bench_step() {
    local mode="" variant="" coldwarm="" bucket="" artifacts_dir="" timeout=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --artifacts-dir) artifacts_dir="$2"; shift 2 ;;
            --timeout)       timeout="$2"; shift 2 ;;
            custom|design|clone) [ -z "$mode" ] && mode="$1" || { echo "error: mode set twice" >&2; exit 2; }; shift ;;
            speed|quality)       [ -z "$variant" ] && variant="$1" || { echo "error: variant set twice" >&2; exit 2; }; shift ;;
            cold|warm)           [ -z "$coldwarm" ] && coldwarm="$1" || { echo "error: cold/warm set twice" >&2; exit 2; }; shift ;;
            short|medium|long)   [ -z "$bucket" ] && bucket="$1" || { echo "error: bucket set twice" >&2; exit 2; }; shift ;;
            *) echo "error: unknown arg '$1'" >&2; exit 2 ;;
        esac
    done
    [ -n "$mode" ] && [ -n "$variant" ] && [ -n "$coldwarm" ] && [ -n "$bucket" ] && [ -n "$artifacts_dir" ] || {
        echo "error: bench-step requires <mode> <variant> <coldwarm> <bucket> --artifacts-dir <dir>" >&2
        exit 2
    }
    if [ -z "$timeout" ]; then
        if [ "$coldwarm" = "cold" ]; then timeout=180; else timeout=90; fi
    fi
    if [ ! -f "$T0_FILE" ]; then
        echo "error: $T0_FILE missing — capture an initial T0 before the first bench-step (e.g. python3 -c 'import datetime...' > $T0_FILE)" >&2
        exit 1
    fi
    local t0
    t0="$(cat "$T0_FILE")"
    /usr/bin/python3 -c "
import datetime as dt, sys
try:
    dt.datetime.strptime(sys.argv[1], '%Y-%m-%d %H:%M:%S.%f')
except Exception as e:
    sys.exit(f'invalid T0 in $T0_FILE: {e}')
" "$t0" || exit 1
    scripts/uitest.sh bench-wait --since "$t0" --timeout "$timeout" >/dev/null
    scripts/uitest.sh bench-record "$mode" "$variant" "$coldwarm" "$bucket" --artifacts-dir "$artifacts_dir" >/dev/null
    /usr/bin/python3 -c "import datetime as dt; d=dt.datetime.now(); print(d.strftime('%Y-%m-%d %H:%M:%S.')+d.strftime('%f')[:3])" > "$T0_FILE"
    echo "ok: ${mode}/${variant}/${coldwarm}/${bucket} (next T0=$(cat "$T0_FILE"))"
}

cmd_screen_size() {
    # Use osascript with "Finder window of desktop" — its bounds equal the
    # screen's logical-points rect. Print "<width> <height>".
    /usr/bin/osascript -e 'tell application "Finder" to set b to bounds of window of desktop
return ((item 3 of b) - (item 1 of b)) & " " & ((item 4 of b) - (item 2 of b))' 2>/dev/null \
        | /usr/bin/tr ',' ' ' \
        | /usr/bin/awk '{print $1, $2}'
}

cmd_artifacts_dir() {
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local dir="$ROOT_DIR/build/Debug/uitest/$ts"
    mkdir -p "$dir"
    echo "$dir"
}

cmd_smoke_check() {
    local mode="${1:-custom}"
    case "$mode" in
        custom|design|clone) ;;
        *) echo "error: unknown mode '$mode' (expected custom|design|clone)" >&2; exit 2 ;;
    esac

    if [ ! -f "$CONTRACT_JSON" ]; then
        echo "error: contract not found at $CONTRACT_JSON" >&2
        exit 1
    fi
    if [ ! -d "$DEBUG_DATA_DIR/models" ]; then
        echo "smoke-check FAIL: no models directory at $DEBUG_DATA_DIR/models" >&2
        echo "                 launch the app and install models in Settings." >&2
        exit 1
    fi

    local installed
    installed="$(/usr/bin/python3 - "$CONTRACT_JSON" "$DEBUG_DATA_DIR/models" "$mode" <<'PY'
import json
import sys
from pathlib import Path

contract = json.loads(Path(sys.argv[1]).read_text())
models_dir = Path(sys.argv[2])
mode = sys.argv[3]

model = next((m for m in contract["models"] if m.get("mode") == mode), None)
if model is None:
    print("CONTRACT_MISSING")
    sys.exit(0)

candidates = []
base_folder = model.get("folder")
if base_folder:
    candidates.append((base_folder, "base"))
for variant in model.get("variants", []):
    folder = variant.get("folder")
    if folder:
        candidates.append((folder, variant.get("id", "variant")))

found = []
for folder, label in candidates:
    safetensors = models_dir / folder / "model.safetensors"
    if safetensors.is_file() and safetensors.stat().st_size > 0:
        found.append(label)

if not found:
    print("NONE_INSTALLED")
else:
    print(",".join(found))
PY
)"

    case "$installed" in
        "")
            echo "smoke-check FAIL: contract inspection failed" >&2
            exit 1
            ;;
        CONTRACT_MISSING)
            echo "smoke-check FAIL: no model with mode='$mode' in $CONTRACT_JSON" >&2
            exit 1
            ;;
        NONE_INSTALLED)
            echo "smoke-check FAIL: no $mode model variant is installed under $DEBUG_DATA_DIR/models" >&2
            echo "                 launch the app and install at least one in Settings -> Model Downloads." >&2
            exit 1
            ;;
        *)
            echo "smoke-check OK: $mode variant(s) installed: $installed"
            ;;
    esac

    # Voice Cloning requires the UITestRef saved-voice fixture
    # (filesystem-canonical; saved voices are not persisted in SQLite).
    if [ "$mode" = "clone" ]; then
        local fixture="$DEBUG_DATA_DIR/voices/UITestRef.wav"
        if [ -f "$fixture" ]; then
            echo "smoke-check OK: clone fixture present at $fixture"
        else
            local voices_dir_count
            voices_dir_count="$(/usr/bin/find "$DEBUG_DATA_DIR/voices" -mindepth 1 -maxdepth 1 -type f -name '*.wav' 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
            echo "smoke-check FAIL: clone mode requires the UITestRef fixture." >&2
            echo "                 Expected: $fixture" >&2
            echo "                 Found ${voices_dir_count:-0} other saved-voice .wav(s) in $DEBUG_DATA_DIR/voices/" >&2
            echo "                 Run the bootstrap: see docs/reference/bootstrap-saved-voice.md" >&2
            exit 1
        fi
    fi
}

cmd_bench_wait() {
    local since=""
    local timeout=90
    while [ $# -gt 0 ]; do
        case "$1" in
            --since)   since="$2"; shift 2 ;;
            --timeout) timeout="$2"; shift 2 ;;
            *) echo "error: unknown arg '$1'" >&2; exit 2 ;;
        esac
    done
    if [ -z "$since" ]; then
        since="$(date +"%Y-%m-%d %H:%M:%S.%3N")"
    fi
    local deadline=$(($(date +%s) + timeout))
    local log_show_failed=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local found log_buf
        # Per-iteration log show; keep stderr silenced so the polling
        # loop doesn't spam, but track whether log show ever produced
        # output so a true `log show` outage shows up in the timeout
        # diagnostic below instead of being misattributed to "no
        # Final File Ready event."
        log_buf="$(/usr/bin/log show --signpost --predicate "$BENCH_LOG_PREDICATE" --last 3m --style compact 2>/dev/null)"
        if [ -z "$log_buf" ]; then
            log_show_failed=1
        fi
        found="$(printf '%s' "$log_buf" | SINCE="$since" /usr/bin/python3 -c '
import os, re, sys
since = os.environ["SINCE"]
last = None
for line in sys.stdin:
    if "Final File Ready" not in line:
        continue
    m = re.match(r"(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}\.\d+)", line)
    if not m:
        continue
    ts = f"{m.group(1)} {m.group(2)}"
    if ts > since:
        last = ts
if last is not None:
    print(last)
    sys.exit(0)
sys.exit(1)
' 2>/dev/null || true)"
        if [ -n "$found" ]; then
            echo "$found"
            return 0
        fi
        sleep 0.5
    done
    if [ "$log_show_failed" = "1" ]; then
        echo "error: timeout after ${timeout}s waiting for Final File Ready since $since (note: \`log show --signpost --predicate $BENCH_LOG_PREDICATE\` produced no output during the polling window — check log show permissions or that signposts are being emitted by Vocello)" >&2
    else
        echo "error: timeout after ${timeout}s waiting for Final File Ready since $since" >&2
    fi
    return 1
}

cmd_streaming_preview_check() {
    local since=""
    local timeout=90
    local artifacts_dir=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --since) since="$2"; shift 2 ;;
            --timeout) timeout="$2"; shift 2 ;;
            --artifacts-dir) artifacts_dir="$2"; shift 2 ;;
            *) echo "error: unknown arg '$1'" >&2; exit 2 ;;
        esac
    done
    if [ -z "$since" ]; then
        since="$(date +"%Y-%m-%d %H:%M:%S.%3N")"
    fi
    if [ -n "$artifacts_dir" ] && [ ! -d "$artifacts_dir" ]; then
        echo "error: artifacts dir not found: $artifacts_dir" >&2
        exit 1
    fi

    local final_ts
    final_ts="$(cmd_bench_wait --since "$since" --timeout "$timeout")" || return $?

    local log_buf log_show_stderr
    log_show_stderr="$(mktemp -t streaming-preview-logshow)"
    if ! log_buf="$(/usr/bin/log show --signpost --predicate "$BENCH_LOG_PREDICATE" --last 5m --style compact 2>"$log_show_stderr")"; then
        echo "error: \`log show --signpost --predicate $BENCH_LOG_PREDICATE\` failed" >&2
        if [ -s "$log_show_stderr" ]; then
            sed 's/^/error:   /' "$log_show_stderr" >&2
        fi
        rm -f "$log_show_stderr"
        return 1
    fi
    rm -f "$log_show_stderr"

    local db_row=""
    for _ in 1 2 3 4 5 6 7 8; do
        db_row="$(/usr/bin/sqlite3 -readonly -separator $'\t' "$HISTORY_DB" \
            "SELECT id, audioPath, duration FROM generations ORDER BY createdAt DESC LIMIT 1" 2>/dev/null || true)"
        [ -n "$db_row" ] && break
        sleep 0.25
    done

    SINCE="$since" FINAL_TS="$final_ts" LOG_BUF="$log_buf" DB_ROW="$db_row" \
        ARTIFACTS_DIR="$artifacts_dir" /usr/bin/python3 - <<'PY'
import datetime as dt
import json
import os
import re
import sys
import wave
from pathlib import Path

since = os.environ["SINCE"]
final_ts = os.environ["FINAL_TS"]
lines = os.environ.get("LOG_BUF", "").splitlines()
db_row = os.environ.get("DB_ROW", "")
artifacts_dir = os.environ.get("ARTIFACTS_DIR", "")

TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}\.\d+)")

def parse_ts(line):
    m = TS_RE.match(line)
    if not m:
        return None
    return f"{m.group(1)} {m.group(2)}"

window = []
for line in lines:
    ts = parse_ts(line)
    if ts is None:
        continue
    if since < ts <= final_ts:
        window.append((ts, line))

def hits(name):
    return [(ts, line) for ts, line in window if name in line]

chunk_received = hits("Chunk Received")
chunk_decoded = hits("Chunk Decoded")
live_session_start = hits("Live Session Start")
live_engine_play = hits("Live Engine Play")
autoplay_start = hits("Autoplay Start")
switch_to_file = hits("Switch To File Playback")
underrun = hits("Live Preview Underrun")
chunk_gap = hits("Live Preview Chunk Gap")

db_id = None
audio_path = None
db_duration_s = None
audio_bytes = None
wav_duration_s = None
if db_row:
    parts = db_row.split("\t")
    if len(parts) >= 3:
        db_id = parts[0]
        audio_path = parts[1]
        try:
            db_duration_s = float(parts[2])
        except ValueError:
            db_duration_s = None
        if audio_path and os.path.isfile(audio_path):
            audio_bytes = os.path.getsize(audio_path)
            try:
                with wave.open(audio_path, "rb") as wav:
                    frames = wav.getnframes()
                    rate = wav.getframerate()
                    if rate > 0:
                        wav_duration_s = frames / float(rate)
            except Exception:
                wav_duration_s = None

checks = {
    "chunk_received": len(chunk_received) > 0,
    "chunk_decoded": len(chunk_decoded) > 0,
    "single_live_session_start": len(live_session_start) == 1,
    "live_engine_play_before_final": len(live_engine_play) > 0,
    "autoplay_start_before_final": len(autoplay_start) > 0,
    "no_live_preview_underrun": len(underrun) == 0,
    "no_live_preview_chunk_gap": len(chunk_gap) == 0,
    "final_wav_exists": bool(audio_path and audio_bytes and audio_bytes > 44),
    "final_wav_has_duration": bool((db_duration_s and db_duration_s > 0) or (wav_duration_s and wav_duration_s > 0)),
    "db_row_landed": db_id is not None,
}

failures = [name for name, passed in checks.items() if not passed]
result = {
    "pass": not failures,
    "failures": failures,
    "since": since,
    "final_ts": final_ts,
    "counts": {
        "chunk_received": len(chunk_received),
        "chunk_decoded": len(chunk_decoded),
        "live_session_start": len(live_session_start),
        "live_engine_play": len(live_engine_play),
        "autoplay_start": len(autoplay_start),
        "switch_to_file_playback": len(switch_to_file),
        "live_preview_underrun": len(underrun),
        "live_preview_chunk_gap": len(chunk_gap),
    },
    "db_id": db_id,
    "audio_path": audio_path,
    "audio_bytes": audio_bytes,
    "db_duration_s": db_duration_s,
    "wav_duration_s": wav_duration_s,
    "timestamp_utc": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}

if artifacts_dir:
    out = Path(artifacts_dir) / "streaming-preview-checks.jsonl"
    with out.open("a") as f:
        f.write(json.dumps(result) + "\n")

print(json.dumps(result, indent=2))
sys.exit(0 if result["pass"] else 1)
PY
}

cmd_bench_record() {
    local mode="" variant="" coldwarm="" bucket="" artifacts_dir=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --artifacts-dir) artifacts_dir="$2"; shift 2 ;;
            custom|design|clone)
                if [ -z "$mode" ]; then mode="$1"; else echo "error: mode set twice" >&2; exit 2; fi; shift ;;
            speed|quality)
                if [ -z "$variant" ]; then variant="$1"; else echo "error: variant set twice" >&2; exit 2; fi; shift ;;
            cold|warm)
                if [ -z "$coldwarm" ]; then coldwarm="$1"; else echo "error: cold/warm set twice" >&2; exit 2; fi; shift ;;
            short|medium|long)
                if [ -z "$bucket" ]; then bucket="$1"; else echo "error: bucket set twice" >&2; exit 2; fi; shift ;;
            *) echo "error: unknown arg '$1'" >&2; exit 2 ;;
        esac
    done
    [ -n "$mode" ] || { echo "error: mode required (custom|design|clone)" >&2; exit 2; }
    [ -n "$variant" ] || { echo "error: variant required (speed|quality)" >&2; exit 2; }
    [ -n "$coldwarm" ] || { echo "error: cold|warm required" >&2; exit 2; }
    [ -n "$bucket" ] || { echo "error: bucket required (short|medium|long)" >&2; exit 2; }
    [ -n "$artifacts_dir" ] || { echo "error: --artifacts-dir required" >&2; exit 2; }
    [ -d "$artifacts_dir" ] || { echo "error: artifacts dir not found: $artifacts_dir" >&2; exit 1; }

    # Single-shot signpost capture for this sample. If `log show` itself
    # fails (permission revocation, system update, signpost subsystem
    # disabled) the downstream parser will report "no Final File Ready"
    # — surface the underlying cause here so the operator can disambiguate.
    local log_buf log_show_stderr
    log_show_stderr="$(mktemp -t bench-record-logshow)"
    if ! log_buf="$(/usr/bin/log show --signpost --predicate "$BENCH_LOG_PREDICATE" --last 3m --style compact 2>"$log_show_stderr")"; then
        echo "warn: \`log show --signpost --predicate $BENCH_LOG_PREDICATE\` failed; signpost-derived timings will be missing from this sample" >&2
        if [ -s "$log_show_stderr" ]; then
            sed 's/^/warn:   /' "$log_show_stderr" >&2
        fi
        log_buf=""
    fi
    rm -f "$log_show_stderr"

    # Wait up to 2 s for the DB row to land (saveGenerationAsync is detached).
    local db_row=""
    local sqlite_failed=0
    for _ in 1 2 3 4 5 6 7 8; do
        if ! db_row="$(/usr/bin/sqlite3 -readonly -separator $'\t' "$HISTORY_DB" \
            "SELECT id, audioPath, duration FROM generations ORDER BY createdAt DESC LIMIT 1" 2>/dev/null)"; then
            sqlite_failed=1
            db_row=""
        fi
        [ -n "$db_row" ] && break
        sleep 0.25
    done
    if [ -z "$db_row" ] && [ "$sqlite_failed" = "1" ]; then
        echo "warn: sqlite3 query against $HISTORY_DB failed across 8 retries (db locked or missing) — db-derived fields will be missing from this sample" >&2
    fi

    # RSS at this moment (single-point sample at FFR). The model lives in
    # the XPC engine service, not the main Vocello process, so we sum
    # both. Captures the real footprint of an active generation pipeline.
    local rss_kb_app rss_kb_xpc rss_kb_total=""
    local vocello_pid xpc_pid
    vocello_pid="$(pgrep -x "$APP_NAME" | head -n 1)"
    xpc_pid="$(pgrep -fx '.*QwenVoiceEngineService\.xpc/Contents/MacOS/QwenVoiceEngineService' | head -n 1)"
    if [ -n "$vocello_pid" ]; then
        rss_kb_app="$(/bin/ps -o rss= -p "$vocello_pid" 2>/dev/null | /usr/bin/tr -d ' ')"
    fi
    if [ -n "$xpc_pid" ]; then
        rss_kb_xpc="$(/bin/ps -o rss= -p "$xpc_pid" 2>/dev/null | /usr/bin/tr -d ' ')"
    fi
    if [ -n "$rss_kb_app" ] || [ -n "$rss_kb_xpc" ]; then
        rss_kb_total=$(( ${rss_kb_app:-0} + ${rss_kb_xpc:-0} ))
    fi

    MODE="$mode" VARIANT="$variant" COLDWARM="$coldwarm" BUCKET="$bucket" \
        ARTIFACTS_DIR="$artifacts_dir" DB_ROW="$db_row" LOG_BUF="$log_buf" \
        RSS_KB="$rss_kb_total" RSS_KB_APP="${rss_kb_app:-0}" RSS_KB_XPC="${rss_kb_xpc:-0}" \
        /usr/bin/python3 - <<'PY'
import json
import os
import re
import sys
import datetime as dt
from pathlib import Path

mode = os.environ["MODE"]
variant = os.environ["VARIANT"]
coldwarm = os.environ["COLDWARM"]
bucket = os.environ["BUCKET"]
artifacts_dir = Path(os.environ["ARTIFACTS_DIR"])
db_row = os.environ.get("DB_ROW", "")
log_buf = os.environ.get("LOG_BUF", "")

TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}\.\d+)")

def parse_ts(line):
    m = TS_RE.match(line)
    if not m:
        return None
    return f"{m.group(1)} {m.group(2)}"

def to_dt(ts):
    return dt.datetime.strptime(ts, "%Y-%m-%d %H:%M:%S.%f")

lines = log_buf.splitlines()
final_ts = None
autoplay_ts = None
first_chunk_ts = None
engine_begin_ts = None
clone_metrics = {}

# Final File Ready: take the latest occurrence.
for line in reversed(lines):
    if "Final File Ready" in line:
        final_ts = parse_ts(line)
        if final_ts:
            break

if final_ts is None:
    print("error: no Final File Ready event in recent signpost log", file=sys.stderr)
    sys.exit(1)

# Walk backward from Final File Ready to find anchors that came before it.
final_idx = None
for i in range(len(lines) - 1, -1, -1):
    if "Final File Ready" in lines[i]:
        final_idx = i
        break

CLONE_METRIC_RE = re.compile(r"\b(clone_[a-z0-9_]+|prime_clone_reference_ms)=([^\s,]+)")
for i in range(final_idx - 1, -1, -1):
    line = lines[i]
    if "Final File Ready" in line:
        break
    if "Clone Prompt Metrics" not in line:
        continue
    clone_metrics = {
        key: value.strip()
        for key, value in CLONE_METRIC_RE.findall(line)
    }
    break

def clone_bool(key):
    value = clone_metrics.get(key)
    if value is None:
        return None
    return value.lower() == "true"

def clone_int(key):
    value = clone_metrics.get(key)
    if value is None:
        return None
    try:
        return int(value)
    except ValueError:
        return None

def clone_str(key):
    value = clone_metrics.get(key)
    return value if value not in (None, "") else None

for i in range(final_idx - 1, -1, -1):
    line = lines[i]
    ts = parse_ts(line)
    if ts is None:
        continue
    if first_chunk_ts is None and "Preview To First Chunk" in line:
        first_chunk_ts = ts
    # The XPC begin event we want is the most recent `[..., begin] XPC Engine Command`
    # before Final File Ready that's NOT inside an event arrow.
    if engine_begin_ts is None and "begin] XPC Engine Command" in line:
        engine_begin_ts = ts
    if engine_begin_ts and first_chunk_ts:
        break

# Autoplay Start. Non-streaming generation fires it AFTER Final File
# Ready (playFile path in GenerationPersistence.swift). Streaming fires
# it BEFORE Final File Ready (live engine plays the first chunk as soon
# as it arrives, then generation continues). Search both directions and
# take the one matching the current generation — defined as the closest
# Autoplay Start to engine_begin_ts on either side of final_idx.
autoplay_candidates = []
for i in range(final_idx + 1, len(lines)):
    if "Autoplay Start" in lines[i]:
        ts = parse_ts(lines[i])
        if ts:
            autoplay_candidates.append(ts)
            break  # first one after final is the right one for the non-streaming case
for i in range(final_idx - 1, -1, -1):
    if "Autoplay Start" in lines[i]:
        ts = parse_ts(lines[i])
        if ts:
            # Only accept if it's after engine_begin (else it's a prior generation's autoplay).
            if engine_begin_ts is None or to_dt(ts) >= to_dt(engine_begin_ts):
                autoplay_candidates.append(ts)
            break  # most recent before final is the right one for streaming
if autoplay_candidates:
    # Pick the candidate closest to engine_begin_ts (or just earliest if no engine_begin).
    if engine_begin_ts:
        eb = to_dt(engine_begin_ts)
        autoplay_ts = min(autoplay_candidates, key=lambda t: abs((to_dt(t) - eb).total_seconds()))
    else:
        autoplay_ts = min(autoplay_candidates, key=to_dt)

def ms_between(a, b):
    if a is None or b is None:
        return None
    return int((to_dt(b) - to_dt(a)).total_seconds() * 1000)

if engine_begin_ts is None:
    print("warn: no XPC Engine Command begin found before Final File Ready", file=sys.stderr)

ms_engine_to_first  = ms_between(engine_begin_ts, first_chunk_ts)
ms_engine_to_final  = ms_between(engine_begin_ts, final_ts)
ms_engine_to_play   = ms_between(engine_begin_ts, autoplay_ts)

db_id = None
audio_path = None
audio_duration_s = None
audio_bytes = None
rtf = None
audio_rms_dbfs = None
audio_peak_dbfs = None
if db_row:
    parts = db_row.split("\t")
    if len(parts) >= 3:
        db_id = parts[0]
        audio_path = parts[1]
        try:
            audio_duration_s = float(parts[2])
        except ValueError:
            audio_duration_s = None
        if audio_path and os.path.isfile(audio_path):
            audio_bytes = os.path.getsize(audio_path)
        if audio_duration_s and ms_engine_to_final:
            rtf = round(audio_duration_s / (ms_engine_to_final / 1000.0), 4)

# Audio quality metrics — RMS + peak in dBFS, computed from the WAV
# directly. Uses stdlib only (wave + audioop). Vocello writes 16-bit
# mono PCM at 24 kHz per the Qwen3-TTS contract.
if audio_path and os.path.isfile(audio_path):
    try:
        import math
        import wave
        import audioop
        with wave.open(audio_path, "rb") as w:
            sampwidth = w.getsampwidth()
            n = w.getnframes()
            frames = w.readframes(n)
        if frames and sampwidth in (1, 2, 3, 4):
            full_scale = float(1 << (8 * sampwidth - 1))
            rms_raw = audioop.rms(frames, sampwidth)
            peak_raw = audioop.max(frames, sampwidth)
            if rms_raw > 0:
                audio_rms_dbfs = round(20.0 * math.log10(rms_raw / full_scale), 3)
            if peak_raw > 0:
                audio_peak_dbfs = round(20.0 * math.log10(peak_raw / full_scale), 3)
    except Exception as e:
        # Don't fail the sample on audio analysis trouble.
        print(f"warn: audio analysis skipped: {e}", file=sys.stderr)

peak_rss_mb = None
peak_rss_mb_app = None
peak_rss_mb_xpc = None
def _kb_to_mb(env_key):
    v = os.environ.get(env_key, "")
    if v.isdigit() and int(v) > 0:
        return round(int(v) / 1024.0, 1)
    return None
peak_rss_mb = _kb_to_mb("RSS_KB")
peak_rss_mb_app = _kb_to_mb("RSS_KB_APP")
peak_rss_mb_xpc = _kb_to_mb("RSS_KB_XPC")

sample = {
    "mode": mode,
    "variant": variant,
    "cold_or_warm": coldwarm,
    "bucket": bucket,
    "ms_engine_start_to_first_chunk": ms_engine_to_first,
    "ms_engine_start_to_final": ms_engine_to_final,
    "ms_engine_start_to_autoplay": ms_engine_to_play,
    "audio_rms_dbfs": audio_rms_dbfs,
    "audio_peak_dbfs": audio_peak_dbfs,
    "clone_prompt_artifact_hit": clone_bool("clone_prompt_artifact_hit"),
    "clone_prompt_memory_hit": clone_bool("clone_prompt_memory_hit"),
    "clone_prompt_built": clone_bool("clone_prompt_built"),
    "clone_transcript_backed": clone_bool("clone_transcript_backed"),
    "clone_reference_was_primed": clone_bool("clone_reference_was_primed"),
    "clone_conditioning_reused": clone_bool("clone_conditioning_reused"),
    "clone_transcript_mode": clone_str("clone_transcript_mode"),
    "clone_prompt_artifact_scope": clone_str("clone_prompt_artifact_scope"),
    "clone_prompt_artifact_load_ms": clone_int("clone_prompt_artifact_load_ms"),
    "clone_prompt_build_ms": clone_int("clone_prompt_build_ms"),
    "clone_prompt_resolve_ms": clone_int("clone_prompt_resolve_ms"),
    "prime_clone_reference_ms": clone_int("prime_clone_reference_ms"),
    "peak_rss_mb": peak_rss_mb,
    "peak_rss_mb_app": peak_rss_mb_app,
    "peak_rss_mb_xpc": peak_rss_mb_xpc,
    "audio_path": audio_path,
    "audio_bytes": audio_bytes,
    "audio_duration_s": audio_duration_s,
    "rtf": rtf,
    "db_id": db_id,
    "signpost_anchors": {
        "engine_begin_ts": engine_begin_ts,
        "first_chunk_ts": first_chunk_ts,
        "final_ts": final_ts,
        "autoplay_ts": autoplay_ts,
    },
    "timestamp_utc": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}

samples_path = artifacts_dir / "bench-samples.jsonl"
with samples_path.open("a") as f:
    f.write(json.dumps(sample) + "\n")
print(json.dumps(sample))
PY
}

cmd_bench_summarize() {
    local artifacts_dir="${1:-}"
    [ -n "$artifacts_dir" ] || { echo "error: artifacts dir required" >&2; exit 2; }
    [ -d "$artifacts_dir" ] || { echo "error: artifacts dir not found: $artifacts_dir" >&2; exit 1; }

    ARTIFACTS_DIR="$artifacts_dir" /usr/bin/python3 - <<'PY'
import json
import os
import statistics as stats
import datetime as dt
from pathlib import Path

artifacts_dir = Path(os.environ["ARTIFACTS_DIR"])
samples_path = artifacts_dir / "bench-samples.jsonl"
result_path = artifacts_dir / "bench-result.json"

METRICS = [
    # ms_engine_start_to_first_chunk intentionally dropped — its
    # underlying `Preview To First Chunk` signpost only fires on the
    # live-streaming preview path (AudioPlayerViewModel.completeStreamingPreview),
    # which the macOS app's default generation path doesn't currently take.
    # The first_chunk_ts anchor is still captured per-sample for forensics.
    "ms_engine_start_to_final",
    "ms_engine_start_to_autoplay",
    "audio_duration_s",
    "rtf",
    # Audio quality (informational; not auto-flagged by bench-compare)
    "audio_rms_dbfs",
    "audio_peak_dbfs",
    # Clone-prompt reuse forensics (informational; not auto-flagged)
    "clone_prompt_artifact_load_ms",
    "clone_prompt_build_ms",
    "clone_prompt_resolve_ms",
    "prime_clone_reference_ms",
    # Memory (informational; not auto-flagged)
    "peak_rss_mb",
]

def stat_block(values):
    values = [v for v in values if v is not None]
    if not values:
        return {"n": 0, "mean": None, "median": None, "p95": None, "min": None, "max": None, "stdev": None}
    n = len(values)
    s_mean = stats.mean(values)
    s_median = stats.median(values)
    s_min = min(values)
    s_max = max(values)
    s_stdev = stats.stdev(values) if n >= 2 else 0.0
    if n == 1:
        s_p95 = values[0]
    else:
        sv = sorted(values)
        idx = max(0, min(n - 1, int(round(0.95 * (n - 1)))))
        s_p95 = sv[idx]
    return {
        "n": n,
        "mean": round(s_mean, 4),
        "median": round(s_median, 4),
        "p95": round(s_p95, 4),
        "min": round(s_min, 4),
        "max": round(s_max, 4),
        "stdev": round(s_stdev, 4),
    }

results = {}
samples = []
if samples_path.exists():
    for line in samples_path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        samples.append(json.loads(line))

for s in samples:
    mo = s.get("mode") or "custom"   # back-compat with element-2 sample files
    v = s["variant"]; cw = s["cold_or_warm"]; b = s["bucket"]
    results.setdefault(mo, {}).setdefault(v, {}).setdefault(cw, {}).setdefault(b, {})
    bucket_node = results[mo][v][cw][b]
    bucket_node.setdefault("_raw", []).append({m: s.get(m) for m in METRICS})

for mo in results:
    for v in results[mo]:
        for cw in results[mo][v]:
            for b in results[mo][v][cw]:
                raw = results[mo][v][cw][b].pop("_raw")
                summary = {}
                for m in METRICS:
                    summary[m] = stat_block([row[m] for row in raw])
                results[mo][v][cw][b] = summary

out = {
    "schema_version": 3,
    "generated_at_utc": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "sample_count": len(samples),
    "results": results,
}
result_path.write_text(json.dumps(out, indent=2) + "\n")
print(str(result_path))
PY
}

cmd_bench_compare() {
    local artifacts_dir=""
    local baseline_path="$BASELINES_JSON"
    while [ $# -gt 0 ]; do
        case "$1" in
            --baseline) baseline_path="$2"; shift 2 ;;
            *) if [ -z "$artifacts_dir" ]; then artifacts_dir="$1"; shift; else echo "error: unknown arg '$1'" >&2; exit 2; fi ;;
        esac
    done
    [ -n "$artifacts_dir" ] || { echo "error: artifacts dir required" >&2; exit 2; }
    [ -d "$artifacts_dir" ] || { echo "error: artifacts dir not found: $artifacts_dir" >&2; exit 1; }

    ARTIFACTS_DIR="$artifacts_dir" BASELINE_PATH="$baseline_path" /usr/bin/python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

THRESHOLD_PCT = 15.0
PRIMARY_METRICS = ["ms_engine_start_to_final", "rtf"]

art = Path(os.environ["ARTIFACTS_DIR"])
result_path = art / "bench-result.json"
baseline_path = Path(os.environ["BASELINE_PATH"])

if not result_path.exists():
    print(f"error: bench-result.json not found at {result_path}", file=sys.stderr)
    sys.exit(2)
current = json.loads(result_path.read_text())

if not baseline_path.exists():
    print(f"no baseline file at {baseline_path}")
    print("run `scripts/uitest.sh bench-update-baselines` to seed it.")
    sys.exit(0)

baseline = json.loads(baseline_path.read_text())
base_results = baseline.get("results") or {}
cur_results = current.get("results") or {}

if not base_results:
    print("baseline file has empty results — first run, nothing to compare yet.")
    print("run `scripts/uitest.sh bench-update-baselines` to seed it.")
    sys.exit(0)

breaches = 0
rows = []
rows.append(("Mode", "Variant", "Phase", "Bucket", "Metric", "Baseline mean", "Current mean", "Δ %", "Flag"))

for mo in sorted(cur_results):
    for v in sorted(cur_results[mo]):
        for cw in sorted(cur_results[mo][v]):
            for b in sorted(cur_results[mo][v][cw]):
                for m in PRIMARY_METRICS:
                    cur_node = cur_results[mo][v][cw][b].get(m) or {}
                    base_node = ((((base_results.get(mo) or {}).get(v) or {}).get(cw) or {}).get(b) or {}).get(m) or {}
                    cur_mean = cur_node.get("mean")
                    base_mean = base_node.get("mean")
                    if cur_mean is None or base_mean is None or base_mean == 0:
                        rows.append((mo, v, cw, b, m, str(base_mean), str(cur_mean), "—", "—"))
                        continue
                    pct = (cur_mean - base_mean) / base_mean * 100.0
                    flag = "⚠" if abs(pct) > THRESHOLD_PCT else ""
                    if flag:
                        breaches += 1
                    rows.append((mo, v, cw, b, m, f"{base_mean}", f"{cur_mean}", f"{pct:+.1f}", flag))

# Markdown table
widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
def fmt(row):
    return "| " + " | ".join(s.ljust(widths[i]) for i, s in enumerate(row)) + " |"
print(fmt(rows[0]))
print("|" + "|".join("-" * (w + 2) for w in widths) + "|")
for r in rows[1:]:
    print(fmt(r))

sys.exit(1 if breaches else 0)
PY
}

cmd_bench_update_baselines() {
    local source=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --from) source="$2"; shift 2 ;;
            *) echo "error: unknown arg '$1'" >&2; exit 2 ;;
        esac
    done
    if [ -z "$source" ]; then
        source="$(/usr/bin/find "$ROOT_DIR/build/Debug/uitest" -name bench-result.json -type f 2>/dev/null \
            | /usr/bin/awk '{print $0}' \
            | /usr/bin/xargs -I {} stat -f "%m %N" {} 2>/dev/null \
            | sort -nr | head -n 1 | awk '{print $2}')"
    fi
    if [ -z "$source" ] || [ ! -f "$source" ]; then
        echo "error: no bench-result.json found; pass --from <path>" >&2
        exit 1
    fi

    SOURCE="$source" BASELINES="$BASELINES_JSON" /usr/bin/python3 - <<'PY'
import json
import os
import platform
import subprocess
import datetime as dt
from pathlib import Path

src = Path(os.environ["SOURCE"])
dst = Path(os.environ["BASELINES"])
current = json.loads(src.read_text())

try:
    cpu = subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip()
except Exception:
    cpu = platform.processor() or platform.machine()

out = {
    "schema_version": current.get("schema_version", 2),
    "machine": cpu,
    "generated_at_utc": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "source": str(src),
    "results": current.get("results", {}),
}
dst.write_text(json.dumps(out, indent=2) + "\n")
print(f"updated {dst}")
PY
}

main() {
    local command="${1:-help}"
    if [ $# -gt 0 ]; then
        shift
    fi
    case "$command" in
        prep)            cmd_prep "$@" ;;
        reset)           cmd_reset "$@" ;;
        locate)          cmd_locate "$@" ;;
        scaled-locate)   cmd_scaled_locate "$@" ;;
        window-locate)   cmd_window_locate "$@" ;;
        bench-step)      cmd_bench_step "$@" ;;
        screen-size)     cmd_screen_size ;;
        activate)        cmd_activate ;;
        logs)            cmd_logs "$@" ;;
        db)              cmd_db "$@" ;;
        artifacts-dir)   cmd_artifacts_dir ;;
        smoke-check)     cmd_smoke_check "$@" ;;
        bench-wait)              cmd_bench_wait "$@" ;;
        streaming-preview-check) cmd_streaming_preview_check "$@" ;;
        bench-record)            cmd_bench_record "$@" ;;
        bench-summarize)         cmd_bench_summarize "$@" ;;
        bench-compare)           cmd_bench_compare "$@" ;;
        bench-update-baselines)  cmd_bench_update_baselines "$@" ;;
        verify-generation)       cmd_verify_generation "$@" ;;
        help|-h|--help)  usage ;;
        *)
            echo "error: unknown command '$command'" >&2
            usage
            exit 2
            ;;
    esac
}

main "$@"
