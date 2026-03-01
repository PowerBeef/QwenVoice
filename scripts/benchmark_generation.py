#!/usr/bin/env python3
"""Fully automated backend-first generation benchmark for QwenVoice."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import platform
import queue
import shutil
import statistics
import subprocess
import sys
import threading
import time
import traceback
import urllib.request
import wave
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PROJECT_DIR = Path(__file__).resolve().parents[1]
SERVER_PATH = PROJECT_DIR / "Sources" / "Resources" / "backend" / "server.py"
REQUIREMENTS_PATH = PROJECT_DIR / "Sources" / "Resources" / "requirements.txt"
VENDOR_DIR = PROJECT_DIR / "Sources" / "Resources" / "vendor"
DEFAULT_BENCH_ROOT = PROJECT_DIR / "build" / "benchmarks"
APP_SUPPORT_DIR = Path.home() / "Library" / "Application Support" / "QwenVoice"
APP_VENV_PYTHON = APP_SUPPORT_DIR / "python" / "bin" / "python3"
APP_MODELS_DIR = APP_SUPPORT_DIR / "models"
BENCHMARK_SCRIPT_VERSION = "1.1.0"

REFERENCE_TEXT = (
    "Hello, this is the benchmark reference voice speaking clearly for the cloning performance test."
)
SHORT_TEXT = "The quick brown fox jumps over the lazy dog."
MEDIUM_TEXT = (
    "The benchmark harness measures repeated speech generation latency under a stable local setup, "
    "tracking both end to end response time and backend stage timing so regressions remain easy to spot."
)
CLONE_TEXT = (
    "This benchmark measures cloning performance with a stable reference sample and a fixed prompt."
)
VOICE_DESCRIPTION = (
    "Warm, confident, conversational female narrator with steady pacing and clear articulation."
)
KATHLEEN_BASE_URL = "https://raw.githubusercontent.com/rhasspy/dataset-voice-kathleen/master"
KATHLEEN_REFERENCE_STEMS = [
    "data/arctic_a0001_1592748600",
    "data/arctic_a0002_1592748556",
    "data/arctic_a0003_1592748511",
    "data/arctic_a0004_1592748478",
]

MODEL_MANIFEST = {
    "pro_custom": {
        "folder": "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
        "repo": "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
    },
    "pro_design": {
        "folder": "Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit",
        "repo": "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit",
    },
    "pro_clone": {
        "folder": "Qwen3-TTS-12Hz-1.7B-Base-8bit",
        "repo": "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit",
    },
}


@dataclass(frozen=True)
class Scenario:
    identifier: str
    model_id: str
    params: dict[str, Any]
    cold_reset: bool = True
    use_streaming: bool = False
    skip_reason: str | None = None


class BackendClient:
    """Minimal newline-delimited JSON-RPC client for the backend server."""

    def __init__(
        self,
        python_path: str,
        rpc_events_path: Path,
        backend_log_path: Path,
        ffmpeg_path: str | None,
    ) -> None:
        self.python_path = python_path
        self.rpc_events_path = rpc_events_path
        self.backend_log_path = backend_log_path
        self.ffmpeg_path = ffmpeg_path
        self.proc: subprocess.Popen[str] | None = None
        self._stdout_thread: threading.Thread | None = None
        self._stderr_thread: threading.Thread | None = None
        self._events: queue.Queue[tuple[float, dict[str, Any]]] = queue.Queue()
        self._next_id = 1
        self._rpc_log_handle = rpc_events_path.open("a", encoding="utf-8")
        self._backend_log_handle = backend_log_path.open("a", encoding="utf-8")
        self._stderr_tail: list[str] = []

    def _record_event(self, direction: str, payload: dict[str, Any]) -> None:
        record = {
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "direction": direction,
            "payload": payload,
        }
        try:
            self._rpc_log_handle.write(json.dumps(record, sort_keys=True) + "\n")
            self._rpc_log_handle.flush()
        except ValueError:
            return

    def _stdout_loop(self) -> None:
        assert self.proc is not None and self.proc.stdout is not None
        for raw in self.proc.stdout:
            line = raw.rstrip("\n")
            if not line:
                continue
            timestamp = time.perf_counter()
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                self._record_event(
                    "from_backend_parse_error",
                    {"raw": line},
                )
                continue
            self._record_event("from_backend", message)
            self._events.put((timestamp, message))

    def _stderr_loop(self) -> None:
        assert self.proc is not None and self.proc.stderr is not None
        for raw in self.proc.stderr:
            try:
                self._backend_log_handle.write(raw)
                self._backend_log_handle.flush()
            except ValueError:
                return
            line = raw.rstrip("\n")
            if line:
                self._stderr_tail.append(line)
                if len(self._stderr_tail) > 200:
                    self._stderr_tail = self._stderr_tail[-200:]

    def start(self) -> None:
        env = os.environ.copy()
        env["PYTHONUNBUFFERED"] = "1"
        if self.ffmpeg_path:
            env["QWENVOICE_FFMPEG_PATH"] = self.ffmpeg_path
        self.proc = subprocess.Popen(
            [self.python_path, str(SERVER_PATH)],
            cwd=str(PROJECT_DIR),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env,
        )
        self._stdout_thread = threading.Thread(target=self._stdout_loop, daemon=True)
        self._stderr_thread = threading.Thread(target=self._stderr_loop, daemon=True)
        self._stdout_thread.start()
        self._stderr_thread.start()
        self.wait_until_ready()

    def wait_until_ready(self, timeout: float = 60.0) -> None:
        deadline = time.perf_counter() + timeout
        while time.perf_counter() < deadline:
            remaining = max(0.1, deadline - time.perf_counter())
            try:
                _, message = self._events.get(timeout=min(1.0, remaining))
            except queue.Empty:
                continue
            if message.get("method") == "ready":
                return
        raise RuntimeError("Timed out waiting for backend ready notification")

    def call(self, method: str, params: dict[str, Any] | None = None, timeout: float = 900.0) -> dict[str, Any]:
        if self.proc is None or self.proc.stdin is None:
            raise RuntimeError("Backend process is not running")

        request_id = self._next_id
        self._next_id += 1
        request = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params or {},
        }
        self._record_event("to_backend", request)
        self.proc.stdin.write(json.dumps(request) + "\n")
        self.proc.stdin.flush()

        start = time.perf_counter()
        deadline = start + timeout
        first_progress_ms: int | None = None
        first_chunk_ms: int | None = None
        progress_count = 0
        chunk_count = 0

        while time.perf_counter() < deadline:
            remaining = max(0.1, deadline - time.perf_counter())
            try:
                timestamp, message = self._events.get(timeout=min(1.0, remaining))
            except queue.Empty:
                continue

            if message.get("id") == request_id:
                if "error" in message:
                    error = message["error"]
                    raise RuntimeError(error.get("message", "Unknown RPC error"))
                return {
                    "result": message.get("result", {}),
                    "metrics": {
                        "request_id": request_id,
                        "first_progress_ms": first_progress_ms,
                        "first_chunk_ms": first_chunk_ms,
                        "progress_count": progress_count,
                        "chunk_count": chunk_count,
                        "total_wall_ms": int((timestamp - start) * 1000),
                    },
                }

            method_name = message.get("method")
            if method_name == "progress":
                progress_count += 1
                if first_progress_ms is None:
                    first_progress_ms = int((timestamp - start) * 1000)
            elif method_name == "generation_chunk":
                params_obj = message.get("params", {})
                if params_obj.get("request_id") == request_id:
                    chunk_count += 1
                    if first_chunk_ms is None:
                        first_chunk_ms = int((timestamp - start) * 1000)

        raise TimeoutError(f"Timed out waiting for RPC response: {method}")

    def stderr_excerpt(self, lines: int = 25) -> str:
        if not self._stderr_tail:
            return ""
        return "\n".join(self._stderr_tail[-lines:])

    def stop(self) -> None:
        if self.proc is not None:
            if self.proc.stdin is not None:
                try:
                    self.proc.stdin.close()
                except OSError:
                    pass
            if self.proc.poll() is None:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait(timeout=5)
        if self._stdout_thread is not None:
            self._stdout_thread.join(timeout=2)
        if self._stderr_thread is not None:
            self._stderr_thread.join(timeout=2)
        self._rpc_log_handle.close()
        self._backend_log_handle.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=7, help="Measured warm runs per scenario.")
    parser.add_argument("--cold-runs", type=int, default=1, help="Measured cold runs per scenario.")
    parser.add_argument("--output-dir", default="", help="Override the benchmark run directory.")
    parser.add_argument(
        "--model-cache-dir",
        default=str(DEFAULT_BENCH_ROOT / "model-cache"),
        help="Persistent cache for downloaded models.",
    )
    parser.add_argument("--download-missing", dest="download_missing", action="store_true", default=True)
    parser.add_argument("--no-download-missing", dest="download_missing", action="store_false")
    parser.add_argument("--include-streaming", dest="include_streaming", action="store_true", default=True)
    parser.add_argument("--no-streaming", dest="include_streaming", action="store_false")
    parser.add_argument("--include-app-sanity", action="store_true", help="Run the UI sanity probe after the backend benchmark.")
    parser.add_argument("--json-only", action="store_true", help="Print only machine-readable summary details.")
    parser.add_argument("--keep-sandbox", action="store_true", help="Keep the isolated benchmark sandbox after completion.")
    parser.add_argument("--python", default="", help="Explicit Python interpreter path for the backend runtime.")
    parser.add_argument(
        "--clone-reference-source",
        choices=("synthetic", "kathleen"),
        default="synthetic",
        help="Source used for clone reference audio.",
    )
    return parser.parse_args()


def now_timestamp() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")


def ensure_directory(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    return path


def run_subprocess(
    argv: list[str],
    *,
    env: dict[str, str] | None = None,
    cwd: Path | None = None,
    capture_output: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv,
        cwd=str(cwd) if cwd else None,
        env=env,
        text=True,
        check=True,
        capture_output=capture_output,
    )


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def python_version_ok(python_path: str) -> bool:
    try:
        result = run_subprocess(
            [python_path, "-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"],
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False
    try:
        major, minor = [int(part) for part in result.stdout.strip().split(".", 1)]
    except ValueError:
        return False
    return (major, minor) >= (3, 11)


def validate_runtime_python(python_path: str) -> bool:
    if not python_version_ok(python_path):
        return False
    try:
        run_subprocess(
            [
                python_path,
                "-c",
                "import huggingface_hub, numpy, soundfile, mlx_audio; print('ok')",
            ]
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def find_bootstrap_python() -> str:
    candidates: list[str] = []
    if sys.executable:
        candidates.append(sys.executable)
    which_python = shutil.which("python3")
    if which_python:
        candidates.append(which_python)
    candidates.extend(
        [
            "/opt/homebrew/bin/python3.13",
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3.13",
            "/usr/local/bin/python3.12",
            "/usr/local/bin/python3.11",
            "/usr/local/bin/python3",
        ]
    )

    seen: set[str] = set()
    for candidate in candidates:
        if not candidate or candidate in seen:
            continue
        seen.add(candidate)
        if os.path.exists(candidate) and python_version_ok(candidate):
            return candidate
    raise RuntimeError("Could not find a Python 3.11+ interpreter to bootstrap the benchmark venv")


def create_benchmark_venv(venv_python: Path) -> str:
    venv_dir = venv_python.parent.parent
    ensure_directory(venv_dir.parent)
    bootstrap_python = find_bootstrap_python()
    if not venv_python.exists():
        run_subprocess([bootstrap_python, "-m", "venv", str(venv_dir)], capture_output=False)

    pip_path = venv_dir / "bin" / "pip"
    install_cmd = [
        str(pip_path),
        "install",
        "--upgrade",
        "pip",
    ]
    run_subprocess(install_cmd, capture_output=False)
    install_cmd = [
        str(pip_path),
        "install",
        "--find-links",
        str(VENDOR_DIR),
        "-r",
        str(REQUIREMENTS_PATH),
    ]
    run_subprocess(install_cmd, capture_output=False)
    if not validate_runtime_python(str(venv_python)):
        raise RuntimeError("Benchmark venv was created but dependencies failed validation")
    return str(venv_python)


def resolve_backend_python(explicit_python: str) -> str:
    if explicit_python:
        if not validate_runtime_python(explicit_python):
            raise RuntimeError(f"Explicit Python runtime is invalid or missing dependencies: {explicit_python}")
        return explicit_python

    if APP_VENV_PYTHON.exists() and validate_runtime_python(str(APP_VENV_PYTHON)):
        return str(APP_VENV_PYTHON)

    benchmark_venv_python = DEFAULT_BENCH_ROOT / ".venv" / "bin" / "python3"
    if benchmark_venv_python.exists() and validate_runtime_python(str(benchmark_venv_python)):
        return str(benchmark_venv_python)

    return create_benchmark_venv(benchmark_venv_python)


def resolve_ffmpeg_binary() -> str | None:
    configured = os.environ.get("QWENVOICE_FFMPEG_PATH")
    if configured and Path(configured).exists():
        return configured

    repo_binary = PROJECT_DIR / "Sources" / "Resources" / "ffmpeg"
    if repo_binary.exists():
        return str(repo_binary)

    which_ffmpeg = shutil.which("ffmpeg")
    if which_ffmpeg:
        return which_ffmpeg

    return None


def git_metadata() -> dict[str, Any]:
    def maybe_run(argv: list[str]) -> str:
        try:
            return run_subprocess(argv, cwd=PROJECT_DIR).stdout.strip()
        except subprocess.CalledProcessError:
            return ""

    branch = maybe_run(["git", "rev-parse", "--abbrev-ref", "HEAD"])
    commit = maybe_run(["git", "rev-parse", "HEAD"])
    status = maybe_run(["git", "status", "--short"])
    return {
        "branch": branch,
        "commit": commit,
        "dirty": bool(status),
    }


def download_model(repo_id: str, target_dir: Path, backend_python: str) -> None:
    ensure_directory(target_dir.parent)
    env = os.environ.copy()
    env["QWENVOICE_REPO_ID"] = repo_id
    env["QWENVOICE_TARGET_DIR"] = str(target_dir)
    code = (
        "import os\n"
        "from huggingface_hub import snapshot_download\n"
        "snapshot_download(\n"
        "    repo_id=os.environ['QWENVOICE_REPO_ID'],\n"
        "    local_dir=os.environ['QWENVOICE_TARGET_DIR'],\n"
        "    resume_download=True,\n"
        ")\n"
    )
    run_subprocess([backend_python, "-c", code], env=env, capture_output=False)


def ensure_model_available(
    model_id: str,
    model_cache_dir: Path,
    sandbox_models_dir: Path,
    backend_python: str,
    download_missing: bool,
) -> dict[str, Any]:
    manifest = MODEL_MANIFEST[model_id]
    folder = manifest["folder"]
    app_source = APP_MODELS_DIR / folder
    cache_source = model_cache_dir / folder

    source_path: Path | None = None
    source_kind = ""
    downloaded = False
    error = ""

    if app_source.exists():
        source_path = app_source
        source_kind = "app_support"
    elif cache_source.exists():
        source_path = cache_source
        source_kind = "model_cache"
    elif download_missing:
        try:
            download_model(manifest["repo"], cache_source, backend_python)
            source_path = cache_source
            source_kind = "downloaded"
            downloaded = True
        except Exception as exc:  # pragma: no cover - handled in report
            error = str(exc)
    else:
        error = "Missing and download_missing is disabled"

    linked_path = sandbox_models_dir / folder
    if linked_path.exists() or linked_path.is_symlink():
        if linked_path.is_dir() and not linked_path.is_symlink():
            shutil.rmtree(linked_path)
        else:
            linked_path.unlink()

    if source_path is not None and source_path.exists():
        os.symlink(source_path, linked_path)

    return {
        "model_id": model_id,
        "folder": folder,
        "repo": manifest["repo"],
        "source_kind": source_kind or "missing",
        "source_path": str(source_path) if source_path else "",
        "downloaded": downloaded,
        "available": source_path is not None and source_path.exists(),
        "error": error,
    }


def validate_output_file(path: Path) -> dict[str, Any]:
    info: dict[str, Any] = {
        "exists": path.exists(),
        "size_bytes": 0,
        "sample_rate": None,
        "frames": None,
        "duration_seconds": None,
        "valid_wav": False,
        "error": "",
    }
    if not path.exists():
        info["error"] = "Output file does not exist"
        return info

    info["size_bytes"] = path.stat().st_size
    try:
        with wave.open(str(path), "rb") as wav_file:
            frames = wav_file.getnframes()
            sample_rate = wav_file.getframerate()
            duration = frames / float(sample_rate) if sample_rate else 0.0
            info["sample_rate"] = sample_rate
            info["frames"] = frames
            info["duration_seconds"] = round(duration, 4)
            info["valid_wav"] = True
    except wave.Error as exc:
        info["error"] = str(exc)
    return info


def download_url_to_file(url: str, destination: Path) -> Path:
    ensure_directory(destination.parent)
    with urllib.request.urlopen(url) as response:
        data = response.read()
    destination.write_bytes(data)
    return destination


def concatenate_wav_files(source_paths: list[Path], destination: Path) -> Path:
    if not source_paths:
        raise RuntimeError("No source WAV files were provided for concatenation")

    params = None
    frames: list[bytes] = []
    for path in source_paths:
        with wave.open(str(path), "rb") as wav_file:
            current = (
                wav_file.getnchannels(),
                wav_file.getsampwidth(),
                wav_file.getframerate(),
                wav_file.getcomptype(),
                wav_file.getcompname(),
            )
            if params is None:
                params = current
            elif current != params:
                raise RuntimeError(f"Incompatible WAV parameters for concatenation: {path}")
            frames.append(wav_file.readframes(wav_file.getnframes()))

    assert params is not None
    ensure_directory(destination.parent)
    with wave.open(str(destination), "wb") as wav_file:
        wav_file.setnchannels(params[0])
        wav_file.setsampwidth(params[1])
        wav_file.setframerate(params[2])
        wav_file.setcomptype(params[3], params[4])
        for chunk in frames:
            wav_file.writeframes(chunk)
    return destination


def prepare_synthetic_reference_assets(
    client: BackendClient,
    references_dir: Path,
    ffmpeg_path: str | None,
) -> dict[str, Any]:
    seed_wav = references_dir / "reference_seed.wav"
    seed_response = client.call(
        "generate",
        {
            "text": REFERENCE_TEXT,
            "voice": "serena",
            "instruct": "neutral",
            "speed": 1.0,
            "output_path": str(seed_wav),
            "benchmark": True,
            "benchmark_label": "bootstrap_reference_generation",
        },
    )
    actual_seed_wav = Path(seed_response["result"]["audio_path"])
    seed_txt = references_dir / "reference_seed.txt"
    seed_txt.write_text(REFERENCE_TEXT, encoding="utf-8")

    seed_m4a = references_dir / "reference_seed.m4a"
    if ffmpeg_path:
        try:
            run_subprocess(
                [
                    ffmpeg_path,
                    "-y",
                    "-loglevel",
                    "error",
                    "-i",
                    str(actual_seed_wav),
                    str(seed_m4a),
                ],
                capture_output=True,
            )
        except subprocess.CalledProcessError:
            if seed_m4a.exists():
                seed_m4a.unlink()

    no_transcript_wav = references_dir / "reference_seed_no_transcript.wav"
    shutil.copy2(actual_seed_wav, no_transcript_wav)
    no_transcript_txt = references_dir / "reference_seed_no_transcript.txt"
    if no_transcript_txt.exists():
        no_transcript_txt.unlink()

    return {
        "seed_wav": actual_seed_wav,
        "seed_txt": seed_txt,
        "seed_m4a": seed_m4a,
        "no_transcript_wav": no_transcript_wav,
        "source": "synthetic",
        "source_files": [],
    }


def prepare_kathleen_reference_assets(
    references_dir: Path,
    ffmpeg_path: str | None,
) -> dict[str, Any]:
    kathleen_dir = ensure_directory(references_dir / "kathleen")
    clip_paths: list[Path] = []
    transcripts: list[str] = []

    for stem in KATHLEEN_REFERENCE_STEMS:
        relative_wav = f"{stem}.wav"
        relative_txt = f"{stem}.txt"
        wav_path = kathleen_dir / Path(relative_wav).name
        txt_path = kathleen_dir / Path(relative_txt).name

        if not wav_path.exists():
            download_url_to_file(f"{KATHLEEN_BASE_URL}/{relative_wav}", wav_path)
        if not txt_path.exists():
            download_url_to_file(f"{KATHLEEN_BASE_URL}/{relative_txt}", txt_path)

        clip_paths.append(wav_path)
        transcripts.append(txt_path.read_text(encoding="utf-8").strip())

    combined_text = " ".join(text for text in transcripts if text)
    if not combined_text:
        raise RuntimeError("Kathleen reference clips did not provide transcript text")

    seed_wav = concatenate_wav_files(clip_paths, references_dir / "reference_seed.wav")
    seed_txt = references_dir / "reference_seed.txt"
    seed_txt.write_text(combined_text, encoding="utf-8")

    seed_m4a = references_dir / "reference_seed.m4a"
    if ffmpeg_path:
        try:
            run_subprocess(
                [
                    ffmpeg_path,
                    "-y",
                    "-loglevel",
                    "error",
                    "-i",
                    str(seed_wav),
                    str(seed_m4a),
                ],
                capture_output=True,
            )
        except subprocess.CalledProcessError:
            if seed_m4a.exists():
                seed_m4a.unlink()

    no_transcript_wav = references_dir / "reference_seed_no_transcript.wav"
    shutil.copy2(seed_wav, no_transcript_wav)
    no_transcript_txt = references_dir / "reference_seed_no_transcript.txt"
    if no_transcript_txt.exists():
        no_transcript_txt.unlink()

    return {
        "seed_wav": seed_wav,
        "seed_txt": seed_txt,
        "seed_m4a": seed_m4a,
        "no_transcript_wav": no_transcript_wav,
        "source": "kathleen",
        "source_files": [str(path) for path in clip_paths],
    }


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    if len(values) == 1:
        return float(values[0])
    sorted_values = sorted(values)
    position = (len(sorted_values) - 1) * p
    lower = int(position)
    upper = min(lower + 1, len(sorted_values) - 1)
    if lower == upper:
        return float(sorted_values[lower])
    weight = position - lower
    return float(sorted_values[lower] * (1.0 - weight) + sorted_values[upper] * weight)


def summarize_numeric(values: list[float]) -> dict[str, float | None]:
    if not values:
        return {
            "count": 0,
            "mean": None,
            "median": None,
            "p95": None,
            "min": None,
            "max": None,
            "cv": None,
        }
    mean_value = statistics.mean(values)
    cv_value = None
    if len(values) > 1 and mean_value:
        cv_value = statistics.stdev(values) / mean_value
    return {
        "count": len(values),
        "mean": round(mean_value, 3),
        "median": round(statistics.median(values), 3),
        "p95": round(percentile(values, 0.95) or values[0], 3),
        "min": round(min(values), 3),
        "max": round(max(values), 3),
        "cv": round(cv_value, 6) if cv_value is not None else None,
    }


def aggregate_samples(cold_samples: list[dict[str, Any]], warm_samples: list[dict[str, Any]]) -> dict[str, Any]:
    def pluck(rows: list[dict[str, Any]], key: str) -> list[float]:
        values: list[float] = []
        for row in rows:
            value = row.get(key)
            if value is None:
                continue
            values.append(float(value))
        return values

    return {
        "cold_total_wall_ms": summarize_numeric(pluck(cold_samples, "total_wall_ms")),
        "warm_total_wall_ms": summarize_numeric(pluck(warm_samples, "total_wall_ms")),
        "warm_backend_total_ms": summarize_numeric(pluck(warm_samples, "backend_total_ms")),
        "warm_generation_ms": summarize_numeric(pluck(warm_samples, "generation_ms")),
        "warm_write_output_ms": summarize_numeric(pluck(warm_samples, "write_output_ms")),
        "warm_output_duration_seconds": summarize_numeric(pluck(warm_samples, "output_duration_seconds")),
        "warm_first_chunk_ms": summarize_numeric(pluck(warm_samples, "first_chunk_ms")),
    }


def safe_round(value: float | None, digits: int = 3) -> float | None:
    if value is None:
        return None
    return round(value, digits)


def make_scenarios(
    seed_wav: Path,
    seed_m4a: Path,
    enrolled_wav: Path,
    no_transcript_wav: Path,
    reference_text: str,
    include_streaming: bool,
    ffmpeg_path: str | None,
) -> list[Scenario]:
    return [
        Scenario(
            identifier="custom_short",
            model_id="pro_custom",
            params={
                "text": SHORT_TEXT,
                "voice": "serena",
                "instruct": "neutral",
                "speed": 1.0,
            },
        ),
        Scenario(
            identifier="custom_medium",
            model_id="pro_custom",
            params={
                "text": MEDIUM_TEXT,
                "voice": "serena",
                "instruct": "neutral",
                "speed": 1.0,
            },
        ),
        Scenario(
            identifier="design_short",
            model_id="pro_design",
            params={
                "text": SHORT_TEXT,
                "instruct": VOICE_DESCRIPTION,
            },
        ),
        Scenario(
            identifier="design_medium",
            model_id="pro_design",
            params={
                "text": MEDIUM_TEXT,
                "instruct": VOICE_DESCRIPTION,
            },
        ),
        Scenario(
            identifier="clone_enrolled_miss_then_hits",
            model_id="pro_clone",
            params={
                "text": CLONE_TEXT,
                "ref_audio": str(enrolled_wav),
            },
        ),
        Scenario(
            identifier="clone_external_wav_miss_then_hits",
            model_id="pro_clone",
            params={
                "text": CLONE_TEXT,
                "ref_audio": str(seed_wav),
                "ref_text": reference_text,
            },
        ),
        Scenario(
            identifier="clone_external_nonwav_miss_then_hits",
            model_id="pro_clone",
            params={
                "text": CLONE_TEXT,
                "ref_audio": str(seed_m4a),
                "ref_text": reference_text,
            },
            skip_reason=None if ffmpeg_path and seed_m4a.exists() else "ffmpeg unavailable; non-WAV reference clip could not be created",
        ),
        Scenario(
            identifier="clone_external_wav_no_transcript_fallback",
            model_id="pro_clone",
            params={
                "text": CLONE_TEXT,
                "ref_audio": str(no_transcript_wav),
            },
        ),
        Scenario(
            identifier="custom_short_streaming",
            model_id="pro_custom",
            params={
                "text": SHORT_TEXT,
                "voice": "serena",
                "instruct": "neutral",
                "speed": 1.0,
                "stream": True,
                "streaming_interval": 2.0,
            },
            use_streaming=True,
            skip_reason=None if include_streaming else "Streaming benchmark disabled",
        ),
        Scenario(
            identifier="design_short_streaming",
            model_id="pro_design",
            params={
                "text": SHORT_TEXT,
                "instruct": VOICE_DESCRIPTION,
                "stream": True,
                "streaming_interval": 2.0,
            },
            use_streaming=True,
            skip_reason=None if include_streaming else "Streaming benchmark disabled",
        ),
    ]


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    fieldnames = sorted({key for row in rows for key in row.keys()})
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def run_sample(
    client: BackendClient,
    scenario: Scenario,
    phase: str,
    iteration: int,
    outputs_root: Path,
) -> dict[str, Any]:
    scenario_output_dir = ensure_directory(outputs_root / scenario.identifier)
    output_path = scenario_output_dir / f"{phase}_{iteration:02d}.wav"
    params = dict(scenario.params)
    params["output_path"] = str(output_path)
    params["benchmark"] = True
    params["benchmark_label"] = scenario.identifier

    response = client.call("generate", params)
    result = response["result"]
    metrics = response["metrics"]
    benchmark = result.get("benchmark", {})
    backend_timings = benchmark.get("timings_ms", {})
    audio_path = Path(result.get("audio_path", str(output_path)))
    output_check = validate_output_file(audio_path)

    return {
        "scenario_id": scenario.identifier,
        "phase": phase,
        "iteration": iteration,
        "model_id": scenario.model_id,
        "streaming": scenario.use_streaming,
        "audio_path": str(audio_path),
        "total_wall_ms": metrics["total_wall_ms"],
        "first_progress_ms": metrics["first_progress_ms"],
        "first_chunk_ms": metrics["first_chunk_ms"],
        "progress_count": metrics["progress_count"],
        "chunk_count": metrics["chunk_count"],
        "backend_total_ms": backend_timings.get("total_backend"),
        "normalize_reference_ms": backend_timings.get("normalize_reference"),
        "prepare_clone_context_ms": backend_timings.get("prepare_clone_context"),
        "generation_ms": backend_timings.get("generation"),
        "write_output_ms": backend_timings.get("write_output"),
        "prepared_clone_used": benchmark.get("prepared_clone_used"),
        "clone_cache_hit": benchmark.get("clone_cache_hit"),
        "used_temp_reference": benchmark.get("used_temp_reference"),
        "streaming_used": benchmark.get("streaming_used"),
        "duration_seconds": result.get("duration_seconds"),
        "output_exists": output_check["exists"],
        "output_size_bytes": output_check["size_bytes"],
        "output_sample_rate": output_check["sample_rate"],
        "output_duration_seconds": output_check["duration_seconds"],
        "output_valid_wav": output_check["valid_wav"],
        "output_error": output_check["error"],
    }


def ensure_model_loaded(client: BackendClient, state: dict[str, Any], model_id: str, force_reload: bool = False) -> None:
    if force_reload and state.get("loaded_model"):
        client.call("unload_model", {})
        state["loaded_model"] = None

    if state.get("loaded_model") != model_id:
        client.call("load_model", {"model_id": model_id})
        state["loaded_model"] = model_id


def run_scenario(
    client: BackendClient,
    scenario: Scenario,
    runs: int,
    cold_runs: int,
    outputs_root: Path,
    available_models: dict[str, dict[str, Any]],
    state: dict[str, Any],
) -> dict[str, Any]:
    if scenario.skip_reason:
        return {
            "status": "skipped",
            "reason": scenario.skip_reason,
            "cold_runs": [],
            "warm_runs": [],
            "aggregates": {},
            "sample_rows": [],
            "backend_flags": {},
            "output_checks": {},
        }

    model_info = available_models.get(scenario.model_id)
    if not model_info or not model_info.get("available"):
        return {
            "status": "skipped",
            "reason": f"Model '{scenario.model_id}' is unavailable",
            "cold_runs": [],
            "warm_runs": [],
            "aggregates": {},
            "sample_rows": [],
            "backend_flags": {},
            "output_checks": {},
        }

    cold_samples: list[dict[str, Any]] = []
    warm_samples: list[dict[str, Any]] = []

    try:
        ensure_model_loaded(client, state, scenario.model_id, force_reload=scenario.cold_reset)

        for index in range(cold_runs):
            if index > 0:
                ensure_model_loaded(client, state, scenario.model_id, force_reload=True)
            cold_samples.append(run_sample(client, scenario, "cold", index + 1, outputs_root))

        if cold_runs == 0:
            ensure_model_loaded(client, state, scenario.model_id, force_reload=scenario.cold_reset)

        for index in range(runs):
            if index == 0 and cold_runs == 0:
                ensure_model_loaded(client, state, scenario.model_id, force_reload=False)
            warm_samples.append(run_sample(client, scenario, "warm", index + 1, outputs_root))

        sample_rows = cold_samples + warm_samples
        output_checks = {
            "files_checked": len(sample_rows),
            "all_exist": all(bool(row.get("output_exists")) for row in sample_rows),
            "all_valid_wav": all(bool(row.get("output_valid_wav")) for row in sample_rows),
            "all_sample_rate_24000": all(row.get("output_sample_rate") == 24000 for row in sample_rows),
        }

        backend_flags = {
            "prepared_clone_used_values": sorted(
                {str(row.get("prepared_clone_used")) for row in sample_rows if row.get("prepared_clone_used") is not None}
            ),
            "clone_cache_hits": sum(1 for row in sample_rows if row.get("clone_cache_hit") is True),
            "clone_cache_misses": sum(1 for row in sample_rows if row.get("clone_cache_hit") is False),
            "streaming_chunk_count_total": sum(int(row.get("chunk_count") or 0) for row in sample_rows),
        }

        return {
            "status": "completed",
            "reason": "",
            "cold_runs": cold_samples,
            "warm_runs": warm_samples,
            "aggregates": aggregate_samples(cold_samples, warm_samples),
            "sample_rows": sample_rows,
            "backend_flags": backend_flags,
            "output_checks": output_checks,
        }
    except Exception as exc:  # pragma: no cover - handled in report
        return {
            "status": "failed",
            "reason": f"{exc.__class__.__name__}: {exc}",
            "cold_runs": cold_samples,
            "warm_runs": warm_samples,
            "aggregates": aggregate_samples(cold_samples, warm_samples),
            "sample_rows": cold_samples + warm_samples,
            "backend_flags": {},
            "output_checks": {},
            "traceback": traceback.format_exc(),
        }


def build_highlights(scenarios: dict[str, dict[str, Any]]) -> dict[str, Any]:
    completed = []
    for scenario_id, data in scenarios.items():
        if data.get("status") != "completed":
            continue
        median_total = data.get("aggregates", {}).get("warm_total_wall_ms", {}).get("median")
        if median_total is None:
            continue
        completed.append((scenario_id, float(median_total)))

    fastest = None
    slowest = None
    if completed:
        fastest = min(completed, key=lambda item: item[1])
        slowest = max(completed, key=lambda item: item[1])

    clone_speedups: dict[str, Any] = {}
    clone_cache_inactive: list[str] = []
    for scenario_id in (
        "clone_enrolled_miss_then_hits",
        "clone_external_wav_miss_then_hits",
        "clone_external_nonwav_miss_then_hits",
    ):
        data = scenarios.get(scenario_id, {})
        if data.get("status") != "completed":
            continue
        backend_flags = data.get("backend_flags", {})
        cache_hits = int(backend_flags.get("clone_cache_hits", 0))
        if cache_hits <= 0:
            clone_cache_inactive.append(scenario_id)
            continue
        cold_mean = data["aggregates"]["cold_total_wall_ms"].get("mean")
        warm_median = data["aggregates"]["warm_total_wall_ms"].get("median")
        if cold_mean and warm_median:
            clone_speedups[scenario_id] = {
                "cold_mean_ms": cold_mean,
                "warm_median_ms": warm_median,
                "speedup_ratio": safe_round(float(cold_mean) / float(warm_median), 4) if warm_median else None,
            }

    streaming_summary: dict[str, Any] = {}
    pairs = [
        ("custom_short", "custom_short_streaming"),
        ("design_short", "design_short_streaming"),
    ]
    for baseline_id, streaming_id in pairs:
        baseline = scenarios.get(baseline_id, {})
        streaming = scenarios.get(streaming_id, {})
        if baseline.get("status") != "completed" or streaming.get("status") != "completed":
            continue
        baseline_total = baseline["aggregates"]["warm_total_wall_ms"].get("median")
        first_chunk = streaming["aggregates"]["warm_first_chunk_ms"].get("median")
        streaming_total = streaming["aggregates"]["warm_total_wall_ms"].get("median")
        streaming_summary[streaming_id] = {
            "baseline_total_median_ms": baseline_total,
            "first_chunk_median_ms": first_chunk,
            "streaming_total_median_ms": streaming_total,
            "first_chunk_advantage_ms": safe_round(
                float(baseline_total) - float(first_chunk), 3
            ) if baseline_total is not None and first_chunk is not None else None,
        }

    return {
        "fastest_scenario": {
            "id": fastest[0],
            "warm_total_wall_median_ms": fastest[1],
        } if fastest else None,
        "slowest_scenario": {
            "id": slowest[0],
            "warm_total_wall_median_ms": slowest[1],
        } if slowest else None,
        "clone_cache_speedups": clone_speedups,
        "clone_cache_state": {
            "active": bool(clone_speedups),
            "inactive_scenarios": clone_cache_inactive,
        },
        "streaming_latency": streaming_summary,
    }


def render_markdown_report(summary: dict[str, Any], artifact_paths: dict[str, str]) -> str:
    lines: list[str] = []
    metadata = summary["metadata"]
    configuration = summary["configuration"]
    setup = summary["setup"]
    scenarios = summary["scenarios"]
    highlights = summary["highlights"]

    lines.append("# QwenVoice Generation Benchmark Report")
    lines.append("")
    lines.append("## Executive Summary")
    lines.append("")
    lines.append(f"- Benchmark layer: backend-first JSON-RPC against `{SERVER_PATH}`")
    lines.append(f"- Warm runs per scenario: {configuration['runs']}")
    lines.append(f"- Cold runs per scenario: {configuration['cold_runs']}")
    lines.append(f"- Streaming enabled: {configuration['streaming_enabled']}")
    lines.append(f"- Clone reference source: {configuration['clone_reference_source']}")
    if highlights.get("fastest_scenario"):
        lines.append(
            f"- Fastest warm median: `{highlights['fastest_scenario']['id']}` "
            f"at {highlights['fastest_scenario']['warm_total_wall_median_ms']} ms"
        )
    if highlights.get("slowest_scenario"):
        lines.append(
            f"- Slowest warm median: `{highlights['slowest_scenario']['id']}` "
            f"at {highlights['slowest_scenario']['warm_total_wall_median_ms']} ms"
        )
    skipped = [scenario_id for scenario_id, data in scenarios.items() if data.get("status") == "skipped"]
    if skipped:
        lines.append(f"- Skipped scenarios: {', '.join(skipped)}")
    lines.append("")

    lines.append("## Environment")
    lines.append("")
    lines.append(f"- Timestamp (UTC): {metadata['timestamp_utc']}")
    lines.append(f"- Host: {metadata['hostname']}")
    lines.append(f"- Machine: {metadata['machine']}")
    lines.append(f"- macOS: {metadata['macos_version']}")
    lines.append(f"- Python runtime: {metadata['python_version']}")
    lines.append(f"- Git branch: {metadata['git']['branch']}")
    lines.append(f"- Git commit: {metadata['git']['commit']}")
    lines.append(f"- Git dirty: {metadata['git']['dirty']}")
    lines.append(f"- Requirements hash: {metadata['requirements_sha256']}")
    lines.append(f"- ffmpeg: {metadata['ffmpeg_path'] or 'unavailable'}")
    reference_setup = setup.get("bootstrap_reference_generation", {})
    if reference_setup:
        lines.append(f"- Clone reference seed source: {reference_setup.get('source', 'unknown')}")
    lines.append("")

    lines.append("## Methodology")
    lines.append("")
    lines.append("- One backend subprocess is reused across the benchmark run.")
    lines.append("- Cold samples are the first generate call after a model load or cache reset.")
    lines.append("- Warm samples reuse the loaded model and, where possible, the clone-conditioning cache.")
    lines.append("- Clone reference audio is prepared once, then reused for enrolled and external clone scenarios.")
    lines.append("- Output files are validated for existence, WAV readability, and 24 kHz sample rate.")
    lines.append("")

    lines.append("## Results By Scenario")
    lines.append("")
    for scenario_id, data in scenarios.items():
        lines.append(f"### `{scenario_id}`")
        lines.append("")
        lines.append(f"- Status: {data.get('status')}")
        if data.get("reason"):
            lines.append(f"- Reason: {data['reason']}")
        if data.get("status") == "completed":
            aggregates = data["aggregates"]
            lines.append("")
            lines.append("| Metric | Value |")
            lines.append("| --- | --- |")
            lines.append(
                f"| Cold mean total wall (ms) | {aggregates['cold_total_wall_ms']['mean']} |"
            )
            lines.append(
                f"| Warm median total wall (ms) | {aggregates['warm_total_wall_ms']['median']} |"
            )
            lines.append(
                f"| Warm p95 total wall (ms) | {aggregates['warm_total_wall_ms']['p95']} |"
            )
            lines.append(
                f"| Warm median backend generation (ms) | {aggregates['warm_generation_ms']['median']} |"
            )
            lines.append(
                f"| Warm median write output (ms) | {aggregates['warm_write_output_ms']['median']} |"
            )
            lines.append(
                f"| Warm median output duration (s) | {aggregates['warm_output_duration_seconds']['median']} |"
            )
            if aggregates["warm_first_chunk_ms"]["median"] is not None:
                lines.append(
                    f"| Warm median first chunk (ms) | {aggregates['warm_first_chunk_ms']['median']} |"
                )
            backend_flags = data.get("backend_flags", {})
            if backend_flags:
                lines.append("")
                lines.append(
                    f"- Clone cache hits: {backend_flags.get('clone_cache_hits', 0)}; "
                    f"misses: {backend_flags.get('clone_cache_misses', 0)}"
                )
        lines.append("")

    lines.append("## Clone Cache Analysis")
    lines.append("")
    clone_speedups = highlights.get("clone_cache_speedups", {})
    clone_cache_state = highlights.get("clone_cache_state", {})
    if clone_speedups:
        for scenario_id, payload in clone_speedups.items():
            lines.append(
                f"- `{scenario_id}`: cold mean {payload['cold_mean_ms']} ms, "
                f"warm median {payload['warm_median_ms']} ms, "
                f"speedup ratio {payload['speedup_ratio']}"
            )
    elif clone_cache_state.get("inactive_scenarios"):
        inactive = ", ".join(f"`{item}`" for item in clone_cache_state["inactive_scenarios"])
        lines.append(
            "- Prepared clone conditioning did not activate on this runtime, so no true "
            f"clone-cache speedups were measured. Affected scenarios: {inactive}."
        )
    else:
        lines.append("- No completed clone cache scenarios were available.")
    lines.append("")

    lines.append("## Streaming Analysis")
    lines.append("")
    streaming_latency = highlights.get("streaming_latency", {})
    if streaming_latency:
        for scenario_id, payload in streaming_latency.items():
            lines.append(
                f"- `{scenario_id}`: first chunk median {payload['first_chunk_median_ms']} ms, "
                f"baseline non-stream total median {payload['baseline_total_median_ms']} ms, "
                f"advantage {payload['first_chunk_advantage_ms']} ms"
            )
    else:
        lines.append("- Streaming scenarios were skipped or disabled.")
    lines.append("")

    lines.append("## Failures And Skips")
    lines.append("")
    failures_or_skips = [
        (scenario_id, data)
        for scenario_id, data in scenarios.items()
        if data.get("status") in {"failed", "skipped"}
    ]
    if failures_or_skips:
        for scenario_id, data in failures_or_skips:
            lines.append(f"- `{scenario_id}`: {data.get('status')} - {data.get('reason')}")
    else:
        lines.append("- None.")
    lines.append("")

    lines.append("## Raw Artifact Locations")
    lines.append("")
    for key, value in artifact_paths.items():
        lines.append(f"- {key}: `{value}`")
    lines.append("")

    return "\n".join(lines)


def maybe_run_app_sanity(run_dir: Path) -> dict[str, Any]:
    start = time.perf_counter()
    log_path = run_dir / "app_sanity.log"
    command = [str(PROJECT_DIR / "scripts" / "run_tests.sh"), "--probe", "generation-perf"]
    with log_path.open("w", encoding="utf-8") as handle:
        result = subprocess.run(
            command,
            cwd=str(PROJECT_DIR),
            text=True,
            stdout=handle,
            stderr=subprocess.STDOUT,
        )
    duration_ms = int((time.perf_counter() - start) * 1000)
    return {
        "status": "passed" if result.returncode == 0 else "failed",
        "duration_ms": duration_ms,
        "log_path": str(log_path),
    }


def main() -> int:
    args = parse_args()

    if args.runs < 1:
        raise SystemExit("--runs must be at least 1")
    if args.cold_runs < 0:
        raise SystemExit("--cold-runs cannot be negative")

    run_dir = Path(args.output_dir) if args.output_dir else DEFAULT_BENCH_ROOT / "runs" / now_timestamp()
    ensure_directory(run_dir)
    ensure_directory(run_dir / "reports")
    sandbox_dir = ensure_directory(run_dir / "sandbox_app_support")
    sandbox_models_dir = ensure_directory(sandbox_dir / "models")
    sandbox_outputs_dir = ensure_directory(sandbox_dir / "outputs")
    ensure_directory(sandbox_dir / "voices")
    references_dir = ensure_directory(run_dir / "references")
    model_cache_dir = ensure_directory(Path(args.model_cache_dir))

    summary_path = run_dir / "summary.json"
    report_path = run_dir / "report.md"
    raw_samples_path = run_dir / "raw_samples.csv"
    rpc_events_path = run_dir / "rpc_events.ndjson"
    backend_log_path = run_dir / "backend.log"

    backend_python = resolve_backend_python(args.python)
    ffmpeg_path = resolve_ffmpeg_binary()

    metadata = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "hostname": platform.node(),
        "machine": platform.machine(),
        "macos_version": platform.mac_ver()[0],
        "python_version": run_subprocess([backend_python, "-c", "import sys; print(sys.version)"]).stdout.strip(),
        "git": git_metadata(),
        "benchmark_script_version": BENCHMARK_SCRIPT_VERSION,
        "requirements_sha256": hash_file(REQUIREMENTS_PATH),
        "ffmpeg_path": ffmpeg_path,
    }
    configuration = {
        "runs": args.runs,
        "cold_runs": args.cold_runs,
        "streaming_enabled": args.include_streaming,
        "download_missing": args.download_missing,
        "clone_reference_source": args.clone_reference_source,
        "sandbox_path": str(sandbox_dir),
        "model_cache_path": str(model_cache_dir),
    }
    summary: dict[str, Any] = {
        "metadata": metadata,
        "configuration": configuration,
        "setup": {
            "model_downloads": [],
            "skipped_downloads": [],
            "bootstrap_reference_generation": {},
            "app_sanity": None,
        },
        "scenarios": {},
        "highlights": {},
    }

    try:
        available_models: dict[str, dict[str, Any]] = {}
        for model_id in MODEL_MANIFEST:
            result = ensure_model_available(
                model_id,
                model_cache_dir,
                sandbox_models_dir,
                backend_python,
                args.download_missing,
            )
            available_models[model_id] = result
            if result["downloaded"]:
                summary["setup"]["model_downloads"].append(result)
            elif not result["available"]:
                summary["setup"]["skipped_downloads"].append(result)
        metadata["model_sources"] = available_models

        client = BackendClient(backend_python, rpc_events_path, backend_log_path, ffmpeg_path)
        state = {"loaded_model": None}
        try:
            client.start()
            client.call("init", {"app_support_dir": str(sandbox_dir)})

            if args.clone_reference_source == "synthetic":
                if not available_models["pro_custom"]["available"]:
                    raise RuntimeError("Custom Voice model is required for bootstrap reference generation")
                ensure_model_loaded(client, state, "pro_custom", force_reload=True)
                reference_assets = prepare_synthetic_reference_assets(
                    client=client,
                    references_dir=references_dir,
                    ffmpeg_path=ffmpeg_path,
                )
            else:
                reference_assets = prepare_kathleen_reference_assets(
                    references_dir=references_dir,
                    ffmpeg_path=ffmpeg_path,
                )

            actual_seed_wav = Path(reference_assets["seed_wav"])
            seed_txt = Path(reference_assets["seed_txt"])
            seed_m4a = Path(reference_assets["seed_m4a"])
            no_transcript_wav = Path(reference_assets["no_transcript_wav"])
            reference_text = seed_txt.read_text(encoding="utf-8").strip()

            enrolled = client.call(
                "enroll_voice",
                {
                    "name": "benchmark_voice",
                    "audio_path": str(actual_seed_wav),
                    "transcript": reference_text,
                },
            )["result"]
            enrolled_wav = Path(enrolled["wav_path"])

            summary["setup"]["bootstrap_reference_generation"] = {
                "source": reference_assets["source"],
                "audio_path": str(actual_seed_wav),
                "audio_validation": validate_output_file(actual_seed_wav),
                "transcript_path": str(seed_txt),
                "m4a_path": str(seed_m4a) if seed_m4a.exists() else "",
                "enrolled_voice_path": str(enrolled_wav),
                "source_files": reference_assets["source_files"],
            }

            scenarios = make_scenarios(
                seed_wav=actual_seed_wav,
                seed_m4a=seed_m4a,
                enrolled_wav=enrolled_wav,
                no_transcript_wav=no_transcript_wav,
                reference_text=reference_text,
                include_streaming=args.include_streaming,
                ffmpeg_path=ffmpeg_path,
            )

            all_rows: list[dict[str, Any]] = []
            for scenario in scenarios:
                result = run_scenario(
                    client,
                    scenario,
                    args.runs,
                    args.cold_runs,
                    sandbox_outputs_dir,
                    available_models,
                    state,
                )
                summary["scenarios"][scenario.identifier] = result
                all_rows.extend(result.get("sample_rows", []))

            if args.include_app_sanity:
                summary["setup"]["app_sanity"] = maybe_run_app_sanity(run_dir)

            summary["highlights"] = build_highlights(summary["scenarios"])
            write_csv(raw_samples_path, all_rows)
        finally:
            if "client" in locals():
                summary.setdefault("setup", {})["backend_stderr_excerpt"] = client.stderr_excerpt()
                client.stop()
    except Exception as exc:  # pragma: no cover - catastrophic path
        summary["fatal_error"] = {
            "type": exc.__class__.__name__,
            "message": str(exc),
            "traceback": traceback.format_exc(),
        }
        summary["highlights"] = build_highlights(summary.get("scenarios", {}))
        if not raw_samples_path.exists():
            raw_samples_path.write_text("", encoding="utf-8")

    artifact_paths = {
        "summary_json": str(summary_path),
        "report_md": str(report_path),
        "raw_samples_csv": str(raw_samples_path),
        "rpc_events_ndjson": str(rpc_events_path),
        "backend_log": str(backend_log_path),
        "run_dir": str(run_dir),
    }
    report_markdown = render_markdown_report(summary, artifact_paths)

    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
    report_path.write_text(report_markdown, encoding="utf-8")

    if not args.keep_sandbox:
        shutil.rmtree(sandbox_dir, ignore_errors=True)

    if args.json_only:
        print(
            json.dumps(
                {
                    "summary_json": str(summary_path),
                    "report_md": str(report_path),
                    "raw_samples_csv": str(raw_samples_path),
                    "fatal_error": summary.get("fatal_error"),
                    "highlights": summary.get("highlights"),
                },
                indent=2,
                sort_keys=True,
            )
        )
    else:
        print(f"Benchmark completed. Summary: {summary_path}")
        print(f"Markdown report: {report_path}")
        if summary.get("fatal_error"):
            print(f"Fatal error: {summary['fatal_error']['message']}")
        elif summary.get("highlights", {}).get("fastest_scenario"):
            fastest = summary["highlights"]["fastest_scenario"]
            print(
                f"Fastest warm median: {fastest['id']} ({fastest['warm_total_wall_median_ms']} ms)"
            )

    return 1 if summary.get("fatal_error") else 0


if __name__ == "__main__":
    raise SystemExit(main())
