#!/usr/bin/env python3
"""Validate Phase 5 promotion-packaged sampling evidence in telemetry notes.

Accepts one or more engine generations.jsonl paths, or JSON objects that embed
notes with sampling* fields. Fail closed unless algorithm v2 seeds agree and a
64-hex WAV digest is present with samplingPromotionPackaged=true.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


HEX64 = re.compile(r"^[0-9a-f]{64}$")


def _notes_from_row(row: dict[str, Any]) -> dict[str, str] | None:
    notes = row.get("notes")
    if isinstance(notes, dict):
        return {str(k): str(v) for k, v in notes.items()}
    return None


def evaluate_notes(notes: dict[str, str], identity: str) -> list[str]:
    findings: list[str] = []
    if notes.get("samplingPromotionPackaged") != "true":
        findings.append(f"{identity}: samplingPromotionPackaged must be true")
    if notes.get("samplingAlgorithmVersion") != "2":
        findings.append(f"{identity}: samplingAlgorithmVersion must be 2")
    planned = notes.get("samplingPlannedSeed")
    observed = notes.get("samplingObservedSeed") or notes.get("samplingSeed")
    if not planned:
        findings.append(f"{identity}: missing samplingPlannedSeed")
    if not observed:
        findings.append(f"{identity}: missing samplingObservedSeed")
    if planned and observed and planned != observed:
        findings.append(f"{identity}: planned/observed seed mismatch")
    digest = notes.get("samplingWAVDigest")
    if not digest:
        findings.append(f"{identity}: missing samplingWAVDigest")
    elif not HEX64.match(digest):
        findings.append(f"{identity}: malformed samplingWAVDigest")
    if notes.get("samplingSeedAgreement") not in {None, "matched"}:
        findings.append(f"{identity}: samplingSeedAgreement must be matched")
    return findings


def evaluate_path(path: Path) -> list[str]:
    findings: list[str] = []
    text = path.read_text(encoding="utf-8")
    if path.suffix == ".jsonl":
        packaged = 0
        for index, line in enumerate(text.splitlines(), start=1):
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if not isinstance(row, dict):
                continue
            notes = _notes_from_row(row)
            if not notes or "samplingWAVDigest" not in notes:
                continue
            packaged += 1
            gid = str(row.get("generationID") or f"line-{index}")
            findings.extend(evaluate_notes(notes, f"{path.name}:{gid}"))
        if packaged == 0:
            findings.append(f"{path}: no sampling WAV digests found")
        return findings

    payload = json.loads(text)
    if isinstance(payload, dict) and isinstance(payload.get("notes"), dict):
        return evaluate_notes(
            {str(k): str(v) for k, v in payload["notes"].items()},
            path.name,
        )
    findings.append(f"{path}: unsupported evidence shape")
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args(argv)
    findings: list[str] = []
    for path in args.paths:
        findings.extend(evaluate_path(path))
    if findings:
        print("sampling promotion evidence: FAIL")
        for item in findings:
            print(f"  - {item}")
        return 1
    print("sampling promotion evidence: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
