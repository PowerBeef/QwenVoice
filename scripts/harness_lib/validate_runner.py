"""Validate subcommand — fast pre-commit checks."""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from .contract import load_contract
from .output import build_suite_result, build_test_result, eprint
from .paths import (
    APP_VENV_PYTHON,
    BACKEND_DIR,
    BUNDLED_PYTHON_BIN,
    BUNDLED_RUNTIME_MANIFEST,
    PROJECT_DIR,
    resolve_backend_python,
)
from .runtime_alignment import (
    app_core_requirements,
    cli_core_requirements,
    compare_expected_versions,
    describe_version_alignment,
    inspect_python_environment,
    load_runtime_manifest,
    manifest_core_versions,
    read_mlx_audio_target_version,
    read_pythonbridge_mlx_audio_versions,
    resolved_python_for_environment,
)


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

    def test_runtime_pin_consistency():
        expected = app_core_requirements()
        cli_versions = cli_core_requirements()
        cli_mismatches = compare_expected_versions(expected, cli_versions)
        if cli_mismatches:
            raise AssertionError(
                f"CLI shared core pins drifted from app requirements: {json.dumps(cli_mismatches, sort_keys=True)}"
            )

        target_version = read_mlx_audio_target_version()
        if target_version != expected["mlx-audio"]:
            raise AssertionError(
                "scripts/build_mlx_audio_wheel.sh TARGET_VERSION drifted from app requirements: "
                f"{target_version} != {expected['mlx-audio']}"
            )

        swift_versions = read_pythonbridge_mlx_audio_versions()
        if swift_versions != {expected["mlx-audio"]}:
            raise AssertionError(
                "PythonBridge stub mlx_audio_version drifted from app requirements: "
                f"{sorted(swift_versions)} != {[expected['mlx-audio']]}"
            )

        return {
            "expected": expected,
            "cli_versions": cli_versions,
            "mlx_audio_target_version": target_version,
            "pythonbridge_mlx_audio_versions": sorted(swift_versions),
        }

    def test_explicit_python_alignment():
        if not python_path:
            return {"skip_reason": "no explicit --python supplied"}

        resolved = Path(python_path)
        if not resolved.exists():
            return {"skip_reason": f"explicit python not found: {resolved}"}

        expected = app_core_requirements()
        actual = inspect_python_environment(str(resolved))
        details = describe_version_alignment("explicit_python", expected, actual)
        if details["mismatches"]:
            raise AssertionError(json.dumps(details["mismatches"], sort_keys=True))
        return details

    def test_local_app_venv_alignment():
        resolved = resolved_python_for_environment(APP_VENV_PYTHON)
        if resolved is None:
            return {"skip_reason": f"app venv missing at {APP_VENV_PYTHON.parent}"}

        expected = app_core_requirements()
        actual = inspect_python_environment(resolved)
        details = describe_version_alignment("app_support_venv", expected, actual)
        if details["mismatches"]:
            raise AssertionError(json.dumps(details["mismatches"], sort_keys=True))
        return details

    def test_bundled_runtime_alignment():
        resolved = resolved_python_for_environment(BUNDLED_PYTHON_BIN)
        if resolved is None:
            return {"skip_reason": f"bundled python missing at {BUNDLED_PYTHON_BIN.parent}"}

        expected = app_core_requirements()
        actual = inspect_python_environment(resolved)
        details = describe_version_alignment("bundled_runtime", expected, actual)
        if details["mismatches"]:
            raise AssertionError(json.dumps(details["mismatches"], sort_keys=True))

        if not BUNDLED_RUNTIME_MANIFEST.exists():
            raise AssertionError(f"Bundled runtime manifest missing at {BUNDLED_RUNTIME_MANIFEST}")

        manifest = load_runtime_manifest(BUNDLED_RUNTIME_MANIFEST)
        manifest_versions = manifest_core_versions(manifest)
        manifest_mismatches = compare_expected_versions(expected, manifest_versions)
        details["manifest_versions"] = manifest_versions
        if manifest_mismatches:
            raise AssertionError(
                f"Bundled runtime manifest drifted from app requirements: {json.dumps(manifest_mismatches, sort_keys=True)}"
            )

        runtime_manifest_mismatches = compare_expected_versions(actual, manifest_versions)
        if runtime_manifest_mismatches:
            raise AssertionError(
                "Bundled runtime manifest does not match installed bundled packages: "
                f"{json.dumps(runtime_manifest_mismatches, sort_keys=True)}"
            )
        return details

    tests = [
        ("contract_consistency", test_contract_consistency),
        ("backend_importable", test_backend_importable),
        ("project_inputs_clean", test_project_inputs),
        ("runtime_pin_consistency", test_runtime_pin_consistency),
        ("explicit_python_alignment", test_explicit_python_alignment),
        ("local_app_venv_alignment", test_local_app_venv_alignment),
        ("bundled_runtime_alignment", test_bundled_runtime_alignment),
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
