#!/usr/bin/env python3
"""Gate language-bench output verification (Phase 3 — in-app Speech round-trip).

Reads device-diagnostics sentinels stamped with `outputVerification` and checks:
  - verification present and pass=true;
  - expectedLanguage matches matrix expectedHint;
  - no skipReason (Speech permission must be granted on device once).

Usage:
  scripts/check_language_output.py <diagnostics-dir> \\
      --run-id ios-lang-bench-20260706-110143 \\
      --matrix config/language-bench-matrix.json \\
      [--subset quick|full]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

sys.path.insert(0, os.path.dirname(__file__))
from check_language_hints import load_json, select_cells


def find_sentinels(diag: str, run_id: str) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    for root, _dirs, files in os.walk(diag):
        if "device-diagnostics-done.json" not in files:
            continue
        path = os.path.join(root, "device-diagnostics-done.json")
        try:
            record = json.load(open(path, encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if record.get("runID", "").startswith(f"{run_id}--"):
            cell_id = record["runID"][len(run_id) + 2 :]
            out[cell_id] = record
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="Gate language-bench output verification")
    parser.add_argument("diag", help="diagnostics dir (pulled app container mirror)")
    parser.add_argument("--run-id", required=True)
    parser.add_argument(
        "--matrix",
        default=os.path.join(os.path.dirname(__file__), "..", "config", "language-bench-matrix.json"),
    )
    parser.add_argument("--subset", choices=("quick", "full"), default="full")
    args = parser.parse_args()

    matrix = load_json(args.matrix)
    cells = select_cells(matrix, args.subset)
    sentinels = find_sentinels(args.diag, args.run_id)
    output_cells = [c for c in cells if not c.get("skipOutputVerification")]

    failures: list[str] = []
    print(
        f"language-output gate: runID={args.run_id} subset={args.subset} "
        f"expected={len(output_cells)} sentinels={len(sentinels)}"
    )

    for cell in cells:
        cell_id = cell["id"]
        expected_hint = cell["expectedHint"]
        if cell.get("skipOutputVerification"):
            print(f"  {cell_id:<28} (output skipped — hint-only cell)")
            continue
        record = sentinels.get(cell_id)
        if record is None:
            failures.append(f"{cell_id}: missing device-diagnostics sentinel")
            continue
        if record.get("status") != "ok":
            failures.append(f"{cell_id}: device-diagnostics status={record.get('status')!r}")
            continue
        verification = record.get("outputVerification")
        if not isinstance(verification, dict):
            failures.append(
                f"{cell_id}: missing outputVerification "
                "(set QVOICE_IOS_DEVICE_DIAGNOSTICS_VERIFY_OUTPUT=1)"
            )
            continue
        if verification.get("skipReason"):
            failures.append(f"{cell_id}: skipped ({verification.get('skipReason')})")
        if verification.get("expectedLanguage") != expected_hint:
            failures.append(
                f"{cell_id}: expectedLanguage {verification.get('expectedLanguage')!r} "
                f"!= matrix {expected_hint!r}"
            )
        if not verification.get("languagePass"):
            failures.append(
                f"{cell_id}: languagePass=false score={verification.get('languageMatchScore')}"
            )
        if not verification.get("accuracyPass"):
            failures.append(
                f"{cell_id}: accuracyPass=false wer={verification.get('wordErrorRate')}"
            )
        passed = verification.get("pass")
        if passed is None:
            passed = (
                verification.get("languagePass")
                and verification.get("accuracyPass")
                and not verification.get("skipReason")
            )
        if not passed:
            failures.append(f"{cell_id}: pass=false")
        print(
            f"  {cell_id:<28} lang={verification.get('languagePass')} "
            f"wer={verification.get('wordErrorRate')} "
            f"score={verification.get('languageMatchScore')} "
            f"pass={passed}"
        )

    if failures:
        print("FAIL:")
        for item in failures:
            print(f"  - {item}")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
