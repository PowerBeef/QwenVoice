"""Audio artifact test runner — offline analysis of native-generated files."""

from __future__ import annotations

import time
from pathlib import Path
from typing import Any

from .output import build_suite_result, build_test_result, eprint


def run_audio_tests(artifact_dir: str | None = None) -> dict[str, Any]:
    """Run audio artifact analysis against an existing artifact directory."""
    if not artifact_dir:
        return build_suite_result(
            "audio_pipeline",
            [
                build_test_result(
                    "native_audio_artifacts_required",
                    passed=True,
                    skip_reason="Pass --artifact-dir with native-generated chunk_*.wav and final.wav files.",
                )
            ],
            0,
        )
    return _run_offline_audio_tests(artifact_dir)


def _wrap_analysis(test_name: str, fn: Any, *args: Any, **kwargs: Any) -> dict[str, Any]:
    start = time.perf_counter()
    try:
        result = fn(*args, **kwargs)
        duration_ms = int((time.perf_counter() - start) * 1000)
        passed = result.get("passed", False)
        skip_reason = result.get("skip_reason")
        error = result.get("error") if not passed else None
        details = {k: v for k, v in result.items() if k not in ("passed", "error", "skip_reason")}
        return build_test_result(
            test_name,
            passed=passed,
            skip_reason=skip_reason,
            error=error,
            duration_ms=duration_ms,
            details=details if details else None,
        )
    except Exception as exc:
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_test_result(test_name, passed=False, error=str(exc), duration_ms=duration_ms)


def _run_offline_audio_tests(artifact_dir: str) -> dict[str, Any]:
    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    artifact_path = Path(artifact_dir)
    if not artifact_path.is_dir():
        results.append(
            build_test_result(
                "artifact_dir_exists",
                passed=False,
                error=f"Directory not found: {artifact_dir}",
            )
        )
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("audio_pipeline", results, duration_ms)

    try:
        from .audio_analysis import load_chunk_directory

        chunks, final_audio, sample_rate = load_chunk_directory(artifact_path)
    except Exception as exc:
        results.append(
            build_test_result(
                "load_artifacts",
                passed=False,
                error=f"Failed to load audio from {artifact_dir}: {exc}",
            )
        )
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("audio_pipeline", results, duration_ms)

    eprint(f"  Loaded {len(chunks)} chunk(s) from {artifact_dir}")

    from .audio_analysis import run_all_analyses

    analyses = run_all_analyses(chunks, final_audio, sample_rate)
    for test_name, analysis in analyses.items():
        results.append(_wrap_analysis(test_name, lambda a=analysis: a))

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("audio_pipeline", results, duration_ms)
