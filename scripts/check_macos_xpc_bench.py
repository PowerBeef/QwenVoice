#!/usr/bin/env python3
"""Gate script for macOS XPC UI benchmark telemetry (post native XCUITest benchmark).

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


def expected_cells(modes: list[str], lengths: list[str], warm: int) -> list[str]:
    cells: list[str] = []
    cold_len = "medium" if "medium" in lengths else lengths[0]
    for mode in modes:
        if mode != "clone":
            cells.append(f"{mode}/{cold_len}/cold#0")
        for length in lengths:
            for repetition in range(warm):
                cells.append(f"{mode}/{length}/warm#{repetition}")
    return cells


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


def audio_qc_failure(row: dict) -> str | None:
    output = row.get("outputMetrics") or {}
    qc = row.get("audioQC") or output.get("audioQC") or {}
    verdict = qc.get("verdict")
    if verdict in {"pass", "warn"}:
        return None
    if verdict == "fail":
        return f"failed: {qc.get('flags') or []}"
    return f"verdict is missing or invalid: {verdict!r}"


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
    expected_cell_order = expected_cells(modes, lengths, args.warm)

    engine_path = os.path.join(diag, "engine", "generations.jsonl")
    service_path = os.path.join(diag, "engine-service", "generations.jsonl")
    app_path = os.path.join(diag, "app", "generations.jsonl")
    merged_path = os.path.join(diag, "generations-merged.jsonl")

    engine_rows = filter_since(read_jsonl(engine_path), args.since_recorded)
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

    engine_id_list = [r.get("generationID") for r in engine_rows]
    if any(not value for value in engine_id_list):
        failures.append("one or more engine rows has no generationID")
    if len(set(engine_id_list)) != len(engine_id_list):
        failures.append("engine generationIDs are not unique")
    engine_ids = {value for value in engine_id_list if value}
    for layer, rows in (("engine-service", service_rows), ("app", app_rows)):
        layer_id_list = [r.get("generationID") for r in rows]
        if any(not value for value in layer_id_list):
            failures.append(f"one or more {layer} rows has no generationID")
        if len(set(layer_id_list)) != len(layer_id_list):
            failures.append(f"{layer} generationIDs are not unique")
        layer_ids = {value for value in layer_id_list if value}
        missing = engine_ids - layer_ids
        if missing:
            failures.append(f"{layer} missing {len(missing)} generationID(s) present in engine")

    merged_ids = {r.get("generationID") for r in merged_rows if r.get("generationID")}
    if engine_ids and not merged_ids >= engine_ids:
        failures.append("generations-merged.jsonl missing engine generationIDs")

    actual_cells: list[str] = []
    actual_indices: list[int] = []
    for row in engine_rows:
        notes = row.get("notes") or {}
        cell = notes.get("benchCell")
        if isinstance(cell, str):
            actual_cells.append(cell)
        try:
            actual_indices.append(int(notes.get("benchTakeIndex")))
        except (TypeError, ValueError):
            failures.append(f"generation {row.get('generationID', '?')} has no valid benchTakeIndex")
        finish = row.get("finishReason")
        if finish not in _BENCHMARK_SUCCESS_FINISH:
            failures.append(f"generation {row.get('generationID', '?')} has unsuccessful finishReason={finish!r}")
        if qc_failure := audio_qc_failure(row):
            gid = row.get("generationID", "?")
            failures.append(f"audioQC {qc_failure} for engine generation {gid}")
        output = row.get("outputMetrics") or {}
        if output.get("readableWAV") is not True:
            failures.append(f"generation {row.get('generationID', '?')} did not prove a readable WAV")
        if output.get("atomicallyPublished") is not True:
            failures.append(f"generation {row.get('generationID', '?')} was not atomically published")
        if not isinstance(output.get("durationSeconds"), (int, float)) or output["durationSeconds"] <= 0:
            failures.append(f"generation {row.get('generationID', '?')} has no positive output duration")

    if actual_cells != expected_cell_order:
        failures.append(f"benchmark cell order differs: actual={actual_cells} expected={expected_cell_order}")
    if actual_indices != list(range(1, expected + 1)):
        failures.append(f"benchmark take order differs: actual={actual_indices} expected=1..{expected}")
    for row in engine_rows:
        cell = (row.get("notes") or {}).get("benchCell", "")
        intended = "cold" if "/cold#" in cell else "warm"
        if row.get("warmState") != intended:
            failures.append(
                f"generation {row.get('generationID', '?')} warmState={row.get('warmState')!r} "
                f"does not match cell {cell!r}"
            )

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
