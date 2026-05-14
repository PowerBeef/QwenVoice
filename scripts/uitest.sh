#!/usr/bin/env bash
# Foundation for autonomous UI-driven testing of the Vocello Debug build.
#
# A Claude Code session uses the computer-use MCP to drive Vocello like a
# person; this script provides the deterministic pieces that don't make
# sense to do via screenshots — launch, state reset, AXIdentifier lookup,
# log tailing, DB queries, artifact directory creation.
#
# usage: scripts/uitest.sh <command> [options]   (see `help`)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"

APP_NAME="Vocello"
DEBUG_APP_BUNDLE="$ROOT_DIR/build/DerivedData/Build/Products/Debug/$APP_NAME.app"
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
                        --full rm -rfs the entire Debug data folder (forces model
                          re-download on next launch).

  locate <ax-id>        Look up a SwiftUI accessibilityIdentifier in Vocello's front
                        window and print "cx cy w h" — center coordinates and size —
                        in macOS logical-points space. See docs/reference/ui-test-surface.md
                        for the screenshot-pixel scaling caveat. Exits non-zero if not found.

  screen-size           Print the screen's logical-point dimensions as "W H". Use with
                        the locate output to scale to your screenshot's image pixels.

  activate              Bring Vocello to the front. Use as a mid-test recovery step when
                        a system dialog or notification has stolen focus, or before a
                        click sequence to guarantee Vocello receives the input.

  logs [--predicate <p>]
                        Tail \`log stream --info --style compact\` for Vocello, defaulting
                        to predicate: subsystem == "com.qwenvoice.app".

  db <sql>              Run a read-only SELECT against history.sqlite and print CSV.

  artifacts-dir         Create build/uitest/<timestamp>/ and print its absolute path.

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
                        build/uitest/). Review \`git diff\` before committing.

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
    local dir="$ROOT_DIR/build/uitest/$ts"
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
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local found
        found="$(/usr/bin/log show --signpost --predicate "$BENCH_LOG_PREDICATE" --last 3m --style compact 2>/dev/null \
            | SINCE="$since" /usr/bin/python3 -c '
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
    echo "error: timeout after ${timeout}s waiting for Final File Ready since $since" >&2
    return 1
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

    local log_buf
    log_buf="$(/usr/bin/log show --signpost --predicate "$BENCH_LOG_PREDICATE" --last 3m --style compact 2>/dev/null || true)"

    # Wait up to 2 s for the DB row to land (saveGenerationAsync is detached).
    local db_row=""
    for _ in 1 2 3 4 5 6 7 8; do
        db_row="$(/usr/bin/sqlite3 -readonly -separator $'\t' "$HISTORY_DB" \
            "SELECT id, audioPath, duration FROM generations ORDER BY createdAt DESC LIMIT 1" 2>/dev/null || true)"
        [ -n "$db_row" ] && break
        sleep 0.25
    done

    MODE="$mode" VARIANT="$variant" COLDWARM="$coldwarm" BUCKET="$bucket" \
        ARTIFACTS_DIR="$artifacts_dir" DB_ROW="$db_row" LOG_BUF="$log_buf" \
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

# Autoplay Start usually fires AFTER Final File Ready (per
# GenerationPersistence.swift). Walk forward from final_idx.
for i in range(final_idx + 1, len(lines)):
    if "Autoplay Start" in lines[i]:
        autoplay_ts = parse_ts(lines[i])
        if autoplay_ts:
            break

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

sample = {
    "mode": mode,
    "variant": variant,
    "cold_or_warm": coldwarm,
    "bucket": bucket,
    "ms_engine_start_to_first_chunk": ms_engine_to_first,
    "ms_engine_start_to_final": ms_engine_to_final,
    "ms_engine_start_to_autoplay": ms_engine_to_play,
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
    "ms_engine_start_to_first_chunk",
    "ms_engine_start_to_final",
    "ms_engine_start_to_autoplay",
    "audio_duration_s",
    "rtf",
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
    "schema_version": 2,
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
        source="$(/usr/bin/find "$ROOT_DIR/build/uitest" -name bench-result.json -type f 2>/dev/null \
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
        screen-size)     cmd_screen_size ;;
        activate)        cmd_activate ;;
        logs)            cmd_logs "$@" ;;
        db)              cmd_db "$@" ;;
        artifacts-dir)   cmd_artifacts_dir ;;
        smoke-check)     cmd_smoke_check "$@" ;;
        bench-wait)              cmd_bench_wait "$@" ;;
        bench-record)            cmd_bench_record "$@" ;;
        bench-summarize)         cmd_bench_summarize "$@" ;;
        bench-compare)           cmd_bench_compare "$@" ;;
        bench-update-baselines)  cmd_bench_update_baselines "$@" ;;
        help|-h|--help)  usage ;;
        *)
            echo "error: unknown command '$command'" >&2
            usage
            exit 2
            ;;
    esac
}

main "$@"
