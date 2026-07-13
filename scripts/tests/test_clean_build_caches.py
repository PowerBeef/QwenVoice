#!/usr/bin/env python3
"""Hermetic contracts for the classified build cleanup policy."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
SHELL = REPO_ROOT / "scripts" / "clean_build_caches.sh"
HELPER = REPO_ROOT / "scripts" / "build_cleanup.py"
POLICY = REPO_ROOT / "config" / "build-output-policy.json"


class CleanBuildCachesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        base = Path(self.temporary.name)
        self.root = base / "checkout"
        (self.root / "scripts").mkdir(parents=True)
        (self.root / "config").mkdir()
        shutil.copy2(SHELL, self.root / "scripts" / SHELL.name)
        shutil.copy2(HELPER, self.root / "scripts" / HELPER.name)
        shutil.copy2(POLICY, self.root / "config" / POLICY.name)
        (self.root / "scripts" / "benchmark_history.py").write_text(
            """#!/usr/bin/env python3
import json
from pathlib import Path
import sys
if len(sys.argv) != 3 or sys.argv[1] != "validate":
    raise SystemExit(2)
payload = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
raise SystemExit(0 if payload.get("_fixtureValid") is True else 1)
""",
            encoding="utf-8",
        )
        self.home = base / "home"
        self.home.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_clean(
        self, *arguments: str, expected: int = 0
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["HOME"] = str(self.home)
        result = subprocess.run(
            [str(self.root / "scripts" / SHELL.name), *arguments],
            cwd=self.root,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(
            result.returncode,
            expected,
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        return result

    @staticmethod
    def write(path: Path, value: str | bytes = "sentinel") -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(value, bytes):
            path.write_bytes(value)
        else:
            path.write_text(value, encoding="utf-8")
        return path

    def track(self, *paths: Path) -> None:
        if not (self.root / ".git").exists():
            subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(
            ["git", "add", "-f", "--", *(str(path.relative_to(self.root)) for path in paths)],
            cwd=self.root,
            check=True,
        )

    def ui_run(self, platform: str, lane: str, suffix: str, status: str) -> Path:
        run_id = f"{platform}-xcui-{lane}-{suffix}"
        run = self.root / "build" / "artifacts" / "ui-tests" / platform / run_id
        self.write(
            run / "run.json",
            json.dumps(
                {
                    "schemaVersion": 2,
                    "platform": platform,
                    "lane": lane,
                    "runID": run_id,
                    "status": status,
                }
            ),
        )
        self.write(run / "result.xcresult" / "payload", b"result")
        return run

    def valid_ui_history(self, run: Path) -> None:
        metadata = json.loads((run / "run.json").read_text())
        record = (
            self.root
            / "benchmarks"
            / "runs"
            / "ui-generation"
            / f"{metadata['runID']}.json"
        )
        self.write(
            record,
            json.dumps(
                {
                    "_fixtureValid": True,
                    "run": {
                        "id": metadata["runID"],
                        "kind": "ui-generation",
                        "platform": metadata["platform"],
                        "status": "passed",
                    },
                }
            ),
        )

    def profile_run(
        self, run_id: str, *, platform: str = "macos", kind: str = "memory"
    ) -> tuple[Path, Path]:
        run = self.root / "build" / "artifacts" / platform / "profiles" / run_id
        trace = run / f"{run_id}.trace"
        self.write(trace / "instrument_data" / "events.bin", b"trace-data")
        return run, trace

    def profile_marker(
        self,
        run: Path,
        trace: Path,
        *,
        platform: str,
        kind: str,
        status: str,
        policy: str,
        capture_time: str,
    ) -> None:
        self.write(
            run / "profile-retention.json",
            json.dumps(
                {
                    "schemaVersion": 1,
                    "runID": run.name,
                    "platform": platform,
                    "profileKind": kind,
                    "status": status,
                    "retentionPolicy": policy,
                    "rawTraceRetained": True,
                    "captureTime": capture_time,
                    "originalEphemeralPath": trace.relative_to(self.root).as_posix(),
                }
            ),
        )
        self.write(
            run / "profile-failure-summary.json",
            json.dumps({"runID": run.name, "rawTraceRetained": True}),
        )

    @staticmethod
    def trace_digest(trace: Path) -> str:
        rows = [
            [path.relative_to(trace).as_posix(), hashlib.sha256(path.read_bytes()).hexdigest()]
            for path in sorted(trace.rglob("*"))
            if path.is_file()
        ]
        return hashlib.sha256(
            json.dumps(
                rows,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=True,
                allow_nan=False,
            ).encode("utf-8")
        ).hexdigest()

    def published_profile(self, run: Path, trace: Path, *, platform: str) -> None:
        digest = self.trace_digest(trace)
        record = (
            self.root
            / "benchmarks"
            / "runs"
            / "instrument-profile"
            / f"{run.name}.json"
        )
        self.write(
            record,
            json.dumps(
                {
                    "run": {"id": run.name, "status": "passed", "platform": platform},
                    "evidence": {"trace": {"validated": True, "digest": digest}},
                }
            ),
        )

    def test_no_arguments_is_read_only_inventory(self) -> None:
        scratch = self.write(
            self.root / "build" / "scratch" / "derived-data" / "foundation" / "blob"
        )
        result = self.run_clean()
        self.assertTrue(scratch.exists())
        self.assertIn("Build-output inventory", result.stdout)
        self.assertNotIn("removed:", result.stdout)

    def test_routine_is_bounded_and_prunes_only_superseded_ui_evidence(self) -> None:
        scratch = self.write(
            self.root / "build" / "scratch" / "derived-data" / "foundation" / "blob"
        )
        foundation = self.write(self.root / "build" / "artifacts" / "foundation" / "result")
        preserved = [
            self.write(self.root / "build" / "cache" / "xcode" / "macos" / "cache"),
            self.write(self.root / "build" / "dist" / "macos" / "Vocello.dmg"),
            self.write(self.root / "build" / "artifacts" / "symbols" / "macos" / "symbol"),
            self.write(self.root / "build" / "artifacts" / "diagnostics" / "failure.log"),
        ]
        old_pass = self.ui_run("macos", "smoke", "20260713-000001-a", "passed")
        newest_pass = self.ui_run("macos", "smoke", "20260713-000002-b", "passed")
        old_fail = self.ui_run("macos", "smoke", "20260713-000003-c", "failed")
        newest_fail = self.ui_run("macos", "smoke", "20260713-000004-d", "failed")

        self.run_clean("--routine")

        self.assertFalse(scratch.exists())
        self.assertFalse(foundation.exists())
        self.assertFalse(old_pass.exists())
        self.assertTrue(newest_pass.exists())
        self.assertFalse(old_fail.exists())
        self.assertTrue(newest_fail.exists())
        for path in preserved:
            self.assertTrue(path.exists(), path)

    def test_prune_ui_results_is_mutually_exclusive_and_cannot_touch_other_classes(self) -> None:
        old = self.ui_run("ios", "smoke", "20260713-000001-a", "passed")
        newest = self.ui_run("ios", "smoke", "20260713-000002-b", "passed")
        scratch = self.write(self.root / "build" / "scratch" / "derived-data" / "ci" / "blob")
        diagnostics = self.write(self.root / "build" / "artifacts" / "diagnostics" / "report")
        dist = self.write(self.root / "build" / "dist" / "ios" / "Vocello.ipa")
        symbols = self.write(self.root / "build" / "artifacts" / "symbols" / "ios" / "symbol")

        self.run_clean("--prune-ui-results")

        self.assertFalse(old.exists())
        self.assertTrue(newest.exists())
        for path in (scratch, diagnostics, dist, symbols):
            self.assertTrue(path.exists())
        result = self.run_clean("--prune-ui-results", "--routine", expected=2)
        self.assertIn("mutually exclusive", result.stderr)

    def test_prune_preserves_benchmark_publication_repair_evidence(self) -> None:
        repair = self.ui_run("macos", "benchmark", "20260713-000001-a", "passed")
        newest = self.ui_run("macos", "benchmark", "20260713-000002-b", "passed")
        result = self.run_clean("--prune-ui-results")
        self.assertTrue(repair.exists())
        self.assertTrue(newest.exists())
        self.assertIn("benchmark-publication-repair-evidence", result.stdout)
        self.valid_ui_history(repair)
        self.run_clean("--prune-ui-results")
        self.assertFalse(repair.exists())

    def test_aggressive_removes_persistent_caches_and_links_but_preserves_dist_and_symbols(self) -> None:
        caches = [
            self.write(self.root / "build" / "cache" / "xcode" / "macos" / "cache"),
            self.write(self.root / "build" / "cache" / "xcode" / "ios-device" / "cache"),
            self.write(self.root / "build" / "cache" / "xcode" / "source-packages" / "checkout"),
            self.write(self.root / "build" / "cache" / "swiftpm" / "mlx-audio-runtime" / "cache"),
        ]
        public_app = self.root / "build" / "Vocello.app"
        public_app.parent.mkdir(parents=True, exist_ok=True)
        public_app.symlink_to("cache/xcode/macos/Build/Products/Release/Vocello.app")
        dist = self.write(self.root / "build" / "dist" / "macos" / "Vocello.dmg")
        symbol = self.write(self.root / "build" / "artifacts" / "symbols" / "macos" / "symbol")

        self.run_clean("--aggressive")

        for path in caches:
            self.assertFalse(path.exists())
        self.assertFalse(public_app.is_symlink())
        self.assertTrue(dist.exists())
        self.assertTrue(symbol.exists())

    def test_distribution_cleanup_is_explicit(self) -> None:
        mac = self.write(self.root / "build" / "dist" / "macos" / "Vocello.dmg")
        ios = self.write(self.root / "build" / "dist" / "ios" / "Vocello.ipa")
        cache = self.write(self.root / "build" / "cache" / "xcode" / "macos" / "cache")
        self.run_clean("--dist")
        self.assertFalse(mac.exists())
        self.assertFalse(ios.exists())
        self.assertTrue(cache.exists())

    def test_profile_cleanup_requires_proof_and_keeps_only_latest_failure(self) -> None:
        published_run, published_trace = self.profile_run(
            "mac-memory-profile-20260713-000000-00000001"
        )
        self.profile_marker(
            published_run,
            published_trace,
            platform="macos",
            kind="memory",
            status="published",
            policy="summaryOnly",
            capture_time="2026-07-13T00:00:00Z",
        )
        self.published_profile(published_run, published_trace, platform="macos")
        old_run, old_trace = self.profile_run(
            "mac-memory-profile-20260713-000001-00000002"
        )
        self.profile_marker(
            old_run,
            old_trace,
            platform="macos",
            kind="memory",
            status="failed",
            policy="failedLatest",
            capture_time="2026-07-13T00:00:01Z",
        )
        new_run, new_trace = self.profile_run(
            "mac-memory-profile-20260713-000002-00000003"
        )
        self.profile_marker(
            new_run,
            new_trace,
            platform="macos",
            kind="memory",
            status="failed",
            policy="failedLatest",
            capture_time="2026-07-13T00:00:02Z",
        )

        self.run_clean("--routine")

        self.assertFalse(published_trace.exists())
        self.assertFalse(old_trace.exists())
        self.assertTrue(new_trace.exists())
        old_marker = json.loads((old_run / "profile-retention.json").read_text())
        self.assertEqual(old_marker["retentionPolicy"], "failedCompacted")

    def test_profile_digest_mismatch_is_preserved(self) -> None:
        run, trace = self.profile_run("mac-cpu-profile-20260713-000000-00000001", kind="cpu")
        self.profile_marker(
            run,
            trace,
            platform="macos",
            kind="cpu",
            status="published",
            policy="summaryOnly",
            capture_time="2026-07-13T00:00:00Z",
        )
        self.published_profile(run, trace, platform="macos")
        self.write(trace / "instrument_data" / "events.bin", b"mutated")
        result = self.run_clean("--routine")
        self.assertTrue(trace.exists())
        self.assertIn("invalid-history-proof", result.stdout)

    def test_models_removes_only_debug_store(self) -> None:
        debug = self.write(
            self.home / "Library" / "Application Support" / "QwenVoice-Debug" / "models" / "model"
        )
        shipped = self.write(
            self.home / "Library" / "Application Support" / "QwenVoice" / "models" / "model"
        )
        cache = self.write(self.root / "build" / "cache" / "xcode" / "macos" / "cache")
        self.run_clean("--models")
        self.assertFalse(debug.exists())
        self.assertTrue(shipped.exists())
        self.assertTrue(cache.exists())

    def test_clobber_requires_confirmation_and_refuses_tracked_generated_state(self) -> None:
        generated = self.write(self.root / "build" / "cache" / "payload")
        self.run_clean("--clobber", expected=2)
        self.assertTrue(generated.exists())
        tracked = self.write(self.root / "build" / "tracked.txt")
        self.track(tracked)
        result = self.run_clean("--clobber", "--yes", expected=1)
        self.assertIn("tracked files", result.stderr)
        self.assertTrue(tracked.exists())

    def test_external_xcode_removal_requires_exact_project_info_and_confirmation(self) -> None:
        derived = self.home / "Library" / "Developer" / "Xcode" / "DerivedData"
        matching = derived / "QwenVoice-abc"
        unrelated = derived / "Other-def"
        self.write(matching / "payload")
        self.write(unrelated / "payload")
        with (matching / "info.plist").open("wb") as stream:
            plistlib.dump({"WorkspacePath": str(self.root / "QwenVoice.xcodeproj")}, stream)
        with (unrelated / "info.plist").open("wb") as stream:
            plistlib.dump({"WorkspacePath": "/tmp/Other.xcodeproj"}, stream)
        self.run_clean("--external-xcode", expected=2)
        self.run_clean("--external-xcode", "--yes")
        self.assertFalse(matching.exists())
        self.assertTrue(unrelated.exists())

    def test_symlinked_build_root_cannot_escape_repository(self) -> None:
        outside = Path(self.temporary.name) / "outside"
        self.write(outside / "scratch" / "derived-data" / "foundation" / "payload")
        (self.root / "build").symlink_to(outside, target_is_directory=True)
        result = self.run_clean("--routine", expected=1)
        self.assertIn("escapes", result.stderr)
        self.assertTrue((outside / "scratch" / "derived-data" / "foundation" / "payload").exists())


if __name__ == "__main__":
    unittest.main()
