#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "scripts" / "check_ios_smoke_acceptance.py"
RUN_ID = "ios-xcui-smoke-fixture"


def memory_row(
    event: str,
    index: int,
    *,
    reason: str = "active_generation_sample_debug_force_critical_once",
    trim_level: str | None = None,
) -> dict:
    return {
        "event": event,
        "recordedAt": f"2026-07-15T12:00:0{index}Z",
        "processUptimeSeconds": 100.0 + index,
        "runID": RUN_ID,
        "reason": reason,
        "trimLevel": trim_level,
    }


def valid_memory_rows() -> list[dict]:
    return [
        memory_row("debug_force_critical_once", 1),
        memory_row("critical_memory_action", 2),
        memory_row("critical_generation_cancel", 3, reason="memory_pressure"),
        memory_row("critical_full_unload", 4, trim_level="fullUnload"),
    ]


def app_row(
    generation_id: str,
    second: int,
    *,
    finish_reason: str = "eos",
    run_id: str = RUN_ID,
) -> dict:
    return {
        "schemaVersion": 8,
        "generationID": generation_id,
        "layer": "app",
        "recordedAt": f"2026-07-15T12:00:{second:02d}Z",
        "finishReason": finish_reason,
        "notes": {"benchRunID": run_id},
    }


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "".join(json.dumps(row, sort_keys=True) + "\n" for row in rows),
        encoding="utf-8",
    )


class IOSSmokeAcceptanceTests(unittest.TestCase):
    def run_checker(self, root: Path, run_id: str = RUN_ID) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(CHECKER), str(root), "--run-id", run_id],
            text=True,
            capture_output=True,
            check=False,
        )

    def make_valid_fixture(self, root: Path, *, duplicate_mirrors: bool = False) -> None:
        memory = valid_memory_rows()
        app = [
            app_row("user-cancelled-generation", 0, finish_reason="cancelled"),
            app_row("memory-cancelled-generation", 3, finish_reason="cancelled"),
            app_row("reused-generation", 8),
            app_row("unrelated-generation", 9, run_id="another-run"),
        ]
        write_jsonl(root / "pull" / RUN_ID / "memory-contexts.jsonl", memory)
        write_jsonl(root / "pull" / "app" / "generations.jsonl", app)
        if duplicate_mirrors:
            write_jsonl(root / "mirror" / RUN_ID / "memory-contexts.jsonl", memory)
            write_jsonl(root / "mirror" / "app" / "generations.jsonl", app)

    def test_accepts_identical_mirrors_and_proves_post_pressure_reuse(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_valid_fixture(root, duplicate_mirrors=True)
            completed = self.run_checker(root)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(completed.stdout)
        self.assertEqual(result["status"], "pass")
        self.assertEqual(result["memoryMirrorCount"], 2)
        self.assertEqual(result["appMirrorCount"], 2)
        self.assertEqual(result["cancellationReason"], "memory_pressure")
        self.assertEqual(result["trimLevel"], "fullUnload")
        self.assertEqual(result["cancelledGenerationCount"], 2)
        self.assertEqual(result["postPressureGenerationID"], "reused-generation")
        self.assertNotIn(directory, completed.stdout)

    def test_rejects_missing_duplicate_or_out_of_order_events(self) -> None:
        mutations = {
            "missing": lambda rows: rows.pop(1),
            "duplicate": lambda rows: rows.insert(2, dict(rows[1])),
            "out of order": lambda rows: rows.__setitem__(slice(1, 3), [rows[2], rows[1]]),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.make_valid_fixture(root)
                rows = valid_memory_rows()
                mutate(rows)
                write_jsonl(root / "pull" / RUN_ID / "memory-contexts.jsonl", rows)
                completed = self.run_checker(root)
                self.assertNotEqual(completed.returncode, 0)

    def test_rejects_wrong_cancellation_reason_and_trim_level(self) -> None:
        for field, value in (("reason", "active_generation_sample"), ("trimLevel", "hardTrim")):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.make_valid_fixture(root)
                rows = valid_memory_rows()
                target = rows[2] if field == "reason" else rows[3]
                target[field] = value
                write_jsonl(root / "pull" / RUN_ID / "memory-contexts.jsonl", rows)
                completed = self.run_checker(root)
                self.assertNotEqual(completed.returncode, 0)

    def test_cancel_failed_is_suite_fatal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_valid_fixture(root)
            rows = valid_memory_rows()
            rows.insert(3, memory_row("critical_generation_cancel_failed", 3))
            write_jsonl(root / "pull" / RUN_ID / "memory-contexts.jsonl", rows)
            completed = self.run_checker(root)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("cancel_failed", completed.stderr)

    def test_rejects_divergent_memory_and_app_mirrors(self) -> None:
        for evidence in ("memory", "app"):
            with self.subTest(evidence=evidence), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.make_valid_fixture(root, duplicate_mirrors=True)
                if evidence == "memory":
                    rows = valid_memory_rows()
                    rows[0]["source"] = "divergent"
                    write_jsonl(root / "mirror" / RUN_ID / "memory-contexts.jsonl", rows)
                else:
                    write_jsonl(
                        root / "mirror" / "app" / "generations.jsonl",
                        [app_row("different-generation", 9)],
                    )
                completed = self.run_checker(root)
                self.assertNotEqual(completed.returncode, 0)
                self.assertIn("diverge", completed.stderr)

    def test_rejects_mixed_run_identity_in_run_scoped_memory_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_valid_fixture(root)
            rows = valid_memory_rows()
            rows[1]["runID"] = "another-run"
            write_jsonl(root / "pull" / RUN_ID / "memory-contexts.jsonl", rows)
            completed = self.run_checker(root)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("mixes run identities", completed.stderr)

    def test_requires_successful_app_completion_after_full_unload(self) -> None:
        variants = {
            "only before": [
                app_row("user-cancel", 0, finish_reason="cancelled"),
                app_row("memory-cancel", 3, finish_reason="cancelled"),
            ],
            "failed after": [
                app_row("user-cancel", 0, finish_reason="cancelled"),
                app_row("memory-cancel", 3, finish_reason="cancelled"),
                app_row("failed-after", 8, finish_reason="failed"),
            ],
        }
        for label, rows in variants.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.make_valid_fixture(root)
                write_jsonl(root / "pull" / "app" / "generations.jsonl", rows)
                completed = self.run_checker(root)
                self.assertNotEqual(completed.returncode, 0)
                self.assertIn("after the critical full unload", completed.stderr)

    def test_requires_distinct_user_and_memory_cancellations(self) -> None:
        variants = {
            "missing user": [
                app_row("memory-cancel", 3, finish_reason="cancelled"),
                app_row("reused", 8),
            ],
            "missing memory": [
                app_row("user-cancel", 0, finish_reason="cancelled"),
                app_row("reused", 8),
            ],
            "duplicate memory": [
                app_row("user-cancel", 0, finish_reason="cancelled"),
                app_row("memory-cancel-1", 2, finish_reason="cancelled"),
                app_row("memory-cancel-2", 3, finish_reason="cancelled"),
                app_row("reused", 8),
            ],
        }
        for label, rows in variants.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.make_valid_fixture(root)
                write_jsonl(root / "pull" / "app" / "generations.jsonl", rows)
                completed = self.run_checker(root)
                self.assertNotEqual(completed.returncode, 0)
                self.assertIn("cancellation", completed.stderr)

    def test_errors_do_not_disclose_the_local_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            completed = self.run_checker(root)
        self.assertNotEqual(completed.returncode, 0)
        self.assertNotIn(directory, completed.stderr)

    def test_xcode_runner_environment_uses_the_stripped_name(self) -> None:
        runner = (ROOT / "scripts" / "ui_test.sh").read_text(encoding="utf-8")
        smoke = (
            ROOT / "Tests" / "VocelloiOSUITests" / "VocelloiOSSmokeUITests.swift"
        ).read_text(encoding="utf-8")

        self.assertIn(
            'export TEST_RUNNER_QVOICE_IOS_SMOKE_RUN_ID="$run_id"',
            runner,
        )
        self.assertIn(
            'runnerEnvironment["QVOICE_IOS_SMOKE_RUN_ID"]',
            smoke,
        )
        self.assertNotIn(
            'runnerEnvironment["TEST_RUNNER_QVOICE_IOS_SMOKE_RUN_ID"]',
            smoke,
        )

    def test_successful_ios_ui_build_preserves_matching_symbols(self) -> None:
        runner = (ROOT / "scripts" / "ui_test.sh").read_text(encoding="utf-8")
        test_start = runner.rindex(
            'required_step_run "$step_ledger" xcuitest run_xcodebuild xcb_run test'
        )
        preserve_index = runner.index("\n  preserve_ios_ui_dsym", test_start)
        crash_delta_index = runner.index(
            "\n  required_step_run \"$step_ledger\" crash-delta",
            preserve_index,
        )
        self.assertLess(test_start, preserve_index)
        self.assertLess(preserve_index, crash_delta_index)
        self.assertIn(
            'preserve_ios_dsym "$source" "$destination" "$app/Vocello"',
            runner,
        )

    def test_ui_runner_transport_names_are_exact_and_benchmarks_fail_closed(self) -> None:
        runner = (ROOT / "scripts" / "ui_test.sh").read_text(encoding="utf-8")
        suites = {
            "MAC": (
                ROOT / "Tests" / "VocelloMacUITests" / "VocelloMacBenchmarkUITests.swift"
            ).read_text(encoding="utf-8"),
            "IOS": (
                ROOT / "Tests" / "VocelloiOSUITests" / "VocelloiOSBenchmarkUITests.swift"
            ).read_text(encoding="utf-8"),
        }
        for platform, source in suites.items():
            for suffix in ("RUN_ID", "MODES", "LENGTHS", "WARM", "LABEL"):
                consumer = f"QVOICE_{platform}_BENCH_{suffix}"
                self.assertIn(f"TEST_RUNNER_{consumer}", runner)
                self.assertIn(f'"{consumer}"', source)
            self.assertNotIn("?? \"mac-xcui-benchmark-", source)
            self.assertNotIn("?? \"ios-xcui-benchmark-", source)

        for path in (ROOT / "Tests").glob("*UITests/*.swift"):
            self.assertNotIn(
                'environment["TEST_RUNNER_',
                path.read_text(encoding="utf-8"),
                f"{path.name} must consume Xcode's stripped runner variable name",
            )


if __name__ == "__main__":
    unittest.main()
