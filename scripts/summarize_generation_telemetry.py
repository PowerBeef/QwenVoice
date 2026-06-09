#!/usr/bin/env python3
"""Summarize per-generation telemetry into a mode × model × cold/warm table.

READ-ONLY analysis of the JSONL the runtime telemetry already writes — it never
drives a generation, never writes baselines, and takes no committed input. It joins
the per-layer rows by `generationID` and prints a comparison table; for the warm
runs in a cell it reports the median, for cold the single value (median if several).

Usage:
    python3 scripts/summarize_generation_telemetry.py [DIAGNOSTICS_DIR] [--label NOTE]
    python3 scripts/summarize_generation_telemetry.py --ledger-row [--label NOTE] [--cell mode/model/state]

The full table is the default. `--ledger-row` prints ONE Markdown table row (the
headline cell) for appending to `benchmarks/HISTORY.md` to track performance over
time, e.g.:

    python3 scripts/summarize_generation_telemetry.py --ledger-row --label "stepeval fix" \\
        >> benchmarks/HISTORY.md

`--label` stamps a free-form note (e.g. what changed); the run is auto-stamped with
the current date + short git SHA so a number ties to a commit. Read-only: it never
writes into the repo itself (you redirect the row).

Default DIAGNOSTICS_DIR:
    ~/Library/Application Support/QwenVoice-Debug/diagnostics

See docs/reference/telemetry-and-benchmarking.md for the benchmark procedure.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import statistics
import subprocess
from collections import defaultdict

DEFAULT_DIR = os.path.expanduser(
    "~/Library/Application Support/QwenVoice-Debug/diagnostics"
)


def git_short_sha():
    """Short HEAD SHA of the repo in CWD, or '-' when unavailable."""
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=5,
        )
        sha = out.stdout.strip()
        return sha if out.returncode == 0 and sha else "-"
    except Exception:
        return "-"


def today_str():
    return datetime.date.today().isoformat()


def read_jsonl(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


# Prompt-length buckets for the benchmark length sweep. Thresholds tied to the
# fixed corpus (short ~35, medium ~110, long ~330 chars); see
# docs/reference/telemetry-and-benchmarking.md. Rows with no promptChars
# (pre-length-capture runs) bucket as "n/a".
LEN_ORDER = {"short": 0, "medium": 1, "long": 2, "n/a": 3}


def len_bucket(prompt_chars):
    if not prompt_chars:
        return "n/a"
    if prompt_chars < 70:
        return "short"
    if prompt_chars > 220:
        return "long"
    return "medium"


def load_runs(diag_dir):
    """Join engine + app rows by generationID. Returns list of per-run dicts."""
    engine = {r.get("generationID"): r for r in read_jsonl(os.path.join(diag_dir, "engine", "generations.jsonl"))}
    app = {r.get("generationID"): r for r in read_jsonl(os.path.join(diag_dir, "app", "generations.jsonl"))}

    runs = []
    for gid, e in engine.items():
        derived = e.get("derivedMetrics") or {}
        timings = e.get("timingsMS") or {}
        summary = e.get("summary") or {}
        a = app.get(gid) or {}
        app_timings = a.get("timingsMS") or {}
        app_counters = a.get("counters") or {}
        qc = e.get("audioQC") or {}
        trim_count, pressure_count, worst = count_memory_events(e, summary)
        runs.append(
            {
                "generationID": gid,
                "mode": e.get("mode") or "?",
                "modelID": e.get("modelID") or "?",
                "warmState": e.get("warmState") or "?",
                "finishReason": e.get("finishReason"),
                "rtf": derived.get("audioSecondsPerWallSecond"),
                "tokps": derived.get("tokensPerSecond"),
                "audioSec": derived.get("audioSeconds"),
                "ttfcMS": app_timings.get("submitToFirstChunkMS"),
                # UI-responsiveness KPI (app row, MainThreadStallWatchdog):
                # main-thread heartbeat stalls during the generation window.
                "uiStall50": app_counters.get("uiStallCount50"),
                "uiStall250": app_counters.get("uiStallCount250"),
                "uiMaxStallMS": app_counters.get("uiMaxStallMS"),
                "decodeLoopMS": timings.get("qwen_token_loop_total"),
                "peakGpuMB": summary.get("gpuAllocatedPeakMB"),
                "peakRssMB": summary.get("residentPeakMB"),
                # phys_footprint is the figure Jetsam judges on Apple Silicon — the
                # most OOM-relevant peak. headroomMin = closest the process came to
                # exhausting its available memory budget during the run.
                "physFootMB": summary.get("physFootprintPeakMB"),
                "headMinMB": summary.get("headroomMinMB"),
                "compressedMB": summary.get("compressedPeakMB"),
                # Kernel memory-pressure activity during the run (stage marks).
                "trims": trim_count,
                "pressure": pressure_count,
                "worstTrim": worst,
                # Resolved device tier this row ran under (notes.deviceClass) —
                # reveals a forced-tier benchmark and the floor Quality→Speed fallback.
                "deviceClass": (e.get("notes") or {}).get("deviceClass") or "?",
                # Whether the tier was forced via QWENVOICE_FORCE_MEMORY_CLASS (vs the
                # native tier) — so a real 8 GB Mac isn't mislabeled "forced".
                "deviceClassForced": (e.get("notes") or {}).get("deviceClassForced") == "true",
                # Input script length (notes.promptChars) → bucket for the
                # short/medium/long sweep. RTF/decode/KV-cache all scale with it.
                "promptChars": int((e.get("notes") or {}).get("promptChars") or 0),
                "lenBucket": len_bucket(int((e.get("notes") or {}).get("promptChars") or 0)),
                # GPU peak MB at pipeline boundaries (mlxMemoryByStage) — shows WHERE
                # GPU memory grows and how much a trim reclaims.
                "gpuByStage": gpu_peak_by_stage(e.get("mlxMemoryByStage") or {}),
                # Per-stage decode ms (timingsMS) — shows WHERE the decode loop spends
                # wall time (Talker / Code Predictor / Code2Wav / eval). Sums ≈ decode ms.
                "decodeStages": decode_stage_breakdown(timings),
                # Reference-free audio-quality verdict (engine).
                "qcVerdict": qc.get("verdict"),
                "qcFlags": qc.get("flags") or [],
            }
        )
    return runs


# Worst-first ranking of QC verdicts for cell aggregation.
_QC_SEVERITY = {"pass": 0, "warn": 1, "fail": 2}


def cell_qc(group):
    """Worst verdict across a cell + the distinct flags that tripped (compact)."""
    worst, rank = None, -1
    flags = []
    for r in group:
        v = r.get("qcVerdict")
        if v is None:
            continue
        if _QC_SEVERITY.get(v, 0) > rank:
            rank, worst = _QC_SEVERITY.get(v, 0), v
        for f in r.get("qcFlags") or []:
            tag = f.split(":")[0]
            if tag not in flags:
                flags.append(tag)
    if worst is None:
        return "-"
    if worst == "pass":
        return "pass"
    return f"{worst}:{','.join(flags[:2])}" if flags else worst


# Boundary stages we surface for GPU growth, in pipeline order. Each cell takes the
# first stage present (streaming and quality-first paths name them differently).
_GPU_STAGE_GROUPS = [
    ("load", ["after_load", "after_clone_conditioning", "after_prewarm"]),
    ("stream", ["before_stream", "first_chunk", "before_quality_generation"]),
    ("peak", ["after_final_write", "after_stream"]),
    ("trim", ["after_generation_trim"]),
]


def gpu_peak_by_stage(mlx_by_stage):
    """Pick GPU peak MB at each pipeline boundary group from mlxMemoryByStage."""
    out = {}
    for label, candidates in _GPU_STAGE_GROUPS:
        for stage in candidates:
            snap = mlx_by_stage.get(stage)
            if snap and snap.get("peakMB") is not None:
                out[label] = snap.get("peakMB")
                break
    return out


# Top-level decode-loop stages (timingsMS keys) in pipeline order. The engine
# attributes the wall clock of the hot token loop to exactly these stages plus an
# audio-chunk-eval / unattributed remainder (see qwenTokenLoopUnattributedMS in the
# vendored Qwen3TTS.swift), so named stages + "other" sum to qwen_token_loop_total.
# This decomposition answers WHERE decode time goes: the Talker forward, the
# autoregressive 15× Code Predictor loop, the Code2Wav audio decoder, or the
# frame-boundary eval flush.
_DECODE_STAGE_KEYS = [
    ("talker", "qwen_talker_forward_total"),        # Talker (CB0) forward
    ("sampCB0", "qwen_sample_first_codebook_total"),  # sample first codebook
    ("codePred", "qwen_code_predictor_total"),      # 15× Code Predictor loop
    ("code2wav", "qwen_stream_decoder_total"),      # Code2Wav audio decoder
    ("stepEval", "qwen_stream_step_eval_total"),    # per-frame eval flush
]


def decode_stage_breakdown(timings):
    """Per-stage decode ms from timingsMS. 'other' = qwen_token_loop_total minus the
    named stages — it folds the small stages the engine also attributes (codec-embedding
    assembly, EOS read, audio-chunk eval) plus the unattributed remainder, so the row
    sums to the loop total. Returns {} when there is no loop total (e.g. load-only rows)."""
    total = timings.get("qwen_token_loop_total")
    if not total:
        return {}
    out = {}
    named_sum = 0
    for label, key in _DECODE_STAGE_KEYS:
        value = timings.get(key)
        if isinstance(value, (int, float)):
            out[label] = value
            named_sum += value
    out["other"] = max(0, total - named_sum)
    return out


# Worst-first ranking of trim levels for the `trims` column annotation.
_TRIM_SEVERITY = {"fullUnload": 3, "hardTrim": 2, "softTrim": 1}


def count_memory_events(engine_row, summary):
    """Count memory_trim / memory_pressure stage marks and the worst trim level.

    Marks live on the engine row's top-level `stageMarks` (and mirror into
    `summary.stageMarks`); each carries `stage` + `metadata.level`. These are
    written by NativeEngineRuntime.trimMemory (memory_trim) and
    recordMemoryPressureObserved (memory_pressure)."""
    marks = engine_row.get("stageMarks") or summary.get("stageMarks") or []
    trim_count = 0
    pressure_count = 0
    worst_rank = 0
    worst_label = None
    for mark in marks:
        stage = mark.get("stage")
        level = (mark.get("metadata") or {}).get("level")
        if stage == "memory_trim":
            trim_count += 1
            rank = _TRIM_SEVERITY.get(level, 0)
            if rank > worst_rank:
                worst_rank, worst_label = rank, level
        elif stage == "memory_pressure":
            pressure_count += 1
    return trim_count, pressure_count, worst_label


def short_model(model_id):
    """Compact a long model id to its distinguishing tail (e.g. 4bit / 8bit)."""
    if not model_id or model_id == "?":
        return "?"
    tail = model_id.replace("Qwen3-TTS-12Hz-1.7B-", "")
    return tail[:26]


def med(values):
    nums = [v for v in values if isinstance(v, (int, float))]
    return statistics.median(nums) if nums else None


def fmt(value, places=2):
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:.{places}f}"
    return str(value)


def select_headline_cell(cells, requested):
    """Pick the cell to summarize in a ledger row. `requested` is an optional
    'mode/model/state/len' selector (model matched as a substring; len optional).
    Default: a warm + medium-length Custom Voice Quality cell, else any warm
    medium cell, else any warm cell, else the first cell."""
    keys = list(cells.keys())
    if requested:
        parts = requested.split("/")
        want_mode = parts[0] if len(parts) > 0 else ""
        want_model = parts[1] if len(parts) > 1 else ""
        want_state = parts[2] if len(parts) > 2 else ""
        want_len = parts[3] if len(parts) > 3 else ""
        for key in keys:
            mode, model_id, state, lb = key
            if want_mode and mode != want_mode:
                continue
            if want_model and want_model.lower() not in model_id.lower():
                continue
            if want_state and state != want_state:
                continue
            if want_len and lb != want_len:
                continue
            return key
        return None
    # Default preference: custom + quality + warm + medium → any warm+medium →
    # any warm → first.
    for key in keys:
        if key[0] == "custom" and "quality" in key[1].lower() and key[2] == "warm" and key[3] == "medium":
            return key
    for key in keys:
        if key[2] == "warm" and key[3] == "medium":
            return key
    for key in keys:
        if key[2] == "warm":
            return key
    return keys[0] if keys else None


def fmt_ui_stall(group):
    """UI-responsiveness cell: '<stalls>50ms/<max>ms' from the app row's
    MainThreadStallWatchdog counters ('—' when the app row carried none —
    CLI bench runs have no UI, and overlapping generations omit the report)."""
    stalls = med(r["uiStall50"] for r in group)
    max_ms = med(r["uiMaxStallMS"] for r in group)
    if stalls is None and max_ms is None:
        return "—"
    return f"{fmt(stalls, 0)}/{fmt(max_ms, 0)}ms"


def emit_ledger_row(cells, label):
    """Print one Markdown table row for benchmarks/HISTORY.md. Columns match the
    table header seeded in that file."""
    key = select_headline_cell(cells, label.get("cell"))
    if key is None:
        print("| (no rows) |")
        return 1
    mode, model_id, state, lb = key
    group = cells[key]
    cell = f"{mode}/{short_model(model_id)}/{state}/{lb}"
    note = (label.get("note") or "").replace("|", "/")
    cols = [
        today_str(),
        git_short_sha(),
        cell,
        fmt(med(r["rtf"] for r in group)),
        fmt(med(r["tokps"] for r in group)),
        fmt(med(r["ttfcMS"] for r in group), 0),
        fmt(med(r["physFootMB"] for r in group), 0),
        fmt_trims(group),
        cell_qc(group),
        note or "—",
        # UI-responsiveness KPI (added 2026-06; trailing so older rows stay
        # aligned). "—" for CLI bench rows (no UI process).
        fmt(med(r["uiMaxStallMS"] for r in group), 0),
    ]
    print("| " + " | ".join(cols) + " |")
    return 0


def main():
    parser = argparse.ArgumentParser(description="Summarize per-generation telemetry.")
    parser.add_argument("diag_dir", nargs="?", default=DEFAULT_DIR,
                        help="diagnostics dir (default: QwenVoice-Debug/diagnostics)")
    parser.add_argument("--label", default="",
                        help="free-form note stamped on the output / ledger row")
    parser.add_argument("--ledger-row", action="store_true",
                        help="print ONE Markdown row for benchmarks/HISTORY.md instead of the table")
    parser.add_argument("--cell", default="",
                        help="ledger cell selector 'mode/model/state' (model = substring)")
    args = parser.parse_args()
    diag_dir = args.diag_dir

    runs = load_runs(diag_dir)
    if not runs:
        print(f"No telemetry rows under {diag_dir}/engine/generations.jsonl")
        print("Run the benchmark first (see docs/reference/telemetry-and-benchmarking.md).")
        return 1

    # Group by (mode, modelID, warmState, lenBucket).
    cells = defaultdict(list)
    for run in runs:
        cells[(run["mode"], run["modelID"], run["warmState"], run["lenBucket"])].append(run)

    if args.ledger_row:
        return emit_ledger_row(cells, {"note": args.label, "cell": args.cell})

    stamp = f"{today_str()} · {git_short_sha()}"
    if args.label:
        stamp += f" · {args.label}"
    print(f"\n[{stamp}]")

    header = (
        f"{'mode':<8} {'model':<26} {'state':<5} {'len':<6} {'n':>2} "
        f"{'RTF':>6} {'tok/s':>7} {'TTFC ms':>8} {'decode ms':>9} "
        f"{'peakGPU':>8} {'physFoot':>8} {'trims':>9} {'UIstall':>9} {'QC':<12}"
    )
    tiers = sorted({r["deviceClass"] for r in runs})
    forced = any(r["deviceClassForced"] for r in runs)
    print(f"\nTelemetry summary — {diag_dir}")
    print(f"({len(runs)} runs across {len(cells)} cells; warm shows median)")
    print(f"tier: {', '.join(tiers)}"
          + ("   ⚠ forced (QWENVOICE_FORCE_MEMORY_CLASS)" if forced else "")
          + "\n")
    print(header)
    print("-" * len(header))

    cell_sort = lambda k: (k[0], short_model(k[1]), k[2] != "cold", LEN_ORDER.get(k[3], 9))
    for key in sorted(cells.keys(), key=cell_sort):
        mode, model_id, state, lb = key
        group = cells[key]
        n = len(group)
        print(
            f"{mode:<8} {short_model(model_id):<26} {state:<5} {lb:<6} {n:>2} "
            f"{fmt(med(r['rtf'] for r in group)):>6} "
            f"{fmt(med(r['tokps'] for r in group)):>7} "
            f"{fmt(med(r['ttfcMS'] for r in group), 0):>8} "
            f"{fmt(med(r['decodeLoopMS'] for r in group), 0):>9} "
            f"{fmt(med(r['peakGpuMB'] for r in group), 0):>8} "
            f"{fmt(med(r['physFootMB'] for r in group), 0):>8} "
            f"{fmt_trims(group):>9} "
            f"{fmt_ui_stall(group):>9} "
            f"{cell_qc(group):<12}"
        )

    # GPU memory by pipeline stage (peak MB) — shows WHERE GPU memory grows and how
    # much the post-generation trim reclaims. Median over each cell's runs.
    gpu_header = (
        f"{'mode':<8} {'model':<26} {'state':<5} {'len':<6} "
        f"{'load':>8} {'stream':>8} {'peak':>8} {'trim':>8}"
    )
    print("\nGPU MB by stage (peak; median over cell) — mlxMemoryByStage\n")
    print(gpu_header)
    print("-" * len(gpu_header))
    for key in sorted(cells.keys(), key=cell_sort):
        mode, model_id, state, lb = key
        group = cells[key]
        print(
            f"{mode:<8} {short_model(model_id):<26} {state:<5} {lb:<6} "
            f"{fmt(med(r['gpuByStage'].get('load') for r in group), 0):>8} "
            f"{fmt(med(r['gpuByStage'].get('stream') for r in group), 0):>8} "
            f"{fmt(med(r['gpuByStage'].get('peak') for r in group), 0):>8} "
            f"{fmt(med(r['gpuByStage'].get('trim') for r in group), 0):>8}"
        )

    # Decode-loop breakdown (ms per stage; median over cell) — from timingsMS. Answers
    # WHERE decode wall time goes: Talker forward vs the autoregressive 15× Code Predictor
    # loop vs the Code2Wav audio decoder vs the frame-boundary eval flush. Named stages +
    # "other" sum to the decode ms column (qwen_token_loop_total).
    dec_header = (
        f"{'mode':<8} {'model':<26} {'state':<5} {'len':<6} "
        f"{'talker':>7} {'sampCB0':>7} {'codePred':>8} {'code2wav':>8} {'stepEval':>8} {'other':>7}"
    )
    print("\nDecode breakdown (ms; median over cell) — timingsMS (named + other ≈ decode ms)\n")
    print(dec_header)
    print("-" * len(dec_header))
    for key in sorted(cells.keys(), key=cell_sort):
        mode, model_id, state, lb = key
        group = cells[key]
        print(
            f"{mode:<8} {short_model(model_id):<26} {state:<5} {lb:<6} "
            f"{fmt(med(r['decodeStages'].get('talker') for r in group), 0):>7} "
            f"{fmt(med(r['decodeStages'].get('sampCB0') for r in group), 0):>7} "
            f"{fmt(med(r['decodeStages'].get('codePred') for r in group), 0):>8} "
            f"{fmt(med(r['decodeStages'].get('code2wav') for r in group), 0):>8} "
            f"{fmt(med(r['decodeStages'].get('stepEval') for r in group), 0):>8} "
            f"{fmt(med(r['decodeStages'].get('other') for r in group), 0):>7}"
        )

    print(
        "\nRTF = audioSeconds / wallSeconds (>1 faster than realtime). "
        "tok/s = codec tokens/s. TTFC = submit→first chunk. "
        "decode ms = qwen_token_loop_total. peakGPU/physFoot/GPU-stage = MB."
    )
    print(
        "Decode breakdown (ms, median): talker = qwen_talker_forward_total · "
        "sampCB0 = qwen_sample_first_codebook_total · codePred = qwen_code_predictor_total "
        "(15× loop) · code2wav = qwen_stream_decoder_total (audio decoder) · "
        "stepEval = qwen_stream_step_eval_total · other = remainder (codec-embedding "
        "assembly + EOS read + audio-chunk eval + unattributed). Named + other ≈ decode ms."
    )
    print(
        "⚠ These are Swift-side wall-clock timers around LAZY MLX ops, not per-stage GPU "
        "compute. talker/codePred measure graph-BUILD time; the single per-frame eval() makes "
        "stepEval the fused compute of Talker+CodePredictor+sampling. code2wav≈0 because the "
        "decoder is asyncEval'd (Phase 2c) and overlaps the token loop — pipelined, not free. "
        "To attribute compute per stage, capture the os_signpost intervals (Talker Forward / "
        "Code Predictor Loop / Step Eval Flush / Audio Decoder) under Instruments xctrace."
    )
    print(
        "physFoot = phys_footprint peak (the figure Jetsam judges — the OOM-relevant "
        "peak; peakRSS + headMin are in the records too). trims = median memory_trim "
        "count [worst level]; raw kernel pressure also recorded as memory_pressure marks."
    )
    print(
        "QC = reference-free audio defect verdict (pass / warn / fail:flags — "
        "nonfinite/clipping/clicks/dropout/near_silent). It does not judge subtle "
        "perceptual quality — that needs the listening pass (see telemetry doc)."
    )
    return 0


def fmt_trims(group):
    """Median memory_trim count for the cell, annotated with the worst level seen."""
    count = med(r["trims"] for r in group)
    worst = None
    worst_rank = 0
    for r in group:
        rank = _TRIM_SEVERITY.get(r.get("worstTrim"), 0)
        if rank > worst_rank:
            worst_rank, worst = rank, r["worstTrim"]
    if count is None:
        return "-"
    label = f"{int(count)}"
    if worst:
        # soft/hard/full — short tag keeps the column narrow.
        label += f" {worst.replace('Trim', '').replace('Unload', '')[:4]}"
    return label


if __name__ == "__main__":
    raise SystemExit(main())
