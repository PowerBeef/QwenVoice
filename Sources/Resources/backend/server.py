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
import math
import hashlib
import subprocess
import warnings
import traceback
import uuid
from importlib import metadata as importlib_metadata
from collections import OrderedDict
from datetime import datetime

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
CLONE_CONTEXT_CACHE_CAPACITY = 8
DEFAULT_STREAMING_INTERVAL = 2.0
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
_enable_speech_tokenizer_encoder_fn = None
_clone_context_cache = OrderedDict()
_mlx_audio_version = None


def _ensure_mlx():
    """Lazy-import mlx_audio so we only load it when needed."""
    global _load_model_fn, _generate_audio_fn, _audio_write_fn
    global _mx, _np, _can_prepare_icl_fn, _prepare_icl_context_fn, _generate_prepared_icl_fn
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
                generate_with_prepared_icl,
                prepare_icl_context,
                try_enable_speech_tokenizer_encoder,
            )
        except ImportError:
            try:
                from mlx_audio.qwenvoice_speed_patch import (
                    can_prepare_icl,
                    generate_with_prepared_icl,
                    prepare_icl_context,
                    try_enable_speech_tokenizer_encoder,
                )
            except ImportError:
                can_prepare_icl = None
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


def _apply_speed_transform(wav_path, speed):
    """Apply a simple ffmpeg atempo transform in-place."""
    if speed is None:
        return wav_path

    target_speed = float(speed)
    if math.isclose(target_speed, 1.0, rel_tol=1e-3, abs_tol=1e-3):
        return wav_path
    if target_speed <= 0:
        raise RuntimeError("Requested speed must be greater than zero.")

    temp_output = f"{wav_path}.speed.tmp.wav"
    cmd = [
        _resolve_ffmpeg_binary(),
        "-y",
        "-v",
        "error",
        "-i",
        wav_path,
        "-filter:a",
        f"atempo={target_speed}",
        "-ar",
        str(SAMPLE_RATE),
        "-ac",
        "1",
        "-c:a",
        "pcm_s16le",
        temp_output,
    ]

    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        os.replace(temp_output, wav_path)
    except (subprocess.CalledProcessError, FileNotFoundError) as error:
        try:
            if os.path.exists(temp_output):
                os.remove(temp_output)
        except OSError:
            pass
        raise RuntimeError("Could not apply the requested speed adjustment.") from error

    return wav_path


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

    if len(entries) <= NORMALIZED_CLONE_REF_CACHE_LIMIT:
        return

    remaining = []
    for name in os.listdir(CLONE_REF_CACHE_DIR):
        if not name.endswith(".wav"):
            continue
        path = os.path.join(CLONE_REF_CACHE_DIR, name)
        try:
            stat_result = os.stat(path)
        except OSError:
            continue
        remaining.append((path, stat_result.st_mtime))

    remaining.sort(key=lambda item: item[1], reverse=True)
    for path, _ in remaining[NORMALIZED_CLONE_REF_CACHE_LIMIT:]:
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


def _write_audio_file(output_path, audio, sample_rate):
    """Write an audio buffer to a WAV file."""
    parent_dir = os.path.dirname(output_path)
    if parent_dir:
        os.makedirs(parent_dir, exist_ok=True)
    _audio_write_fn(output_path, _np.array(audio), sample_rate, format="wav")


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
    chunk_arrays = []
    chunk_index = 0
    cumulative_duration = 0.0
    first_chunk_ms = None
    total_token_count = 0
    peak_memory_usage = 0.0
    last_chunk = None

    for chunk in generator:
        chunk_path = os.path.join(session_dir, f"chunk_{chunk_index:03d}.wav")
        _write_audio_file(chunk_path, chunk.audio, chunk.sample_rate)

        audio_array = _np.array(chunk.audio)
        chunk_arrays.append(audio_array)
        chunk_duration_seconds = (
            float(chunk.samples) / float(chunk.sample_rate)
            if getattr(chunk, "samples", 0) and getattr(chunk, "sample_rate", 0)
            else 0.0
        )
        cumulative_duration += chunk_duration_seconds
        total_token_count += int(getattr(chunk, "token_count", 0) or 0)
        peak_memory_usage = max(
            peak_memory_usage,
            float(getattr(chunk, "peak_memory_usage", 0.0) or 0.0),
        )

        if first_chunk_ms is None:
            first_chunk_ms = int((time.perf_counter() - stream_start) * 1000)

        send_generation_chunk(
            request_id=request_id,
            chunk_index=chunk_index,
            chunk_path=chunk_path,
            is_final=bool(getattr(chunk, "is_final_chunk", False)),
            chunk_duration_seconds=chunk_duration_seconds,
            cumulative_duration_seconds=cumulative_duration,
            stream_session_dir=session_dir,
        )
        last_chunk = chunk
        chunk_index += 1

    if not chunk_arrays:
        raise RuntimeError("Generation produced no audio file")

    full_audio = chunk_arrays[0] if len(chunk_arrays) == 1 else _np.concatenate(chunk_arrays, axis=0)
    _audio_write_fn(final_path, full_audio, _current_model.sample_rate, format="wav")
    write_output_ms = int((time.perf_counter() - write_start) * 1000)

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
        get_audio_metadata(final_path),
    )


def handle_load_model(params, request_id=None):
    """Load a model into memory. Unloads any existing model first."""
    global _current_model, _current_model_path, _current_model_id

    model_id = params.get("model_id")
    model_path = params.get("model_path")
    benchmark = bool(params.get("benchmark", False))
    load_start = time.perf_counter()

    # Resolve model path from model_id if not given directly
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

    # Skip reload if same model already loaded
    if _current_model is not None and _current_model_path == model_path:
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
        return result

    # Unload existing model
    if _current_model is not None:
        _discard_loaded_model()

    _ensure_mlx()
    send_progress(5, "Preparing model...", request_id=request_id)
    send_progress(25, "Loading model...", request_id=request_id)

    _current_model = _load_model_fn(model_path)
    if _enable_speech_tokenizer_encoder_fn is not None:
        _enable_speech_tokenizer_encoder_fn(_current_model, model_path)
    _current_model_path = model_path
    _current_model_id = resolved_model_id

    send_progress(100, "Model ready", request_id=request_id)

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
    voice = params.get("voice")
    instruct = params.get("instruct")
    speed = params.get("speed")
    ref_audio = params.get("ref_audio")
    ref_text = params.get("ref_text")
    temperature = params.get("temperature", 0.6)
    max_tokens = params.get("max_tokens")
    temperature_value = float(temperature)
    stream = bool(params.get("stream", False))
    streaming_interval = float(params.get("streaming_interval", DEFAULT_STREAMING_INTERVAL))
    benchmark = bool(params.get("benchmark", False))
    benchmark_label = params.get("benchmark_label")
    benchmark_mode = _resolve_generation_mode(requested_mode, voice=voice, ref_audio=ref_audio)
    current_model_contract = _current_model_contract()
    requested_speed_value = float(speed) if speed is not None else None

    if requested_mode and requested_mode not in MODELS_BY_MODE:
        raise ValueError(f"Unknown generation mode: {requested_mode}")

    if requested_mode and current_model_contract and current_model_contract["mode"] != requested_mode:
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

            if prepared_context is not None and not instruct:
                benchmark_flags["prepared_clone_used"] = True
                if effective_max_tokens is None:
                    effective_max_tokens = 4096
                    benchmark_flags["request_max_tokens"] = effective_max_tokens
                if stream and request_id is not None:
                    send_progress(55, "Streaming audio...", request_id=request_id)
                    generation_start = time.perf_counter()
                    result, benchmark_timings["write_output"], output_metadata = _consume_streaming_generator(
                        _generate_prepared_icl_fn(
                            _current_model,
                            text,
                            prepared_context,
                            temperature=temperature_value,
                            max_tokens=effective_max_tokens,
                            stream=True,
                            streaming_interval=streaming_interval,
                        ),
                        request_id=request_id,
                        final_path=final_path,
                    )
                    benchmark_timings["generation"] = int((time.perf_counter() - generation_start) * 1000)
                    stream_session_dirs.append(result["stream_session_dir"])
                    metrics = dict(result.get("metrics") or {})
                else:
                    send_progress(60, "Generating audio...", request_id=request_id)
                    generation_start = time.perf_counter()
                    prepared_results = list(
                        _generate_prepared_icl_fn(
                            _current_model,
                            text,
                            prepared_context,
                            temperature=temperature_value,
                            max_tokens=effective_max_tokens,
                        )
                    )
                    benchmark_timings["generation"] = int((time.perf_counter() - generation_start) * 1000)
                    if not prepared_results:
                        raise RuntimeError("Generation produced no audio file")
                    send_progress(90, "Saving audio...", request_id=request_id)
                    write_start = time.perf_counter()
                    prepared_result = prepared_results[0]
                    _write_audio_file(
                        final_path,
                        prepared_result.audio,
                        prepared_result.sample_rate,
                    )
                    benchmark_timings["write_output"] = int((time.perf_counter() - write_start) * 1000)
                    output_metadata = get_audio_metadata(final_path)
                    metrics = _metrics_from_generation_result(prepared_result, streaming_used=False)
                    result = {
                        "audio_path": final_path,
                        "duration_seconds": round(output_metadata["duration_seconds"], 2),
                    }
            else:
                generation_start = time.perf_counter()
                fallback_kwargs = {
                    "text": text,
                    "temperature": temperature_value,
                    "verbose": False,
                }
                if max_tokens is not None:
                    fallback_kwargs["max_tokens"] = int(max_tokens)
                fallback_kwargs["ref_audio"] = clean_ref_audio
                if resolved_ref_text:
                    fallback_kwargs["ref_text"] = resolved_ref_text
                if instruct:
                    fallback_kwargs["instruct"] = instruct

                if stream and request_id is not None:
                    fallback_kwargs["stream"] = True
                    fallback_kwargs["streaming_interval"] = streaming_interval
                    send_progress(55, "Streaming audio...", request_id=request_id)
                    result, benchmark_timings["write_output"], output_metadata = _consume_streaming_generator(
                        _current_model.generate(**fallback_kwargs),
                        request_id=request_id,
                        final_path=final_path,
                    )
                    benchmark_timings["generation"] = int((time.perf_counter() - generation_start) * 1000)
                    stream_session_dirs.append(result["stream_session_dir"])
                    metrics = dict(result.get("metrics") or {})
                else:
                    send_progress(60, "Generating audio...", request_id=request_id)
                    fallback_results = list(_current_model.generate(**fallback_kwargs))
                    benchmark_timings["generation"] = int((time.perf_counter() - generation_start) * 1000)
                    if not fallback_results:
                        raise RuntimeError("Generation produced no audio file")
                    send_progress(90, "Saving audio...", request_id=request_id)
                    write_start = time.perf_counter()
                    fallback_result = fallback_results[0]
                    _write_audio_file(
                        final_path,
                        fallback_result.audio,
                        fallback_result.sample_rate,
                    )
                    benchmark_timings["write_output"] = int((time.perf_counter() - write_start) * 1000)
                    output_metadata = get_audio_metadata(final_path)
                    metrics = _metrics_from_generation_result(fallback_result, streaming_used=False)
                    result = {
                        "audio_path": final_path,
                        "duration_seconds": round(output_metadata["duration_seconds"], 2),
                    }
        elif stream and request_id is not None:
            stream_kwargs = {
                "text": text,
                "temperature": temperature_value,
                "verbose": False,
                "stream": True,
                "streaming_interval": streaming_interval,
            }
            if max_tokens is not None:
                stream_kwargs["max_tokens"] = int(max_tokens)
            if voice:
                stream_kwargs["voice"] = voice
            if instruct:
                stream_kwargs["instruct"] = instruct
            if speed is not None and voice:
                stream_kwargs["speed"] = float(speed)

            send_progress(35, "Streaming audio...", request_id=request_id)
            generation_start = time.perf_counter()
            result, benchmark_timings["write_output"], output_metadata = _consume_streaming_generator(
                _current_model.generate(**stream_kwargs),
                request_id=request_id,
                final_path=final_path,
            )
            benchmark_timings["generation"] = int((time.perf_counter() - generation_start) * 1000)
            stream_session_dirs.append(result["stream_session_dir"])
            metrics = dict(result.get("metrics") or {})
            send_progress(85, "Saving audio...", request_id=request_id)
        else:
            gen_kwargs = {
                "model": _current_model,
                "text": text,
                "output_path": target_dir,
                "file_prefix": target_stem,
                "verbose": False,
                "temperature": temperature_value,
            }
            if max_tokens is not None:
                gen_kwargs["max_tokens"] = int(max_tokens)
            if voice:
                gen_kwargs["voice"] = voice
                if instruct:
                    gen_kwargs["instruct"] = instruct
                if speed is not None:
                    gen_kwargs["speed"] = float(speed)
            elif instruct:
                gen_kwargs["instruct"] = instruct

            generation_start = time.perf_counter()
            send_progress(45, "Generating audio...", request_id=request_id)
            _generate_audio_fn(**gen_kwargs)
            benchmark_timings["generation"] = int((time.perf_counter() - generation_start) * 1000)
            send_progress(85, "Saving audio...", request_id=request_id)

            write_start = time.perf_counter()
            if not os.path.exists(generated_path):
                raise RuntimeError("Generation produced no audio file")
            if generated_path != final_path:
                os.replace(generated_path, final_path)
            benchmark_timings["write_output"] = int((time.perf_counter() - write_start) * 1000)
            output_metadata = get_audio_metadata(final_path)
            metrics = {
                "processing_time_seconds": round(benchmark_timings["generation"] / 1000.0, 4),
                "streaming_used": False,
            }
            result = {
                "audio_path": final_path,
                "duration_seconds": round(output_metadata["duration_seconds"], 2),
            }

        if (
            benchmark_mode in {"design", "clone"}
            and requested_speed_value is not None
            and not math.isclose(requested_speed_value, 1.0, rel_tol=1e-3, abs_tol=1e-3)
        ):
            send_progress(92, "Applying speed...", request_id=request_id)
            _apply_speed_transform(final_path, requested_speed_value)
            output_metadata = get_audio_metadata(final_path)
            result["duration_seconds"] = round(output_metadata["duration_seconds"], 2)

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


def handle_convert_audio(params):
    """Convert audio file to 24kHz mono WAV."""
    input_path = params.get("input_path")
    if not input_path:
        raise ValueError("Missing required param: input_path")

    output_path = params.get("output_path")
    wav_path = convert_audio_if_needed(input_path)

    if output_path and wav_path and wav_path != input_path:
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        shutil.move(wav_path, output_path)
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
    "unload_model": handle_unload_model,
    "generate": handle_generate,
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
        if method in {"generate", "load_model"}:
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
