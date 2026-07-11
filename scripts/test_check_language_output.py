#!/usr/bin/env python3
"""Offline fixture tests for scripts/check_language_output.py (no device)."""

import json
import os
import subprocess
import sys
import tempfile
import unittest


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CHECK = os.path.join(ROOT, "scripts", "check_language_output.py")
MATRIX = os.path.join(ROOT, "config", "language-bench-matrix.json")

QUICK_CELLS = (
    ("custom-en-pinned", "english"),
    ("custom-en-auto", "english"),
    ("design-en-auto", "english"),
    ("custom-fr-pinned", "french"),
    ("custom-fr-auto", "french"),
    ("design-fr-auto", "french"),
)


def write_fixture(diag: str, run_id: str, *, mismatch: bool = False) -> None:
    for index, (cell_id, expected_language) in enumerate(QUICK_CELLS):
        directory = os.path.join(diag, cell_id)
        os.makedirs(directory, exist_ok=True)
        if mismatch and index == 0:
            expected_language = "french"
        record = {
            "runID": f"{run_id}--{cell_id}",
            "status": "ok",
            "outputVerification": {
                "expectedLanguage": expected_language,
                "languagePass": True,
                "accuracyPass": True,
                "languageMatchScore": 1.0,
                "wordErrorRate": 0.0,
                "pass": True,
            },
        }
        with open(os.path.join(directory, "device-diagnostics-done.json"), "w", encoding="utf-8") as fh:
            json.dump(record, fh)


class CheckLanguageOutputTests(unittest.TestCase):
    def run_checker(self, diag: str, run_id: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                CHECK,
                diag,
                "--run-id",
                run_id,
                "--matrix",
                MATRIX,
                "--subset",
                "quick",
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_quick_subset_passes_fixture(self) -> None:
        run_id = "fixture-output"
        with tempfile.TemporaryDirectory() as diag:
            write_fixture(diag, run_id)
            result = self.run_checker(diag, run_id)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_expected_language_mismatch_fails(self) -> None:
        run_id = "fixture-output-mismatch"
        with tempfile.TemporaryDirectory() as diag:
            write_fixture(diag, run_id, mismatch=True)
            result = self.run_checker(diag, run_id)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("expectedLanguage", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
