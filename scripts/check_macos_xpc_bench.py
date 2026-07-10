#!/usr/bin/env python3
"""Gate script for macOS XPC UI benchmark telemetry (post bench-ui).

Usage:
    python3 scripts/check_macos_xpc_bench.py DIAGNOSTICS_DIR \\
        [--modes custom,design,clone] [--lengths short,medium,long] [--warm 3] \\
        [--max-chunk-gaps 0] [--max-ui-stall50 0]

Exits 0 when layer row counts match the matrix, merged joins exist, audioQC passes,
chunkGaps stay within threshold, and UI stalls are within budget on floor tier rows.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

DEFAULT_MODES = ["custom", "design", "clone"]
DEFAULT_LENGTHS = ["short", "medium", "long"]
DEFAULT_WARM = 3
_BENCHMARK_SUCCESS_FINISH = frozenset({"eos", "max_tokens", "maxTokens", "completed"})


def parse_list(raw: str | None, default: list[str]) -> list[str]:
    if not raw or not raw.strip():
        return default
    return [p.strip() for p in raw.split(",") if p.strip()]


def expected_take_count(modes: list[str], lengths: list[str], warm: int) -> int:
    warm = max(1, warm)
    cold_len = "medium" if "medium" in lengths else (lengths[0] if lengths else None)
    total = 0
    for mode in modes:
        if mode != "clone" and cold_len:
            total += 1
        total += len(lengths) * warm
    return total


def read_jsonl(path: str) -> list[dict]:
    if not os.path.isfile(path):
        return []
    rows = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


def filter_since(rows: list[dict], since_iso: str) -> list[dict]:
    if not since_iso:
        return rows
    return [r for r in rows if (r.get("recordedAt") or "") >= since_iso]


def benchmark_engine_rows(rows: list[dict]) -> list[dict]:
    out = []
    for row in rows:
        finish = row.get("finishReason")
        if finish is not None and finish not in _BENCHMARK_SUCCESS_FINISH:
            continue
        out.append(row)
    return out


def audio_qc_failed(row: dict) -> bool:
    qc = row.get("audioQC") or {}
    if qc.get("passed") is False:
        return True
    if qc.get("ok") is False:
        return True
    status = (qc.get("status") or "").lower()
    return status in {"fail", "failed", "error"}


def filter_run_id(rows: list[dict], run_id: str) -> list[dict]:
    if not run_id:
        return rows
    filtered = []
    for row in rows:
        notes = row.get("notes") or {}
        if notes.get("benchRunID") == run_id:
            filtered.append(row)
    return filtered


def main() -> int:
    parser = argparse.ArgumentParser(description="Gate macOS XPC UI bench telemetry")
    parser.add_argument("diag_dir", help="QwenVoice-Debug/diagnostics directory")
    parser.add_argument("--modes", default=",".join(DEFAULT_MODES))
    parser.add_argument("--lengths", default=",".join(DEFAULT_LENGTHS))
    parser.add_argument("--warm", type=int, default=DEFAULT_WARM)
    parser.add_argument("--run-id", default="", help="prefer rows stamped with notes.benchRunID")
    parser.add_argument("--max-chunk-gaps", type=int, default=0,
                        help="fail if any engine-service row exceeds this chunkGaps count")
    parser.add_argument("--max-ui-stall50", type=int, default=0,
                        help="fail if any floor-tier app row exceeds this uiStallCount50")
    parser.add_argument("--since-recorded", default="",
                        help="only count rows with recordedAt >= this ISO8601 timestamp (UTC)")
    args = parser.parse_args()

    diag = os.path.expanduser(args.diag_dir)
    modes = parse_list(args.modes, DEFAULT_MODES)
    lengths = parse_list(args.lengths, DEFAULT_LENGTHS)
    expected = expected_take_count(modes, lengths, args.warm)

    engine_path = os.path.join(diag, "engine", "generations.jsonl")
    service_path = os.path.join(diag, "engine-service", "generations.jsonl")
    app_path = os.path.join(diag, "app", "generations.jsonl")
    merged_path = os.path.join(diag, "generations-merged.jsonl")

    engine_rows = benchmark_engine_rows(filter_since(read_jsonl(engine_path), args.since_recorded))
    service_rows = filter_since(read_jsonl(service_path), args.since_recorded)
    app_rows = filter_since(read_jsonl(app_path), args.since_recorded)
    merged_rows = filter_since(read_jsonl(merged_path), args.since_recorded)

    if args.run_id:
        engine_rows = filter_run_id(engine_rows, args.run_id)
        service_rows = filter_run_id(service_rows, args.run_id)
        app_rows = filter_run_id(app_rows, args.run_id)
        merged_rows = [r for r in merged_rows if r.get("generationID") in {
            row.get("generationID") for row in engine_rows if row.get("generationID")
        }]

    failures: list[str] = []

    if len(engine_rows) != expected:
        failures.append(f"engine rows {len(engine_rows)} != expected {expected}")
    if len(service_rows) != expected:
        failures.append(f"engine-service rows {len(service_rows)} != expected {expected}")
    if len(app_rows) != expected:
        failures.append(f"app rows {len(app_rows)} != expected {expected}")
    if len(merged_rows) != expected:
        failures.append(f"merged rows {len(merged_rows)} != expected {expected}")

    engine_ids = {r.get("generationID") for r in engine_rows if r.get("generationID")}
    for layer, rows in (("engine-service", service_rows), ("app", app_rows)):
        layer_ids = {r.get("generationID") for r in rows if r.get("generationID")}
        missing = engine_ids - layer_ids
        if missing:
            failures.append(f"{layer} missing {len(missing)} generationID(s) present in engine")

    merged_ids = {r.get("generationID") for r in merged_rows if r.get("generationID")}
    if engine_ids and not merged_ids >= engine_ids:
        failures.append("generations-merged.jsonl missing engine generationIDs")

    for row in engine_rows:
        if audio_qc_failed(row):
            gid = row.get("generationID", "?")
            failures.append(f"audioQC failed for engine generation {gid}")

    for row in service_rows:
        gaps = (row.get("counters") or {}).get("chunkGaps")
        if gaps is not None and gaps > args.max_chunk_gaps:
            gid = row.get("generationID", "?")
            failures.append(f"chunkGaps {gaps} > {args.max_chunk_gaps} (generation {gid})")

    app_by_id = {r.get("generationID"): r for r in app_rows if r.get("generationID")}
    for er in engine_rows:
        gid = er.get("generationID")
        if not gid:
            continue
        device = (er.get("notes") or {}).get("deviceClass") or ""
        if device != "floor8GBMac":
            continue
        app_row = app_by_id.get(gid) or {}
        stalls = (app_row.get("counters") or {}).get("uiStallCount50")
        if stalls is not None and stalls > args.max_ui_stall50:
            failures.append(f"uiStallCount50 {stalls} > {args.max_ui_stall50} on floor tier (generation {gid})")

    print(f"XPC bench gate: expected={expected} engine={len(engine_rows)} "
          f"service={len(service_rows)} app={len(app_rows)} merged={len(merged_rows)}")

    if failures:
        print("FAIL:")
        for item in failures:
            print(f"  - {item}")
        return 1

    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
