import argparse
import importlib.util
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = Path(__file__).parent / "lib" / "macos_agent_ui.py"
SPEC = importlib.util.spec_from_file_location("macos_agent_ui", MODULE_PATH)
assert SPEC and SPEC.loader
HARNESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HARNESS)


def engine_row(generation_id="generation-1", finish="eos"):
    return {
        "schemaVersion": 6,
        "generationID": generation_id,
        "recordedAt": "2026-07-10T00:00:00Z",
        "finishReason": finish,
        "usedStreaming": True,
        "stageMarks": [{"tNS": 1}, {"tNS": 2}],
        "backendMetrics": {
            "finishReason": finish,
            "finalChunkBarrierObserved": True,
        },
    }


def transport_row(generation_id="generation-1", finish="eos", **counters):
    values = {
        "chunksForwarded": 2,
        "chunkGaps": 0,
        "duplicateChunks": 0,
        "outOfOrderChunks": 0,
    }
    values.update(counters)
    return {
        "schemaVersion": 6,
        "generationID": generation_id,
        "recordedAt": "2026-07-10T00:00:01Z",
        "finishReason": finish,
        "transportMetrics": {"finishReason": finish, "counters": values},
    }


class ProbeValidationTests(unittest.TestCase):
    def test_accepts_correlated_monotonic_terminal_rows(self):
        checked, errors = HARNESS.validate_probe_rows([engine_row()], [transport_row()])
        self.assertEqual(len(checked), 1)
        self.assertEqual(errors, [])

    def test_rejects_missing_duplicate_reordered_and_mismatched_rows(self):
        _, missing = HARNESS.validate_probe_rows([engine_row()], [])
        self.assertTrue(any("missing middle-layer" in error for error in missing))
        _, duplicate = HARNESS.validate_probe_rows(
            [engine_row(), engine_row()],
            [transport_row(), transport_row()],
        )
        self.assertTrue(any("duplicate terminal rows" in error for error in duplicate))
        _, reordered = HARNESS.validate_probe_rows(
            [engine_row()],
            [transport_row(outOfOrderChunks=1)],
        )
        self.assertTrue(any("out-of-order" in error for error in reordered))
        _, mismatch = HARNESS.validate_probe_rows(
            [engine_row(finish="cancelled")],
            [transport_row(finish="failed")],
        )
        self.assertTrue(any("terminal mismatch" in error for error in mismatch))

    def test_rejects_corrupted_jsonl(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rows.jsonl"
            path.write_text("{not-json}\n")
            with self.assertRaises(HARNESS.HarnessError):
                HARNESS.read_jsonl(path)


class ContractTests(unittest.TestCase):
    def test_benchmark_manifest_matches_the_29_take_contract(self):
        manifest = HARNESS.benchmark_manifest()
        self.assertEqual(len(manifest), 29)
        self.assertEqual(
            [(take["mode"], take["warmState"]) for take in manifest if take["warmState"] == "cold"],
            [("custom", "cold"), ("design", "cold")],
        )
        self.assertEqual([take["index"] for take in manifest], list(range(1, 30)))

    def test_impact_levels_select_highest_matching_requirement(self):
        config = HARNESS.read_json(HARNESS.IMPACT)
        self.assertEqual(HARNESS.classify_paths(["README.md"], config)[0], "none")
        self.assertEqual(HARNESS.classify_paths(["Sources/Views/HistoryView.swift"], config)[0], "quick")
        self.assertEqual(HARNESS.classify_paths(["Sources/QwenVoiceNative/XPCNativeEngineClient.swift"], config)[0], "full")
        self.assertEqual(HARNESS.classify_paths(["third_party_patches/mlx-audio-swift/Package.swift"], config)[0], "benchmark")

    def test_stale_source_fingerprint_invalidates_report(self):
        report = {
            "schemaVersion": 1,
            "runID": "fixture",
            "suite": "full",
            "status": "pass",
            "sourceFingerprint": "stale",
            "buildInputFingerprint": HARNESS.fingerprint(build_inputs_only=True),
            "appBinarySHA256": HARNESS.sha256(HARNESS.APP_BINARY),
            "probeVerdict": "pass",
            "cleanupVerdict": "pass",
            "issues": [],
        }
        errors = HARNESS.validate_report(report)
        self.assertIn("source fingerprint is stale", errors)

    def test_report_requires_every_suite_scenario_to_pass(self):
        report = {
            "schemaVersion": 1,
            "runID": "fixture",
            "suite": "quick",
            "status": "pass",
            "sourceFingerprint": "fixture",
            "buildInputFingerprint": "fixture",
            "appBinarySHA256": "fixture",
            "probeVerdict": "pass",
            "cleanupVerdict": "pass",
            "issues": [],
            "scenarios": {},
        }
        errors = HARNESS.validate_report(report, current_fingerprints=False)
        self.assertTrue(any("required scenarios" in error for error in errors))

    def test_destructive_start_requires_explicit_authorization(self):
        args = argparse.Namespace(suite="destructive", allow_destructive=False)
        with self.assertRaises(HARNESS.HarnessError):
            HARNESS.cmd_start(args)


if __name__ == "__main__":
    unittest.main()
