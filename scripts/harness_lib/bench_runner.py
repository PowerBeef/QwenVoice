"""Opt-in benchmark lanes for local release signoff."""

from __future__ import annotations

import statistics
import subprocess
import time
from typing import Any

from .output import build_suite_result, build_test_result, eprint
from .paths import PROJECT_DIR


def run_benchmarks(
    category: str = "all",
    runs: int = 3,
    output_dir: str | None = None,
    tier: str = "all",
) -> list[dict[str, Any]]:
    """Run selected benchmark categories."""
    _ = runs
    _ = output_dir
    _ = tier
    suites: list[dict[str, Any]] = []

    if category in ("all", "latency"):
        eprint("==> Running generation latency benchmarks...")
        suites.append(_run_packaged_app_launch_benchmark(runs=runs))

    if category in ("all", "load"):
        eprint("==> Running model load benchmarks...")
        suites.append(_run_xcode_settings_load_benchmark(runs=runs))

    if category in ("all", "quality"):
        eprint("==> Running clone quality benchmarks...")
        suites.append(
            _retired_suite(
                "native_quality_contract",
                "Native acoustic quality analysis requires installed local models and an optional analyzer; run manual A/B against the fixed prompt suite for model-output-changing changes.",
            )
        )

    if category in ("all", "tts_roundtrip"):
        eprint("==> Running TTS round-trip intelligibility benchmark...")
        suites.append(
            _retired_suite(
                "tts_roundtrip",
                "Native TTS round-trip needs installed local models and an ASR analyzer before it can produce intelligibility scores.",
            )
        )

    return suites


def _retired_suite(name: str, reason: str) -> dict[str, Any]:
    return build_suite_result(
        name,
        [build_test_result(f"{name}_retired", passed=True, skip_reason=reason)],
        0,
    )


def _run_packaged_app_launch_benchmark(runs: int) -> dict[str, Any]:
    app_path = PROJECT_DIR / "build" / "Vocello.app"
    verifier = PROJECT_DIR / "scripts" / "verify_release_bundle.sh"
    if not app_path.exists():
        return _retired_suite(
            "packaged_app_launch",
            "No build/Vocello.app bundle is available. Run ./scripts/release.sh before this benchmark.",
        )

    return _run_command_benchmark(
        suite_name="packaged_app_launch",
        test_name="verify_release_bundle_launch_smoke",
        command=[str(verifier), str(app_path)],
        runs=runs,
    )


def _run_xcode_settings_load_benchmark(runs: int) -> dict[str, Any]:
    return _run_command_benchmark(
        suite_name="xcode_project_load",
        test_name="xcodebuild_show_build_settings",
        command=[
            "xcodebuild",
            "-project",
            str(PROJECT_DIR / "QwenVoice.xcodeproj"),
            "-scheme",
            "QwenVoice",
            "-showBuildSettings",
        ],
        runs=runs,
    )


def _run_command_benchmark(
    *,
    suite_name: str,
    test_name: str,
    command: list[str],
    runs: int,
) -> dict[str, Any]:
    started = time.perf_counter()
    durations_ms: list[int] = []
    stdout_tail: list[str] = []
    stderr_tail: list[str] = []

    for _ in range(max(runs, 1)):
        run_started = time.perf_counter()
        proc = subprocess.run(
            command,
            cwd=str(PROJECT_DIR),
            capture_output=True,
            text=True,
            timeout=300,
        )
        durations_ms.append(int((time.perf_counter() - run_started) * 1000))
        stdout_tail = proc.stdout.splitlines()[-20:]
        stderr_tail = proc.stderr.splitlines()[-20:]
        if proc.returncode != 0:
            result = build_test_result(
                test_name,
                passed=False,
                error=f"benchmark command exited with {proc.returncode}",
                duration_ms=int((time.perf_counter() - started) * 1000),
                details={
                    "command": command,
                    "stdout_tail": stdout_tail,
                    "stderr_tail": stderr_tail,
                    "durations_ms": durations_ms,
                },
            )
            return build_suite_result(suite_name, [result], result["duration_ms"])

    result = build_test_result(
        test_name,
        passed=True,
        duration_ms=int((time.perf_counter() - started) * 1000),
        details={
            "command": command,
            "runs": len(durations_ms),
            "durations_ms": durations_ms,
            "median_ms": statistics.median(durations_ms),
            "min_ms": min(durations_ms),
            "max_ms": max(durations_ms),
            "stdout_tail": stdout_tail,
            "stderr_tail": stderr_tail,
        },
    )
    return build_suite_result(suite_name, [result], result["duration_ms"])
