"""TTS round-trip intelligibility benchmark for the QwenVoice harness."""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Any

from .backend_client import BackendClient
from .contract import load_contract, model_is_installed
from .output import build_suite_result, build_test_result, eprint
from .paths import PROJECT_DIR, ensure_directory, resolve_backend_python

ROUNDTRIP_CORPUS: list[tuple[str, str]] = [
    ("delivery_notice", "Please leave the package with the concierge if nobody answers."),
    ("numbers_and_time", "The meeting starts at 7:45 PM on platform 12, not platform 2."),
    ("long_form", "QwenVoice keeps generation local on Apple Silicon so private narration work stays offline."),
]
DEFAULT_ASR_MODEL_CANDIDATES = [
    "mlx-community/whisper-tiny-asr-fp16",
]
ASR_MODEL_ENV = "QWENVOICE_TTS_ROUNDTRIP_ASR_MODEL"
CLONE_REFERENCE_PATH = PROJECT_DIR / "tests" / "fixtures" / "release_clone_reference.wav"
CLONE_REFERENCE_TEXT_PATH = PROJECT_DIR / "tests" / "fixtures" / "release_clone_reference.txt"
ASR_HELPER_PATH = PROJECT_DIR / "scripts" / "harness_lib" / "tts_roundtrip_asr.py"


def normalize_wer_text(text: str) -> list[str]:
    return re.findall(r"[a-z0-9']+", text.lower())


def word_error_rate(reference: str, hypothesis: str) -> float:
    ref_words = normalize_wer_text(reference)
    hyp_words = normalize_wer_text(hypothesis)

    if not ref_words:
        return 0.0 if not hyp_words else 1.0

    previous = list(range(len(hyp_words) + 1))
    for ref_index, ref_word in enumerate(ref_words, start=1):
        current = [ref_index]
        for hyp_index, hyp_word in enumerate(hyp_words, start=1):
            substitution_cost = 0 if ref_word == hyp_word else 1
            current.append(
                min(
                    previous[hyp_index] + 1,
                    current[hyp_index - 1] + 1,
                    previous[hyp_index - 1] + substitution_cost,
                )
            )
        previous = current

    return previous[-1] / float(len(ref_words))


def _benchmark_dir(output_dir: str | None) -> Path:
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    bench_dir = (
        Path(output_dir)
        if output_dir
        else PROJECT_DIR / "build" / "benchmarks" / timestamp / "tts_roundtrip"
    )
    return ensure_directory(bench_dir)


def _asr_model_candidates() -> list[str]:
    candidates: list[str] = []
    configured = os.environ.get(ASR_MODEL_ENV, "").strip()
    if configured:
        candidates.append(configured)
    for candidate in DEFAULT_ASR_MODEL_CANDIDATES:
        if candidate not in candidates:
            candidates.append(candidate)
    return candidates


def _first_chunk_ms(notifications: list[dict[str, Any]]) -> float | None:
    for notification in notifications:
        if notification.get("method") == "generation_chunk":
            value = notification.get("_received_at_ms")
            if isinstance(value, (int, float)):
                return round(float(value), 2)
    return None


def _roundtrip_params(
    mode: str,
    text: str,
    output_path: str,
) -> dict[str, Any]:
    params: dict[str, Any] = {
        "text": text,
        "output_path": output_path,
        "benchmark": True,
        "stream": True,
        "streaming_interval": 2.0,
    }
    if mode == "custom":
        params["voice"] = "vivian"
    elif mode == "design":
        params["instruct"] = "A clear and natural female speaker with calm pacing."
    elif mode == "clone":
        params["ref_audio"] = str(CLONE_REFERENCE_PATH)
        if CLONE_REFERENCE_TEXT_PATH.exists():
            params["ref_text"] = CLONE_REFERENCE_TEXT_PATH.read_text(encoding="utf-8").strip()
    return params


def _run_transcriptions(
    *,
    python_path: str,
    bench_dir: Path,
    files: list[str],
) -> tuple[dict[str, str] | None, str | None, str | None]:
    request_payload = {
        "files": files,
        "model_candidates": _asr_model_candidates(),
    }
    request_path = bench_dir / "tts_roundtrip_asr_request.json"
    output_path = bench_dir / "tts_roundtrip_asr_output.json"
    request_path.write_text(json.dumps(request_payload, indent=2), encoding="utf-8")

    proc = subprocess.run(
        [
            python_path,
            str(ASR_HELPER_PATH),
            "--request-json",
            str(request_path),
            "--output-json",
            str(output_path),
        ],
        capture_output=True,
        text=True,
        timeout=1800,
        cwd=str(PROJECT_DIR),
    )

    if proc.returncode == 2:
        detail = proc.stderr.strip() or proc.stdout.strip() or "ASR evaluator is not locally available"
        return None, None, detail

    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "ASR evaluator failed")

    payload = json.loads(output_path.read_text(encoding="utf-8"))
    return payload.get("transcripts", {}), payload.get("resolved_model"), None


def run_tts_roundtrip_bench(
    *,
    python_path: str | None,
    output_dir: str | None,
) -> dict[str, Any]:
    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    try:
        resolved_python = resolve_backend_python(python_path)
    except RuntimeError as exc:
        results.append(
            build_test_result(
                "backend_python_available",
                passed=False,
                skip_reason=str(exc),
            )
        )
        return build_suite_result("tts_roundtrip", results, 0)

    contract = load_contract()
    installed_models = [model for model in contract["models"] if model_is_installed(model["id"])]
    if not installed_models:
        results.append(
            build_test_result(
                "models_available",
                passed=True,
                skip_reason="No installed TTS models available for round-trip benchmarking",
            )
        )
        return build_suite_result("tts_roundtrip", results, 0)

    clone_reference_available = CLONE_REFERENCE_PATH.exists()
    bench_dir = _benchmark_dir(output_dir)
    artifact_records: list[dict[str, Any]] = []

    client = BackendClient(resolved_python)
    try:
        client.start()
        client.call("init", timeout=30)

        for model_def in installed_models:
            mode = model_def["mode"]
            if mode == "clone" and not clone_reference_available:
                results.append(
                    build_test_result(
                        f"tts_roundtrip_{model_def['id']}",
                        passed=True,
                        skip_reason=(
                            "Clone reference fixture is missing at "
                            f"{CLONE_REFERENCE_PATH}"
                        ),
                    )
                )
                continue

            eprint(f"  Round-trip benchmark: loading {model_def['id']}...")
            load_start = time.perf_counter()
            client.call("load_model", {"model_id": model_def["id"], "benchmark": True}, timeout=180)
            cold_load_ms = round((time.perf_counter() - load_start) * 1000, 2)

            file_records: list[dict[str, Any]] = []
            audio_files: list[str] = []
            for sample_name, sample_text in ROUNDTRIP_CORPUS:
                output_path = bench_dir / f"{model_def['id']}_{sample_name}.wav"
                params = _roundtrip_params(mode, sample_text, str(output_path))
                eprint(f"    Generating {model_def['id']} / {sample_name}...")
                result, notifications = client.call_collecting_notifications_timed(
                    "generate",
                    params,
                    timeout=600,
                )
                benchmark = result.get("benchmark", {})
                output_duration_seconds = float(benchmark.get("output_duration_seconds") or 0.0)
                wall_ms = float(result.get("_wall_ms") or 0.0)
                first_chunk_ms = _first_chunk_ms(notifications)
                rtf = None
                if output_duration_seconds > 0:
                    rtf = round((wall_ms / 1000.0) / output_duration_seconds, 4)

                file_records.append(
                    {
                        "sample": sample_name,
                        "reference_text": sample_text,
                        "output_path": str(output_path),
                        "wall_ms": round(wall_ms, 2),
                        "first_chunk_ms": first_chunk_ms,
                        "output_duration_seconds": round(output_duration_seconds, 4),
                        "rtf": rtf,
                        "backend_timings_ms": benchmark.get("timings_ms", {}),
                        "reference_preprocessing": benchmark.get(
                            "reference_preprocessing", {}
                        ),
                    }
                )
                audio_files.append(str(output_path))

            transcripts, evaluator_model, skip_reason = _run_transcriptions(
                python_path=resolved_python,
                bench_dir=bench_dir,
                files=audio_files,
            )
            if skip_reason:
                results.append(
                    build_test_result(
                        f"tts_roundtrip_{model_def['id']}",
                        passed=True,
                        skip_reason=skip_reason,
                        details={
                            "model_id": model_def["id"],
                            "mode": mode,
                            "cold_load_ms": cold_load_ms,
                        },
                    )
                )
                client.call("unload_model", timeout=30)
                continue

            wers: list[float] = []
            wall_times: list[float] = []
            first_chunk_times: list[float] = []
            rtfs: list[float] = []

            for record in file_records:
                transcription = (transcripts or {}).get(record["output_path"], "")
                record["transcription"] = transcription
                wer = round(word_error_rate(record["reference_text"], transcription), 4)
                record["wer"] = wer
                wers.append(wer)
                wall_times.append(record["wall_ms"])
                if isinstance(record["first_chunk_ms"], (int, float)):
                    first_chunk_times.append(float(record["first_chunk_ms"]))
                if isinstance(record["rtf"], (int, float)):
                    rtfs.append(float(record["rtf"]))

            artifact = {
                "model_id": model_def["id"],
                "mode": mode,
                "cold_load_ms": cold_load_ms,
                "evaluator_model": evaluator_model,
                "records": file_records,
            }
            artifact_records.append(artifact)
            artifact_path = bench_dir / f"{model_def['id']}_tts_roundtrip.json"
            artifact_path.write_text(json.dumps(artifact, indent=2), encoding="utf-8")

            details = {
                "model_id": model_def["id"],
                "mode": mode,
                "evaluator_model": evaluator_model,
                "corpus_size": len(file_records),
                "cold_load_ms": cold_load_ms,
                "wer": {
                    "mean": round(sum(wers) / len(wers), 4),
                    "max": round(max(wers), 4),
                },
                "wall_ms": {
                    "mean": round(sum(wall_times) / len(wall_times), 2),
                    "max": round(max(wall_times), 2),
                },
                "first_chunk_ms": (
                    {
                        "mean": round(sum(first_chunk_times) / len(first_chunk_times), 2),
                        "max": round(max(first_chunk_times), 2),
                    }
                    if first_chunk_times
                    else None
                ),
                "rtf": (
                    {
                        "mean": round(sum(rtfs) / len(rtfs), 4),
                        "max": round(max(rtfs), 4),
                    }
                    if rtfs
                    else None
                ),
                "artifact_path": str(artifact_path),
            }
            results.append(
                build_test_result(
                    f"tts_roundtrip_{model_def['id']}",
                    passed=True,
                    details=details,
                )
            )
            client.call("unload_model", timeout=30)

    except Exception as exc:
        results.append(
            build_test_result(
                "tts_roundtrip_runner",
                passed=False,
                error=str(exc),
            )
        )
    finally:
        client.stop()

    summary_path = bench_dir / "tts_roundtrip_summary.json"
    summary_path.write_text(json.dumps({"models": artifact_records}, indent=2), encoding="utf-8")

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("tts_roundtrip", results, duration_ms)
