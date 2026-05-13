#!/usr/bin/env bash
# scripts/bench_ui_generation.sh — timing primitives for the desktop-UI
# Vocello generation benchmark.
#
# This is the timing helper called by an automation agent (or you) around each
# Generate action in a foreground Vocello window. By default it triggers
# Cmd+Return itself for manual/non-agent runs. With --external-trigger it prints
# READY_FOR_TRIGGER, leaves the UI action to Computer Use / Ordinateur, then
# times the post-trigger pipeline (file appears → size stable → audio decodable)
# and computes wall_secs / audio_secs / RTF. Driving the UI (paste brief, paste
# script, click Generate / hit Cmd+Return) normally lives in the automation
# driver's computer-control session because Vocello's GenerationDraft state
# isn't surfaced via CLI.
#
# AGENT NOTE: agents should always pass --external-trigger. The default
# (non-external) mode shells out to `osascript`, which is not in the
# Claude Code Bash allowlist (.claude/settings.local.json), so an
# unattended agent run would stall on a permission prompt. Per CLAUDE.md,
# computer-use is the canonical UI-op channel for agents.
#
# NO SWAP / RAM PREFLIGHT (by policy). The desktop-UI bench
# characterises behaviour at the hardware floor including memory-
# pressure regimes; aborting on high swap would defeat the purpose.
# Only the single-instance rule applies: caller must `pkill -x Vocello`
# before each cold relaunch. Engine wedge (no output progress for >60 s
# with the Vocello process still alive) is the one legitimate abort
# condition; the script's existing 4000×0.1s = 400 s completion-detect
# loop covers it via a 60 s no-growth fallback when diagnostic logs are
# enabled.
#
# Usage:
#   scripts/bench_ui_generation.sh <mode> <length> <state> <sample> [csv_path] [--external-trigger]
#
#   mode      custom | design | clone
#   length    label (micro / short / medium / long / very-long / ...)
#   state     cold | warm
#   sample    numeric sample number (1, 2, 3, ...)
#   csv_path  optional; default /tmp/vocello-ui-bench-results.csv
#
# Cold/warm semantics are the caller's responsibility:
#   - cold = kill Vocello, relaunch, wait for "Engine ready", paste
#            inputs, then run this script
#   - warm = call this script back-to-back without restarting Vocello
#
# CSV columns: mode,length,state,sample,wall_secs,audio_secs,rtf,filename
#
# This is the **default** benchmark method per CLAUDE.md "Common Commands"
# benchmarking" — it captures the full user-perceived pipeline (paste,
# UI activation, generation, file write, and final playback handoff).
# Optional `[LivePreview]` log parsing remains diagnostics-only for
# preview experiments. For tighter engine-only regression checks, see
# `./scripts/qa.sh test --layer perf`.

set -euo pipefail

LOG_FILE=""
EXTERNAL_TRIGGER=false
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --external-trigger)
            EXTERNAL_TRIGGER=true; shift ;;
        --log-file)
            LOG_FILE="$2"; shift 2 ;;
        --log-file=*)
            LOG_FILE="${1#*=}"; shift ;;
        -h|--help)
            cat <<'USAGE'
Usage: bench_ui_generation.sh <mode> <length> <state> <sample> [csv_path]
                              [--external-trigger] [--log-file <path>]

  mode       custom | design | clone
  length     label (micro / short / medium / long / very-long / ...)
  state      cold | warm
  sample     numeric sample number (1, 2, 3, ...)
  csv_path   optional; default /tmp/vocello-ui-bench-results.csv
  --external-trigger
             print READY_FOR_TRIGGER and wait for an external UI driver
             (Computer Use / Ordinateur) to trigger Generate. This avoids
             agent-run UI automation through AppleScript.
  --log-file optional; when provided, the script reads `[LivePreview]`
             trace lines emitted during this sample's timing window
             and adds anomaly columns to the CSV (underrun_count,
             total_stall_ms, ttfa_ms, max_chunk_gap_ms, decode_fails,
             stream_errors, duration_mismatch_s, chunk_count).
             Caller is responsible for launching Vocello with stdout
             redirected to this file, e.g.:
               nohup .../Vocello > /tmp/vocello-bench.log 2>&1 &

Vocello must be the foreground app with the script + (for design)
brief fields populated. Without --external-trigger the script issues
Cmd+Return itself, then times wall-clock to file size stability.
USAGE
            exit 0 ;;
        *)
            POSITIONAL+=("$1"); shift ;;
    esac
done
set -- "${POSITIONAL[@]}"

if [ $# -lt 4 ]; then
    echo "missing required positional args; run with --help for usage" >&2
    exit 1
fi

MODE="$1"
LENGTH="$2"
STATE="$3"
SAMPLE="$4"
CSV="${5:-/tmp/vocello-ui-bench-results.csv}"

case "$MODE" in
    custom)  OUT_DIR="CustomVoice" ;;
    design)  OUT_DIR="VoiceDesign" ;;
    clone)   OUT_DIR="Clones" ;;
    *) echo "unknown mode: $MODE (expected custom|design|clone)" >&2; exit 2 ;;
esac

OUT="$HOME/Library/Application Support/QwenVoice/outputs/$OUT_DIR"
HDR_SIZE=4096
# Cmd+Return takes ~1.5s to round-trip activation + UI through the
# generation handoff; subtract it so wall_secs reflects actual
# generation time rather than activation overhead.
ACTIVATION_OVERHEAD=1.5
if [ "$EXTERNAL_TRIGGER" = "true" ]; then
    # External mode is driven by Computer Use / Ordinateur. The script
    # starts timing immediately after READY_FOR_TRIGGER is printed, so the
    # caller should trigger Generate promptly.
    ACTIVATION_OVERHEAD=0
fi

[ -d "$OUT" ] || { echo "output dir not found: $OUT" >&2; exit 3; }

# Single-instance preflight. The header's pkill rule (line 18) only matters
# if it is actually enforced; otherwise overlapping Vocellos silently
# corrupt the RSS baselines captured at lines 164–165.
# pgrep exits 1 when no match. Tolerate that explicitly so `set -o pipefail`
# doesn't kill the script before the case statement below can run.
VOCELLO_COUNT=$( (pgrep -x Vocello 2>/dev/null || true) | wc -l | tr -d ' ')
case "$STATE:$VOCELLO_COUNT" in
    cold:0|cold:1|warm:1) : ;;
    warm:0)
        echo "STATE=warm requires a running Vocello; none found." >&2
        echo "Either launch Vocello and wait for 'Engine ready' before retrying," >&2
        echo "or call this script with STATE=cold so a relaunch is expected." >&2
        exit 6 ;;
    *:*)
        echo "Found $VOCELLO_COUNT Vocello processes; expected ≤ 1." >&2
        echo "Run \`pkill -x Vocello\` (and any helper processes) before retrying." >&2
        exit 6 ;;
esac

rss_mb_for_pids() {
    local pids="$1"
    local total_kb=0
    local found=false
    local pid
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        local rss_kb
        rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)
        if [[ "$rss_kb" =~ ^[0-9]+$ ]]; then
            total_kb=$((total_kb + rss_kb))
            found=true
        fi
    done <<< "$pids"

    if [ "$found" = "true" ]; then
        awk -v kb="$total_kb" 'BEGIN { printf "%.1f", kb / 1024 }'
    fi
}

rss_mb_for_exact_process() {
    local process_name="$1"
    local pids
    pids=$(pgrep -x "$process_name" 2>/dev/null || true)
    rss_mb_for_pids "$pids"
}

rss_mb_for_matching_process() {
    local process_pattern="$1"
    local pids
    pids=$(pgrep -f "$process_pattern" 2>/dev/null || true)
    rss_mb_for_pids "$pids"
}

# Snapshot file set before triggering
BEFORE=$(ls "$OUT" 2>/dev/null | sort)
VOCELLO_RSS_MB_BEFORE=$(rss_mb_for_exact_process "Vocello")
ENGINE_RSS_MB_BEFORE=$(rss_mb_for_matching_process "QwenVoiceEngineService")

# Capture pre-trigger log state. We pin OUR session as the
# (SESSION_START_COUNT_BEFORE + 1)-th `event=session_start` in the log.
#
# Why session-counter gating instead of byte-offset slicing: diagnostic
# preview logs emit `session_start` and `preview_completed` in causal
# order. Byte-offset slicing was fooled by a previous sample's late
# summary flushing into the log AFTER our LOG_OFFSET_BEFORE was captured;
# sample N+1 would then read sample N's stale summary as its own. Counter
# gating is immune: even if the stale event appears anywhere in the log
# past our offset, it's by definition before our session_start, so the
# awk filter rejects it.
HAS_LOG_FILE=false
SESSION_START_COUNT_BEFORE=0
TARGET_SESSION_INDEX=0
LOG_OFFSET_BEFORE=0
if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
    HAS_LOG_FILE=true
    SESSION_START_COUNT_BEFORE=$(grep -c "event=session_start" "$LOG_FILE" 2>/dev/null || echo 0)
    SESSION_START_COUNT_BEFORE=${SESSION_START_COUNT_BEFORE//[^0-9]/}
    SESSION_START_COUNT_BEFORE=${SESSION_START_COUNT_BEFORE:-0}
    TARGET_SESSION_INDEX=$((SESSION_START_COUNT_BEFORE + 1))
    # Byte-offset capture is still used by the cross-layer probe-aggregate
    # parser below: `[Probe.Engine|Transport|UI]` events carry no session
    # ID, so they can't be session-counter-gated. Per-chunk latency
    # aggregation is best-effort and the race is impactful only if a prior
    # sample's probe events are still flushing during ours — accepted for
    # now; revisit when probes grow a session_id field.
    LOG_OFFSET_BEFORE=$(stat -f %z "$LOG_FILE" 2>/dev/null || echo 0)
fi

if [ "$EXTERNAL_TRIGGER" != "true" ]; then
    osascript -e 'tell application "Vocello" to activate' 2>/dev/null
    sleep 0.4
fi

if [ "$EXTERNAL_TRIGGER" = "true" ]; then
    # Emit on both channels: stderr is unbuffered by default on macOS, so
    # an agent reading the script's stderr stream sees READY_FOR_TRIGGER
    # immediately even when stdout is block-buffered through a pipe.
    # stdout stays for back-compat with existing recipes that grep stdout.
    printf 'READY_FOR_TRIGGER\n'
    printf 'READY_FOR_TRIGGER\n' >&2
fi

T0=$(date +%s.%N)
# Reference file pinned at T0 for portable `find -newer` (BSD find on
# macOS doesn't accept the GNU/bfs `-newermt "@<epoch>"` syntax).
T0_REF=$(mktemp -t bench-t0.XXXXXX)
trap 'rm -f "$T0_REF"' EXIT
if [ "$EXTERNAL_TRIGGER" != "true" ]; then
    osascript -e 'tell application "System Events" to keystroke return using command down'
fi

# Wait for the first new wav to appear (max ~180s of 0.1s polls)
NEW=""
for i in $(seq 1 1800); do
    CURRENT=$(ls "$OUT" 2>/dev/null | sort)
    if [ "$CURRENT" != "$BEFORE" ]; then
        NEW=$(comm -13 <(echo "$BEFORE") <(echo "$CURRENT") | grep -E "\.wav$" | head -1 || true)
        [ -n "$NEW" ] && break
    fi
    sleep 0.1
done
[ -z "$NEW" ] && { echo "FILE_TIMEOUT (no new wav appeared in $OUT)" >&2; exit 4; }
NEWFILE="$OUT/$NEW"

# Wait for file size to grow past the WAV header
for i in $(seq 1 2000); do
    S=$(stat -f %z "$NEWFILE" 2>/dev/null || echo 0)
    [ "$S" -gt "$HDR_SIZE" ] && break
    sleep 0.1
done

# Wait for completion. Two signals:
#
# (1) When --log-file is provided for diagnostic preview experiments:
#     wait for the `[LivePreview] event=preview_completed` line. This is
#     the diagnostic path's own authoritative signal. Size-stability is
#     treated as a hang fallback only, not a primary signal, because
#     inter-chunk pauses can falsely trip a short stability window during
#     a healthy diagnostic preview session.
#
# (2) Without --log-file: fall back to size stability (5s of no growth).
#     The 5s window must exceed normal inter-chunk gaps (~1.6s for
#     medium/long gens) to avoid false positives.
LAST_SIZE=0
STABLE=0
COMPLETED_VIA_LOG=false
SUMMARY_LINE=""
for i in $(seq 1 4000); do
    if [ "$HAS_LOG_FILE" = "true" ]; then
        # Look for OUR session's preview_completed: the first preview_completed
        # AFTER the (TARGET_SESSION_INDEX)-th session_start. awk exits early
        # if it walks past our session (session_idx > target) without a match,
        # which keeps the per-tick scan cheap.
        SUMMARY_LINE=$(awk -v target="$TARGET_SESSION_INDEX" '
            /event=session_start/ {
                session_idx++
                if (session_idx == target) { our_seen = 1; next }
                if (session_idx > target) exit
                next
            }
            our_seen && /event=preview_completed/ { print; exit }
        ' "$LOG_FILE" 2>/dev/null || true)
        if [ -n "$SUMMARY_LINE" ]; then
            COMPLETED_VIA_LOG=true
            break
        fi
        # Size-stability is a HANG fallback when --log-file is set:
        # only break on 60 s of no growth (truly stuck) so normal
        # inter-chunk pauses never short-circuit the wait.
        S=$(stat -f %z "$NEWFILE" 2>/dev/null || echo 0)
        if [ "$S" = "$LAST_SIZE" ]; then
            STABLE=$((STABLE + 1))
            [ "$STABLE" -ge 600 ] && break
        else
            STABLE=0
            LAST_SIZE=$S
        fi
    else
        # No log file: 5 s size-stability is the only signal.
        S=$(stat -f %z "$NEWFILE" 2>/dev/null || echo 0)
        if [ "$S" = "$LAST_SIZE" ]; then
            STABLE=$((STABLE + 1))
            [ "$STABLE" -ge 50 ] && break
        else
            STABLE=0
            LAST_SIZE=$S
        fi
    fi
    sleep 0.1
done

T1=$(date +%s.%N)
WALL=$(echo "scale=3; $T1 - $T0 - $ACTIVATION_OVERHEAD" | bc)
VOCELLO_RSS_MB_AFTER=$(rss_mb_for_exact_process "Vocello")
ENGINE_RSS_MB_AFTER=$(rss_mb_for_matching_process "QwenVoiceEngineService")

# Audio duration source — two paths:
#
# (A) When --log-file is provided AND preview_completed was seen, read
#     `total_audio_s` from the trace. This is the engine's own ground
#     truth and avoids the afinfo race on the WAV header (which can
#     read 0.000000 between streaming-write completion and
#     finalWriter.finish() updating the RIFF header).
#
# (B) Otherwise (no log file, or final-file generation with no diagnostic preview),
#     fall back to summing afinfo durations across all wavs newer
#     than T0. Includes a retry loop for the header-finalization race.
T0_INT=$(echo "$T0" | cut -d. -f1)
TOTAL_AUDIO=0
SEG_COUNT=0

if [ "$COMPLETED_VIA_LOG" = "true" ]; then
    # SUMMARY_LINE was captured in the wait loop above and is already
    # scoped to OUR session via session-counter gating.
    LOG_AUDIO=$(echo "$SUMMARY_LINE" | grep -oE 'total_audio_s=[0-9.]+' | cut -d= -f2)
    if [ -n "$LOG_AUDIO" ] && [ "$LOG_AUDIO" != "0" ]; then
        TOTAL_AUDIO="$LOG_AUDIO"
        SEG_COUNT=1
    fi
fi

if [ "$TOTAL_AUDIO" = "0" ] || [ -z "$TOTAL_AUDIO" ]; then
    for retry in $(seq 1 50); do
        TOTAL_AUDIO=0
        SEG_COUNT=0
        while IFS= read -r -d '' seg; do
            D=$(afinfo "$seg" 2>/dev/null | grep "estimated duration" | awk '{print $3}' || true)
            if [ -n "$D" ] && [ "$D" != "0.000000" ]; then
                TOTAL_AUDIO=$(echo "scale=3; $TOTAL_AUDIO + $D" | bc)
                SEG_COUNT=$((SEG_COUNT + 1))
            fi
        done < <(find "$OUT" -name "*.wav" -newer "$T0_REF" -print0 2>/dev/null | sort -z)
        [ "$TOTAL_AUDIO" != "0" ] && [ -n "$TOTAL_AUDIO" ] && break
        sleep 0.2
    done
fi

if [ "$TOTAL_AUDIO" = "0" ] || [ -z "$TOTAL_AUDIO" ]; then
    echo "PARSE_FAILED (no readable audio in new files; neither preview_completed event nor afinfo returned a non-zero duration)" >&2
    exit 5
fi

RTF=$(echo "scale=3; $WALL / $TOTAL_AUDIO" | bc)

if [ "$SEG_COUNT" -gt 1 ]; then
    FILE_LABEL="${SEG_COUNT}-segment-batch"
else
    FILE_LABEL="$NEW"
fi

# ---------------------------------------------------------------------
# Anomaly parsing — when --log-file points at a captured Vocello stdout,
# extract the `[LivePreview]` event lines emitted in this sample's
# timing window and reduce them to summary columns.
#
# Schema (emitted by AudioPlayerViewModel.swift, DEBUG-only):
#   [LivePreview] event=session_start session=<id>
#   [LivePreview] event=chunk_arrived seq=N audio_s=X cumulative_s=Y queue_depth=Q gap_ms=G
#   [LivePreview] event=playback_started ttfa_ms=T queue_depth=Q
#   [LivePreview] event=underrun_paused underrun_n=N audio_played_s=X
#   [LivePreview] event=underrun_resumed stall_ms=S queue_depth=Q
#   [LivePreview] event=decode_failed branch=<file|inline>
#   [LivePreview] event=stream_error message=<text>
#   [LivePreview] event=final_handoff preview_audio_s=X final_audio_s=Y delta_s=D
#   [LivePreview] event=preview_completed underruns=N total_stall_ms=S ...
# ---------------------------------------------------------------------
UNDERRUN_COUNT=""
TOTAL_STALL_MS=""
TTFA_MS=""
MAX_CHUNK_GAP_MS=""
DECODE_FAILS=""
STREAM_ERRORS=""
DURATION_MISMATCH_S=""
CHUNK_COUNT=""

if [ "$HAS_LOG_FILE" = "true" ] && [ "$TARGET_SESSION_INDEX" -gt 0 ]; then
    # Pull all `[LivePreview]` lines belonging to OUR session: from our
    # session_start (inclusive) up to the next session_start (exclusive)
    # or end of log. Same counter-gating as the wait loop.
    TRACE=$(awk -v target="$TARGET_SESSION_INDEX" '
        /\[LivePreview\]/ && /event=session_start/ {
            session_idx++
            if (session_idx == target) { our_seen = 1; print; next }
            if (session_idx > target) exit
            next
        }
        our_seen && /\[LivePreview\]/ { print }
    ' "$LOG_FILE" 2>/dev/null || true)

    if [ -n "$TRACE" ]; then
        # preview_completed line carries all aggregate counters.
        # `|| true` on every grep so a missing line (e.g. very short
        # audio that skips the live-preview path) doesn't trip
        # `set -e` and kill the script before the CSV is written.
        SUMMARY=$(echo "$TRACE" | grep "event=preview_completed" | tail -1 || true)
        if [ -n "$SUMMARY" ]; then
            UNDERRUN_COUNT=$(echo "$SUMMARY" | grep -oE 'underruns=[0-9]+' | cut -d= -f2 || true)
            TOTAL_STALL_MS=$(echo "$SUMMARY" | grep -oE 'total_stall_ms=[0-9]+' | cut -d= -f2 || true)
            DECODE_FAILS=$(echo "$SUMMARY" | grep -oE 'decode_fails=[0-9]+' | cut -d= -f2 || true)
            STREAM_ERRORS=$(echo "$SUMMARY" | grep -oE 'stream_errors=[0-9]+' | cut -d= -f2 || true)
            MAX_CHUNK_GAP_MS=$(echo "$SUMMARY" | grep -oE 'max_chunk_gap_ms=[0-9]+' | cut -d= -f2 || true)
            CHUNK_COUNT=$(echo "$SUMMARY" | grep -oE 'chunk_count=[0-9]+' | cut -d= -f2 || true)
        fi

        # ttfa_ms comes from playback_started — missing for very-short
        # generations where the live-preview path never engages
        # (queue duration < initial prebuffer threshold of 2.25 s).
        STARTED_LINE=$(echo "$TRACE" | grep "event=playback_started" | tail -1 || true)
        if [ -n "$STARTED_LINE" ]; then
            TTFA_MS=$(echo "$STARTED_LINE" | grep -oE 'ttfa_ms=[0-9]+' | cut -d= -f2 || true)
        fi

        # duration_mismatch_s = abs(delta_s) from final_handoff
        HANDOFF_LINE=$(echo "$TRACE" | grep "event=final_handoff" | tail -1 || true)
        if [ -n "$HANDOFF_LINE" ]; then
            DELTA=$(echo "$HANDOFF_LINE" | grep -oE 'delta_s=-?[0-9.]+' | cut -d= -f2 || true)
            if [ -n "$DELTA" ]; then
                DURATION_MISMATCH_S=$(echo "$DELTA" | tr -d -)
            fi
        fi
    fi
fi

UNDERRUN_COUNT=${UNDERRUN_COUNT:-}
TOTAL_STALL_MS=${TOTAL_STALL_MS:-}
TTFA_MS=${TTFA_MS:-}
MAX_CHUNK_GAP_MS=${MAX_CHUNK_GAP_MS:-}
DECODE_FAILS=${DECODE_FAILS:-}
STREAM_ERRORS=${STREAM_ERRORS:-}
DURATION_MISMATCH_S=${DURATION_MISMATCH_S:-}
CHUNK_COUNT=${CHUNK_COUNT:-}

# ---------------------------------------------------------------------
# Cross-layer chunk probe parsing — when --log-file points at captured
# Vocello stdout, extract `[Probe.Engine]` / `[Probe.Transport]` /
# `[Probe.UI]` lines emitted in this sample's window and join by `seq`
# to compute per-chunk latency aggregates.
#
# Probe schema (emitted by XPCNativeEngineClient + AudioPlayerViewModel,
# DEBUG-only, fired once per chunk per layer with a shared engine seq):
#   [Probe.Engine]    event=chunk_emitted   seq=N audio_s=A infer_ms=I engine_at_ms=T_E
#   [Probe.Transport] event=chunk_delivered seq=N transport_at_ms=T_T xpc_latency_ms=L
#   [Probe.UI]        event=chunk_consumed  seq=N ui_at_ms=T_U
# ---------------------------------------------------------------------
PROBE_E2T_MAX_MS=""
PROBE_E2T_P50_MS=""
PROBE_T2U_MAX_MS=""
PROBE_T2U_P50_MS=""
PROBE_E2U_MAX_MS=""
PROBE_INFER_MAX_MS=""
PROBE_INFER_P50_MS=""
PROBE_CHUNK_COUNT=""
# Engine probe Phase 1 sub-stage maxes — `[Probe.Engine]` lines now
# carry `talker_forward_ms`, `code_predictor_ms`, and
# `audio_decoder_ms` per chunk. These three deltas always sum to less
# than `infer_ms` (the wall-clock between chunk emits also includes
# eval cadence, scratch buffer conversion, file write, and event
# dispatch overhead). Empty when probes are emitted by a non-Qwen3
# backend or legacy chunk.
PROBE_TALKER_MAX_MS=""
PROBE_CODE_PREDICTOR_MAX_MS=""
PROBE_AUDIO_DECODER_MAX_MS=""
# Engine probe Phase 2a — eval cadence + EOS read + audio chunk eval.
# Together with Phase 1's three stages they should account for ≥ 80 %
# of `infer_ms`. If still under 50 %, the next layer down is MLX
# kernel-launch overhead which requires Instruments / signposts
# profiling rather than wall-clock counters.
PROBE_STREAM_STEP_EVAL_MAX_MS=""
PROBE_STREAM_STEP_EOS_READ_MAX_MS=""
PROBE_AUDIO_CHUNK_EVAL_MAX_MS=""

if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
    LOG_OFFSET_AFTER=$(stat -f %z "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$LOG_OFFSET_AFTER" -gt "$LOG_OFFSET_BEFORE" ]; then
        PROBE_AGGREGATES=$(tail -c "+$((LOG_OFFSET_BEFORE + 1))" "$LOG_FILE" \
            | awk '
                BEGIN { e2t_max=0; t2u_max=0; e2u_max=0; infer_max=0; n=0;
                        talker_max=0; code_max=0; decoder_max=0;
                        stream_eval_max=0; eos_read_max=0; chunk_eval_max=0 }
                /^\[Probe\.Engine\] event=chunk_emitted/ {
                    seq=""; eng=""; inf=""; talker=""; code=""; decoder=""
                    stream_eval=""; eos_read=""; chunk_eval=""
                    for (i=1; i<=NF; i++) {
                        if ($i ~ /^seq=/) { sub("seq=", "", $i); seq=$i }
                        else if ($i ~ /^engine_at_ms=/) { sub("engine_at_ms=", "", $i); eng=$i }
                        else if ($i ~ /^infer_ms=/) { sub("infer_ms=", "", $i); inf=$i }
                        else if ($i ~ /^talker_forward_ms=/) { sub("talker_forward_ms=", "", $i); talker=$i }
                        else if ($i ~ /^code_predictor_ms=/) { sub("code_predictor_ms=", "", $i); code=$i }
                        else if ($i ~ /^audio_decoder_ms=/) { sub("audio_decoder_ms=", "", $i); decoder=$i }
                        else if ($i ~ /^stream_step_eval_ms=/) { sub("stream_step_eval_ms=", "", $i); stream_eval=$i }
                        else if ($i ~ /^stream_step_eos_read_ms=/) { sub("stream_step_eos_read_ms=", "", $i); eos_read=$i }
                        else if ($i ~ /^audio_chunk_eval_ms=/) { sub("audio_chunk_eval_ms=", "", $i); chunk_eval=$i }
                    }
                    if (seq != "") {
                        engine_at[seq]=eng; infer[seq]=inf
                        if (talker != "") talker_t[seq] = talker
                        if (code != "") code_t[seq] = code
                        if (decoder != "") decoder_t[seq] = decoder
                        if (stream_eval != "") stream_eval_t[seq] = stream_eval
                        if (eos_read != "") eos_read_t[seq] = eos_read
                        if (chunk_eval != "") chunk_eval_t[seq] = chunk_eval
                    }
                }
                /^\[Probe\.Transport\] event=chunk_delivered/ {
                    seq=""; tr=""
                    for (i=1; i<=NF; i++) {
                        if ($i ~ /^seq=/) { sub("seq=", "", $i); seq=$i }
                        else if ($i ~ /^transport_at_ms=/) { sub("transport_at_ms=", "", $i); tr=$i }
                    }
                    if (seq != "") { transport_at[seq]=tr }
                }
                /^\[Probe\.UI\] event=chunk_consumed/ {
                    seq=""; ui=""
                    for (i=1; i<=NF; i++) {
                        if ($i ~ /^seq=/) { sub("seq=", "", $i); seq=$i }
                        else if ($i ~ /^ui_at_ms=/) { sub("ui_at_ms=", "", $i); ui=$i }
                    }
                    if (seq != "") { ui_at[seq]=ui }
                }
                END {
                    # Build per-seq deltas where all 3 layers landed
                    n=0
                    for (s in engine_at) {
                        if ((s in transport_at) && (s in ui_at)) {
                            e2t = transport_at[s] - engine_at[s]
                            t2u = ui_at[s] - transport_at[s]
                            e2u = ui_at[s] - engine_at[s]
                            inf = infer[s] + 0.0
                            if (e2t > e2t_max) e2t_max = e2t
                            if (t2u > t2u_max) t2u_max = t2u
                            if (e2u > e2u_max) e2u_max = e2u
                            if (inf > infer_max) infer_max = inf
                            e2ts[n] = e2t; t2us[n] = t2u; infers[n] = inf
                            n++
                        }
                    }
                    # Sub-stage maxes — independent of cross-layer join,
                    # so even chunks whose Transport / UI events were
                    # missing still contribute to the engine-side maxes.
                    for (s in talker_t) {
                        v = talker_t[s] + 0.0
                        if (v > talker_max) talker_max = v
                    }
                    for (s in code_t) {
                        v = code_t[s] + 0.0
                        if (v > code_max) code_max = v
                    }
                    for (s in decoder_t) {
                        v = decoder_t[s] + 0.0
                        if (v > decoder_max) decoder_max = v
                    }
                    for (s in stream_eval_t) {
                        v = stream_eval_t[s] + 0.0
                        if (v > stream_eval_max) stream_eval_max = v
                    }
                    for (s in eos_read_t) {
                        v = eos_read_t[s] + 0.0
                        if (v > eos_read_max) eos_read_max = v
                    }
                    for (s in chunk_eval_t) {
                        v = chunk_eval_t[s] + 0.0
                        if (v > chunk_eval_max) chunk_eval_max = v
                    }
                    if (n == 0) {
                        printf "0.000,0.000,0.000,0.000,0.000,0.000,0.000,0,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f", \
                            talker_max, code_max, decoder_max, stream_eval_max, eos_read_max, chunk_eval_max
                        exit
                    }
                    # Sort each array (selection sort, n is small).
                    for (i=0; i<n; i++) {
                        mi=i
                        for (j=i+1; j<n; j++) if (e2ts[j] < e2ts[mi]) mi=j
                        t=e2ts[i]; e2ts[i]=e2ts[mi]; e2ts[mi]=t
                    }
                    for (i=0; i<n; i++) {
                        mi=i
                        for (j=i+1; j<n; j++) if (t2us[j] < t2us[mi]) mi=j
                        t=t2us[i]; t2us[i]=t2us[mi]; t2us[mi]=t
                    }
                    for (i=0; i<n; i++) {
                        mi=i
                        for (j=i+1; j<n; j++) if (infers[j] < infers[mi]) mi=j
                        t=infers[i]; infers[i]=infers[mi]; infers[mi]=t
                    }
                    e2t_p50 = e2ts[int(n/2)]
                    t2u_p50 = t2us[int(n/2)]
                    infer_p50 = infers[int(n/2)]
                    printf "%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f", \
                        e2t_max, e2t_p50, t2u_max, t2u_p50, e2u_max, infer_max, infer_p50, n, \
                        talker_max, code_max, decoder_max, \
                        stream_eval_max, eos_read_max, chunk_eval_max
                }
            ' || true)
        if [ -n "$PROBE_AGGREGATES" ]; then
            IFS=',' read -r PROBE_E2T_MAX_MS PROBE_E2T_P50_MS PROBE_T2U_MAX_MS PROBE_T2U_P50_MS PROBE_E2U_MAX_MS PROBE_INFER_MAX_MS PROBE_INFER_P50_MS PROBE_CHUNK_COUNT PROBE_TALKER_MAX_MS PROBE_CODE_PREDICTOR_MAX_MS PROBE_AUDIO_DECODER_MAX_MS PROBE_STREAM_STEP_EVAL_MAX_MS PROBE_STREAM_STEP_EOS_READ_MAX_MS PROBE_AUDIO_CHUNK_EVAL_MAX_MS <<< "$PROBE_AGGREGATES"
        fi
    fi
fi

PROBE_E2T_MAX_MS=${PROBE_E2T_MAX_MS:-}
PROBE_E2T_P50_MS=${PROBE_E2T_P50_MS:-}
PROBE_T2U_MAX_MS=${PROBE_T2U_MAX_MS:-}
PROBE_T2U_P50_MS=${PROBE_T2U_P50_MS:-}
PROBE_E2U_MAX_MS=${PROBE_E2U_MAX_MS:-}
PROBE_INFER_MAX_MS=${PROBE_INFER_MAX_MS:-}
PROBE_INFER_P50_MS=${PROBE_INFER_P50_MS:-}
PROBE_CHUNK_COUNT=${PROBE_CHUNK_COUNT:-}
PROBE_TALKER_MAX_MS=${PROBE_TALKER_MAX_MS:-}
PROBE_CODE_PREDICTOR_MAX_MS=${PROBE_CODE_PREDICTOR_MAX_MS:-}
PROBE_AUDIO_DECODER_MAX_MS=${PROBE_AUDIO_DECODER_MAX_MS:-}
PROBE_STREAM_STEP_EVAL_MAX_MS=${PROBE_STREAM_STEP_EVAL_MAX_MS:-}
PROBE_STREAM_STEP_EOS_READ_MAX_MS=${PROBE_STREAM_STEP_EOS_READ_MAX_MS:-}
PROBE_AUDIO_CHUNK_EVAL_MAX_MS=${PROBE_AUDIO_CHUNK_EVAL_MAX_MS:-}

CSV_HEADER_WITH_RSS="mode,length,state,sample,wall_secs,audio_secs,rtf,filename,underrun_count,total_stall_ms,ttfa_ms,max_chunk_gap_ms,decode_fails,stream_errors,duration_mismatch_s,chunk_count,e2t_max_ms,e2t_p50_ms,t2u_max_ms,t2u_p50_ms,e2u_max_ms,infer_max_ms,infer_p50_ms,probe_chunk_count,talker_max_ms,code_predictor_max_ms,audio_decoder_max_ms,stream_step_eval_max_ms,stream_step_eos_read_max_ms,audio_chunk_eval_max_ms,vocello_rss_mb_before,vocello_rss_mb_after,engine_rss_mb_before,engine_rss_mb_after"
if [ ! -f "$CSV" ]; then
    echo "$CSV_HEADER_WITH_RSS" > "$CSV"
fi

CSV_HEADER=$(head -n 1 "$CSV" 2>/dev/null || true)
if [[ "$CSV_HEADER" == *"vocello_rss_mb_before"* ]]; then
    ROW="$MODE,$LENGTH,$STATE,$SAMPLE,$WALL,$TOTAL_AUDIO,$RTF,$FILE_LABEL,$UNDERRUN_COUNT,$TOTAL_STALL_MS,$TTFA_MS,$MAX_CHUNK_GAP_MS,$DECODE_FAILS,$STREAM_ERRORS,$DURATION_MISMATCH_S,$CHUNK_COUNT,$PROBE_E2T_MAX_MS,$PROBE_E2T_P50_MS,$PROBE_T2U_MAX_MS,$PROBE_T2U_P50_MS,$PROBE_E2U_MAX_MS,$PROBE_INFER_MAX_MS,$PROBE_INFER_P50_MS,$PROBE_CHUNK_COUNT,$PROBE_TALKER_MAX_MS,$PROBE_CODE_PREDICTOR_MAX_MS,$PROBE_AUDIO_DECODER_MAX_MS,$PROBE_STREAM_STEP_EVAL_MAX_MS,$PROBE_STREAM_STEP_EOS_READ_MAX_MS,$PROBE_AUDIO_CHUNK_EVAL_MAX_MS,$VOCELLO_RSS_MB_BEFORE,$VOCELLO_RSS_MB_AFTER,$ENGINE_RSS_MB_BEFORE,$ENGINE_RSS_MB_AFTER"
else
    ROW="$MODE,$LENGTH,$STATE,$SAMPLE,$WALL,$TOTAL_AUDIO,$RTF,$FILE_LABEL,$UNDERRUN_COUNT,$TOTAL_STALL_MS,$TTFA_MS,$MAX_CHUNK_GAP_MS,$DECODE_FAILS,$STREAM_ERRORS,$DURATION_MISMATCH_S,$CHUNK_COUNT,$PROBE_E2T_MAX_MS,$PROBE_E2T_P50_MS,$PROBE_T2U_MAX_MS,$PROBE_T2U_P50_MS,$PROBE_E2U_MAX_MS,$PROBE_INFER_MAX_MS,$PROBE_INFER_P50_MS,$PROBE_CHUNK_COUNT,$PROBE_TALKER_MAX_MS,$PROBE_CODE_PREDICTOR_MAX_MS,$PROBE_AUDIO_DECODER_MAX_MS,$PROBE_STREAM_STEP_EVAL_MAX_MS,$PROBE_STREAM_STEP_EOS_READ_MAX_MS,$PROBE_AUDIO_CHUNK_EVAL_MAX_MS"
fi
echo "$ROW"
echo "$ROW" >> "$CSV"
