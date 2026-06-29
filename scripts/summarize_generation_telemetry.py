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
from dataclasses import dataclass, field

DEFAULT_DIR = os.path.expanduser(
    "~/Library/Application Support/QwenVoice-Debug/diagnostics"
)

# Engine rows with these finishReason values are omitted from benchmark medians
# (failed/superseded/cancelled runs would skew RTF and memory aggregates).
_BENCHMARK_SUCCESS_FINISH_REASONS = frozenset({
    "eos",
    "max_tokens",
    "maxTokens",
    "completed",
})


def _engine_row_counts_for_benchmark(row):
    """True when an engine JSONL row should contribute to benchmark aggregates."""
    finish = row.get("finishReason")
    if finish is None:
        return True  # legacy rows without finishReason
    return finish in _BENCHMARK_SUCCESS_FINISH_REASONS


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


def iter_jsonl(path):
    """Lazy stream of decoded JSON objects from a JSONL file."""
    if not os.path.exists(path):
        return
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def read_jsonl(path):
    """Eager load of a JSONL file; kept for callers that need a list."""
    return list(iter_jsonl(path))


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


def load_prosody(diag_dir):
    """Load bench-prosody.json sidecar, if present. Returns list of rows."""
    path = os.path.join(diag_dir, "bench-prosody.json")
    if not os.path.exists(path):
        return []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return []


def prosody_for_delivery(prosody_rows, mode, model_id, delivery):
    """Median prosody effect and supporting deltas for a delivery cell."""
    rows = [
        r for r in prosody_rows
        if r["mode"] == mode and r["model"] == model_id and r["delivery"] == delivery
    ]
    if not rows:
        return None
    return {
        "effect": med(r["prosodyEffect"] for r in rows),
        "dF0Std": med(r["dF0Std"] for r in rows),
        "dRateCV": med(r["dRateCV"] for r in rows),
        "dPauseRatio": med(r["dPauseRatio"] for r in rows),
        "dRoughness": med(r["dRoughness"] for r in rows),
        "n": len(rows),
    }


def first_stage_mark_ms(record, stage):
    for mark in record.get("stageMarks", []):
        if mark.get("stage") == stage:
            return mark.get("tMS")
    return None


def load_merged_runs(diag_dir):
    """Load generations-merged.jsonl and join per-layer first-chunk marks."""
    path = os.path.join(diag_dir, "generations-merged.jsonl")
    rows = read_jsonl(path)
    runs = []
    for row in rows:
        app = row.get("app") or {}
        engine = row.get("engine") or {}
        engine_service = row.get("engineService") or {}
        run = {
            "generationID": row.get("generationID"),
            "appTTFCMS": (app.get("timingsMS") or {}).get("submitToFirstChunkMS"),
            "engineFirstChunkMS": first_stage_mark_ms(engine, "firstChunk"),
            "engineServiceFirstChunkMS": first_stage_mark_ms(engine_service, "firstChunk"),
        }
        if run["appTTFCMS"] is not None and run["engineFirstChunkMS"] is not None:
            run["frontendOverheadMS"] = run["appTTFCMS"] - run["engineFirstChunkMS"]
        runs.append(run)
    return runs


def _app_index(diag_dir):
    """Stream app/generations.jsonl and keep only the fields needed for joining."""
    index = {}
    for a in iter_jsonl(os.path.join(diag_dir, "app", "generations.jsonl")):
        gid = a.get("generationID")
        if gid is None:
            continue
        index[gid] = {
            "timingsMS": a.get("timingsMS") or {},
            "counters": a.get("counters") or {},
        }
    return index


def _engine_run(e, app_lookup):
    """Build one per-run dict from an engine row + joined app row."""
    derived = e.get("derivedMetrics") or {}
    timings = e.get("timingsMS") or {}
    summary = e.get("summary") or {}
    a = app_lookup.get(e.get("generationID")) or {}
    app_timings = a.get("timingsMS") or {}
    app_counters = a.get("counters") or {}
    qc = e.get("audioQC") or {}
    trim_count, pressure_count, worst = count_memory_events(e, summary)
    run = {
        "generationID": e.get("generationID"),
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
        "gpuWsRatioPeak": summary.get("gpuWorkingSetUsageRatioPeak"),
        "thermalWorst": (e.get("thermalState") or {}).get("worst"),
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
        # Bench delivery-cell id (notes.delivery, preset id)
        # for instruct-bearing takes from `vocello bench --delivery`.
        # Empty for plain matrix takes; delivery rows are segregated into
        # their own block so the headline cells stay comparable.
        "delivery": (e.get("notes") or {}).get("delivery") or "",
        # GPU peak MB at pipeline boundaries (mlxMemoryByStage) — shows WHERE
        # GPU memory grows and how much a trim reclaims.
        "gpuByStage": gpu_peak_by_stage(e.get("mlxMemoryByStage") or {}),
        # Per-stage decode ms (timingsMS) — shows WHERE the decode loop spends
        # wall time (Talker / Code Predictor / Code2Wav / eval). Sums ≈ decode ms.
        "decodeStages": decode_stage_breakdown(timings),
        # Streaming chunk timeline — per-cell medians of first-chunk arrival,
        # inter-chunk interval, and the per-chunk substage latencies.
        "chunkCount": None,
        "firstChunkArrivalMS": None,
        "medianInterChunkMS": None,
        **{f"chunk_{key}": None for key in _CHUNK_SUBSTAGE_KEYS},
        **{f"mimi_{key}": None for key in _MIMI_DECODER_KEYS},
        # Reference-free audio-quality verdict (engine).
        "qcVerdict": qc.get("verdict"),
        "qcFlags": qc.get("flags") or [],
    }
    chunks = e.get("chunkTimeline") or []
    if chunks:
        run["chunkCount"] = len(chunks)
        run["firstChunkArrivalMS"] = chunks[0]["arrivalMS"]
        run["medianInterChunkMS"] = med(
            chunks[i]["arrivalMS"] - chunks[i - 1]["arrivalMS"]
            for i in range(1, len(chunks))
        )
        for key in _CHUNK_SUBSTAGE_KEYS:
            run[f"chunk_{key}"] = med(c[key] for c in chunks if key in c)
        for key in _MIMI_DECODER_KEYS:
            values = [
                c.get("mimiDecoderBreakdownMS", {}).get(key)
                for c in chunks
                if c.get("mimiDecoderBreakdownMS")
            ]
            run[f"mimi_{key}"] = med(values) if values else None
    return run


def load_runs(diag_dir):
    """Join engine + app rows by generationID. Returns list of per-run dicts."""
    app_lookup = _app_index(diag_dir)
    return [
        _engine_run(e, app_lookup)
        for e in iter_jsonl(os.path.join(diag_dir, "engine", "generations.jsonl"))
        if _engine_row_counts_for_benchmark(e)
    ]


@dataclass
class CellAccumulator:
    """Streaming accumulator for one benchmark cell's aggregate metrics."""

    key: tuple
    rtfs: list = field(default_factory=list)
    tokpss: list = field(default_factory=list)
    ttfcs: list = field(default_factory=list)
    decode_loop_ms: list = field(default_factory=list)
    peak_gpu_mb: list = field(default_factory=list)
    phys_foot_mb: list = field(default_factory=list)
    head_min_mb: list = field(default_factory=list)
    gpu_ws_ratio_peaks: list = field(default_factory=list)
    thermal_worsts: list = field(default_factory=list)
    trims: list = field(default_factory=list)
    worst_trims: list = field(default_factory=list)
    ui_stalls: list = field(default_factory=list)
    ui_max_stalls: list = field(default_factory=list)
    qc_verdicts: list = field(default_factory=list)
    qc_flags: set = field(default_factory=set)
    chunk_counts: list = field(default_factory=list)
    first_chunk_arrivals: list = field(default_factory=list)
    median_inter_chunks: list = field(default_factory=list)
    chunk_substage_values: dict = field(default_factory=lambda: defaultdict(list))
    mimi_decoder_values: dict = field(default_factory=lambda: defaultdict(list))
    gpu_by_stage: dict = field(default_factory=lambda: defaultdict(list))
    decode_stages: dict = field(default_factory=lambda: defaultdict(list))

    def add_run(self, run: dict) -> None:
        """Ingest one run into the accumulator's lists."""
        if run.get("rtf") is not None:
            self.rtfs.append(run["rtf"])
        if run.get("tokps") is not None:
            self.tokpss.append(run["tokps"])
        if run.get("ttfcMS") is not None:
            self.ttfcs.append(run["ttfcMS"])
        if run.get("decodeLoopMS") is not None:
            self.decode_loop_ms.append(run["decodeLoopMS"])
        if run.get("peakGpuMB") is not None:
            self.peak_gpu_mb.append(run["peakGpuMB"])
        if run.get("physFootMB") is not None:
            self.phys_foot_mb.append(run["physFootMB"])
        if run.get("headMinMB") is not None:
            self.head_min_mb.append(run["headMinMB"])
        if run.get("gpuWsRatioPeak") is not None:
            self.gpu_ws_ratio_peaks.append(run["gpuWsRatioPeak"])
        if run.get("thermalWorst") is not None:
            self.thermal_worsts.append(run["thermalWorst"])
        if run.get("trims") is not None:
            self.trims.append(run["trims"])
        if run.get("worstTrim") is not None:
            self.worst_trims.append(run["worstTrim"])
        if run.get("uiStall50") is not None:
            self.ui_stalls.append(run["uiStall50"])
        if run.get("uiMaxStallMS") is not None:
            self.ui_max_stalls.append(run["uiMaxStallMS"])
        if run.get("qcVerdict") is not None:
            self.qc_verdicts.append(run["qcVerdict"])
        for f in run.get("qcFlags") or []:
            self.qc_flags.add(f.split(":")[0])
        if run.get("chunkCount") is not None:
            self.chunk_counts.append(run["chunkCount"])
        if run.get("firstChunkArrivalMS") is not None:
            self.first_chunk_arrivals.append(run["firstChunkArrivalMS"])
        if run.get("medianInterChunkMS") is not None:
            self.median_inter_chunks.append(run["medianInterChunkMS"])
        for key in _CHUNK_SUBSTAGE_KEYS:
            v = run.get(f"chunk_{key}")
            if v is not None:
                self.chunk_substage_values[key].append(v)
        for key in _MIMI_DECODER_KEYS:
            v = run.get(f"mimi_{key}")
            if v is not None:
                self.mimi_decoder_values[key].append(v)
        for label, values in (run.get("gpuByStage") or {}).items():
            if values is not None:
                self.gpu_by_stage[label].append(values)
        for label, value in (run.get("decodeStages") or {}).items():
            if value is not None:
                self.decode_stages[label].append(value)

    def finalize(self) -> dict:
        """Return a JSON-serializable summary dict for this cell."""
        mode, model_id, state, bucket = self.key
        # Worst QC verdict across the cell.
        worst_qc, qc_rank = None, -1
        for v in self.qc_verdicts:
            rank = _QC_SEVERITY.get(v, 0)
            if rank > qc_rank:
                qc_rank, worst_qc = rank, v
        if worst_qc is None:
            qc = "-"
        elif worst_qc == "pass":
            qc = "pass"
        else:
            flags = sorted(self.qc_flags)
            qc = f"{worst_qc}:{','.join(flags[:2])}" if flags else worst_qc

        # Worst trim level across the cell.
        worst_trim, worst_rank = None, 0
        for level in self.worst_trims:
            rank = _TRIM_SEVERITY.get(level, 0)
            if rank > worst_rank:
                worst_rank, worst_trim = rank, level

        return {
            "key": self.key,
            "mode": mode,
            "modelID": model_id,
            "warmState": state,
            "lenBucket": bucket,
            "delivery": None,
            "n": len(self.rtfs) or len(self.tokpss) or len(self.ttfcs),
            "rtf": med(self.rtfs),
            "tokps": med(self.tokpss),
            "ttfcMS": med(self.ttfcs),
            "decodeLoopMS": med(self.decode_loop_ms),
            "peakGpuMB": med(self.peak_gpu_mb),
            "physFootMB": med(self.phys_foot_mb),
            "headMinMB": med(self.head_min_mb),
            "gpuWsRatioPeak": med(self.gpu_ws_ratio_peaks),
            "thermalWorst": _worst_thermal(self.thermal_worsts),
            "rtfIQR": iqr(self.rtfs),
            "physFootIQR": iqr(self.phys_foot_mb),
            "trims": med(self.trims),
            "worstTrim": worst_trim,
            "uiStall50": med(self.ui_stalls),
            "uiMaxStallMS": med(self.ui_max_stalls),
            "qcVerdict": qc,
            "qcFlags": sorted(self.qc_flags),
            "chunkCount": med(self.chunk_counts),
            "firstChunkArrivalMS": med(self.first_chunk_arrivals),
            "medianInterChunkMS": med(self.median_inter_chunks),
            "chunkSubstageMS": {
                key: med(values) for key, values in self.chunk_substage_values.items()
            },
            "mimiDecoderBreakdownMS": {
                key: med(values) for key, values in self.mimi_decoder_values.items()
            },
            "gpuByStage": {
                label: med(values) for label, values in self.gpu_by_stage.items()
            },
            "decodeStages": {
                label: med(values) for label, values in self.decode_stages.items()
            },
        }


def aggregate_runs(diag_dir):
    """Stream engine + app rows and aggregate them into finalized cell summaries.

    Returns (runs, cells, delivery_cells, skipped_failed) where `runs` is the
    materialized list of per-run dicts, and the cell dicts are keyed by
    (mode, modelID, warmState, bucket) with delivery cells keyed by
    (mode, modelID, warmState, delivery). Rows with finishReason
    failed/superseded/cancelled are omitted from aggregates.
    """
    app_lookup = _app_index(diag_dir)
    accumulators = {}
    delivery_accumulators = {}
    runs = []
    skipped_failed = 0
    for e in iter_jsonl(os.path.join(diag_dir, "engine", "generations.jsonl")):
        if not _engine_row_counts_for_benchmark(e):
            skipped_failed += 1
            continue
        run = _engine_run(e, app_lookup)
        runs.append(run)
        if run.get("delivery"):
            key = (run["mode"], run["modelID"], run["warmState"], run["delivery"])
            acc = delivery_accumulators.setdefault(key, CellAccumulator(key=key))
        else:
            key = (run["mode"], run["modelID"], run["warmState"], run["lenBucket"])
            acc = accumulators.setdefault(key, CellAccumulator(key=key))
        acc.add_run(run)
    cells = {k: v.finalize() for k, v in accumulators.items()}
    delivery_cells = {}
    for key, acc in delivery_accumulators.items():
        summary = acc.finalize()
        summary["lenBucket"] = None
        summary["delivery"] = key[3]
        delivery_cells[key] = summary
    return runs, cells, delivery_cells, skipped_failed


# Worst-first ranking of QC verdicts for cell aggregation.
_QC_SEVERITY = {"pass": 0, "warn": 1, "fail": 2}

_THERMAL_SEVERITY = {
    "nominal": 0,
    "fair": 1,
    "serious": 2,
    "critical": 3,
}


def _worst_thermal(states):
    """Return the worst thermal state label seen in a cell."""
    if not states:
        return None
    worst, rank = None, -1
    for state in states:
        if state is None:
            continue
        r = _THERMAL_SEVERITY.get(state, 0)
        if r > rank:
            rank, worst = r, state
    return worst


def cell_qc(group):
    """Worst verdict across a cell + the distinct flags that tripped (compact).

    Accepts either a list of run dicts (legacy) or a finalized cell summary dict."""
    if isinstance(group, dict):
        return group.get("qcVerdict") or "-"
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


# Per-chunk substage keys written by the engine into chunkTimeline. Used for both
# placeholder initialization and aggregate extraction in load_runs().
_CHUNK_SUBSTAGE_KEYS = [
    "talkerForwardMS",
    "codePredictorMS",
    "streamStepEvalMS",
    "audioDecoderMS",
]

# Phase 4 per-frame Mimi decoder step-breakdown keys written into
# chunkTimeline[].mimiDecoderBreakdownMS.
_MIMI_DECODER_KEYS = [
    "quantizerMS",
    "preConvMS",
    "preTransformerMS",
    "upsampleMS",
    "initConvMS",
    "decoderBlocksMS",
    "outputSnakeMS",
    "outputConvMS",
    "totalMS",
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


def _quartiles(nums):
    """Return (Q1, Q3) for a sorted numeric list using the median-of-halves method."""
    if len(nums) < 2:
        return None, None
    q1 = statistics.median(nums[:len(nums) // 2])
    q3 = statistics.median(nums[(len(nums) + 1) // 2:])
    return q1, q3


def iqr(values):
    nums = sorted(v for v in values if isinstance(v, (int, float)))
    q1, q3 = _quartiles(nums)
    if q1 is None or q3 is None:
        return None
    return q3 - q1


def mad(values):
    nums = [v for v in values if isinstance(v, (int, float))]
    if not nums:
        return None
    median_value = statistics.median(nums)
    return statistics.median(abs(x - median_value) for x in nums)


def reject_outliers(values, factor=1.5):
    """Return sorted values inside the Tukey fence (factor * IQR beyond Q1/Q3).

    factor=1.5 is the conventional Tukey fence for outlier detection.
    A minimum of 4 numeric samples is required before filtering; below that the
    sorted input is returned unchanged because quartiles are unstable.
    """
    nums = sorted(v for v in values if isinstance(v, (int, float)))
    if len(nums) < 4:
        # Too few samples for a stable IQR-based filter.
        return nums
    q1, q3 = _quartiles(nums)
    spread = q3 - q1
    lo = q1 - factor * spread
    hi = q3 + factor * spread
    return [x for x in nums if lo <= x <= hi]


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
    CLI bench runs have no UI, and overlapping generations omit the report).

    Accepts either a list of run dicts (legacy) or a finalized cell summary dict."""
    if isinstance(group, dict):
        stalls = group.get("uiStall50")
        max_ms = group.get("uiMaxStallMS")
    else:
        stalls = med(r["uiStall50"] for r in group)
        max_ms = med(r["uiMaxStallMS"] for r in group)
    if stalls is None and max_ms is None:
        return "—"
    return f"{fmt(stalls, 0)}/{fmt(max_ms, 0)}ms"


def format_ledger_row(cells, label):
    """Return one Markdown table row for benchmarks/HISTORY.md, or None if no headline cell."""
    key = select_headline_cell(cells, label.get("cell"))
    if key is None:
        return None
    mode, model_id, state, lb = key
    summary = cells[key]
    cell = f"{mode}/{short_model(model_id)}/{state}/{lb}"
    note = (label.get("note") or "").replace("|", "/")
    cols = [
        today_str(),
        git_short_sha(),
        cell,
        fmt(summary["rtf"]),
        fmt(summary["tokps"]),
        fmt(summary["ttfcMS"], 0),
        fmt(summary["physFootMB"], 0),
        fmt_trims(summary),
        cell_qc(summary),
        note or "—",
        fmt(summary["uiMaxStallMS"], 0),
    ]
    return "| " + " | ".join(cols) + " |"


def emit_ledger_row(cells, label):
    """Print one Markdown table row for benchmarks/HISTORY.md. Columns match the
    table header seeded in that file. `cells` is a dict of finalized cell summaries."""
    row = format_ledger_row(cells, label)
    if row is None:
        print("| (no rows) |")
        return 1
    print(row)
    return 0


def build_summary(cells):
    """Build a JSON-serializable summary of per-cell medians for baseline save/compare.

    `cells` is a dict of finalized cell summaries (as returned by aggregate_runs)."""
    summary = []
    for key, s in cells.items():
        mode, model_id, state, lb = key
        summary.append(
            {
                "cellKey": [mode, model_id, state, lb],
                "mode": mode,
                "modelID": model_id,
                "warmState": state,
                "lenBucket": lb,
                "n": s["n"],
                "rtf": s["rtf"],
                "tokps": s["tokps"],
                "ttfcMS": s["ttfcMS"],
                "physFootMB": s["physFootMB"],
                "qcVerdict": cell_qc(s),
            }
        )
    return summary


def compare_summaries(baseline, current, threshold=0.05):
    """Return regression entries where current is worse than baseline by > threshold.

    A regression is:
      - rtf increased by > threshold
      - tokps decreased by > threshold
      - ttfcMS increased by > threshold
      - physFootMB increased by > threshold
      - qcVerdict worsened (pass -> warn/fail, warn -> fail)
    """
    baseline_by_key = {tuple(b["cellKey"]): b for b in baseline}
    current_by_key = {tuple(c["cellKey"]): c for c in current}
    regressions = []
    for key, cur in current_by_key.items():
        base = baseline_by_key.get(key)
        if base is None:
            continue
        for metric, direction in [
            ("rtf", "up"),
            ("ttfcMS", "up"),
            ("physFootMB", "up"),
            ("tokps", "down"),
        ]:
            b = base.get(metric)
            c = cur.get(metric)
            if b is None or c is None or b == 0:
                continue
            delta = (c - b) / b
            is_regression = (
                (direction == "up" and delta > threshold)
                or (direction == "down" and -delta > threshold)
            )
            if is_regression:
                regressions.append(
                    {
                        "cellKey": key,
                        "metric": metric,
                        "baseline": b,
                        "current": c,
                        "delta": delta,
                    }
                )
        b_qc = base.get("qcVerdict")
        c_qc = cur.get("qcVerdict")
        if b_qc and c_qc and b_qc != "-":
            b_sev = _QC_SEVERITY.get(b_qc.split(":")[0], 0)
            c_sev = _QC_SEVERITY.get(c_qc.split(":")[0], 0)
            if c_sev > b_sev:
                regressions.append(
                    {
                        "cellKey": key,
                        "metric": "qcVerdict",
                        "baseline": b_qc,
                        "current": c_qc,
                    }
                )
    return regressions


def print_regressions(regressions):
    """Print a Markdown-aligned table of detected regressions."""
    if not regressions:
        print("\nNo regressions detected against baseline.")
        return
    print(f"\n⚠ Regressions detected ({len(regressions)} cell-metrics exceeded threshold):")
    header = (
        f"{'mode':<8} {'model':<26} {'state':<5} {'len':<6} "
        f"{'metric':<12} {'baseline':>10} {'current':>10} {'delta':>10}"
    )
    print(header)
    print("-" * len(header))
    for r in regressions:
        mode, model_id, state, lb = r["cellKey"]
        baseline = r.get("baseline")
        current = r.get("current")
        if isinstance(baseline, float):
            baseline_str = f"{baseline:.3f}"
        else:
            baseline_str = str(baseline) if baseline is not None else "-"
        if isinstance(current, float):
            current_str = f"{current:.3f}"
        else:
            current_str = str(current) if current is not None else "-"
        delta_str = f"{r['delta']:+.2%}" if "delta" in r else "-"
        print(
            f"{mode:<8} {short_model(model_id):<26} {state:<5} {lb:<6} "
            f"{r['metric']:<12} {baseline_str:>10} {current_str:>10} {delta_str:>10}"
        )


def print_merged_table(merged_runs):
    """Print cross-layer first-chunk latency table from generations-merged.jsonl."""
    if not merged_runs:
        return
    header = (
        f"{'generationID':<16} {'appTTFCMS':>11} "
        f"{'engineServiceFirstChunkMS':>26} {'engineFirstChunkMS':>20} "
        f"{'frontendOverheadMS':>18}"
    )
    print("\nCross-layer first-chunk latency (ms)\n")
    print(header)
    print("-" * len(header))
    for run in merged_runs:
        print(
            f"{run['generationID']:<16} {fmt(run['appTTFCMS'], 0):>11} "
            f"{fmt(run['engineServiceFirstChunkMS'], 0):>26} "
            f"{fmt(run['engineFirstChunkMS'], 0):>20} "
            f"{fmt(run.get('frontendOverheadMS'), 0):>18}"
        )


def main():
    parser = argparse.ArgumentParser(description="Summarize per-generation telemetry.")
    parser.add_argument("diag_dir", nargs="?", default=DEFAULT_DIR,
                        help="diagnostics dir (default: QwenVoice-Debug/diagnostics)")
    parser.add_argument("--label", default="",
                        help="free-form note stamped on the output / ledger row")
    parser.add_argument("--ledger-row", action="store_true",
                        help="print ONE Markdown row for benchmarks/HISTORY.md instead of the table")
    parser.add_argument("--emit-ledger-row", action="store_true",
                        help="after the full table, print a # ledger-row marker and one HISTORY row")
    parser.add_argument("--cell", default="",
                        help="ledger cell selector 'mode/model/state' (model = substring)")
    parser.add_argument("--show-variance", action="store_true",
                        help="include IQR columns for RTF and physFoot in the summary table")
    parser.add_argument("--merged", action="store_true",
                        help="show cross-layer first-chunk latency from generations-merged.jsonl")
    parser.add_argument("--save-baseline", metavar="PATH",
                        help="write current summary as JSON baseline")
    parser.add_argument("--compare-baseline", metavar="PATH",
                        help="compare to saved baseline and highlight regressions")
    parser.add_argument("--regress-threshold", type=float, default=0.05,
                        help="relative delta threshold for regression (default 0.05)")
    args = parser.parse_args()
    diag_dir = args.diag_dir

    runs, cells, delivery_cells, skipped_failed = aggregate_runs(diag_dir)
    if not runs:
        print(f"No telemetry rows under {diag_dir}/engine/generations.jsonl")
        print("Run the benchmark first (see docs/reference/telemetry-and-benchmarking.md).")
        return 1
    if skipped_failed:
        print(f"(skipped {skipped_failed} non-success engine row(s) with finishReason failed/superseded/cancelled)")
    prosody_rows = load_prosody(diag_dir)

    if args.ledger_row:
        return emit_ledger_row(cells, {"note": args.label, "cell": args.cell})

    if args.save_baseline:
        summary = build_summary(cells)
        with open(args.save_baseline, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=2)

    stamp = f"{today_str()} · {git_short_sha()}"
    if args.label:
        stamp += f" · {args.label}"
    print(f"\n[{stamp}]")

    variance_cols = ""
    if args.show_variance:
        variance_cols = f" {'RTF_IQR':>7} {'physFoot_IQR':>12}"
    header = (
        f"{'mode':<8} {'model':<26} {'state':<5} {'len':<6} {'n':>2} "
        f"{'RTF':>6} {'tok/s':>7} {'TTFC ms':>8} {'decode ms':>9} "
        f"{'peakGPU':>8} {'physFoot':>8} {'headMin':>8} {'gpuWS':>6} {'thermal':<8} "
        f"{'trims':>9} {'UIstall':>9} {'QC':<12}"
        + variance_cols
    )
    tiers = sorted({r["deviceClass"] for r in runs})
    forced = any(r["deviceClassForced"] for r in runs)
    print(f"\nTelemetry summary — {diag_dir}")
    print(f"({len(runs)} runs across {len(cells) + len(delivery_cells)} cells; warm shows median)")
    print(f"tier: {', '.join(tiers)}"
          + ("   ⚠ forced (QWENVOICE_FORCE_MEMORY_CLASS)" if forced else "")
          + "\n")
    print(header)
    print("-" * len(header))

    cell_sort = lambda k: (k[0], short_model(k[1]), k[2] != "cold", LEN_ORDER.get(k[3], 9))
    for key in sorted(cells.keys(), key=cell_sort):
        mode, model_id, state, lb = key
        summary = cells[key]
        n = summary["n"]
        row = (
            f"{mode:<8} {short_model(model_id):<26} {state:<5} {lb:<6} {n:>2} "
            f"{fmt(summary['rtf']):>6} "
            f"{fmt(summary['tokps']):>7} "
            f"{fmt(summary['ttfcMS'], 0):>8} "
            f"{fmt(summary['decodeLoopMS'], 0):>9} "
            f"{fmt(summary['peakGpuMB'], 0):>8} "
            f"{fmt(summary['physFootMB'], 0):>8} "
            f"{fmt(summary.get('headMinMB'), 0):>8} "
            f"{fmt(summary.get('gpuWsRatioPeak')):>6} "
            f"{(summary.get('thermalWorst') or '-'):<8} "
            f"{fmt_trims(summary):>9} "
            f"{fmt_ui_stall(summary):>9} "
            f"{cell_qc(summary):<12}"
        )
        if args.show_variance:
            row += (
                f" {fmt(summary.get('rtfIQR')):>7} "
                f"{fmt(summary.get('physFootIQR'), 0):>12}"
            )
        print(row)

    # Delivery cells (vocello bench --delivery): instruct-bearing takes, keyed by
    # the delivery preset id instead of the length bucket (they all run the medium
    # text). Kept out of the tables above so the headline matrix stays comparable;
    # QC + the listening pass are the point of these rows.
    if delivery_cells:
        has_prosody = bool(prosody_rows)
        d_header = (
            f"{'mode':<8} {'model':<26} {'state':<5} {'delivery':<16} {'n':>2} "
            f"{'RTF':>6} {'tok/s':>7} {'decode ms':>9} {'physFoot':>8} {'QC':<12}"
            + (f" {'prosN':>5} {'prosEff':>8} {'dF0Std':>7} {'dRateCV':>8} {'dPauseR':>8} {'dRough':>7}" if has_prosody else "")
        )
        print("\nDelivery cells (--delivery; medium text, instruct-bearing) — notes.delivery\n")
        print(d_header)
        print("-" * len(d_header))
        d_sort = lambda k: (k[0], short_model(k[1]), k[2] != "cold", k[3])
        for key in sorted(delivery_cells.keys(), key=d_sort):
            mode, model_id, state, delivery = key
            summary = delivery_cells[key]
            base = (
                f"{mode:<8} {short_model(model_id):<26} {state:<5} {delivery:<16} {summary['n']:>2} "
                f"{fmt(summary['rtf']):>6} "
                f"{fmt(summary['tokps']):>7} "
                f"{fmt(summary['decodeLoopMS'], 0):>9} "
                f"{fmt(summary['physFootMB'], 0):>8} "
                f"{cell_qc(summary):<12}"
            )
            if has_prosody:
                p = prosody_for_delivery(prosody_rows, mode, model_id, delivery)
                if p:
                    base += (
                        f" {p['n']:>5} {p['effect']:>+8.2f} {p['dF0Std']:>+7.2f} "
                        f"{p['dRateCV']:>+8.3f} {p['dPauseRatio']:>+8.3f} {p['dRoughness']:>+7.3f}"
                    )
                else:
                    base += "     -        -       -        -        -       -"
            print(base)

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
        summary = cells[key]
        gpu = summary.get("gpuByStage") or {}
        print(
            f"{mode:<8} {short_model(model_id):<26} {state:<5} {lb:<6} "
            f"{fmt(gpu.get('load'), 0):>8} "
            f"{fmt(gpu.get('stream'), 0):>8} "
            f"{fmt(gpu.get('peak'), 0):>8} "
            f"{fmt(gpu.get('trim'), 0):>8}"
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
        summary = cells[key]
        dec = summary.get("decodeStages") or {}
        print(
            f"{mode:<8} {short_model(model_id):<26} {state:<5} {lb:<6} "
            f"{fmt(dec.get('talker'), 0):>7} "
            f"{fmt(dec.get('sampCB0'), 0):>7} "
            f"{fmt(dec.get('codePred'), 0):>8} "
            f"{fmt(dec.get('code2wav'), 0):>8} "
            f"{fmt(dec.get('stepEval'), 0):>8} "
            f"{fmt(dec.get('other'), 0):>7}"
        )

    # Streaming chunk timeline (cells that actually have chunkTimeline data).
    # Medians over cell: chunk count, first-chunk arrival, inter-chunk gap, and the
    # per-chunk substage latencies (Talker / Code Predictor / step eval / decoder).
    chunk_cells = {
        k: s for k, s in cells.items()
        if s.get("chunkCount") is not None
    }
    if chunk_cells:
        chunk_header = (
            f"{'mode':<8} {'model':<26} {'state':<5} {'len':<6} "
            f"{'nChunks':>7} {'firstChunkMS':>12} {'medianInterChunkMS':>18} "
            f"{'talker':>7} {'codePred':>8} {'stepEval':>8} {'audioDecoder':>12}"
        )
        print("\nChunk timeline summary (streaming cells; median over cell)\n")
        print(chunk_header)
        print("-" * len(chunk_header))
        for key in sorted(chunk_cells.keys(), key=cell_sort):
            mode, model_id, state, lb = key
            summary = chunk_cells[key]
            cs = summary.get("chunkSubstageMS") or {}
            print(
                f"{mode:<8} {short_model(model_id):<26} {state:<5} {lb:<6} "
                f"{fmt(summary['chunkCount'], 0):>7} "
                f"{fmt(summary['firstChunkArrivalMS'], 0):>12} "
                f"{fmt(summary['medianInterChunkMS'], 0):>18} "
                f"{fmt(cs.get('talkerForwardMS'), 0):>7} "
                f"{fmt(cs.get('codePredictorMS'), 0):>8} "
                f"{fmt(cs.get('streamStepEvalMS'), 0):>8} "
                f"{fmt(cs.get('audioDecoderMS'), 0):>12}"
            )

    # Per-frame Mimi decoder step breakdown (cells that emitted step timings).
    mimi_cells = {
        k: s for k, s in cells.items()
        if (s.get("mimiDecoderBreakdownMS") or {})
    }
    if mimi_cells:
        mimi_header = (
            f"{'mode':<8} {'model':<26} {'state':<5} {'len':<6} "
            f"{'quant':>6} {'preC':>5} {'preT':>5} {'upsm':>5} "
            f"{'initC':>5} {'blocks':>6} {'snake':>6} {'outC':>5} {'total':>6}"
        )
        print("\nMimi decoder breakdown per frame (ms; median over cell)\n")
        print(mimi_header)
        print("-" * len(mimi_header))
        for key in sorted(mimi_cells.keys(), key=cell_sort):
            mode, model_id, state, lb = key
            summary = mimi_cells[key]
            md = summary.get("mimiDecoderBreakdownMS") or {}
            print(
                f"{mode:<8} {short_model(model_id):<26} {state:<5} {lb:<6} "
                f"{fmt(md.get('quantizerMS'), 0):>6} "
                f"{fmt(md.get('preConvMS'), 0):>5} "
                f"{fmt(md.get('preTransformerMS'), 0):>5} "
                f"{fmt(md.get('upsampleMS'), 0):>5} "
                f"{fmt(md.get('initConvMS'), 0):>5} "
                f"{fmt(md.get('decoderBlocksMS'), 0):>6} "
                f"{fmt(md.get('outputSnakeMS'), 0):>6} "
                f"{fmt(md.get('outputConvMS'), 0):>5} "
                f"{fmt(md.get('totalMS'), 0):>6}"
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
    if prosody_rows:
        print(
            "Delivery prosody: prosEff = signed prosody-effect score vs paired neutral "
            "(+F0 dynamics +rate variability -pauses +roughness). Requires `vocello bench --delivery`."
        )

    if args.merged:
        merged_runs = load_merged_runs(diag_dir)
        if merged_runs:
            print_merged_table(merged_runs)
        else:
            print("\nNo generations-merged.jsonl found; cross-layer table skipped.")

    if args.compare_baseline:
        with open(args.compare_baseline, "r", encoding="utf-8") as f:
            baseline = json.load(f)
        current = build_summary(cells)
        regressions = compare_summaries(baseline, current, threshold=args.regress_threshold)
        print_regressions(regressions)
        if regressions:
            return 2

    if args.emit_ledger_row:
        row = format_ledger_row(cells, {"note": args.label, "cell": args.cell})
        print("\n# ledger-row")
        if row is None:
            print("| (no rows) |")
            return 1
        print(row)

    return 0


def fmt_trims(group):
    """Median memory_trim count for the cell, annotated with the worst level seen.

    Accepts either a list of run dicts (legacy) or a finalized cell summary dict."""
    if isinstance(group, dict):
        count = group.get("trims")
        worst = group.get("worstTrim")
    else:
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
