#!/usr/bin/env python3
"""Offline order and output fixtures for check_ios_ui_benchmark.py."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts" / "check_ios_ui_benchmark.py"
RUN_ID = "ios-ui-order-fixture"


def make_row(index: int, mode: str, length: str, warm_state: str) -> dict:
    prompt_chars = {"short": 36, "medium": 100, "long": 150}[length]
    return {
        "generationID": f"fixture-{index}",
        "mode": mode,
        "warmState": warm_state,
        "finishReason": "completed",
        "notes": {"benchRunID": RUN_ID, "promptChars": str(prompt_chars)},
        "outputMetrics": {
            "readableWAV": True,
            "atomicallyPublished": True,
            "durationSeconds": 1.0,
        },
        "audioQC": {"verdict": "pass"},
    }


class CheckIOSUIBenchmarkTests(unittest.TestCase):
    expected_order = [
        ("custom", "medium", "cold"),
        ("custom", "short", "warm"),
        ("custom", "medium", "warm"),
        ("clone", "short", "warm"),
        ("clone", "medium", "warm"),
    ]

    def run_checker(
        self,
        cells: list[tuple[str, str, str]],
        mutate_rows=None,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temp:
            diagnostics = Path(temp)
            engine = diagnostics / "engine"
            engine.mkdir()
            rows = [make_row(index, *cell) for index, cell in enumerate(cells, start=1)]
            if mutate_rows is not None:
                mutate_rows(rows)
            (engine / "generations.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in rows),
                encoding="utf-8",
            )
            return subprocess.run(
                [
                    sys.executable,
                    str(CHECK),
                    str(diagnostics),
                    "--run-id",
                    RUN_ID,
                    "--modes",
                    "custom,clone",
                    "--lengths",
                    "short,medium",
                    "--warm",
                    "1",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

    def test_exact_order_passes(self) -> None:
        result = self.run_checker(self.expected_order)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_same_distribution_in_wrong_order_fails(self) -> None:
        reordered = self.expected_order.copy()
        reordered[1], reordered[2] = reordered[2], reordered[1]
        result = self.run_checker(reordered)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cell order mismatch", result.stdout + result.stderr)

    def test_missing_audio_qc_fails(self) -> None:
        def remove_audio_qc(rows: list[dict]) -> None:
            rows[0].pop("audioQC")

        result = self.run_checker(self.expected_order, remove_audio_qc)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("audioQC verdict is missing", result.stdout + result.stderr)

    def test_audio_qc_warning_is_accepted(self) -> None:
        def mark_warning(rows: list[dict]) -> None:
            rows[0]["audioQC"] = {"verdict": "warn", "flags": ["fixture"]}

        result = self.run_checker(self.expected_order, mark_warning)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    raise SystemExit(unittest.main())
