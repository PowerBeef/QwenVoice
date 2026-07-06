#!/usr/bin/env python3
"""Gate language-bench telemetry (Phase 2 — hint contract, no ASR).

Validates pulled engine rows for one language-bench run:
  - one row per matrix cell (notes.benchRunID + notes.benchCell);
  - notes.languageHint matches the matrix expected resolved hint;
  - generation finished successfully;
  - audioQC is not a hard fail.

Usage:
  scripts/check_language_hints.py <diagnostics-dir> \\
      --run-id ios-lang-bench-20260705-120000 \\
      --matrix config/language-bench-matrix.json \\
      --corpus config/language-bench-corpus.json \\
      [--subset quick|full]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any


def load_json(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def corpus_scripts(corpus: dict[str, Any]) -> dict[str, str]:
    out: dict[str, str] = {}
    for entry in corpus.get("languages") or []:
        lang_id = entry.get("id")
        script = entry.get("script")
        if isinstance(lang_id, str) and isinstance(script, str):
            out[lang_id] = script
    return out


def select_cells(matrix: dict[str, Any], subset: str) -> list[dict[str, Any]]:
    cells = matrix.get("cells") or []
    if subset == "full":
        return list(cells)
    if subset == "quick":
        return [c for c in cells if c.get("quick")]
    raise SystemExit(f"unknown subset '{subset}' (use quick | full)")


def qc_verdict(row: dict[str, Any]) -> str:
    qc = row.get("audioQC")
    if not isinstance(qc, dict):
        return "-"
    verdict = qc.get("verdict")
    if isinstance(verdict, str):
        return verdict
    flags = qc.get("flags")
    if isinstance(flags, list) and flags:
        return "fail:" + ",".join(str(f) for f in flags)
    return "pass"


def finish_ok(row: dict[str, Any]) -> bool:
    reason = row.get("finishReason")
    if reason in (None, "completed", "complete", "done"):
        return True
    if isinstance(reason, str) and reason.lower() in {"completed", "complete", "done", "ok"}:
        return True
    # Some rows omit finishReason on success — treat missing as ok when audioQC passes.
    return reason is None


def read_engine_rows(diag: str, run_id: str) -> list[dict[str, Any]]:
    engine_path = os.path.join(diag, "engine", "generations.jsonl")
    if not os.path.isfile(engine_path):
        # Pulled iOS mirror may nest under an extra directory level.
        for root, _dirs, files in os.walk(diag):
            if "generations.jsonl" in files and root.endswith(os.path.join("engine")):
                engine_path = os.path.join(root, "generations.jsonl")
                break
    if not os.path.isfile(engine_path):
        raise FileNotFoundError(engine_path)

    rows: list[dict[str, Any]] = []
    with open(engine_path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            notes = row.get("notes") or {}
            if notes.get("benchRunID") == run_id:
                rows.append(row)
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description="Gate language-bench languageHint telemetry")
    parser.add_argument("diag", help="diagnostics dir containing engine/generations.jsonl")
    parser.add_argument("--run-id", required=True)
    parser.add_argument(
        "--matrix",
        default=os.path.join(os.path.dirname(__file__), "..", "config", "language-bench-matrix.json"),
    )
    parser.add_argument(
        "--corpus",
        default=os.path.join(os.path.dirname(__file__), "..", "config", "language-bench-corpus.json"),
    )
    parser.add_argument("--subset", choices=("quick", "full"), default="full")
    args = parser.parse_args()

    matrix = load_json(args.matrix)
    corpus = load_json(args.corpus)
    scripts = corpus_scripts(corpus)
    cells = select_cells(matrix, args.subset)

    missing_scripts = sorted({c["scriptLang"] for c in cells if c.get("scriptLang") not in scripts})
    if missing_scripts:
        print(f"FAIL: corpus missing scriptLang ids: {', '.join(missing_scripts)}", file=sys.stderr)
        return 1

    try:
        rows = read_engine_rows(args.diag, args.run_id)
    except FileNotFoundError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1

    by_cell: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        notes = row.get("notes") or {}
        cell_id = notes.get("benchCell")
        if isinstance(cell_id, str):
            by_cell.setdefault(cell_id, []).append(row)

    failures: list[str] = []
    print(
        f"language-hint gate: runID={args.run_id} subset={args.subset} "
        f"expected={len(cells)} engine={len(rows)}"
    )

    for cell in cells:
        cell_id = cell["id"]
        expected_hint = cell["expectedHint"]
        matched = by_cell.get(cell_id, [])
        if len(matched) != 1:
            failures.append(f"{cell_id}: expected 1 row, got {len(matched)}")
            continue
        row = matched[0]
        notes = row.get("notes") or {}
        actual_hint = notes.get("languageHint")
        if actual_hint != expected_hint:
            failures.append(
                f"{cell_id}: languageHint '{actual_hint}' != expected '{expected_hint}'"
            )
        if row.get("mode") != cell.get("mode"):
            failures.append(
                f"{cell_id}: mode '{row.get('mode')}' != expected '{cell.get('mode')}'"
            )
        if not finish_ok(row):
            failures.append(
                f"{cell_id}: finishReason={row.get('finishReason')!r}"
            )
        verdict = qc_verdict(row)
        if verdict.startswith("fail"):
            failures.append(f"{cell_id}: audioQC {verdict}")
        print(
            f"  {cell_id:<28} hint={actual_hint!s:<10} "
            f"mode={row.get('mode', '?'):<8} QC={verdict}"
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
