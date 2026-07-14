#!/usr/bin/env python3
"""Validate one run-scoped iOS Speech asset bootstrap sentinel."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any


EXPECTED_LOCALES = ["de_DE", "es_419", "ja_JP", "zh_CN"]


class ValidationError(ValueError):
    """The sentinel does not prove the requested Speech readiness contract."""


def load_record(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValidationError("completion evidence is unreadable or invalid JSON") from error
    if not isinstance(payload, dict):
        raise ValidationError("completion evidence must be a JSON object")
    return payload


def validate_record(record: dict[str, Any], *, run_id: str) -> list[dict[str, Any]]:
    if record.get("schemaVersion") != 1:
        raise ValidationError("unexpected schema version")
    if record.get("runID") != run_id:
        raise ValidationError("run identity mismatch")
    if record.get("requestedLocaleIdentifiers") != EXPECTED_LOCALES:
        raise ValidationError("requested locale contract mismatch")

    rows = record.get("locales")
    if not isinstance(rows, list) or len(rows) != len(EXPECTED_LOCALES):
        raise ValidationError("incomplete locale evidence")
    for requested, row in zip(EXPECTED_LOCALES, rows, strict=True):
        if not isinstance(row, dict) or row.get("requestedIdentifier") != requested:
            raise ValidationError("locale ordering mismatch")
        if not isinstance(row.get("resolvedIdentifier"), str):
            raise ValidationError(f"{requested} has no resolved locale")

    modern_ready = (
        record.get("assetInventoryReady") is True
        and record.get("aggregateStatusAfter") == "installed"
        and all(
            row.get("statusAfter") == "installed"
            and row.get("installedLocalePresentAfter") is True
            for row in rows
        )
    )
    if not modern_ready:
        code = record.get("failureCode") or "unknown"
        domain = record.get("failureDomain") or "none"
        value = record.get("failureCodeValue")
        raise ValidationError(
            f"installation failed code={code} domain={domain} value={value}"
        )

    legacy_ready = record.get("vocelloLegacyReady") is True and all(
        isinstance(row.get("legacyRecognizerIdentifier"), str)
        and row.get("legacyRecognizerAvailable") is True
        and row.get("legacySupportsOnDeviceRecognition") is True
        and isinstance(row.get("vocelloSelectedLegacyIdentifier"), str)
        and row.get("vocelloSelectedLegacyAvailable") is True
        and row.get("vocelloSelectedLegacySupportsOnDeviceRecognition") is True
        and row.get("vocelloLegacyReady") is True
        for row in rows
    )
    if not legacy_ready:
        raise ValidationError(
            "assets are installed, but Vocello's legacy on-device recognizer gate is blocked"
        )
    if record.get("status") != "pass":
        raise ValidationError(
            "inconsistent completion verdict "
            f"code={record.get('failureCode') or 'unknown'}"
        )
    return rows


def print_report(rows: list[dict[str, Any]]) -> None:
    print(
        "requested  resolved  status_before -> status_after  installed  "
        "legacy_available  legacy_on_device  vocello_selected"
    )
    for requested, row in zip(EXPECTED_LOCALES, rows, strict=True):
        resolved = row["resolvedIdentifier"]
        before = row.get("statusBefore") or "unknown"
        after = row.get("statusAfter") or "unknown"
        installed = row.get("installedLocalePresentAfter") is True
        available = row.get("legacyRecognizerAvailable") is True
        legacy = row.get("legacySupportsOnDeviceRecognition") is True
        selected = row.get("vocelloSelectedLegacyIdentifier") or "none"
        print(
            f"{requested:9}  {resolved:8}  {before:11} -> {after:11}  "
            f"{str(installed).lower():9}  {str(available).lower():16}  "
            f"{str(legacy).lower():16}  {selected}"
        )
    print("asset_inventory=PASS")
    print("vocello_legacy_gate=PASS")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sentinel", type=Path)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args(argv)
    try:
        rows = validate_record(load_record(args.sentinel), run_id=args.run_id)
    except ValidationError as error:
        print(f"speech-assets: {error}", file=sys.stderr)
        return 1
    print_report(rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
