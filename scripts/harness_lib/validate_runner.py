"""Validate subcommand — fast native-only repo checks."""

from __future__ import annotations

import subprocess
import time
from typing import Any

from .contract import load_contract
from .output import build_suite_result, build_test_result, eprint
from .paths import PROJECT_DIR


def run_validate() -> list[dict[str, Any]]:
    """Run fast pre-commit validation checks."""
    eprint("==> Running pre-commit validation...")
    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    def test_contract_consistency() -> None:
        contract = load_contract()
        assert "models" in contract and len(contract["models"]) > 0
        assert "speakers" in contract and len(contract["speakers"]) > 0
        assert "defaultSpeaker" in contract

        ids = [model["id"] for model in contract["models"]]
        assert len(ids) == len(set(ids)), f"Duplicate model IDs: {ids}"

        modes = [model["mode"] for model in contract["models"]]
        assert len(modes) == len(set(modes)), f"Duplicate modes: {modes}"

        all_speakers: list[str] = []
        for group_name in sorted(contract["speakers"].keys()):
            all_speakers.extend(contract["speakers"][group_name])
        assert contract["defaultSpeaker"] in all_speakers

    def test_project_inputs() -> dict[str, Any] | None:
        check_script = PROJECT_DIR / "scripts" / "check_project_inputs.sh"
        if not check_script.exists():
            return {"skip_reason": "check_project_inputs.sh not found"}

        proc = subprocess.run(
            ["bash", str(check_script)],
            capture_output=True,
            text=True,
            timeout=60,
            cwd=str(PROJECT_DIR),
        )
        if proc.returncode != 0:
            raise AssertionError(f"Project inputs check failed: {proc.stderr.strip()}")
        return None

    tests = [
        ("contract_consistency", test_contract_consistency),
        ("project_inputs_clean", test_project_inputs),
    ]

    for name, fn in tests:
        t0 = time.perf_counter()
        try:
            result = fn()
            dt = int((time.perf_counter() - t0) * 1000)
            if isinstance(result, dict) and result.get("skip_reason"):
                results.append(
                    build_test_result(
                        name,
                        passed=True,
                        skip_reason=result["skip_reason"],
                        duration_ms=dt,
                    )
                )
            else:
                results.append(build_test_result(name, passed=True, duration_ms=dt))
        except Exception as exc:
            dt = int((time.perf_counter() - t0) * 1000)
            results.append(build_test_result(name, passed=False, error=str(exc), duration_ms=dt))

    duration_ms = int((time.perf_counter() - start) * 1000)
    return [build_suite_result("pre_commit_validation", results, duration_ms)]
