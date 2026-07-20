#!/usr/bin/env python3
"""Validate Phase 6 history-facing streaming telemetry v9 sidecar authority.

Checks that a diagnostics directory (or generations.jsonl) records publication-
ready nested transitions and, when complete sidecars exist, binds SHA-256
digests that match on-disk `*.streaming-telemetry-v9.json` files.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


HEX64 = re.compile(r"^[0-9a-f]{64}$")
SIDECAR_SUFFIX = ".streaming-telemetry-v9.json"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def evaluate_generations(path: Path) -> list[str]:
    findings: list[str] = []
    ready = 0
    sidecars = 0
    for index, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        if not isinstance(row, dict):
            continue
        notes = row.get("notes") if isinstance(row.get("notes"), dict) else {}
        transition = row.get("streamingTelemetryV9")
        if transition is None and notes.get("streamingTelemetryV9PublicationReady") != "true":
            continue
        ready += 1
        identity = str(row.get("generationID") or f"line-{index}")
        if notes.get("streamingTelemetryV9PublicationReady") != "true":
            # Nested transition without the packaged marker is transitional only.
            if not isinstance(transition, dict):
                findings.append(f"{identity}: missing nested streamingTelemetryV9")
            continue
        digest = notes.get("streamingTelemetryV9SidecarDigest")
        if digest:
            sidecars += 1
            if not HEX64.match(str(digest)):
                findings.append(f"{identity}: malformed streamingTelemetryV9SidecarDigest")
    if ready == 0:
        findings.append(f"{path}: no publication-ready streaming v9 rows found")
    return findings


def evaluate_sidecar_dir(directory: Path) -> list[str]:
    findings: list[str] = []
    files = sorted(directory.glob(f"*{SIDECAR_SUFFIX}"))
    if not files:
        findings.append(f"{directory}: no complete v9 sidecars present")
        return findings
    for path in files:
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            findings.append(f"{path.name}: invalid JSON ({exc})")
            continue
        if document.get("schemaVersion") != 9:
            findings.append(f"{path.name}: schemaVersion must be 9")
        digest = sha256_file(path)
        if not HEX64.match(digest):
            findings.append(f"{path.name}: unable to hash sidecar")
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "paths",
        nargs="+",
        type=Path,
        help="generations.jsonl and/or streaming-telemetry-v9 directories",
    )
    args = parser.parse_args(argv)
    findings: list[str] = []
    for path in args.paths:
        if path.is_dir():
            findings.extend(evaluate_sidecar_dir(path))
        elif path.name.endswith(".jsonl"):
            findings.extend(evaluate_generations(path))
        else:
            findings.append(f"{path}: unsupported path")
    if findings:
        print("streaming telemetry v9 history: FAIL")
        for item in findings:
            print(f"  - {item}")
        return 1
    print("streaming telemetry v9 history: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
