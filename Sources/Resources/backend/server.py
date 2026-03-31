#!/usr/bin/env python3
"""
QwenVoice — Python JSON-RPC backend.

Reads JSON-RPC 2.0 requests from stdin, dispatches to handlers,
writes JSON-RPC responses to stdout. One model in memory at a time.

Refactored from main.py.
"""

import os
import sys
import json
import shutil
import time
import wave
import gc
import re
import hashlib
import subprocess
import warnings
import traceback
import uuid
from importlib import metadata as importlib_metadata
from collections import OrderedDict
from datetime import datetime

BACKEND_DIR = os.path.dirname(os.path.realpath(__file__))
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

# Suppress harmless library warnings
os.environ["TOKENIZERS_PARALLELISM"] = "false"
warnings.filterwarnings("ignore", category=UserWarning)
warnings.filterwarnings("ignore", category=FutureWarning)

# Redirect stderr for clean JSON-RPC on stdout
_original_stderr = sys.stderr

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


def _env_flag(name, default=True):
    """Read a boolean-ish environment variable with a conservative default."""
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw not in {"0", "false", "False"}


def _resolve_cache_policy():
    raw = os.environ.get("QWENVOICE_CACHE_POLICY")
    if raw is not None:
        normalized = raw.strip().lower()
        if normalized in {"adaptive", "always", "never"}:
            return normalized
        raise RuntimeError(
            "QWENVOICE_CACHE_POLICY must be one of: adaptive, always, never"
        )

    legacy = os.environ.get("QWENVOICE_POST_REQUEST_CACHE_CLEAR")
    if legacy is not None:
        return "always" if legacy not in {"0", "false", "False"} else "never"

    return "adaptive"


SAMPLE_RATE = 24000
FILENAME_MAX_LEN = 20
CACHE_POLICY = _resolve_cache_policy()
CLONE_CONTEXT_CACHE_CAPACITY = 16
DEFAULT_STREAMING_INTERVAL = 2.0
PREWARM_PROFILES = {
    "custom": {
        "text": "Voice warmup.",
        "max_tokens": 48,
        "run_generation": True,
    },
    "design": {
        "text": "",
        "max_tokens": 0,
        "run_generation": False,
    },
    "clone": {
        "text": "The selected voice model is warming up.",
        "max_tokens": 128,
        "run_generation": True,
    },
}
NORMALIZED_CLONE_REF_CACHE_LIMIT = 32
NORMALIZED_CLONE_REF_MAX_AGE_SECONDS = 30 * 24 * 60 * 60
# Default paths — overridable via init params
APP_SUPPORT_DIR = os.path.expanduser("~/Library/Application Support/QwenVoice")
MODELS_DIR = os.path.join(APP_SUPPORT_DIR, "models")
OUTPUTS_DIR = os.path.join(APP_SUPPORT_DIR, "outputs")
VOICES_DIR = os.path.join(APP_SUPPORT_DIR, "voices")
CLONE_REF_CACHE_DIR = os.path.join(APP_SUPPORT_DIR, "cache", "normalized_clone_refs")
STREAM_SESSIONS_DIR = os.path.join(APP_SUPPORT_DIR, "cache", "stream_sessions")


def _resolve_resources_dir():
    script_dir = os.path.dirname(os.path.realpath(__file__))
    candidates = [
        script_dir,
        os.path.dirname(script_dir),
    ]

    for candidate in candidates:
        if os.path.exists(os.path.join(candidate, "qwenvoice_contract.json")):
            return candidate

    return script_dir


RESOURCES_DIR = _resolve_resources_dir()
CONTRACT_PATH = os.path.join(RESOURCES_DIR, "qwenvoice_contract.json")

def _load_contract():
    with open(CONTRACT_PATH, "r", encoding="utf-8") as handle:
        contract = json.load(handle)

    if not contract.get("models"):
        raise RuntimeError("qwenvoice_contract.json must define at least one model")

    if not contract.get("speakers"):
        raise RuntimeError("qwenvoice_contract.json must define at least one speaker group")

    model_ids = [model["id"] for model in contract["models"]]
    if len(model_ids) != len(set(model_ids)):
        raise RuntimeError("qwenvoice_contract.json contains duplicate model ids")

    modes = [model["mode"] for model in contract["models"]]
    if len(modes) != len(set(modes)):
        raise RuntimeError("qwenvoice_contract.json contains duplicate model modes")

    all_speakers = [
        speaker
        for group_name in sorted(contract["speakers"].keys())
        for speaker in contract["speakers"][group_name]
    ]
    if contract["defaultSpeaker"] not in all_speakers:
        raise RuntimeError("qwenvoice_contract.json defaultSpeaker is not present in speakers")

    return contract


CONTRACT = _load_contract()
MODELS = {model["id"]: model for model in CONTRACT["models"]}
MODELS_BY_MODE = {model["mode"]: model for model in CONTRACT["models"]}
SPEAKER_MAP = CONTRACT["speakers"]
DEFAULT_SPEAKER = CONTRACT["defaultSpeaker"]

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

_current_model = None
_current_model_path = None
_current_model_id = None
_load_model_fn = None
_generate_audio_fn = None
_audio_write_fn = None
_mx = None
_np = None
_can_prepare_icl_fn = None
_prepare_icl_context_fn = None
_generate_prepared_icl_fn = None
_batch_generate_prepared_icl_fn = None
_enable_speech_tokenizer_encoder_fn = None
_clone_context_cache = OrderedDict()
_mlx_audio_version = None
_prewarmed_model_keys = set()
_primed_clone_reference_keys = set()


def _ensure_mlx():
    """Lazy-import mlx_audio so we only load it when needed."""
    global _load_model_fn, _generate_audio_fn, _audio_write_fn
    global _mx, _np, _can_prepare_icl_fn, _prepare_icl_context_fn, _generate_prepared_icl_fn
    global _batch_generate_prepared_icl_fn
    global _enable_speech_tokenizer_encoder_fn, _mlx_audio_version
    if _load_model_fn is None:
        import numpy as np
        from mlx_audio.tts.utils import load_model
        from mlx_audio.tts.generate import generate_audio
        from mlx_audio.audio_io import write as audio_write
        import mlx.core as mx
        try:
            from mlx_audio_qwen_speed_patch import (
                can_prepare_icl,
                batch_generate_with_prepared_icl,
                generate_with_prepared_icl,
                prepare_icl_context,
                try_enable_speech_tokenizer_encoder,
            )
        except ImportError:
            try:
                from mlx_audio.qwenvoice_speed_patch import (
                    can_prepare_icl,
                    batch_generate_with_prepared_icl,
                    generate_with_prepared_icl,
                    prepare_icl_context,
                    try_enable_speech_tokenizer_encoder,
                )
            except ImportError:
                can_prepare_icl = None
                batch_generate_with_prepared_icl = None
                generate_with_prepared_icl = None
                prepare_icl_context = None
                try_enable_speech_tokenizer_encoder = None

        _load_model_fn = load_model
        _generate_audio_fn = generate_audio
        _audio_write_fn = audio_write
        _mx = mx
        _np = np
        _can_prepare_icl_fn = can_prepare_icl
        _prepare_icl_context_fn = prepare_icl_context
        _generate_prepared_icl_fn = generate_with_prepared_icl
        _batch_generate_prepared_icl_fn = batch_generate_with_prepared_icl
        _enable_speech_tokenizer_encoder_fn = try_enable_speech_tokenizer_encoder
        try:
            _mlx_audio_version = importlib_metadata.version("mlx-audio")
        except importlib_metadata.PackageNotFoundError:
            _mlx_audio_version = "unknown"


def _resolve_ffmpeg_binary():
    """Prefer the app-bundled ffmpeg, then fall back to PATH."""
    configured = os.environ.get("QWENVOICE_FFMPEG_PATH")
    if configured and os.path.exists(configured):
        return configured

    bundled = os.path.join(RESOURCES_DIR, "ffmpeg")
    if os.path.exists(bundled):
        return bundled

    return "ffmpeg"


def _base_model_capabilities(model_def):
    version = _mlx_audio_version
    if version is None:
        try:
            version = importlib_metadata.version("mlx-audio")
        except importlib_metadata.PackageNotFoundError:
            version = "unknown"
    is_clone = model_def["mode"] == "clone"
    return {
        "mlx_audio_version": version,
        "supports_streaming": True,
        "supports_prepared_clone": is_clone,
        "supports_clone_streaming": is_clone,
        "supports_batch": True,
    }


def _resolved_model_capabilities(model_def):
    capabilities = dict(_base_model_capabilities(model_def))

    if (
        _current_model is None
        or _current_model_id != model_def["id"]
    ):
        return capabilities

    capabilities["supports_streaming"] = hasattr(_current_model, "generate")
    capabilities["supports_batch"] = bool(
        hasattr(_current_model, "batch_generate")
        or hasattr(_current_model, "generate_batch")
    )

    if model_def["mode"] == "clone":
        supports_prepared_clone = bool(
            _can_prepare_icl_fn
            and _can_prepare_icl_fn(_current_model)
        )
        capabilities["supports_prepared_clone"] = supports_prepared_clone
        capabilities["supports_clone_streaming"] = bool(
            capabilities["supports_streaming"] and supports_prepared_clone
        )

    return capabilities


# ---------------------------------------------------------------------------
# Utilities (from main.py)
# ---------------------------------------------------------------------------


def get_smart_path(folder_name):
    """Resolve model path, handling HuggingFace snapshots directory."""
    full_path = os.path.join(MODELS_DIR, folder_name)
    if not os.path.exists(full_path):
        return None

    snapshots_dir = os.path.join(full_path, "snapshots")
    if os.path.exists(snapshots_dir):
        subfolders = [f for f in os.listdir(snapshots_dir) if not f.startswith(".")]
        if subfolders:
            return os.path.join(snapshots_dir, subfolders[0])

    return full_path


def _resolve_model_id_for_path(model_path):
    if not model_path:
        return None

    normalized = os.path.realpath(model_path)
    for model_id, model_def in MODELS.items():
        resolved = get_smart_path(model_def["folder"])
        if resolved and os.path.realpath(resolved) == normalized:
            return model_id

    return None


def convert_audio_if_needed(input_path):
    """Convert audio to 24kHz mono WAV if needed. Returns path to WAV file."""
    if not os.path.exists(input_path):
        return None

    ext = os.path.splitext(input_path)[1].lower()

    if ext == ".wav":
        try:
            with wave.open(input_path, "rb") as f:
                if f.getnchannels() == 1 and f.getframerate() == SAMPLE_RATE:
                    return input_path
        except wave.Error:
            pass

    temp_wav = os.path.join(OUTPUTS_DIR, f"temp_convert_{time.time_ns()}.wav")
    if _audio_write_fn is not None:
        try:
            return _convert_audio_with_mlx(input_path, temp_wav)
        except (OSError, RuntimeError, ValueError):
            pass
    return _convert_audio_to_wav(input_path, temp_wav)


def make_output_path(subfolder, text_snippet):
    """Generate an output file path with timestamp and text snippet."""
    save_dir = os.path.join(OUTPUTS_DIR, subfolder)
    os.makedirs(save_dir, exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d_%H-%M-%S-%f")
    clean_text = (
        re.sub(r"[^\w\s-]", "", text_snippet)[:FILENAME_MAX_LEN].strip().replace(" ", "_")
        or "audio"
    )
    filename = f"{timestamp}_{clean_text}.wav"
    return os.path.join(save_dir, filename)


def get_audio_metadata(wav_path):
    """Return frame and duration metadata for a WAV file."""
    try:
        with wave.open(wav_path, "rb") as f:
            frames = f.getnframes()
            rate = f.getframerate()
            duration = frames / float(rate) if rate > 0 else 0.0
            return {"frames": frames, "duration_seconds": duration}
    except Exception:
        return {"frames": None, "duration_seconds": 0.0}


def _resolve_model_request(model_id=None, model_path=None):
    """Resolve the on-disk model path and canonical model identifier."""
    if not model_path and model_id:
        model_def = MODELS.get(model_id)
        if not model_def:
            raise ValueError(f"Unknown model_id: {model_id}")
        model_path = get_smart_path(model_def["folder"])
        if not model_path:
            raise FileNotFoundError(f"Model not found on disk: {model_def['folder']}")

    if not model_path:
        raise ValueError("Must provide model_id or model_path")

    resolved_model_id = model_id or _resolve_model_id_for_path(model_path)
    return model_path, resolved_model_id


def _model_identity_key(resolved_model_id, model_path):
    """Return a stable per-process identity key for model warm-up tracking."""
    return resolved_model_id or os.path.realpath(model_path)


def _has_meaningful_delivery_instruction(instruct):
    trimmed = (instruct or "").strip()
    return bool(trimmed) and trimmed.lower() != "normal tone"


def _prewarm_identity_key(model_key, mode, voice=None, instruct=None, ref_audio=None, ref_text=None):
    """Return a stable warm-up key for the specific request shape."""
    components = [model_key, mode or ""]

    if mode == "clone":
        components.extend([
            os.path.realpath(ref_audio) if ref_audio else "",
            (ref_text or "").strip(),
        ])
    elif mode == "design":
        return tuple(components)
    else:
        components.extend([
            (voice or "").strip(),
            (instruct or "").strip() if _has_meaningful_delivery_instruction(instruct) else "",
        ])

    return tuple(components)


def _collect_single_generation_result(generator):
    result, _ = _collect_generation_result_with_timings(generator)
    return result


def _collect_generation_result_with_timings(generator):
    collect_start = time.perf_counter()
    first_yield_ms = None
    last_result = None

    for result in generator:
        if first_yield_ms is None:
            first_yield_ms = int((time.perf_counter() - collect_start) * 1000)
        last_result = result

    if last_result is None:
        raise RuntimeError("Generation produced no audio file")

    return last_result, {
        "first_generator_yield": first_yield_ms or 0,
        "collect_generation": int((time.perf_counter() - collect_start) * 1000),
    }


def _collect_batch_generation_results_with_timings(generator, expected_count):
    collect_start = time.perf_counter()
    first_yield_ms = None
    results = []

    for result in generator:
        if first_yield_ms is None:
            first_yield_ms = int((time.perf_counter() - collect_start) * 1000)
        results.append(result)

    if len(results) != expected_count:
        raise RuntimeError(
            f"Batch generation produced {len(results)} results for {expected_count} requested items"
        )

    results.sort(key=lambda item: int(getattr(item, "sequence_idx", 0) or 0))
    return results, {
        "first_generator_yield": first_yield_ms or 0,
        "collect_generation": int((time.perf_counter() - collect_start) * 1000),
    }


def _prewarm_profile(mode):
    profile = PREWARM_PROFILES.get(mode)
    if profile is None:
        raise ValueError(f"Unknown prewarm mode: {mode}")
    return profile


def _timing_breakdown_template():
    return {
        "first_generator_yield": 0,
        "collect_generation": 0,
        "audio_file_write": 0,
        "metadata_lookup": 0,
        "chunk_file_write": 0,
        "chunk_notifications": 0,
        "first_stream_chunk": 0,
    }


def _apply_timing_breakdown(target, breakdown):
    for key, value in breakdown.items():
        target[key] = int(value)


def _normalize_request_language(language):
    if language is None:
        return None
    normalized = str(language).strip()
    if not normalized or normalized.lower() == "auto":
        return None
    return normalized


def _with_optional_kwarg(kwargs, key, value):
    if value is not None:
        kwargs[key] = value
    return kwargs


def _build_generation_kwargs(
    text,
    temperature,
    max_tokens=None,
    *,
    language="auto",
    voice=None,
    instruct=None,
    ref_audio=None,
    ref_text=None,
    stream=False,
    streaming_interval=None,
):
    language = _normalize_request_language(language)
    kwargs = {
        "text": text,
        "temperature": temperature,
        "verbose": False,
    }
    if max_tokens is not None:
        kwargs["max_tokens"] = int(max_tokens)
    if language is not None:
        kwargs["lang_code"] = language
    if voice:
        kwargs["voice"] = voice
    if instruct:
        kwargs["instruct"] = instruct
    if ref_audio:
        kwargs["ref_audio"] = ref_audio
    if ref_text:
        kwargs["ref_text"] = ref_text
    if stream:
        kwargs["stream"] = True
        if streaming_interval is not None:
            kwargs["streaming_interval"] = streaming_interval
    return kwargs


def _build_standard_generator(model, text, temperature, max_tokens=None, *, language="auto", voice=None, instruct=None, stream=False, streaming_interval=None):
    return model.generate(
        **_build_generation_kwargs(
            text=text,
            temperature=temperature,
            max_tokens=max_tokens,
            language=language,
            voice=voice,
            instruct=instruct,
            stream=stream,
            streaming_interval=streaming_interval,
        )
    )


def _build_clone_fallback_generator(model, text, temperature, clean_ref_audio, resolved_ref_text, max_tokens=None, *, language="auto", stream=False, streaming_interval=None):
    return model.generate(
        **_build_generation_kwargs(
            text=text,
            temperature=temperature,
            max_tokens=max_tokens,
            language=language,
            ref_audio=clean_ref_audio,
            ref_text=resolved_ref_text,
            stream=stream,
            streaming_interval=streaming_interval,
        )
    )


def _stream_generator_to_output(generator, request_id, final_path):
    response, write_output_ms, output_metadata, stream_breakdown = _consume_streaming_generator(
        generator,
        request_id=request_id,
        final_path=final_path,
    )
    return response, write_output_ms, output_metadata, stream_breakdown


def _stream_prepared_result_to_output(result, request_id, final_path, streaming_interval):
    response, write_output_ms, output_metadata, stream_breakdown = _stream_selected_audio(
        result,
        request_id=request_id,
        final_path=final_path,
        streaming_interval=streaming_interval,
    )
    return response, write_output_ms, output_metadata, stream_breakdown


def _finalize_generated_audio(result, final_path, streaming_used):
    write_start = time.perf_counter()
    _write_audio_file(
        final_path,
        result.audio,
        result.sample_rate,
    )
    audio_file_write_ms = int((time.perf_counter() - write_start) * 1000)
    metadata_start = time.perf_counter()
    output_metadata = get_audio_metadata(final_path)
    metadata_lookup_ms = int((time.perf_counter() - metadata_start) * 1000)
    metrics = _metrics_from_generation_result(result, streaming_used=streaming_used)
    response = {
        "audio_path": final_path,
        "duration_seconds": round(output_metadata["duration_seconds"], 2),
    }
    write_output_ms = audio_file_write_ms + metadata_lookup_ms
    return response, metrics, output_metadata, write_output_ms, {
        "audio_file_write": audio_file_write_ms,
        "metadata_lookup": metadata_lookup_ms,
    }


def _stream_selected_audio(result, request_id, final_path, streaming_interval):
    stream_start = time.perf_counter()
    normalized_audio, _, nchannels = _flatten_audio_samples(result.audio)
    session_dir = _make_stream_session_dir(request_id)

    total_samples = int(normalized_audio.shape[0])
    chunk_samples = max(1, int(result.sample_rate * max(streaming_interval, 0.16)))
    cumulative_duration = 0.0
    first_chunk_ms = None
    chunk_file_write_seconds = 0.0
    chunk_notification_seconds = 0.0

    for chunk_index, start in enumerate(range(0, total_samples, chunk_samples)):
        end = min(start + chunk_samples, total_samples)
        audio_chunk = normalized_audio[start:end] if normalized_audio.ndim == 1 else normalized_audio[start:end, :]
        chunk_path = os.path.join(session_dir, f"chunk_{chunk_index:03d}.wav")
        chunk_write_start = time.perf_counter()
        _audio_write_fn(chunk_path, audio_chunk, result.sample_rate, format="wav")
        chunk_file_write_seconds += time.perf_counter() - chunk_write_start

        chunk_sample_count = int(audio_chunk.shape[0])
        chunk_duration_seconds = chunk_sample_count / float(result.sample_rate)
        cumulative_duration += chunk_duration_seconds

        if first_chunk_ms is None:
            first_chunk_ms = int((time.perf_counter() - stream_start) * 1000)

        notification_start = time.perf_counter()
        send_generation_chunk(
            request_id=request_id,
            chunk_index=chunk_index,
            chunk_path=chunk_path,
            is_final=end >= total_samples,
            chunk_duration_seconds=chunk_duration_seconds,
            cumulative_duration_seconds=cumulative_duration,
            stream_session_dir=session_dir,
        )
        chunk_notification_seconds += time.perf_counter() - notification_start

    file_write_start = time.perf_counter()
    try:
        _write_audio_file(final_path, result.audio, result.sample_rate)
    except Exception:
        if final_path and os.path.exists(final_path):
            try:
                os.remove(final_path)
            except OSError:
                pass
        raise
    audio_file_write_ms = int((time.perf_counter() - file_write_start) * 1000)
    metadata_start = time.perf_counter()
    output_metadata = get_audio_metadata(final_path)
    metadata_lookup_ms = int((time.perf_counter() - metadata_start) * 1000)

    metrics = _metrics_from_generation_result(result, streaming_used=True)
    metrics["first_chunk_ms"] = first_chunk_ms or 0
    response = {
        "audio_path": final_path,
        "duration_seconds": round(output_metadata["duration_seconds"], 2),
        "stream_session_dir": session_dir,
        "metrics": metrics,
    }
    write_output_ms = int((time.perf_counter() - stream_start) * 1000)
    return response, write_output_ms, output_metadata, {
        "audio_file_write": audio_file_write_ms,
        "metadata_lookup": metadata_lookup_ms,
        "chunk_file_write": int(chunk_file_write_seconds * 1000),
        "chunk_notifications": int(chunk_notification_seconds * 1000),
        "first_stream_chunk": first_chunk_ms or 0,
    }


def _maybe_send_progress(percent, message, request_id=None):
    if request_id is not None:
        send_progress(percent, message, request_id=request_id)


# ---------------------------------------------------------------------------
# JSON-RPC helpers
# ---------------------------------------------------------------------------


def send_response(req_id, result):
    """Send a JSON-RPC success response."""
    msg = {"jsonrpc": "2.0", "id": req_id, "result": result}
    line = json.dumps(msg, ensure_ascii=False)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def send_error(req_id, code, message):
    """Send a JSON-RPC error response."""
    msg = {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}
    line = json.dumps(msg, ensure_ascii=False)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def send_notification(method, params):
    """Send a JSON-RPC notification (no id, no response expected)."""
    msg = {"jsonrpc": "2.0", "method": method, "params": params}
    line = json.dumps(msg, ensure_ascii=False)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def send_progress(percent, message, request_id=None):
    """Send a progress notification to the frontend."""
    payload = {"percent": percent, "message": message}
    if request_id is not None:
        payload["request_id"] = request_id
    send_notification("progress", payload)


def send_generation_chunk(
    request_id,
    chunk_index,
    chunk_path,
    is_final,
    chunk_duration_seconds,
    cumulative_duration_seconds,
    stream_session_dir,
):
    """Send a generation chunk notification to the frontend."""
    if request_id is None:
        return
    send_notification(
        "generation_chunk",
        {
            "request_id": request_id,
            "chunk_index": chunk_index,
            "chunk_path": chunk_path,
            "is_final": is_final,
            "chunk_duration_seconds": round(chunk_duration_seconds, 4),
            "cumulative_duration_seconds": round(cumulative_duration_seconds, 4),
            "stream_session_dir": stream_session_dir,
        },
    )


# ---------------------------------------------------------------------------
# RPC method handlers
# ---------------------------------------------------------------------------


def handle_ping(params):
    return {"status": "ok"}


def handle_init(params):
    """Initialize paths. Called once at startup."""
    global MODELS_DIR, OUTPUTS_DIR, VOICES_DIR, APP_SUPPORT_DIR, CLONE_REF_CACHE_DIR, STREAM_SESSIONS_DIR

    if "app_support_dir" in params:
        APP_SUPPORT_DIR = params["app_support_dir"]
        MODELS_DIR = os.path.join(APP_SUPPORT_DIR, "models")
        OUTPUTS_DIR = os.path.join(APP_SUPPORT_DIR, "outputs")
        VOICES_DIR = os.path.join(APP_SUPPORT_DIR, "voices")
        CLONE_REF_CACHE_DIR = os.path.join(APP_SUPPORT_DIR, "cache", "normalized_clone_refs")
        STREAM_SESSIONS_DIR = os.path.join(APP_SUPPORT_DIR, "cache", "stream_sessions")

    os.makedirs(MODELS_DIR, exist_ok=True)
    os.makedirs(OUTPUTS_DIR, exist_ok=True)
    os.makedirs(VOICES_DIR, exist_ok=True)
    os.makedirs(CLONE_REF_CACHE_DIR, exist_ok=True)
    os.makedirs(STREAM_SESSIONS_DIR, exist_ok=True)
    _prune_normalized_clone_reference_cache()

    return {"status": "ok", "models_dir": MODELS_DIR, "outputs_dir": OUTPUTS_DIR}


def _clear_clone_context_cache():
    """Drop all cached clone-conditioning state."""
    _clone_context_cache.clear()


def _clear_mlx_cache():
    if _mx is not None:
        _mx.clear_cache()


def _perform_memory_recovery():
    gc.collect()
    _clear_mlx_cache()


def _discard_loaded_model():
    global _current_model, _current_model_path, _current_model_id

    _current_model = None
    _current_model_path = None
    _current_model_id = None
    _clear_clone_context_cache()
    _primed_clone_reference_keys.clear()
    _perform_memory_recovery()


def _should_clear_cache_after_request(succeeded):
    if CACHE_POLICY == "always":
        return True
    if CACHE_POLICY == "adaptive":
        return not succeeded
    return False


def _is_retryable_allocation_error(error):
    message = str(error).lower()
    patterns = (
        "out of memory",
        "failed to allocate",
        "resource exhausted",
        "memory allocation",
        "insufficient memory",
        "mtlheap",
    )
    return any(pattern in message for pattern in patterns) or (
        "allocate" in message and ("memory" in message or "metal" in message)
    )


def _convert_audio_to_wav(input_path, output_path):
    """Convert audio to 24kHz mono WAV at a specific target path."""
    parent_dir = os.path.dirname(output_path)
    if parent_dir:
        os.makedirs(parent_dir, exist_ok=True)

    cmd = [
        _resolve_ffmpeg_binary(), "-y", "-v", "error", "-i", input_path,
        "-ar", str(SAMPLE_RATE), "-ac", "1", "-c:a", "pcm_s16le", output_path,
    ]

    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    except (subprocess.CalledProcessError, FileNotFoundError):
        raise RuntimeError("Could not convert audio. Is ffmpeg installed?")

    return output_path


def _convert_audio_with_mlx(input_path, output_path):
    """Convert audio to 24kHz mono WAV using mlx_audio (no subprocess)."""
    from mlx_audio.utils import load_audio

    audio = load_audio(input_path, sample_rate=SAMPLE_RATE)
    audio_np = _np.array(audio, dtype=_np.float32)
    if audio_np.ndim > 1:
        audio_np = audio_np.mean(axis=-1)

    parent_dir = os.path.dirname(output_path)
    if parent_dir:
        os.makedirs(parent_dir, exist_ok=True)
    _audio_write_fn(output_path, audio_np, SAMPLE_RATE, format="wav")
    return output_path


def _clone_reference_cache_path(input_path):
    """Build a stable normalized WAV cache path for an external reference clip."""
    stat_result = os.stat(input_path)
    fingerprint = hashlib.sha256(
        f"{os.path.realpath(input_path)}:{stat_result.st_size}:{stat_result.st_mtime_ns}".encode("utf-8")
    ).hexdigest()[:16]
    stem = re.sub(r"[^\w\s-]", "", os.path.splitext(os.path.basename(input_path))[0]).strip().replace(" ", "_")
    stem = stem or "reference"
    return os.path.join(CLONE_REF_CACHE_DIR, f"{stem}_{fingerprint}.wav")


def _prune_normalized_clone_reference_cache():
    """Bound disk usage for persistent normalized clone-reference WAVs."""
    if not os.path.isdir(CLONE_REF_CACHE_DIR):
        return

    now = time.time()
    entries = []
    for name in os.listdir(CLONE_REF_CACHE_DIR):
        if not name.endswith(".wav"):
            continue
        path = os.path.join(CLONE_REF_CACHE_DIR, name)
        try:
            stat_result = os.stat(path)
        except OSError:
            continue
        entries.append((path, stat_result.st_mtime, stat_result.st_size))

    for path, mtime, _ in list(entries):
        if now - mtime > NORMALIZED_CLONE_REF_MAX_AGE_SECONDS:
            try:
                os.remove(path)
            except OSError:
                pass

    remaining = [(p, m, s) for p, m, s in entries
                 if now - m <= NORMALIZED_CLONE_REF_MAX_AGE_SECONDS]
    if len(remaining) <= NORMALIZED_CLONE_REF_CACHE_LIMIT:
        return

    remaining.sort(key=lambda item: item[1], reverse=True)
    for path, _, _ in remaining[NORMALIZED_CLONE_REF_CACHE_LIMIT:]:
        try:
            os.remove(path)
        except OSError:
            pass


def _normalize_audio_with_stable_cache(input_path):
    """Convert once and reuse a stable cached WAV for repeated reference audio."""
    if not os.path.exists(input_path):
        return None

    ext = os.path.splitext(input_path)[1].lower()
    if ext == ".wav":
        try:
            with wave.open(input_path, "rb") as f:
                if f.getnchannels() == 1 and f.getframerate() == SAMPLE_RATE:
                    return input_path
        except wave.Error:
            pass

    cached_wav = _clone_reference_cache_path(input_path)
    if os.path.exists(cached_wav):
        try:
            os.utime(cached_wav, None)
        except OSError:
            pass
        return cached_wav

    if _audio_write_fn is not None:
        try:
            converted = _convert_audio_with_mlx(input_path, cached_wav)
        except Exception:
            converted = _convert_audio_to_wav(input_path, cached_wav)
    else:
        converted = _convert_audio_to_wav(input_path, cached_wav)
    _prune_normalized_clone_reference_cache()
    return converted


def _normalize_clone_reference(ref_audio_path):
    """Return a normalized WAV path suitable for clone conditioning.

    Non-WAV references are converted and stored in a stable disk cache so the
    prepared clone-conditioning cache can reuse the same converted reference
    across requests.
    """
    return _normalize_audio_with_stable_cache(ref_audio_path)


def _resolve_clone_transcript(clean_ref_audio_path, requested_transcript):
    """Prefer an explicit transcript, then fall back to a sidecar transcript."""
    transcript = (requested_transcript or "").strip()
    if transcript:
        return transcript

    if not clean_ref_audio_path:
        return None

    sidecar = os.path.splitext(clean_ref_audio_path)[0] + ".txt"
    if not os.path.exists(sidecar):
        return None

    try:
        with open(sidecar, "r", encoding="utf-8") as f:
            text = f.read().strip()
            return text or None
    except OSError:
        return None


def _clone_cache_key(clean_ref_audio_path, ref_text):
    """Build a stable cache key for prepared clone-conditioning state."""
    stat_result = os.stat(clean_ref_audio_path)
    real_path = os.path.realpath(clean_ref_audio_path)
    cache_root = os.path.realpath(CLONE_REF_CACHE_DIR)

    # Stable normalized reference files already encode the source identity in
    # their cache-path fingerprint. Ignore mtime here so access-time refreshes
    # used for pruning do not invalidate prepared clone contexts on every hit.
    if real_path.startswith(cache_root + os.sep):
        file_identity = (real_path, stat_result.st_size)
    else:
        file_identity = (real_path, stat_result.st_size, stat_result.st_mtime_ns)

    return (
        _current_model_path,
        *file_identity,
        (ref_text or "").strip(),
    )


def _cache_clone_context(cache_key, prepared_context):
    """Insert a prepared clone context into the bounded LRU cache."""
    _clone_context_cache[cache_key] = prepared_context
    _clone_context_cache.move_to_end(cache_key)
    while len(_clone_context_cache) > CLONE_CONTEXT_CACHE_CAPACITY:
        _clone_context_cache.popitem(last=False)


def _get_or_prepare_clone_context(clean_ref_audio_path, ref_text):
    """Fetch or build a prepared clone context for repeated requests."""
    if (
        _prepare_icl_context_fn is None
        or _can_prepare_icl_fn is None
        or _current_model is None
        or not _can_prepare_icl_fn(_current_model)
        or not ref_text
    ):
        return None, None

    cache_key = _clone_cache_key(clean_ref_audio_path, ref_text)
    cached = _clone_context_cache.get(cache_key)
    if cached is not None:
        _clone_context_cache.move_to_end(cache_key)
        return cached, True

    prepared = _prepare_icl_context_fn(_current_model, clean_ref_audio_path, ref_text)
    _cache_clone_context(cache_key, prepared)
    return prepared, False


def _can_use_shared_reference_clone_batch_fast_path(
    model,
    *,
    can_use_prepared,
    requested_stream,
):
    """Return True when `generate_clone_batch` can use the shared-reference fast path.

    This internal clone-batch RPC intentionally keeps the optimized shared-reference
    path non-streaming-only. When streaming is requested, or when the small set of
    upstream mlx-audio 0.4.2 batch seams we rely on are unavailable, the server
    falls back to repeated single-item generation while still reusing the prepared
    reference context when possible.
    """
    if requested_stream or not can_use_prepared or _batch_generate_prepared_icl_fn is None:
        return False

    if getattr(getattr(model, "config", None), "tts_model_type", None) != "base":
        return False

    if not hasattr(model, "_sample_token_batch"):
        return False

    speech_tokenizer = getattr(model, "speech_tokenizer", None)
    return hasattr(speech_tokenizer, "batch_decode")


def _clone_prime_identity_key(clean_ref_audio_path, ref_text):
    """Build a stable key for primed clone-reference streaming state."""
    return (
        _current_model_path,
        *_clone_cache_key(clean_ref_audio_path, ref_text),
    )


def _reset_clone_streaming_state():
    decoder = getattr(getattr(_current_model, "speech_tokenizer", None), "decoder", None)
    reset_streaming_state = getattr(decoder, "reset_streaming_state", None)
    if callable(reset_streaming_state):
        reset_streaming_state()


def _prime_streaming_generator(generator):
    """Advance a streaming generator through its first yielded chunk, then clean up."""
    generation_start = time.perf_counter()
    first_chunk_ms = None

    try:
        for _ in generator:
            first_chunk_ms = int((time.perf_counter() - generation_start) * 1000)
            break
    finally:
        close = getattr(generator, "close", None)
        if callable(close):
            try:
                close()
            except Exception:
                pass
        _reset_clone_streaming_state()

    if first_chunk_ms is None:
        raise RuntimeError("Clone priming produced no streaming chunk")

    return {
        "first_stream_chunk": first_chunk_ms,
        "generation": int((time.perf_counter() - generation_start) * 1000),
    }


def _run_clone_reference_prime(clean_ref_audio_path, resolved_ref_text, streaming_interval, language=None):
    """Prime the actual clone streaming path so the next visible generate is fast."""
    if _current_model is None:
        raise RuntimeError("No model loaded. Call load_model first.")

    profile = _prewarm_profile("clone")
    warmup_text = profile["text"]
    warmup_max_tokens = profile["max_tokens"]
    prepare_clone_context_ms = 0
    prepared_clone_used = False
    clone_cache_hit = None

    prepare_start = time.perf_counter()
    prepared_context, clone_cache_hit = _get_or_prepare_clone_context(
        clean_ref_audio_path,
        resolved_ref_text,
    )
    prepare_clone_context_ms = int((time.perf_counter() - prepare_start) * 1000)

    if prepared_context is not None and _generate_prepared_icl_fn is not None:
        prepared_clone_used = True
        generator = _generate_prepared_icl_fn(
            _current_model,
            warmup_text,
            prepared_context,
            **_with_optional_kwarg(
                {
                    "temperature": 0.6,
                    "top_p": 1.0,
                    "repetition_penalty": 1.5,
                    "max_tokens": warmup_max_tokens,
                    "stream": True,
                    "streaming_interval": streaming_interval,
                },
                "language",
                language,
            ),
        )
    else:
        generator = _build_clone_fallback_generator(
            _current_model,
            text=warmup_text,
            temperature=0.6,
            clean_ref_audio=clean_ref_audio_path,
            resolved_ref_text=resolved_ref_text,
            max_tokens=warmup_max_tokens,
            stream=True,
            streaming_interval=streaming_interval,
            **({"language": language} if language is not None else {}),
        )

    streaming_timings = _prime_streaming_generator(generator)
    return {
        "prepare_clone_context": prepare_clone_context_ms,
        "generation": streaming_timings["generation"],
        "first_stream_chunk": streaming_timings["first_stream_chunk"],
        "prepared_clone_used": prepared_clone_used,
        "clone_cache_hit": clone_cache_hit,
        "prime_max_tokens": warmup_max_tokens,
        "streaming_interval": streaming_interval,
    }


def _infer_legacy_mode(voice=None, ref_audio=None):
    if ref_audio:
        return "clone"
    if voice:
        return "custom"
    return "design"


def _current_model_contract():
    if not _current_model_id:
        return None
    return MODELS.get(_current_model_id)


def _resolve_generation_mode(requested_mode, voice=None, ref_audio=None):
    if requested_mode:
        return requested_mode

    current_model_contract = _current_model_contract()
    if current_model_contract:
        return current_model_contract["mode"]

    return _infer_legacy_mode(voice=voice, ref_audio=ref_audio)


def _resolve_output_subfolder(requested_mode, voice=None, ref_audio=None):
    current_model_contract = _current_model_contract()
    if current_model_contract:
        return current_model_contract["outputSubfolder"]

    if requested_mode and requested_mode in MODELS_BY_MODE:
        return MODELS_BY_MODE[requested_mode]["outputSubfolder"]

    legacy_mode = _infer_legacy_mode(voice=voice, ref_audio=ref_audio)
    if legacy_mode in MODELS_BY_MODE:
        return MODELS_BY_MODE[legacy_mode]["outputSubfolder"]

    return {
        "custom": "CustomVoice",
        "design": "VoiceDesign",
        "clone": "Clones",
    }[legacy_mode]


def _resolve_final_output_path(explicit_output_path, text, mode=None, voice=None, ref_audio=None):
    """Resolve the final output path while preserving the existing contract."""
    if explicit_output_path:
        parent_dir = os.path.dirname(explicit_output_path)
        if parent_dir:
            os.makedirs(parent_dir, exist_ok=True)
        return explicit_output_path

    subfolder = _resolve_output_subfolder(mode, voice=voice, ref_audio=ref_audio)
    return make_output_path(subfolder, text)


def _derive_generation_paths(final_path):
    """Return the target directory, file stem, and default generated file path."""
    target_dir = os.path.dirname(final_path) or OUTPUTS_DIR
    os.makedirs(target_dir, exist_ok=True)
    stem = os.path.splitext(os.path.basename(final_path))[0] or "audio"
    generated_path = os.path.join(target_dir, f"{stem}_000.wav")
    return target_dir, stem, generated_path


def _to_int16_audio_array(audio):
    """Convert model output audio into the signed int16 format used for WAV output."""
    array = audio if isinstance(audio, _np.ndarray) else _np.array(audio)

    if array.dtype in (_np.float32, _np.float64):
        array = _np.clip(array, -1.0, 1.0)
        array = (array * 32767).astype(_np.int16)
    elif array.dtype != _np.int16:
        array = array.astype(_np.int16)

    return array


def _flatten_audio_samples(audio):
    """Return normalized int16 audio data plus flattened interleaved PCM samples."""
    normalized = _to_int16_audio_array(audio)
    if normalized.ndim == 1:
        nchannels = 1
        samples_flat = normalized
    else:
        nchannels = int(normalized.shape[1])
        samples_flat = normalized.reshape(-1)

    return normalized, samples_flat, nchannels


def _write_audio_file(output_path, audio, sample_rate):
    """Write an audio buffer to a WAV file."""
    parent_dir = os.path.dirname(output_path)
    if parent_dir:
        os.makedirs(parent_dir, exist_ok=True)
    _audio_write_fn(output_path, _to_int16_audio_array(audio), sample_rate, format="wav")


def _make_stream_session_dir(request_id):
    session_id = f"{int(time.time() * 1000)}_{request_id or 'stream'}_{uuid.uuid4().hex[:8]}"
    session_dir = os.path.join(STREAM_SESSIONS_DIR, session_id)
    os.makedirs(session_dir, exist_ok=True)
    return session_dir


def _metrics_from_generation_result(result, streaming_used):
    if result is None:
        return {"streaming_used": streaming_used}

    return {
        "token_count": int(getattr(result, "token_count", 0) or 0),
        "processing_time_seconds": round(float(getattr(result, "processing_time_seconds", 0.0) or 0.0), 4),
        "peak_memory_usage": round(float(getattr(result, "peak_memory_usage", 0.0) or 0.0), 4),
        "streaming_used": streaming_used,
    }


def _consume_streaming_generator(generator, request_id, final_path):
    stream_start = time.perf_counter()
    write_start = time.perf_counter()
    session_dir = _make_stream_session_dir(request_id)
    chunk_index = 0
    cumulative_duration = 0.0
    first_chunk_ms = None
    total_token_count = 0
    peak_memory_usage = 0.0
    last_chunk = None
    wav_writer = None
    expected_sample_rate = None
    expected_channels = None
    chunk_file_write_seconds = 0.0
    chunk_notification_seconds = 0.0

    try:
        for chunk in generator:
            chunk_received_at = time.perf_counter()
            if first_chunk_ms is None:
                first_chunk_ms = int((chunk_received_at - stream_start) * 1000)

            normalized_audio, samples_flat, nchannels = _flatten_audio_samples(chunk.audio)
            chunk_sample_rate = int(getattr(chunk, "sample_rate", 0) or 0)
            if chunk_sample_rate <= 0:
                raise RuntimeError("Streaming chunk is missing a valid sample rate")

            if wav_writer is None:
                parent_dir = os.path.dirname(final_path)
                if parent_dir:
                    os.makedirs(parent_dir, exist_ok=True)
                wav_writer = wave.open(final_path, "wb")
                wav_writer.setnchannels(nchannels)
                wav_writer.setsampwidth(2)
                wav_writer.setframerate(chunk_sample_rate)
                expected_sample_rate = chunk_sample_rate
                expected_channels = nchannels
            elif chunk_sample_rate != expected_sample_rate or nchannels != expected_channels:
                raise RuntimeError("Streaming generation produced incompatible audio chunk formats")

            chunk_path = os.path.join(session_dir, f"chunk_{chunk_index:03d}.wav")
            chunk_write_start = time.perf_counter()
            _audio_write_fn(chunk_path, normalized_audio, chunk_sample_rate, format="wav")
            wav_writer.writeframes(samples_flat.tobytes())
            chunk_file_write_seconds += time.perf_counter() - chunk_write_start

            sample_count = int(getattr(chunk, "samples", 0) or 0)
            if sample_count <= 0:
                sample_count = samples_flat.size // max(nchannels, 1)

            chunk_duration_seconds = sample_count / float(chunk_sample_rate)
            cumulative_duration += chunk_duration_seconds
            total_token_count += int(getattr(chunk, "token_count", 0) or 0)
            peak_memory_usage = max(
                peak_memory_usage,
                float(getattr(chunk, "peak_memory_usage", 0.0) or 0.0),
            )

            notification_start = time.perf_counter()
            send_generation_chunk(
                request_id=request_id,
                chunk_index=chunk_index,
                chunk_path=chunk_path,
                is_final=bool(getattr(chunk, "is_final_chunk", False)),
                chunk_duration_seconds=chunk_duration_seconds,
                cumulative_duration_seconds=cumulative_duration,
                stream_session_dir=session_dir,
            )
            chunk_notification_seconds += time.perf_counter() - notification_start
            last_chunk = chunk
            chunk_index += 1
    finally:
        if wav_writer is not None:
            wav_writer.close()

    if last_chunk is None:
        raise RuntimeError("Generation produced no audio file")

    write_output_ms = int((time.perf_counter() - write_start) * 1000)
    metadata_start = time.perf_counter()
    output_metadata = get_audio_metadata(final_path)
    metadata_lookup_ms = int((time.perf_counter() - metadata_start) * 1000)

    metrics = _metrics_from_generation_result(last_chunk, streaming_used=True)
    metrics["token_count"] = total_token_count
    metrics["peak_memory_usage"] = round(peak_memory_usage, 4)
    metrics["processing_time_seconds"] = round(time.perf_counter() - stream_start, 4)
    metrics["first_chunk_ms"] = first_chunk_ms

    return (
        {
            "audio_path": final_path,
            "duration_seconds": round(cumulative_duration, 2),
            "stream_session_dir": session_dir,
            "metrics": metrics,
        },
        write_output_ms,
        output_metadata,
        {
            "first_generator_yield": first_chunk_ms or 0,
            "collect_generation": int((time.perf_counter() - stream_start) * 1000),
            "chunk_file_write": int(chunk_file_write_seconds * 1000),
            "chunk_notifications": int(chunk_notification_seconds * 1000),
            "metadata_lookup": metadata_lookup_ms,
        },
    )


def _load_model_request(model_id=None, model_path=None, benchmark=False, request_id=None):
    """Load a model into memory and return the standard response payload."""
    global _current_model, _current_model_path, _current_model_id

    load_start = time.perf_counter()
    model_path, resolved_model_id = _resolve_model_request(model_id=model_id, model_path=model_path)
    was_same_model_loaded = _current_model is not None and _current_model_path == model_path

    if was_same_model_loaded:
        result = {
            "success": True,
            "model_path": model_path,
            "cached": True,
            "model_id": resolved_model_id,
        }
        if resolved_model_id:
            _current_model_id = resolved_model_id
            result.update(_resolved_model_capabilities(MODELS[resolved_model_id]))
        if benchmark:
            result["benchmark"] = {
                "timings_ms": {
                    "load_model_total": int((time.perf_counter() - load_start) * 1000),
                }
            }
        return result, resolved_model_id, model_path, False

    if _current_model is not None:
        _discard_loaded_model()

    _ensure_mlx()
    _maybe_send_progress(5, "Preparing model...", request_id=request_id)
    _maybe_send_progress(25, "Loading model...", request_id=request_id)

    _current_model = _load_model_fn(model_path)
    if _enable_speech_tokenizer_encoder_fn is not None:
        _enable_speech_tokenizer_encoder_fn(_current_model, model_path)
    _current_model_path = model_path
    _current_model_id = resolved_model_id

    _maybe_send_progress(100, "Model ready", request_id=request_id)

    result = {
        "success": True,
        "model_path": model_path,
        "model_id": resolved_model_id,
    }
    if resolved_model_id:
        result.update(_resolved_model_capabilities(MODELS[resolved_model_id]))
    if benchmark:
        result["benchmark"] = {
            "timings_ms": {
                "load_model_total": int((time.perf_counter() - load_start) * 1000),
            }
        }
    return result, resolved_model_id, model_path, True


def handle_load_model(params, request_id=None):
    """Load a model into memory. Unloads any existing model first."""
    result, _, _, _ = _load_model_request(
        model_id=params.get("model_id"),
        model_path=params.get("model_path"),
        benchmark=bool(params.get("benchmark", False)),
        request_id=request_id,
    )
    return result


def _run_model_prewarm(mode, voice=None, instruct=None, ref_audio=None, ref_text=None, language=None):
    """Run a short in-memory generation to pay one-time model warm-up costs while idle."""
    if _current_model is None:
        raise RuntimeError("No model loaded. Call load_model first.")

    profile = _prewarm_profile(mode)
    warmup_text = profile["text"]
    warmup_max_tokens = profile["max_tokens"]
    generation_start = time.perf_counter()
    normalize_reference_ms = 0
    prepare_clone_context_ms = 0
    prepared_clone_used = False
    clone_cache_hit = None
    generation_ms = 0

    if mode == "custom":
        warm_results = list(
            _build_standard_generator(
                _current_model,
                text=warmup_text,
                temperature=0.6,
                max_tokens=warmup_max_tokens,
                language=language,
                voice=voice or DEFAULT_SPEAKER,
                instruct=instruct or "Normal tone",
            )
        )
        generation_ms = int((time.perf_counter() - generation_start) * 1000)
    elif mode == "design":
        # Model load alone warms Metal shader caches sufficiently for design mode.
        warm_results = None
        generation_ms = int((time.perf_counter() - generation_start) * 1000)
    elif mode == "clone":
        if not ref_audio:
            raise ValueError("Mode 'clone' prewarm requires ref_audio.")

        normalize_start = time.perf_counter()
        clean_ref_audio = _normalize_clone_reference(ref_audio)
        normalize_reference_ms = int((time.perf_counter() - normalize_start) * 1000)
        if not clean_ref_audio:
            raise RuntimeError("Could not process reference audio file")

        resolved_ref_text = _resolve_clone_transcript(clean_ref_audio, ref_text)
        prepare_start = time.perf_counter()
        prepared_context, clone_cache_hit = _get_or_prepare_clone_context(
            clean_ref_audio,
            resolved_ref_text,
        )
        prepare_clone_context_ms = int((time.perf_counter() - prepare_start) * 1000)
        if prepared_context is not None and _generate_prepared_icl_fn is not None:
            prepared_clone_used = True
            generator = _generate_prepared_icl_fn(
                _current_model,
                warmup_text,
                prepared_context,
                **_with_optional_kwarg(
                    {
                        "temperature": 0.6,
                        "top_p": 1.0,
                        "repetition_penalty": 1.5,
                        "max_tokens": warmup_max_tokens,
                    },
                    "language",
                    language,
                ),
            )
            warm_results = list(generator)
        else:
            warm_kwargs = {
                "text": warmup_text,
                "ref_audio": clean_ref_audio,
                "verbose": False,
                "temperature": 0.6,
                "max_tokens": warmup_max_tokens,
            }
            if language is not None:
                warm_kwargs["lang_code"] = language
            if resolved_ref_text:
                warm_kwargs["ref_text"] = resolved_ref_text
            warm_results = list(_current_model.generate(**warm_kwargs))
        generation_ms = int((time.perf_counter() - generation_start) * 1000)
    else:
        raise ValueError(f"Unknown prewarm mode: {mode}")

    if warm_results is not None and not warm_results:
        raise RuntimeError("Prewarm produced no generation output")

    return {
        "normalize_reference": normalize_reference_ms,
        "prepare_clone_context": prepare_clone_context_ms,
        "generation": generation_ms,
        "prepared_clone_used": prepared_clone_used,
        "clone_cache_hit": clone_cache_hit,
        "prewarm_max_tokens": warmup_max_tokens,
    }


def handle_prewarm_model(params, request_id=None):
    """Optionally load and warm a model so the first user-facing request is cheaper."""
    benchmark = bool(params.get("benchmark", False))
    model_id = params.get("model_id")
    model_path = params.get("model_path")
    requested_mode = params.get("mode")
    voice = params.get("voice")
    instruct = params.get("instruct")
    ref_audio = params.get("ref_audio")
    ref_text = params.get("ref_text")
    language = _normalize_request_language(params.get("language"))

    overall_start = time.perf_counter()
    model_path, resolved_model_id = _resolve_model_request(model_id=model_id, model_path=model_path)
    model_key = _model_identity_key(resolved_model_id, model_path)
    loaded_model_changed = _current_model_path != model_path

    load_result, resolved_model_id, model_path, _ = _load_model_request(
        model_id=model_id,
        model_path=model_path,
        benchmark=benchmark,
        request_id=None,
    )
    load_timings = load_result.get("benchmark", {}).get("timings_ms", {})
    warm_mode = requested_mode or (MODELS.get(resolved_model_id, {}).get("mode") if resolved_model_id else None)
    if not warm_mode:
        current_model_contract = _current_model_contract()
        warm_mode = current_model_contract["mode"] if current_model_contract else None
    if not warm_mode:
        raise RuntimeError("Could not determine which generation mode to prewarm")

    prewarm_key = _prewarm_identity_key(
        model_key,
        warm_mode,
        voice=voice,
        instruct=instruct,
        ref_audio=ref_audio,
        ref_text=ref_text,
    )

    already_prewarmed = prewarm_key in _prewarmed_model_keys
    prewarm_timings = {
        "normalize_reference": 0,
        "prepare_clone_context": 0,
        "generation": 0,
        "prewarm_max_tokens": 0,
    }
    prepared_clone_used = False
    clone_cache_hit = None

    if not already_prewarmed:
        prewarm_timings = _run_model_prewarm(
            warm_mode,
            voice=voice,
            instruct=instruct,
            ref_audio=ref_audio,
            ref_text=ref_text,
            language=language,
        )
        prepared_clone_used = prewarm_timings["prepared_clone_used"]
        clone_cache_hit = prewarm_timings["clone_cache_hit"]
        _prewarmed_model_keys.add(prewarm_key)

    result = {
        "success": True,
        "model_id": resolved_model_id,
        "model_path": model_path,
        "loaded_model_changed": loaded_model_changed,
        "already_prewarmed": already_prewarmed,
        "prewarm_applied": not already_prewarmed,
    }
    if benchmark:
        result["benchmark"] = {
            "mode": warm_mode,
            "prepared_clone_used": prepared_clone_used,
            "clone_cache_hit": clone_cache_hit,
            "prewarm_max_tokens": prewarm_timings.get("prewarm_max_tokens", 0),
            "timings_ms": {
                "load_model_total": load_timings.get("load_model_total", 0),
                "normalize_reference": prewarm_timings["normalize_reference"],
                "prepare_clone_context": prewarm_timings["prepare_clone_context"],
                "generation": prewarm_timings["generation"],
                "total_backend": int((time.perf_counter() - overall_start) * 1000),
            },
        }
    return result


def handle_prepare_clone_reference(params, request_id=None):
    """Prepare clone reference state without blocking on a warm-up generation."""
    benchmark = bool(params.get("benchmark", False))
    model_id = params.get("model_id")
    model_path = params.get("model_path")
    ref_audio = params.get("ref_audio")
    ref_text = params.get("ref_text")

    if not ref_audio:
        raise ValueError("prepare_clone_reference requires ref_audio")

    overall_start = time.perf_counter()
    model_path, resolved_model_id = _resolve_model_request(model_id=model_id, model_path=model_path)
    loaded_model_changed = _current_model_path != model_path

    load_result, resolved_model_id, model_path, _ = _load_model_request(
        model_id=model_id,
        model_path=model_path,
        benchmark=benchmark,
        request_id=request_id,
    )
    load_timings = load_result.get("benchmark", {}).get("timings_ms", {})

    normalize_start = time.perf_counter()
    clean_ref_audio = _normalize_clone_reference(ref_audio)
    normalize_reference_ms = int((time.perf_counter() - normalize_start) * 1000)
    if not clean_ref_audio:
        raise RuntimeError("Could not process reference audio file")

    resolved_ref_text = _resolve_clone_transcript(clean_ref_audio, ref_text)
    send_progress(20, "Preparing voice context...", request_id=request_id)
    prepare_start = time.perf_counter()
    prepared_context, clone_cache_hit = _get_or_prepare_clone_context(
        clean_ref_audio,
        resolved_ref_text,
    )
    prepare_clone_context_ms = int((time.perf_counter() - prepare_start) * 1000)
    prepared_clone_used = prepared_context is not None and _generate_prepared_icl_fn is not None

    result = {
        "success": True,
        "model_id": resolved_model_id,
        "model_path": model_path,
        "loaded_model_changed": loaded_model_changed,
        "prepared_clone_used": prepared_clone_used,
        "clone_cache_hit": clone_cache_hit,
        "reference_prepared": prepared_context is not None,
    }
    if benchmark:
        result["benchmark"] = {
            "prepared_clone_used": prepared_clone_used,
            "clone_cache_hit": clone_cache_hit,
            "timings_ms": {
                "load_model_total": load_timings.get("load_model_total", 0),
                "normalize_reference": normalize_reference_ms,
                "prepare_clone_context": prepare_clone_context_ms,
                "total_backend": int((time.perf_counter() - overall_start) * 1000),
            },
        }
    return result


def handle_prime_clone_reference(params, request_id=None):
    """Prime the real clone streaming path for a specific reference voice."""
    benchmark = bool(params.get("benchmark", False))
    model_id = params.get("model_id")
    model_path = params.get("model_path")
    ref_audio = params.get("ref_audio")
    ref_text = params.get("ref_text")
    language = _normalize_request_language(params.get("language"))
    streaming_interval = float(params.get("streaming_interval", DEFAULT_STREAMING_INTERVAL))

    if not ref_audio:
        raise ValueError("prime_clone_reference requires ref_audio")

    overall_start = time.perf_counter()
    model_path, resolved_model_id = _resolve_model_request(model_id=model_id, model_path=model_path)
    loaded_model_changed = _current_model_path != model_path

    load_result, resolved_model_id, model_path, _ = _load_model_request(
        model_id=model_id,
        model_path=model_path,
        benchmark=benchmark,
        request_id=request_id,
    )
    load_timings = load_result.get("benchmark", {}).get("timings_ms", {})

    normalize_start = time.perf_counter()
    clean_ref_audio = _normalize_clone_reference(ref_audio)
    normalize_reference_ms = int((time.perf_counter() - normalize_start) * 1000)
    if not clean_ref_audio:
        raise RuntimeError("Could not process reference audio file")

    resolved_ref_text = _resolve_clone_transcript(clean_ref_audio, ref_text)
    prime_key = _clone_prime_identity_key(clean_ref_audio, resolved_ref_text)
    already_primed = prime_key in _primed_clone_reference_keys

    prime_timings = {
        "normalize_reference": normalize_reference_ms,
        "prepare_clone_context": 0,
        "generation": 0,
        "first_stream_chunk": 0,
        "prime_max_tokens": 0,
        "streaming_interval": streaming_interval,
    }
    prepared_clone_used = False
    clone_cache_hit = None

    if not already_primed:
        send_progress(20, "Preparing voice context...", request_id=request_id)
        prime_timings = _run_clone_reference_prime(
            clean_ref_audio,
            resolved_ref_text,
            streaming_interval=streaming_interval,
            language=language,
        )
        prime_timings["normalize_reference"] = normalize_reference_ms
        prepared_clone_used = prime_timings["prepared_clone_used"]
        clone_cache_hit = prime_timings["clone_cache_hit"]
        _primed_clone_reference_keys.add(prime_key)

    result = {
        "success": True,
        "model_id": resolved_model_id,
        "model_path": model_path,
        "loaded_model_changed": loaded_model_changed,
        "already_primed": already_primed,
        "prime_applied": not already_primed,
        "prepared_clone_used": prepared_clone_used,
        "clone_cache_hit": clone_cache_hit,
    }
    if benchmark:
        result["benchmark"] = {
            "prepared_clone_used": prepared_clone_used,
            "clone_cache_hit": clone_cache_hit,
            "prime_max_tokens": prime_timings.get("prime_max_tokens", 0),
            "streaming_interval": prime_timings.get("streaming_interval", streaming_interval),
            "timings_ms": {
                "load_model_total": load_timings.get("load_model_total", 0),
                "normalize_reference": prime_timings["normalize_reference"],
                "prepare_clone_context": prime_timings["prepare_clone_context"],
                "first_stream_chunk": prime_timings["first_stream_chunk"],
                "generation": prime_timings["generation"],
                "total_backend": int((time.perf_counter() - overall_start) * 1000),
            },
        }
    return result


def handle_unload_model(params):
    """Unload current model and free memory."""
    _discard_loaded_model()

    return {"success": True}


def handle_generate(params, request_id=None):
    """Generate audio from text. Requires a model to be loaded."""
    global _current_model

    if _current_model is None:
        raise RuntimeError("No model loaded. Call load_model first.")

    _ensure_mlx()

    text = (params.get("text") or "").strip()
    if not text:
        raise ValueError("Missing required param: text")

    output_path = params.get("output_path")
    requested_mode = params.get("mode")
    model_id = params.get("model_id")
    voice = params.get("voice")
    instruct = params.get("instruct")
    ref_audio = params.get("ref_audio")
    ref_text = params.get("ref_text")
    language = _normalize_request_language(params.get("language"))
    temperature = params.get("temperature", 0.6)
    max_tokens = params.get("max_tokens")
    temperature_value = float(temperature)
    stream = bool(params.get("stream", False))
    streaming_interval = float(params.get("streaming_interval", DEFAULT_STREAMING_INTERVAL))
    benchmark = bool(params.get("benchmark", False))
    benchmark_label = params.get("benchmark_label")
    benchmark_mode = _resolve_generation_mode(requested_mode, voice=voice, ref_audio=ref_audio)
    current_model_contract = _current_model_contract()

    if requested_mode and requested_mode not in MODELS_BY_MODE:
        raise ValueError(f"Unknown generation mode: {requested_mode}")

    if requested_mode and current_model_contract and current_model_contract["mode"] != requested_mode:
        if model_id:
            _load_model_request(model_id=model_id, benchmark=False, request_id=None)
            current_model_contract = _current_model_contract()
        else:
            raise ValueError(
                f"Requested mode '{requested_mode}' does not match loaded model '{_current_model_id}' ({current_model_contract['mode']})."
            )

    if benchmark_mode == "custom" and not voice:
        raise ValueError("Mode 'custom' requires a voice.")
    if benchmark_mode == "design" and not instruct:
        raise ValueError("Mode 'design' requires instruct.")
    if benchmark_mode == "clone" and not ref_audio:
        raise ValueError("Mode 'clone' requires ref_audio.")

    effective_max_tokens = int(max_tokens) if max_tokens is not None else None
    model_was_loaded = _current_model is not None
    benchmark_flags_base = {
        "label": benchmark_label or benchmark_mode,
        "mode": benchmark_mode,
        "prepared_clone_used": False,
        "clone_cache_hit": None,
        "streaming_used": bool(stream and request_id is not None),
        "used_temp_reference": False,
        "request_temperature": temperature_value,
        "request_max_tokens": effective_max_tokens,
        "model_path": _current_model_path,
        "model_already_loaded": bool(model_was_loaded),
        "post_request_cache_clear_enabled": CACHE_POLICY == "always",
        "cache_policy": CACHE_POLICY,
        "allocation_retry_attempted": False,
        "allocation_retry_succeeded": False,
    }
    overall_start = time.perf_counter()
    final_path = _resolve_final_output_path(output_path, text, mode=benchmark_mode, voice=voice, ref_audio=ref_audio)
    target_dir, target_stem, generated_path = _derive_generation_paths(final_path)
    stream_session_dirs = []

    if ref_audio:
        send_progress(10, "Normalizing reference...", request_id=request_id)
    else:
        send_progress(15, "Preparing request...", request_id=request_id)

    def cleanup_partial_outputs():
        paths_to_remove = {final_path}
        if generated_path != final_path:
            paths_to_remove.add(generated_path)

        for path in paths_to_remove:
            if os.path.exists(path):
                try:
                    os.remove(path)
                except OSError:
                    pass

        chunk_prefix = f"{target_stem}__chunk_"
        if os.path.isdir(target_dir):
            for name in os.listdir(target_dir):
                if name.startswith(chunk_prefix) and name.endswith(".wav"):
                    try:
                        os.remove(os.path.join(target_dir, name))
                    except OSError:
                        pass

        for session_dir in stream_session_dirs:
            if os.path.isdir(session_dir):
                shutil.rmtree(session_dir, ignore_errors=True)

    def generate_once():
        nonlocal effective_max_tokens, stream_session_dirs

        benchmark_flags = dict(benchmark_flags_base)
        benchmark_timings = {
            "normalize_reference": 0,
            "prepare_clone_context": 0,
            "generation": 0,
            "write_output": 0,
        }
        benchmark_timings.update(_timing_breakdown_template())
        metrics = None

        if ref_audio:
            normalize_start = time.perf_counter()
            clean_ref_audio = _normalize_clone_reference(ref_audio)
            benchmark_timings["normalize_reference"] = int((time.perf_counter() - normalize_start) * 1000)
            if not clean_ref_audio:
                raise RuntimeError("Could not process reference audio file")
            benchmark_flags["used_temp_reference"] = clean_ref_audio != ref_audio

            resolved_ref_text = _resolve_clone_transcript(clean_ref_audio, ref_text)
            prepare_start = time.perf_counter()
            prepared_context, clone_cache_hit = _get_or_prepare_clone_context(
                clean_ref_audio,
                resolved_ref_text,
            )
            benchmark_timings["prepare_clone_context"] = int((time.perf_counter() - prepare_start) * 1000)
            benchmark_flags["clone_cache_hit"] = clone_cache_hit

            send_progress(30, "Preparing voice context...", request_id=request_id)
            if prepared_context is not None and _generate_prepared_icl_fn is not None:
                benchmark_flags["prepared_clone_used"] = True
                if effective_max_tokens is None:
                    effective_max_tokens = 4096
                    benchmark_flags["request_max_tokens"] = effective_max_tokens
                generator = _generate_prepared_icl_fn(
                    _current_model,
                    text,
                    prepared_context,
                    **_with_optional_kwarg(
                        {
                            "temperature": temperature_value,
                            "max_tokens": effective_max_tokens,
                            "stream": bool(stream and request_id is not None),
                            "streaming_interval": streaming_interval,
                        },
                        "language",
                        language,
                    ),
                )
                if stream and request_id is not None:
                    send_progress(55, "Streaming audio...", request_id=request_id)
                    generation_start = time.perf_counter()
                    result, benchmark_timings["write_output"], output_metadata, stream_breakdown = _stream_generator_to_output(
                        generator,
                        request_id=request_id,
                        final_path=final_path,
                    )
                    benchmark_timings["generation"] = int((time.perf_counter() - generation_start) * 1000)
                    _apply_timing_breakdown(benchmark_timings, stream_breakdown)
                    stream_session_dirs.append(result["stream_session_dir"])
                    metrics = dict(result.get("metrics") or {})
                else:
                    send_progress(60, "Generating audio...", request_id=request_id)
                    generation_start = time.perf_counter()
                    prepared_result, collection_breakdown = _collect_generation_result_with_timings(generator)
                    benchmark_timings["generation"] = int((time.perf_counter() - generation_start) * 1000)
                    _apply_timing_breakdown(benchmark_timings, collection_breakdown)
                    send_progress(90, "Saving audio...", request_id=request_id)
                    result, metrics, output_metadata, benchmark_timings["write_output"], finalize_breakdown = _finalize_generated_audio(
                        prepared_result,
                        final_path=final_path,
                        streaming_used=False,
                    )
                    _apply_timing_breakdown(benchmark_timings, finalize_breakdown)
            else:
                generation_start = time.perf_counter()
                generator = _build_clone_fallback_generator(
                    _current_model,
                    text=text,
                    temperature=temperature_value,
                    clean_ref_audio=clean_ref_audio,
                    resolved_ref_text=resolved_ref_text,
                    max_tokens=max_tokens,
                    stream=bool(stream and request_id is not None),
                    streaming_interval=streaming_interval,
                    **({"language": language} if language is not None else {}),
                )
                if stream and request_id is not None:
                    send_progress(55, "Streaming audio...", request_id=request_id)
                    result, benchmark_timings["write_output"], output_metadata, stream_breakdown = _stream_generator_to_output(
                        generator,
                        request_id=request_id,
                        final_path=final_path,
                    )
                    benchmark_timings["generation"] = int((time.perf_counter() - generation_start) * 1000)
                    _apply_timing_breakdown(benchmark_timings, stream_breakdown)
                    stream_session_dirs.append(result["stream_session_dir"])
                    metrics = dict(result.get("metrics") or {})
                else:
                    send_progress(60, "Generating audio...", request_id=request_id)
                    fallback_result, collection_breakdown = _collect_generation_result_with_timings(generator)
                    benchmark_timings["generation"] = int((time.perf_counter() - generation_start) * 1000)
                    _apply_timing_breakdown(benchmark_timings, collection_breakdown)
                    send_progress(90, "Saving audio...", request_id=request_id)
                    result, metrics, output_metadata, benchmark_timings["write_output"], finalize_breakdown = _finalize_generated_audio(
                        fallback_result,
                        final_path=final_path,
                        streaming_used=False,
                    )
                    _apply_timing_breakdown(benchmark_timings, finalize_breakdown)
        elif stream and request_id is not None:
            generator = _build_standard_generator(
                _current_model,
                text=text,
                temperature=temperature_value,
                max_tokens=max_tokens,
                language=language,
                voice=voice,
                instruct=instruct,
                stream=True,
                streaming_interval=streaming_interval,
            )
            send_progress(35, "Streaming audio...", request_id=request_id)
            generation_start = time.perf_counter()
            result, benchmark_timings["write_output"], output_metadata, stream_breakdown = _stream_generator_to_output(
                generator,
                request_id=request_id,
                final_path=final_path,
            )
            benchmark_timings["generation"] = int((time.perf_counter() - generation_start) * 1000)
            _apply_timing_breakdown(benchmark_timings, stream_breakdown)
            stream_session_dirs.append(result["stream_session_dir"])
            metrics = dict(result.get("metrics") or {})
            send_progress(85, "Saving audio...", request_id=request_id)
        else:
            generator = _build_standard_generator(
                _current_model,
                text=text,
                temperature=temperature_value,
                max_tokens=max_tokens,
                language=language,
                voice=voice,
                instruct=instruct,
            )
            generation_start = time.perf_counter()
            send_progress(45, "Generating audio...", request_id=request_id)
            collected_result, collection_breakdown = _collect_generation_result_with_timings(generator)
            benchmark_timings["generation"] = int((time.perf_counter() - generation_start) * 1000)
            _apply_timing_breakdown(benchmark_timings, collection_breakdown)
            send_progress(85, "Saving audio...", request_id=request_id)
            result, metrics, output_metadata, benchmark_timings["write_output"], finalize_breakdown = _finalize_generated_audio(
                collected_result,
                final_path=final_path,
                streaming_used=False,
            )
            _apply_timing_breakdown(benchmark_timings, finalize_breakdown)

        metrics = dict(metrics or {})
        metrics.setdefault("streaming_used", bool(stream and request_id is not None))
        metrics["prepared_clone_used"] = benchmark_flags["prepared_clone_used"]
        metrics["clone_cache_hit"] = benchmark_flags["clone_cache_hit"]
        result["metrics"] = metrics
        return result, benchmark_flags, benchmark_timings, output_metadata

    request_succeeded = False
    retried_after_allocation_failure = False

    try:
        try:
            result, benchmark_flags, benchmark_timings, output_metadata = generate_once()
        except Exception as error:
            if not _is_retryable_allocation_error(error):
                raise

            retried_after_allocation_failure = True
            cleanup_partial_outputs()
            _perform_memory_recovery()
            result, benchmark_flags, benchmark_timings, output_metadata = generate_once()

        request_succeeded = True
        benchmark_timings["total_backend"] = int((time.perf_counter() - overall_start) * 1000)
        benchmark_flags["allocation_retry_attempted"] = retried_after_allocation_failure
        benchmark_flags["allocation_retry_succeeded"] = retried_after_allocation_failure
        send_progress(100, "Done", request_id=request_id)

        if benchmark:
            result["benchmark"] = {
                **benchmark_flags,
                "output_duration_seconds": round(output_metadata["duration_seconds"], 4),
                "output_frames": output_metadata["frames"],
                "timings_ms": benchmark_timings,
            }
        return result

    finally:
        if _should_clear_cache_after_request(request_succeeded):
            _clear_mlx_cache()


def handle_generate_clone_batch(params, request_id=None):
    """Generate multiple clone clips that share one reference voice."""
    if _current_model is None:
        raise RuntimeError("No model loaded. Call load_model first.")

    _ensure_mlx()

    model_id = params.get("model_id")
    if model_id and _current_model_id != model_id:
        _load_model_request(model_id=model_id, benchmark=False, request_id=None)

    current_model_contract = _current_model_contract()
    if current_model_contract and current_model_contract["mode"] != "clone":
        raise ValueError(
            f"generate_clone_batch requires a clone model, but '{current_model_contract['id']}' is {current_model_contract['mode']}"
        )

    raw_texts = params.get("texts") or []
    if not isinstance(raw_texts, list) or not raw_texts:
        raise ValueError("Missing required param: texts")

    texts = [str(item).strip() for item in raw_texts]
    if any(not text for text in texts):
        raise ValueError("Clone batch generation requires every text item to be non-empty")

    raw_output_paths = params.get("output_paths") or []
    if not isinstance(raw_output_paths, list) or len(raw_output_paths) != len(texts):
        raise ValueError("output_paths must be a list matching texts")

    ref_audio = params.get("ref_audio")
    ref_text = params.get("ref_text")
    if not ref_audio:
        raise ValueError("generate_clone_batch requires ref_audio")

    language = _normalize_request_language(params.get("language"))
    temperature_value = float(params.get("temperature", 0.6))
    max_tokens = params.get("max_tokens")
    effective_max_tokens = int(max_tokens) if max_tokens is not None else 4096
    requested_stream = bool(params.get("stream", False))

    final_paths = [
        _resolve_final_output_path(path, text, mode="clone", ref_audio=ref_audio)
        for text, path in zip(texts, raw_output_paths)
    ]

    def cleanup_partial_outputs():
        for path in final_paths:
            if path and os.path.exists(path):
                try:
                    os.remove(path)
                except OSError:
                    pass

    def generate_once():
        _maybe_send_progress(10, "Normalizing reference...", request_id=request_id)
        clean_ref_audio = _normalize_clone_reference(ref_audio)
        if not clean_ref_audio:
            raise RuntimeError("Could not process reference audio file")

        resolved_ref_text = _resolve_clone_transcript(clean_ref_audio, ref_text)
        _maybe_send_progress(30, "Preparing voice context...", request_id=request_id)
        prepared_context, clone_cache_hit = _get_or_prepare_clone_context(
            clean_ref_audio,
            resolved_ref_text,
        )
        can_use_prepared = (
            prepared_context is not None and _generate_prepared_icl_fn is not None
        )
        can_use_batch_fast_path = len(texts) > 1 and _can_use_shared_reference_clone_batch_fast_path(
            _current_model,
            can_use_prepared=can_use_prepared,
            requested_stream=requested_stream,
        )

        if can_use_batch_fast_path:
            _maybe_send_progress(60, "Generating audio batch...", request_id=request_id)
            collected_results, _ = _collect_batch_generation_results_with_timings(
                _batch_generate_prepared_icl_fn(
                    _current_model,
                    texts,
                    prepared_context,
                    **_with_optional_kwarg(
                        {
                            "temperature": temperature_value,
                            "max_tokens": effective_max_tokens,
                            "stream": False,
                        },
                        "language",
                        language,
                    ),
                ),
                len(texts),
            )
        else:
            collected_results = []
            total = len(texts)
            for index, text in enumerate(texts):
                percent = 45 + int((index / max(total, 1)) * 30)
                _maybe_send_progress(
                    percent,
                    f"Generating item {index + 1}/{total}...",
                    request_id=request_id,
                )
                if can_use_prepared:
                    generator = _generate_prepared_icl_fn(
                        _current_model,
                        text,
                        prepared_context,
                        **_with_optional_kwarg(
                            {
                                "temperature": temperature_value,
                                "max_tokens": effective_max_tokens,
                                "stream": False,
                            },
                            "language",
                            language,
                        ),
                    )
                else:
                    generator = _build_clone_fallback_generator(
                        _current_model,
                        text=text,
                        temperature=temperature_value,
                        clean_ref_audio=clean_ref_audio,
                        resolved_ref_text=resolved_ref_text,
                        max_tokens=effective_max_tokens,
                        stream=False,
                        **({"language": language} if language is not None else {}),
                    )
                item_result, _ = _collect_generation_result_with_timings(generator)
                collected_results.append(item_result)

        responses = []
        total = len(collected_results)
        for index, (result, final_path) in enumerate(zip(collected_results, final_paths)):
            percent = 80 + int((index / max(total, 1)) * 15)
            _maybe_send_progress(
                percent,
                f"Saving item {index + 1}/{total}...",
                request_id=request_id,
            )
            response_item, metrics, _, _, _ = _finalize_generated_audio(
                result,
                final_path=final_path,
                streaming_used=False,
            )
            metrics = dict(metrics or {})
            metrics["prepared_clone_used"] = can_use_prepared
            metrics["clone_cache_hit"] = clone_cache_hit
            metrics["batch_generation_used"] = can_use_batch_fast_path
            response_item["metrics"] = metrics
            responses.append(response_item)

        return responses

    request_succeeded = False

    try:
        try:
            results = generate_once()
        except Exception as error:
            if not _is_retryable_allocation_error(error):
                raise
            cleanup_partial_outputs()
            _perform_memory_recovery()
            results = generate_once()

        request_succeeded = True
        _maybe_send_progress(100, "Done", request_id=request_id)
        return results
    finally:
        if _should_clear_cache_after_request(request_succeeded):
            _clear_mlx_cache()


def handle_convert_audio(params):
    """Convert audio file to 24kHz mono WAV."""
    input_path = params.get("input_path")
    if not input_path:
        raise ValueError("Missing required param: input_path")

    output_path = params.get("output_path")
    wav_path = convert_audio_if_needed(input_path)

    if output_path and wav_path and wav_path != input_path:
        parent = os.path.dirname(output_path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        try:
            shutil.move(wav_path, output_path)
        except Exception:
            try:
                os.remove(wav_path)
            except OSError:
                pass
            raise
        wav_path = output_path

    return {"wav_path": wav_path}


def handle_list_voices(params):
    """List enrolled voices in the voices directory."""
    if not os.path.exists(VOICES_DIR):
        return []

    voices = []
    for f in sorted(os.listdir(VOICES_DIR)):
        if f.endswith(".wav"):
            name = f[:-4]
            txt_path = os.path.join(VOICES_DIR, f"{name}.txt")
            voices.append({
                "name": name,
                "has_transcript": os.path.exists(txt_path),
                "wav_path": os.path.join(VOICES_DIR, f),
            })

    return voices


def handle_enroll_voice(params):
    """Enroll a new voice by copying audio and optional transcript."""
    name = params.get("name")
    audio_path = params.get("audio_path")

    if not name or not audio_path:
        raise ValueError("Missing required params: name, audio_path")

    safe_name = re.sub(r"[^\w\s-]", "", name).strip().replace(" ", "_")
    if not safe_name:
        raise ValueError("Invalid voice name")

    os.makedirs(VOICES_DIR, exist_ok=True)

    # Convert to WAV if needed
    clean_wav = _normalize_clone_reference(audio_path)
    if not clean_wav:
        raise RuntimeError("Could not process audio file")

    target_wav = os.path.join(VOICES_DIR, f"{safe_name}.wav")
    target_txt = os.path.join(VOICES_DIR, f"{safe_name}.txt")

    if os.path.exists(target_wav) or os.path.exists(target_txt):
        raise ValueError(
            f'A saved voice named "{safe_name}" already exists. Choose a different name.'
        )

    shutil.copy(clean_wav, target_wav)

    transcript = params.get("transcript", "")
    if transcript:
        with open(target_txt, "w", encoding="utf-8") as f:
            f.write(transcript)

    return {"success": True, "name": safe_name, "wav_path": target_wav}


def handle_delete_voice(params):
    """Delete an enrolled voice."""
    name = params.get("name")
    if not name:
        raise ValueError("Missing required param: name")

    safe_name = re.sub(r"[^\w\s-]", "", name).strip().replace(" ", "_")
    if not safe_name:
        raise ValueError("Invalid voice name")

    wav_path = os.path.join(VOICES_DIR, f"{safe_name}.wav")
    txt_path = os.path.join(VOICES_DIR, f"{safe_name}.txt")

    deleted = False
    if os.path.exists(wav_path):
        os.remove(wav_path)
        deleted = True
    if os.path.exists(txt_path):
        os.remove(txt_path)

    return {"success": deleted}


def handle_get_model_info(params):
    """Get information about available models and their download status."""
    models_info = []
    for model_id, model_def in MODELS.items():
        path = get_smart_path(model_def["folder"])
        size_bytes = 0
        if path:
            for root, dirs, files in os.walk(path):
                for f in files:
                    size_bytes += os.path.getsize(os.path.join(root, f))

        models_info.append({
            "id": model_id,
            "name": model_def["name"],
            "folder": model_def["folder"],
            "mode": model_def["mode"],
            "tier": model_def["tier"],
            "output_subfolder": model_def["outputSubfolder"],
            "hugging_face_repo": model_def["huggingFaceRepo"],
            "required_relative_paths": model_def["requiredRelativePaths"],
            "downloaded": path is not None,
            "size_bytes": size_bytes,
            **_resolved_model_capabilities(model_def),
        })

    return models_info


def handle_get_speakers(params):
    """Return the speaker map."""
    return SPEAKER_MAP


# ---------------------------------------------------------------------------
# Method dispatch table
# ---------------------------------------------------------------------------

METHODS = {
    "ping": handle_ping,
    "init": handle_init,
    "load_model": handle_load_model,
    "prewarm_model": handle_prewarm_model,
    "prepare_clone_reference": handle_prepare_clone_reference,
    "prime_clone_reference": handle_prime_clone_reference,
    "unload_model": handle_unload_model,
    "generate": handle_generate,
    "generate_clone_batch": handle_generate_clone_batch,
    "convert_audio": handle_convert_audio,
    "list_voices": handle_list_voices,
    "enroll_voice": handle_enroll_voice,
    "delete_voice": handle_delete_voice,
    "get_model_info": handle_get_model_info,
    "get_speakers": handle_get_speakers,
}


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------


def process_request(line):
    """Parse and dispatch a single JSON-RPC request."""
    try:
        req = json.loads(line)
    except json.JSONDecodeError as e:
        send_error(None, -32700, f"Parse error: {e}")
        return

    req_id = req.get("id")
    method = req.get("method")
    params = req.get("params", {})

    if method not in METHODS:
        send_error(req_id, -32601, f"Method not found: {method}")
        return

    try:
        if method in {"generate", "generate_clone_batch", "load_model", "prewarm_model", "prepare_clone_reference", "prime_clone_reference"}:
            result = METHODS[method](params, request_id=req_id)
        else:
            result = METHODS[method](params)
        send_response(req_id, result)
    except Exception as e:
        tb = traceback.format_exc()
        print(tb, file=_original_stderr)
        send_error(req_id, -32000, str(e))


def main():
    """Read JSON-RPC requests from stdin, one per line."""
    # Signal readiness
    send_notification("ready", {"version": "1.0.0"})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        process_request(line)


if __name__ == "__main__":
    main()
