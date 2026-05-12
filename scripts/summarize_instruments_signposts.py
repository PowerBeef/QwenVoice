#!/usr/bin/env python3
"""Summarize exported xctrace signpost interval XML.

The xctrace XML shape varies a little across Xcode releases, so this parser is
deliberately tolerant: it looks for known QwenVoice signpost names, a
com.qwenvoice subsystem string, and a duration value with units in each row.
If Xcode changes the schema again, the script fails closed instead of
inventing timings.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


KNOWN_INTERVALS = [
    "Native Prepare Generation",
    "Native Quality-First Generation",
    "Native Final Audio Materialize",
    "Native PCM Limiter Convert",
    "Native Final WAV Write",
    "Native Final WAV Manual Header Build",
    "Native Final WAV Manual File Write",
    "Native Final WAV Manual Publish",
    "Native Final WAV Writer Create",
    "Native Final WAV Buffer Build",
    "Native Final WAV AVAudioFile Write",
    "Native Final WAV AVAudioFile Finalize",
    "Native Generation Stream",
    "Native First Audio Chunk",
    "Native Final WAV Finish",
    "Talker Forward",
    "Code Predictor Loop",
    "Step Eval Flush",
    "Audio Decoder",
    "Audio Chunk Eval",
    "XPC Engine Command",
]

DURATION_RE = re.compile(
    r"(?<![A-Za-z0-9_.-])(-?\d+(?:\.\d+)?)\s*(ns|µs|us|ms|s|sec|secs|second|seconds)\b",
    re.IGNORECASE,
)
SUBSYSTEM_RE = re.compile(r"com\.qwenvoice(?:\.[A-Za-z0-9_-]+)*")


def local_name(tag: str) -> str:
    if "}" in tag:
        return tag.rsplit("}", 1)[1]
    return tag


def flatten_values(row: ET.Element) -> list[tuple[str, str]]:
    values: list[tuple[str, str]] = []
    for element in row.iter():
        name = local_name(element.tag)
        text = (element.text or "").strip()
        if text:
            values.append((name, text))
        for key, value in element.attrib.items():
            if value:
                values.append((key, value.strip()))
    return values


def duration_to_ms(value: float, unit: str) -> float:
    normalized = unit.lower()
    if normalized == "ns":
        return value / 1_000_000
    if normalized in {"µs", "us"}:
        return value / 1_000
    if normalized == "ms":
        return value
    return value * 1_000


def find_duration_ms(values: list[tuple[str, str]]) -> float | None:
    preferred: list[float] = []
    fallback: list[float] = []

    for key, value in values:
        for match in DURATION_RE.finditer(value):
            duration = duration_to_ms(float(match.group(1)), match.group(2))
            target = preferred if "duration" in key.lower() or "elapsed" in key.lower() else fallback
            target.append(duration)

    if preferred:
        return preferred[0]
    if fallback:
        return fallback[-1]
    return None


def percentile(sorted_values: list[float], percentile_value: float) -> float:
    if not sorted_values:
        return 0.0
    index = max(0, min(len(sorted_values) - 1, math.ceil(percentile_value * len(sorted_values)) - 1))
    return sorted_values[index]


def summarize(xml_path: Path) -> dict[str, dict[str, object]]:
    root = ET.parse(xml_path).getroot()
    buckets: dict[tuple[str, str], list[float]] = {}
    matched_rows = 0

    for row in root.iter():
        if local_name(row.tag) != "row":
            continue
        values = flatten_values(row)
        joined = " ".join(value for _, value in values)
        interval = next((candidate for candidate in KNOWN_INTERVALS if candidate in joined), None)
        if interval is None:
            continue
        duration = find_duration_ms(values)
        if duration is None:
            continue
        subsystem_match = SUBSYSTEM_RE.search(joined)
        subsystem = subsystem_match.group(0) if subsystem_match else "unknown"
        buckets.setdefault((subsystem, interval), []).append(duration)
        matched_rows += 1

    if matched_rows == 0:
        raise RuntimeError(
            "No known QwenVoice signpost intervals were parsed from the xctrace XML. "
            "Keep the raw trace/XML and inspect the exported schema before deleting it."
        )

    summaries: dict[str, dict[str, object]] = {}
    for (subsystem, interval), durations in sorted(buckets.items()):
        sorted_durations = sorted(durations)
        key = f"{subsystem}::{interval}"
        summaries[key] = {
            "subsystem": subsystem,
            "interval": interval,
            "count": len(durations),
            "total_ms": round(sum(durations), 3),
            "p50_ms": round(statistics.median(durations), 3),
            "p95_ms": round(percentile(sorted_durations, 0.95), 3),
            "max_ms": round(max(durations), 3),
        }
    return summaries


def write_markdown(path: Path, trace_path: str, fixture: str, summaries: dict[str, dict[str, object]]) -> None:
    rows = sorted(
        summaries.values(),
        key=lambda item: (str(item["subsystem"]), str(item["interval"])),
    )
    lines = [
        "# Instruments Signpost Summary",
        "",
        f"Trace: `{trace_path}`",
    ]
    if fixture:
        lines.extend(["", f"Fixture: {fixture}"])
    lines.extend(
        [
            "",
            "| Subsystem | Interval | Count | Total | p50 | p95 | Max |",
            "|---|---:|---:|---:|---:|---:|---:|",
        ]
    )
    for item in rows:
        lines.append(
            "| {subsystem} | {interval} | {count} | {total:.3f} s | {p50:.3f} ms | "
            "{p95:.3f} ms | {max:.3f} ms |".format(
                subsystem=item["subsystem"],
                interval=item["interval"],
                count=item["count"],
                total=float(item["total_ms"]) / 1_000,
                p50=item["p50_ms"],
                p95=item["p95_ms"],
                max=item["max_ms"],
            )
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xml", type=Path, help="Exported xctrace signpost XML")
    parser.add_argument("--trace", default="", help="Original trace bundle path")
    parser.add_argument("--fixture", default="", help="Short fixture description")
    parser.add_argument("--markdown", type=Path, help="Markdown summary output")
    parser.add_argument("--json", type=Path, help="JSON summary output")
    args = parser.parse_args()

    summaries = summarize(args.xml)
    payload = {
        "trace": args.trace,
        "fixture": args.fixture,
        "intervals": summaries,
    }

    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        write_markdown(args.markdown, args.trace, args.fixture, summaries)
    if not args.json and not args.markdown:
        json.dump(payload, sys.stdout, indent=2, sort_keys=True)
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
