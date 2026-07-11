#!/usr/bin/env python3
"""Focused fixtures for check_macos_xpc_bench.py ordering and output gates."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts" / "check_macos_xpc_bench.py"
RUN_ID = "mac-ui-order-fixture"


def make_engine_row(index: int, cell: str) -> dict:
    mode, _, state_and_repetition = cell.split("/")
    warm_state, _ = state_and_repetition.split("#")
    generation_id = f"fixture-{index}"
    return {
        "generationID": generation_id,
        "mode": mode,
        "warmState": warm_state,
        "finishReason": "completed",
        "notes": {
            "benchRunID": RUN_ID,
            "benchTakeIndex": str(index),
            "benchCell": cell,
        },
        "outputMetrics": {
            "readableWAV": True,
            "atomicallyPublished": True,
            "durationSeconds": 1.0,
        },
        "audioQC": {"verdict": "pass", "flags": []},
    }


class CheckMacOSXPCBenchmarkTests(unittest.TestCase):
    expected_order = [
        "custom/medium/cold#0",
        "custom/short/warm#0",
        "custom/medium/warm#0",
        "clone/short/warm#0",
        "clone/medium/warm#0",
    ]

    def run_checker(
        self,
        cells: list[str],
        mutate_engine_rows=None,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temp:
            diagnostics = Path(temp)
            engine_rows = [
                make_engine_row(index, cell)
                for index, cell in enumerate(cells, start=1)
            ]
            if mutate_engine_rows is not None:
                mutate_engine_rows(engine_rows)

            correlated_rows = [
                {
                    "generationID": row["generationID"],
                    "notes": {"benchRunID": RUN_ID},
                }
                for row in engine_rows
            ]
            for layer, rows in (
                ("engine", engine_rows),
                ("engine-service", correlated_rows),
                ("app", correlated_rows),
            ):
                directory = diagnostics / layer
                directory.mkdir()
                (directory / "generations.jsonl").write_text(
                    "".join(json.dumps(row) + "\n" for row in rows),
                    encoding="utf-8",
                )
            (diagnostics / "generations-merged.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in correlated_rows),
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

    def test_exact_order_and_pass_qc_pass(self) -> None:
        result = self.run_checker(self.expected_order)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_same_distribution_with_sequential_indices_in_wrong_order_fails(self) -> None:
        reordered = self.expected_order.copy()
        reordered[1], reordered[2] = reordered[2], reordered[1]
        result = self.run_checker(reordered)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("benchmark cell order differs", result.stdout + result.stderr)

    def test_missing_audio_qc_fails(self) -> None:
        def remove_audio_qc(rows: list[dict]) -> None:
            rows[0].pop("audioQC")

        result = self.run_checker(self.expected_order, remove_audio_qc)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("audioQC verdict is missing", result.stdout + result.stderr)

    def test_failed_audio_qc_fails(self) -> None:
        def fail_audio_qc(rows: list[dict]) -> None:
            rows[0]["audioQC"] = {"verdict": "fail", "flags": ["fixture"]}

        result = self.run_checker(self.expected_order, fail_audio_qc)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("audioQC failed", result.stdout + result.stderr)

    def test_audio_qc_warning_is_accepted(self) -> None:
        def warn_audio_qc(rows: list[dict]) -> None:
            rows[0]["audioQC"] = {"verdict": "warn", "flags": ["fixture"]}

        result = self.run_checker(self.expected_order, warn_audio_qc)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    raise SystemExit(unittest.main())
