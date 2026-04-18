"""Bench subcommand — native-only benchmark surface for the QwenVoice harness."""

from __future__ import annotations

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
        suites.append(_retired_suite("generation_latency", "Native latency benchmarking is not yet reimplemented in the harness."))

    if category in ("all", "load"):
        eprint("==> Running model load benchmarks...")
        suites.append(_retired_suite("model_load", "Native load benchmarking is not yet reimplemented in the harness."))

    if category in ("all", "quality"):
        eprint("==> Running clone quality benchmarks...")
        suites.append(_retired_suite("clone_quality", "The old quality lane depended on the deleted Python backend path."))

    if category in ("all", "release"):
        eprint("==> Running release bundle validation...")
        suites.append(_run_release_bench())

    if category in ("all", "tts_roundtrip"):
        eprint("==> Running TTS round-trip intelligibility benchmark...")
        suites.append(_retired_suite("tts_roundtrip", "TTS round-trip needs a native harness rewrite before it can run again."))

    if category in ("all", "perf"):
        eprint("==> Running exhaustive performance profiler...")
        suites.append(_retired_suite("perf_profiler", "The old perf lane depended on backend timing surfaces that no longer exist."))

    return suites


def _retired_suite(name: str, reason: str) -> dict[str, Any]:
    return build_suite_result(
        name,
        [build_test_result(f"{name}_retired", passed=True, skip_reason=reason)],
        0,
    )


def _run_release_bench() -> dict[str, Any]:
    start = time.perf_counter()
    verify_script = PROJECT_DIR / "scripts" / "verify_release_bundle.sh"
    build_app = PROJECT_DIR / "build" / "QwenVoice.app"
    if not build_app.exists():
        return build_suite_result(
            "release_bundle_validation",
            [
                build_test_result(
                    "release_bundle_available",
                    passed=True,
                    skip_reason="Local build/QwenVoice.app is missing.",
                )
            ],
            0,
        )

    proc = subprocess.run(
        [str(verify_script), str(build_app)],
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
    )
    result = build_test_result(
        "verify_release_bundle",
        passed=proc.returncode == 0,
        error=None if proc.returncode == 0 else f"verify_release_bundle.sh exited with {proc.returncode}",
        duration_ms=int((time.perf_counter() - start) * 1000),
        details={
            "app_bundle": str(build_app),
            "stdout_tail": proc.stdout.splitlines()[-20:],
            "stderr_tail": proc.stderr.splitlines()[-20:],
        },
    )
    return build_suite_result("release_bundle_validation", [result], result["duration_ms"])
