"""Bench subcommand — source-build benchmark surface for the QwenVoice harness."""

from __future__ import annotations

from typing import Any

from .output import build_suite_result, build_test_result, eprint


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
