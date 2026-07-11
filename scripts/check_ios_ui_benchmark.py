#!/usr/bin/env python3
"""Validate one physical-iPhone XCUITest benchmark from pulled engine telemetry."""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import sys

DEFAULT_MODES = ["custom", "design", "clone"]
DEFAULT_LENGTHS = ["short", "medium", "long"]
SUCCESS_FINISH = {"eos", "max_tokens", "maxTokens", "completed"}


def parse_list(raw: str, allowed: list[str], kind: str) -> list[str]:
    values = [value.strip() for value in raw.split(",") if value.strip()]
    if not values or len(values) != len(set(values)):
        raise ValueError(f"{kind} list must be non-empty and unique")
    unknown = set(values) - set(allowed)
    if unknown:
        raise ValueError(f"unknown {kind}: {', '.join(sorted(unknown))}")
    return values


def length_bucket(chars: int) -> str:
    if chars < 70:
        return "short"
    if chars >= 140:
        return "long"
    return "medium"


def expected_ordered_cells(
    modes: list[str], lengths: list[str], warm: int
) -> list[tuple[str, str, str]]:
    cells: list[tuple[str, str, str]] = []
    cold_length = "medium" if "medium" in lengths else lengths[0]
    for mode in modes:
        if mode != "clone":
            cells.append((mode, cold_length, "cold"))
        for length in lengths:
            cells.extend((mode, length, "warm") for _ in range(warm))
    return cells


def load_rows(path: Path, run_id: str) -> list[dict]:
    rows: list[dict] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        try:
            row = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if (row.get("notes") or {}).get("benchRunID") == run_id:
            rows.append(row)
    return rows


def output_failure(row: dict) -> str | None:
    output = row.get("outputMetrics") or {}
    qc = row.get("audioQC") or output.get("audioQC") or {}
    if row.get("finishReason") not in SUCCESS_FINISH:
        return f"unsuccessful finishReason={row.get('finishReason')!r}"
    if output.get("readableWAV") is not True:
        return "outputMetrics.readableWAV is not true"
    if output.get("atomicallyPublished") is not True:
        return "outputMetrics.atomicallyPublished is not true"
    if not isinstance(output.get("durationSeconds"), (int, float)) or output["durationSeconds"] <= 0:
        return "output duration is missing or non-positive"
    verdict = qc.get("verdict")
    if verdict not in {"pass", "warn"}:
        if verdict == "fail":
            return f"audioQC failed: {qc.get('flags') or []}"
        return f"audioQC verdict is missing or invalid: {verdict!r}"
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("diagnostics", type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--modes", default=",".join(DEFAULT_MODES))
    parser.add_argument("--lengths", default=",".join(DEFAULT_LENGTHS))
    parser.add_argument("--warm", type=int, default=3)
    args = parser.parse_args()

    try:
        modes = parse_list(args.modes, DEFAULT_MODES, "mode")
        lengths = parse_list(args.lengths, DEFAULT_LENGTHS, "length")
    except ValueError as error:
        parser.error(str(error))
    if args.warm < 1:
        parser.error("--warm must be at least 1")

    path = args.diagnostics / "engine" / "generations.jsonl"
    if not path.is_file():
        print(f"FAIL: missing {path}", file=sys.stderr)
        return 1
    rows = load_rows(path, args.run_id)
    expected_order = expected_ordered_cells(modes, lengths, args.warm)
    expected = Counter(expected_order)
    failures: list[str] = []

    generation_ids = [row.get("generationID") for row in rows]
    if len(rows) != sum(expected.values()):
        failures.append(f"engine rows {len(rows)} != expected {sum(expected.values())}")
    if any(not value for value in generation_ids):
        failures.append("one or more engine rows has no generationID")
    if len(set(generation_ids)) != len(generation_ids):
        failures.append("engine generationIDs are not unique")

    actual: Counter[tuple[str, str, str]] = Counter()
    actual_order: list[tuple[str, str, str]] = []
    for row in rows:
        notes = row.get("notes") or {}
        try:
            chars = int(notes.get("promptChars", "0"))
        except (TypeError, ValueError):
            chars = 0
        cell = (row.get("mode") or "?", length_bucket(chars), row.get("warmState") or "?")
        actual[cell] += 1
        actual_order.append(cell)
        if failure := output_failure(row):
            failures.append(f"{row.get('generationID', '?')}: {failure}")

    if actual != expected:
        failures.append(f"cell distribution mismatch: actual={dict(actual)} expected={dict(expected)}")
    if actual_order != expected_order:
        failures.append(f"cell order mismatch: actual={actual_order} expected={expected_order}")

    print(f"iOS XCUITest benchmark: runID={args.run_id} rows={len(rows)} expected={sum(expected.values())}")
    for cell in sorted(actual):
        print(f"  {'/'.join(cell):<28} n={actual[cell]}")
    if failures:
        print("FAIL:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
