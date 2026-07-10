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

OVERHEAD_PATH = Path(__file__).parent / "telemetry_overhead.py"
OVERHEAD_SPEC = importlib.util.spec_from_file_location("telemetry_overhead", OVERHEAD_PATH)
assert OVERHEAD_SPEC and OVERHEAD_SPEC.loader
OVERHEAD = importlib.util.module_from_spec(OVERHEAD_SPEC)
OVERHEAD_SPEC.loader.exec_module(OVERHEAD)


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

    def test_rejects_cross_layer_privacy_leaks(self):
        engine = engine_row()
        engine["notes"] = {"audioPath": "/Users/example/private.wav"}
        _, errors = HARNESS.validate_probe_rows([engine], [transport_row()])
        self.assertTrue(any("forbidden raw field" in error for error in errors))
        self.assertTrue(any("raw local path" in error for error in errors))


class ContractTests(unittest.TestCase):
    def test_benchmark_manifest_matches_the_29_take_contract(self):
        manifest = HARNESS.benchmark_manifest()
        self.assertEqual(len(manifest), 29)
        self.assertEqual(
            [(take["mode"], take["warmState"]) for take in manifest if take["warmState"] == "cold"],
            [("custom", "cold"), ("design", "cold")],
        )
        self.assertEqual([take["index"] for take in manifest], list(range(1, 30)))

    def test_impact_rules_union_independent_requirements(self):
        config = HARNESS.read_json(HARNESS.IMPACT)
        self.assertEqual(HARNESS.classify_paths(["README.md"], config)[:2], ([], []))
        self.assertEqual(HARNESS.classify_paths(["Sources/Views/HistoryView.swift"], config)[0], ["quick"])
        self.assertEqual(HARNESS.classify_paths(["Sources/QwenVoiceNative/XPCNativeEngineClient.swift"], config)[0], ["full"])
        suites, checks, _ = HARNESS.classify_paths(
            ["Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift"], config
        )
        self.assertEqual(suites, ["benchmark", "full"])
        self.assertEqual(checks, ["telemetry-overhead"])

    def test_stale_source_fingerprint_invalidates_report(self):
        report = {
            "schemaVersion": 2,
            "runID": "fixture",
            "suite": "full",
            "status": "pass",
            "sourceFingerprint": "stale",
            "buildInputFingerprint": HARNESS.fingerprint(build_inputs_only=True),
            "appBinarySHA256": HARNESS.sha256(HARNESS.APP_BINARY),
            "executableIdentity": HARNESS.executable_identity(),
            "environment": {"toolchain": HARNESS.toolchain_identity()},
            "probeVerdict": "pass",
            "cleanupVerdict": "pass",
            "issues": [],
        }
        errors = HARNESS.validate_report(report)
        self.assertIn("source fingerprint is stale", errors)

    def test_report_requires_every_suite_scenario_to_pass(self):
        report = {
            "schemaVersion": 2,
            "runID": "fixture",
            "suite": "quick",
            "status": "pass",
            "sourceFingerprint": "fixture",
            "buildInputFingerprint": "fixture",
            "appBinarySHA256": "fixture",
            "executableIdentity": {"sha256": "fixture"},
            "environment": {"toolchain": HARNESS.toolchain_identity()},
            "probeVerdict": "pass",
            "cleanupVerdict": "pass",
            "issues": [],
            "scenarios": {},
        }
        errors = HARNESS.validate_report(report, current_fingerprints=False)
        self.assertTrue(any("required scenarios" in error for error in errors))

    def test_quick_and_full_reports_enforce_declared_time_budgets(self):
        base = {
            "schemaVersion": 2,
            "runID": "fixture",
            "status": "pass",
            "sourceFingerprint": "fixture",
            "buildInputFingerprint": "fixture",
            "appBinarySHA256": "fixture",
            "executableIdentity": {"sha256": "fixture"},
            "environment": {"toolchain": HARNESS.toolchain_identity()},
            "probeVerdict": "pass",
            "cleanupVerdict": "pass",
            "issues": [],
        }
        quick = dict(base, suite="quick", durationSeconds=601, scenarios={})
        full = dict(base, suite="full", durationSeconds=2_401, scenarios={})
        quick_errors = HARNESS.validate_report(quick, current_fingerprints=False)
        full_errors = HARNESS.validate_report(full, current_fingerprints=False)
        self.assertTrue(any("10-minute budget" in error for error in quick_errors))
        self.assertTrue(any("40-minute budget" in error for error in full_errors))

    def test_destructive_start_requires_explicit_authorization(self):
        args = argparse.Namespace(suite="destructive", allow_destructive=False)
        with self.assertRaises(HARNESS.HarnessError):
            HARNESS.cmd_start(args)

    def test_full_can_satisfy_quick_but_benchmark_cannot_satisfy_full(self):
        base = {
            "schemaVersion": 2,
            "runID": "fixture",
            "status": "pass",
            "sourceFingerprint": "fixture",
            "buildInputFingerprint": "fixture",
            "appBinarySHA256": "fixture",
            "executableIdentity": {"sha256": "fixture"},
            "environment": {"toolchain": HARNESS.toolchain_identity()},
            "probeVerdict": "pass",
            "cleanupVerdict": "pass",
            "issues": [],
            "scenarios": {},
        }
        full = dict(base, suite="full")
        benchmark = dict(base, suite="benchmark")
        full_errors = HARNESS.validate_report(full, required_suite="quick", current_fingerprints=False)
        benchmark_errors = HARNESS.validate_report(benchmark, required_suite="full", current_fingerprints=False)
        self.assertFalse(any("insufficient" in error for error in full_errors))
        self.assertTrue(any("actual full" in error for error in benchmark_errors))

    def test_ci_attestation_skips_local_signed_binary_hash_only(self):
        identity = {
            "sourceFingerprint": HARNESS.fingerprint(),
            "buildInputFingerprint": HARNESS.fingerprint(build_inputs_only=True),
            "toolchainIdentity": HARNESS.toolchain_identity(),
        }
        entry = {
            "status": "pass",
            "suite": "full",
            "probeVerdict": "pass",
            "cleanupVerdict": "pass",
            "issues": {"blocker": 0, "major": 0},
            "executableIdentity": {"sha256": "different-signature"},
        }
        attestation = {"schemaVersion": 2, **identity, "entries": {"full": entry}, "runtimeChecks": {}}
        local = HARNESS.validate_attestation(attestation, ["full"], [], ci=False)
        ci = HARNESS.validate_attestation(attestation, ["full"], [], ci=True)
        self.assertTrue(any("full evidence" in error for error in local))
        self.assertFalse(any("full evidence" in error for error in ci))

    def test_schema_v1_attestation_is_diagnostic_only(self):
        errors = HARNESS.validate_attestation({"schemaVersion": 1}, ["quick"], [], ci=True)
        self.assertTrue(any("diagnostic-only" in error for error in errors))

    def test_contracts_are_schema_v2_and_all_risk_references_resolve(self):
        self.assertEqual(HARNESS.validate_config(), [])

    def test_exact_launch_targets_path_and_never_bundle_identifier(self):
        command = HARNESS.exact_launch_command("fixture", Path("/tmp/disposable"))
        self.assertEqual(command[-1], str(HARNESS.APP))
        self.assertNotIn(HARNESS.BUNDLE_ID, command)
        self.assertIn("QWENVOICE_APP_SUPPORT_DIR=/tmp/disposable", command)

    def test_destructive_root_is_disposable_and_not_shared(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory) / "run"
            run.mkdir()
            root = HARNESS.destructive_root(run)
            self.assertTrue(root.is_relative_to(run.resolve()))
            self.assertNotEqual(root, HARNESS.DEBUG_ROOT.resolve())
            self.assertNotEqual(root, HARNESS.PRODUCTION_ROOT.resolve())
            self.assertFalse((root / "models").is_symlink())
            self.assertFalse((root / "voices").is_symlink())

    def test_stale_toolchain_identity_invalidates_attestation(self):
        attestation = {
            "schemaVersion": 2,
            "sourceFingerprint": HARNESS.fingerprint(),
            "buildInputFingerprint": HARNESS.fingerprint(build_inputs_only=True),
            "toolchainIdentity": {"digest": "stale"},
            "entries": {},
            "runtimeChecks": {},
        }
        errors = HARNESS.validate_attestation(attestation, [], [], ci=True)
        self.assertIn("attestation toolchain identity is stale", errors)


class TelemetryOverheadMathTests(unittest.TestCase):
    def test_rtf_is_audio_per_wall_second_and_lower_throughput_is_regression(self):
        self.assertAlmostEqual(OVERHEAD.throughput_regression(0.9, 1.0), 10.0)
        self.assertAlmostEqual(OVERHEAD.throughput_regression(1.1, 1.0), -10.0)

    def test_higher_ttfc_is_regression(self):
        self.assertAlmostEqual(OVERHEAD.latency_regression(110.0, 100.0), 10.0)
        self.assertAlmostEqual(OVERHEAD.latency_regression(90.0, 100.0), -10.0)


if __name__ == "__main__":
    unittest.main()
