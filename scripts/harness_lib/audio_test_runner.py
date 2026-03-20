"""Audio pipeline test runner — live and offline modes.

Live mode: starts the backend via RPC, generates audio with streaming, and
validates chunk-to-final fidelity, timing, artifacts, and loudness.

Offline mode: loads pre-existing chunk_*.wav + final.wav from a directory.
"""

from __future__ import annotations

import os
import tempfile
import time
from pathlib import Path
from typing import Any

from .output import build_suite_result, build_test_result, eprint


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

def run_audio_tests(
    python_path: str | None = None,
    artifact_dir: str | None = None,
) -> dict[str, Any]:
    """Run audio pipeline tests. Returns build_suite_result dict.

    If artifact_dir is set -> offline mode. Otherwise -> live mode via RPC.
    """
    if artifact_dir:
        return _run_offline_audio_tests(artifact_dir)
    return _run_live_audio_tests(python_path)


# ---------------------------------------------------------------------------
# Test wrapper
# ---------------------------------------------------------------------------

def _wrap_analysis(test_name: str, fn: Any, *args: Any, **kwargs: Any) -> dict[str, Any]:
    """Call fn, catch exceptions, wrap into build_test_result format."""
    start = time.perf_counter()
    try:
        result = fn(*args, **kwargs)
        duration_ms = int((time.perf_counter() - start) * 1000)
        passed = result.get("passed", False)
        skip_reason = result.get("skip_reason")
        error = result.get("error") if not passed else None
        # Strip passed/error/skip_reason from details to avoid duplication
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


# ---------------------------------------------------------------------------
# Notification extraction
# ---------------------------------------------------------------------------

def _extract_chunk_metadata(
    notifications: list[dict[str, Any]],
) -> tuple[list[str], list[float], float | None, list[float]]:
    """Filter for method=='generation_chunk', extract paths/durations/timestamps.

    Returns (chunk_paths, chunk_durations, last_cumulative, received_at_ms).
    """
    chunk_paths: list[str] = []
    chunk_durations: list[float] = []
    received_at_ms: list[float] = []
    last_cumulative: float | None = None

    for n in notifications:
        if n.get("method") != "generation_chunk":
            continue
        params = n.get("params", {})
        path = params.get("chunk_path")
        if path:
            chunk_paths.append(path)
        dur = params.get("chunk_duration_seconds")
        if dur is not None:
            chunk_durations.append(float(dur))
        cum = params.get("cumulative_duration_seconds")
        if cum is not None:
            last_cumulative = float(cum)
        ts = n.get("_received_at_ms")
        if ts is not None:
            received_at_ms.append(float(ts))

    return chunk_paths, chunk_durations, last_cumulative, received_at_ms


# ---------------------------------------------------------------------------
# Live mode
# ---------------------------------------------------------------------------

def _run_live_audio_tests(python_path: str | None) -> dict[str, Any]:
    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    from .contract import model_ids, model_is_installed
    from .paths import resolve_backend_python

    try:
        resolved_python = resolve_backend_python(python_path)
    except RuntimeError as exc:
        results.append(build_test_result(
            "backend_python_available", passed=False, skip_reason=str(exc),
        ))
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("audio_pipeline", results, duration_ms)

    # Find a custom-mode model that is installed
    installed = [mid for mid in model_ids() if model_is_installed(mid)]
    if not installed:
        results.append(build_test_result(
            "model_available", passed=True,
            skip_reason="No models installed — skipping audio pipeline tests",
        ))
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("audio_pipeline", results, duration_ms)

    from .backend_client import BackendClient
    from .contract import load_contract

    # Pick the first installed model (prefer custom mode for speaker-based generation)
    contract = load_contract()
    model_id = installed[0]
    for m in contract["models"]:
        if m["id"] in installed and m["mode"] == "custom":
            model_id = m["id"]
            break

    client: BackendClient | None = None
    tmp_dir = tempfile.mkdtemp(prefix="qwenvoice_audio_test_")
    try:
        # Start backend
        client = BackendClient(resolved_python)
        client.start()
        eprint(f"  Backend started, using model {model_id}")

        # Init
        client.call("init", {"app_support_dir": os.path.expanduser(
            "~/Library/Application Support/QwenVoice"
        )}, timeout=30)

        # Load model
        client.call("load_model", {"model_id": model_id}, timeout=120)
        eprint("  Model loaded")

        # Generate with streaming
        output_path = os.path.join(tmp_dir, "final.wav")
        gen_params: dict[str, Any] = {
            "text": "The quick brown fox jumps over the lazy dog near the riverbank.",
            "output_path": output_path,
            "voice": "vivian",
            "stream": True,
            "streaming_interval": 0.32,
        }

        eprint("  Generating audio with streaming...")
        gen_result, notifications = client.call_collecting_notifications_timed(
            "generate", gen_params, timeout=300,
        )

        # Extract chunk metadata from notifications
        chunk_paths, chunk_durations, last_cumulative, received_at_ms = (
            _extract_chunk_metadata(notifications)
        )

        eprint(f"  Got {len(chunk_paths)} chunk(s), loading audio...")

        # Load chunks from their actual paths
        from .audio_analysis import load_wav

        chunks: list[tuple[Any, int]] = []
        sample_rate = 0
        for cp in chunk_paths:
            if Path(cp).exists():
                data, sr = load_wav(cp)
                chunks.append((data, sr))
                if sample_rate == 0:
                    sample_rate = sr

        # Load final audio
        final_audio = None
        actual_output = gen_result.get("audio_path", output_path)
        if Path(actual_output).exists():
            final_audio, sr = load_wav(actual_output)
            if sample_rate == 0:
                sample_rate = sr

        # Run all 12 analyses
        from .audio_analysis import run_all_analyses
        analyses = run_all_analyses(
            chunks, final_audio, sample_rate,
            reported_durations=chunk_durations if chunk_durations else None,
            reported_cumulative=last_cumulative,
            received_at_ms=received_at_ms if received_at_ms else None,
        )

        for test_name, analysis in analyses.items():
            results.append(_wrap_analysis(test_name, lambda a=analysis: a))

        # Unload model
        client.call("unload_model", timeout=30)

    except Exception as exc:
        results.append(build_test_result(
            "audio_pipeline_setup", passed=False, error=str(exc),
        ))
    finally:
        if client is not None:
            client.stop()
        # Clean up temp dir
        import shutil
        shutil.rmtree(tmp_dir, ignore_errors=True)

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("audio_pipeline", results, duration_ms)


# ---------------------------------------------------------------------------
# Offline mode
# ---------------------------------------------------------------------------

def _run_offline_audio_tests(artifact_dir: str) -> dict[str, Any]:
    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    artifact_path = Path(artifact_dir)
    if not artifact_path.is_dir():
        results.append(build_test_result(
            "artifact_dir_exists", passed=False,
            error=f"Directory not found: {artifact_dir}",
        ))
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("audio_pipeline", results, duration_ms)

    try:
        from .audio_analysis import load_chunk_directory
        chunks, final_audio, sample_rate = load_chunk_directory(artifact_path)
    except Exception as exc:
        results.append(build_test_result(
            "load_artifacts", passed=False,
            error=f"Failed to load audio from {artifact_dir}: {exc}",
        ))
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("audio_pipeline", results, duration_ms)

    eprint(f"  Loaded {len(chunks)} chunk(s) from {artifact_dir}")

    # Offline mode: no reported durations or timestamps
    from .audio_analysis import run_all_analyses
    analyses = run_all_analyses(
        chunks, final_audio, sample_rate,
        reported_durations=None,
        reported_cumulative=None,
        received_at_ms=None,
    )

    for test_name, analysis in analyses.items():
        results.append(_wrap_analysis(test_name, lambda a=analysis: a))

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("audio_pipeline", results, duration_ms)
