#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts/refresh_derived_artifacts.py"
SPEC = importlib.util.spec_from_file_location("refresh_derived_artifacts", HELPER)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
import sys

sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class RefreshDerivedArtifactsTests(unittest.TestCase):
    def test_artifact_ids_are_unique_and_documented(self) -> None:
        ids = [artifact.artifact_id for artifact in MODULE.ARTIFACTS]
        self.assertEqual(ids, sorted(set(ids), key=ids.index))
        self.assertIn("vendor-current-inventory", ids)
        self.assertIn("project-health-summary", ids)
        self.assertIn("documentation-index", ids)

    def test_is_stale_matches_marker_and_ignores_unrelated_failures(self) -> None:
        artifact = MODULE.ARTIFACTS[0]
        stale = subprocess.CompletedProcess(
            args=[],
            returncode=1,
            stdout="",
            stderr="error: CURRENT_INVENTORY is stale; run rebuild\n",
        )
        other = subprocess.CompletedProcess(
            args=[],
            returncode=1,
            stdout="",
            stderr="error: unrelated contract failure\n",
        )
        ok = subprocess.CompletedProcess(args=[], returncode=0, stdout="PASS\n", stderr="")
        self.assertTrue(MODULE.is_stale(artifact, stale))
        self.assertFalse(MODULE.is_stale(artifact, other))
        self.assertFalse(MODULE.is_stale(artifact, ok))

    def test_status_and_validate_pass_on_current_checkout(self) -> None:
        status = subprocess.run(
            ["python3", str(HELPER), "status"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(status.returncode, 0, status.stdout + status.stderr)
        validate = subprocess.run(
            ["python3", str(HELPER), "validate"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(validate.returncode, 0, validate.stdout + validate.stderr)
        self.assertIn("Derived artifacts: PASS", validate.stdout)

    def test_dry_run_refresh_does_not_fail_when_fresh(self) -> None:
        result = subprocess.run(
            ["python3", str(HELPER), "refresh", "--dry-run"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("nothing to refresh", result.stdout)


if __name__ == "__main__":
    unittest.main()
