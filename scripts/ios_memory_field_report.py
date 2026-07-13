#!/usr/bin/env python3
"""Summarize already-pulled, bounded iOS memory field evidence.

This command is deliberately local-only. It never calls CoreDevice, Instruments, or
MetricKit and it never copies raw MetricKit payloads into benchmark history. The iOS
app owns collection and privacy reduction; this reader aggregates that allowlisted
output after a normal ``ios_device.sh pull`` or an explicit artifact export.
"""

from __future__ import annotations

import argparse
from datetime import datetime
import json
import math
from pathlib import Path
import sys
from typing import Any, Iterable


SUMMARY_FILENAME = "metrickit-memory-exit-summaries.json"
FOREGROUND_KEYS = {
    "normal",
    "watchdog",
    "memoryResourceLimit",
    "memoryPressure",
    "badAccess",
    "illegalInstruction",
    "abnormal",
}
BACKGROUND_KEYS = FOREGROUND_KEYS | {
    "taskTimeout",
    "cpuResourceLimit",
    "suspendedWithLockedFile",
}
DIAGNOSTIC_KEYS = {
    "crash",
    "hang",
    "cpuException",
    "diskWriteException",
}


class ReportError(RuntimeError):
    pass


def candidate_files(source: Path) -> list[Path]:
    if source.is_file():
        return [source]
    if not source.exists():
        return []
    candidates: list[Path] = []
    for path in source.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in {".json", ".jsonl"}:
            continue
        in_memory_field = "memory-field" in path.parts
        if in_memory_field or path.name == SUMMARY_FILENAME:
            candidates.append(path)
    return sorted(set(candidates))


def load_rows(path: Path) -> list[dict[str, Any]]:
    try:
        if path.suffix.lower() == ".jsonl":
            values = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
        else:
            payload = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(payload, dict) and isinstance(payload.get("records"), list):
                values = payload["records"]
            else:
                values = [payload]
    except (OSError, json.JSONDecodeError) as error:
        raise ReportError(f"invalid local memory field evidence: {path.name}: {error}") from error
    if any(not isinstance(value, dict) for value in values):
        raise ReportError(f"invalid local memory field records: {path.name}")
    return values


def timestamp(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value or len(value) > 64:
        raise ReportError(f"invalid {field} value")
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ReportError(f"invalid {field} timestamp") from error
    return value


def bounded_peak(value: Any) -> float | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ReportError("peakMemoryMB must be numeric")
    result = float(value)
    if not math.isfinite(result) or result < 0:
        raise ReportError("peakMemoryMB must be finite and nonnegative")
    return result


def counter_map(value: Any, allowed: set[str], field: str) -> dict[str, int]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise ReportError(f"{field} must be an object")
    result: dict[str, int] = {}
    for key, count in value.items():
        if key not in allowed:
            continue
        if isinstance(count, bool) or not isinstance(count, int) or count < 0:
            raise ReportError(f"{field}.{key} must be a nonnegative integer")
        result[key] = count
    return result


def add_counts(total: dict[str, int], observed: dict[str, int]) -> None:
    for key, value in observed.items():
        total[key] = total.get(key, 0) + value


def first_mapping(row: dict[str, Any], names: Iterable[str]) -> Any:
    for name in names:
        if name in row:
            return row[name]
    return None


def build_report(source: Path) -> dict[str, Any]:
    paths = candidate_files(source)
    if not paths:
        return {
            "schemaVersion": 1,
            "status": "notYetDelivered",
            "sourceFileCount": 0,
            "recordCount": 0,
            "peakMemoryMB": None,
            "foregroundExitCounts": {},
            "backgroundExitCounts": {},
            "diagnosticCounts": {},
        }

    starts: list[str] = []
    ends: list[str] = []
    peaks: list[float] = []
    foreground: dict[str, int] = {}
    background: dict[str, int] = {}
    diagnostics: dict[str, int] = {}
    record_count = 0
    for path in paths:
        for row in load_rows(path):
            record_count += 1
            if (value := timestamp(row.get("intervalStart"), "intervalStart")) is not None:
                starts.append(value)
            if (value := timestamp(row.get("intervalEnd"), "intervalEnd")) is not None:
                ends.append(value)
            if (value := bounded_peak(row.get("peakMemoryMB"))) is not None:
                peaks.append(value)
            add_counts(
                foreground,
                counter_map(
                    first_mapping(row, ("foregroundExitCounts", "foregroundExits")),
                    FOREGROUND_KEYS,
                    "foregroundExitCounts",
                ),
            )
            add_counts(
                background,
                counter_map(
                    first_mapping(row, ("backgroundExitCounts", "backgroundExits")),
                    BACKGROUND_KEYS,
                    "backgroundExitCounts",
                ),
            )
            add_counts(
                diagnostics,
                counter_map(row.get("diagnosticCounts"), DIAGNOSTIC_KEYS, "diagnosticCounts"),
            )

    return {
        "schemaVersion": 1,
        "status": "available" if record_count else "notYetDelivered",
        "sourceFileCount": len(paths),
        "recordCount": record_count,
        "intervalStart": min(starts) if starts else None,
        "intervalEnd": max(ends) if ends else None,
        "peakMemoryMB": max(peaks) if peaks else None,
        "foregroundExitCounts": dict(sorted(foreground.items())),
        "backgroundExitCounts": dict(sorted(background.items())),
        "diagnosticCounts": dict(sorted(diagnostics.items())),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="already-pulled diagnostics directory or bounded summary file")
    args = parser.parse_args(argv)
    try:
        report = build_report(args.source)
    except ReportError as error:
        print(f"memory-field-report: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2, sort_keys=True))
    if report["status"] == "notYetDelivered":
        print(
            "memory-field-report: no delayed MetricKit memory summary has been delivered yet; "
            "this is diagnostic, not a benchmark failure",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
