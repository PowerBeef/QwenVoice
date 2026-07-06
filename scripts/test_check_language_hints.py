#!/usr/bin/env python3
"""Offline fixture tests for scripts/check_language_hints.py (no device)."""

import json
import os
import subprocess
import sys
import tempfile
import unittest


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CHECK = os.path.join(ROOT, "scripts", "check_language_hints.py")
MATRIX = os.path.join(ROOT, "config", "language-bench-matrix.json")
CORPUS = os.path.join(ROOT, "config", "language-bench-corpus.json")


def write_fixture(diag: str, run_id: str) -> None:
    engine_dir = os.path.join(diag, "engine")
    os.makedirs(engine_dir, exist_ok=True)
    quick_cells = [
        ("custom-en-pinned", "custom", "english"),
        ("custom-en-auto", "custom", "english"),
        ("design-en-auto", "design", "english"),
        ("custom-fr-pinned", "custom", "french"),
        ("custom-fr-auto", "custom", "french"),
        ("design-fr-auto", "design", "french"),
        ("custom-fr-text-en-pinned", "custom", "english"),
    ]
    rows = []
    for cell_id, mode, hint in quick_cells:
        rows.append(
            {
                "mode": mode,
                "finishReason": "completed",
                "notes": {
                    "benchRunID": run_id,
                    "benchCell": cell_id,
                    "languageHint": hint,
                },
                "audioQC": {"verdict": "pass"},
            }
        )
    with open(os.path.join(engine_dir, "generations.jsonl"), "w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row) + "\n")


class CheckLanguageHintsTests(unittest.TestCase):
    def test_quick_subset_passes_fixture(self) -> None:
        run_id = "fixture-run"
        with tempfile.TemporaryDirectory() as diag:
            write_fixture(diag, run_id)
            proc = subprocess.run(
                [
                    sys.executable,
                    CHECK,
                    diag,
                    "--run-id",
                    run_id,
                    "--matrix",
                    MATRIX,
                    "--corpus",
                    CORPUS,
                    "--subset",
                    "quick",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_wrong_hint_fails(self) -> None:
        run_id = "fixture-bad"
        with tempfile.TemporaryDirectory() as diag:
            write_fixture(diag, run_id)
            path = os.path.join(diag, "engine", "generations.jsonl")
            text = open(path, encoding="utf-8").read().replace('"languageHint": "english"', '"languageHint": "french"', 1)
            open(path, "w", encoding="utf-8").write(text)
            proc = subprocess.run(
                [
                    sys.executable,
                    CHECK,
                    diag,
                    "--run-id",
                    run_id,
                    "--matrix",
                    MATRIX,
                    "--corpus",
                    CORPUS,
                    "--subset",
                    "quick",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("languageHint", proc.stdout + proc.stderr)


if __name__ == "__main__":
    unittest.main()
