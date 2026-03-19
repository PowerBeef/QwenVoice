"""Validate subcommand — fast pre-commit checks."""

from __future__ import annotations

import json
import subprocess
import sys
import time
from typing import Any

from .contract import load_contract
from .output import build_suite_result, build_test_result, eprint
from .paths import BACKEND_DIR, PROJECT_DIR, resolve_backend_python


def run_validate(python_path: str | None = None) -> list[dict[str, Any]]:
    """Run fast pre-commit validation checks."""
    eprint("==> Running pre-commit validation...")
    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    # Contract consistency
    def test_contract_consistency():
        contract = load_contract()
        assert "models" in contract and len(contract["models"]) > 0
        assert "speakers" in contract and len(contract["speakers"]) > 0
        assert "defaultSpeaker" in contract

        # No duplicate IDs
        ids = [m["id"] for m in contract["models"]]
        assert len(ids) == len(set(ids)), f"Duplicate model IDs: {ids}"

        # No duplicate modes
        modes = [m["mode"] for m in contract["models"]]
        assert len(modes) == len(set(modes)), f"Duplicate modes: {modes}"

        # Default speaker in list
        all_speakers = []
        for group_name in sorted(contract["speakers"].keys()):
            all_speakers.extend(contract["speakers"][group_name])
        assert contract["defaultSpeaker"] in all_speakers

    def test_backend_importable():
        # Determine which Python to use — try app venv, fall back to current
        try:
            py = resolve_backend_python(python_path)
        except RuntimeError:
            py = sys.executable

        proc = subprocess.run(
            [
                py, "-c",
                "import sys; sys.path.insert(0, '{}'); "
                "import clone_delivery_pipeline; "
                "import server".format(str(BACKEND_DIR)),
            ],
            capture_output=True,
            text=True,
            timeout=30,
            cwd=str(BACKEND_DIR),
        )
        if proc.returncode != 0:
            raise AssertionError(
                f"Backend import failed: {proc.stderr.strip()}"
            )

    def test_project_inputs():
        check_script = PROJECT_DIR / "scripts" / "check_project_inputs.sh"
        if not check_script.exists():
            return {"skip_reason": "check_project_inputs.sh not found"}
        proc = subprocess.run(
            ["bash", str(check_script)],
            capture_output=True,
            text=True,
            timeout=30,
            cwd=str(PROJECT_DIR),
        )
        if proc.returncode != 0:
            raise AssertionError(
                f"Project inputs check failed: {proc.stderr.strip()}"
            )

    tests = [
        ("contract_consistency", test_contract_consistency),
        ("backend_importable", test_backend_importable),
        ("project_inputs_clean", test_project_inputs),
    ]

    for name, fn in tests:
        t0 = time.perf_counter()
        try:
            result = fn()
            dt = int((time.perf_counter() - t0) * 1000)
            if isinstance(result, dict) and result.get("skip_reason"):
                results.append(build_test_result(name, passed=True, skip_reason=result["skip_reason"], duration_ms=dt))
            else:
                results.append(build_test_result(name, passed=True, duration_ms=dt))
        except Exception as exc:
            dt = int((time.perf_counter() - t0) * 1000)
            results.append(build_test_result(name, passed=False, error=str(exc), duration_ms=dt))

    duration_ms = int((time.perf_counter() - start) * 1000)
    return [build_suite_result("pre_commit_validation", results, duration_ms)]
