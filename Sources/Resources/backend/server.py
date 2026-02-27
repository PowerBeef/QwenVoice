#!/usr/bin/env python3
"""
Qwen Voice — Python JSON-RPC backend.

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
import subprocess
import warnings
import traceback
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

SAMPLE_RATE = 24000
FILENAME_MAX_LEN = 20

# Default paths — overridable via init params
APP_SUPPORT_DIR = os.path.expanduser("~/Library/Application Support/QwenVoice")
MODELS_DIR = os.path.join(APP_SUPPORT_DIR, "models")
OUTPUTS_DIR = os.path.join(APP_SUPPORT_DIR, "outputs")
VOICES_DIR = os.path.join(APP_SUPPORT_DIR, "voices")

# Model definitions (mirrors main.py MODELS dict)
MODELS = {
    # Pro (1.7B)
    "pro_custom": {
        "name": "Custom Voice (Pro)",
        "folder": "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
        "mode": "custom",
        "tier": "pro",
        "output_subfolder": "CustomVoice",
    },
    "pro_design": {
        "name": "Voice Design (Pro)",
        "folder": "Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit",
        "mode": "design",
        "tier": "pro",
        "output_subfolder": "VoiceDesign",
    },
    "pro_clone": {
        "name": "Voice Cloning (Pro)",
        "folder": "Qwen3-TTS-12Hz-1.7B-Base-8bit",
        "mode": "clone",
        "tier": "pro",
        "output_subfolder": "Clones",
    },
}

SPEAKER_MAP = {
    "English": ["ryan", "aiden", "serena", "vivian"],
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

_current_model = None
_current_model_path = None
_load_model_fn = None
_generate_audio_fn = None
_mx = None


def _ensure_mlx():
    """Lazy-import mlx_audio so we only load it when needed."""
    global _load_model_fn, _generate_audio_fn, _mx
    if _load_model_fn is None:
        from mlx_audio.tts.utils import load_model
        from mlx_audio.tts.generate import generate_audio
        import mlx.core as mx

        _load_model_fn = load_model
        _generate_audio_fn = generate_audio
        _mx = mx


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


def convert_audio_if_needed(input_path):
    """Convert audio to 24kHz mono WAV if needed. Returns path to WAV file."""
    if not os.path.exists(input_path):
        return None

    ext = os.path.splitext(input_path)[1].lower()

    if ext == ".wav":
        try:
            with wave.open(input_path, "rb") as f:
                if f.getnchannels() > 0:
                    return input_path
        except wave.Error:
            pass

    temp_wav = os.path.join(OUTPUTS_DIR, f"temp_convert_{int(time.time())}.wav")
    os.makedirs(os.path.dirname(temp_wav), exist_ok=True)

    cmd = [
        "ffmpeg", "-y", "-v", "error", "-i", input_path,
        "-ar", str(SAMPLE_RATE), "-ac", "1", "-c:a", "pcm_s16le", temp_wav,
    ]

    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        return temp_wav
    except (subprocess.CalledProcessError, FileNotFoundError):
        raise RuntimeError("Could not convert audio. Is ffmpeg installed?")


def make_output_path(subfolder, text_snippet):
    """Generate an output file path with timestamp and text snippet."""
    save_dir = os.path.join(OUTPUTS_DIR, subfolder)
    os.makedirs(save_dir, exist_ok=True)

    timestamp = datetime.now().strftime("%H-%M-%S-%f")
    clean_text = (
        re.sub(r"[^\w\s-]", "", text_snippet)[:FILENAME_MAX_LEN].strip().replace(" ", "_")
        or "audio"
    )
    filename = f"{timestamp}_{clean_text}.wav"
    return os.path.join(save_dir, filename)


def get_audio_duration(wav_path):
    """Get duration in seconds of a WAV file."""
    try:
        with wave.open(wav_path, "rb") as f:
            frames = f.getnframes()
            rate = f.getframerate()
            return frames / float(rate) if rate > 0 else 0.0
    except Exception:
        return 0.0


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


def send_progress(percent, message):
    """Send a progress notification to the frontend."""
    send_notification("progress", {"percent": percent, "message": message})


# ---------------------------------------------------------------------------
# RPC method handlers
# ---------------------------------------------------------------------------


def handle_ping(params):
    return {"status": "ok"}


def handle_init(params):
    """Initialize paths. Called once at startup."""
    global MODELS_DIR, OUTPUTS_DIR, VOICES_DIR, APP_SUPPORT_DIR

    if "app_support_dir" in params:
        APP_SUPPORT_DIR = params["app_support_dir"]
        MODELS_DIR = os.path.join(APP_SUPPORT_DIR, "models")
        OUTPUTS_DIR = os.path.join(APP_SUPPORT_DIR, "outputs")
        VOICES_DIR = os.path.join(APP_SUPPORT_DIR, "voices")

    os.makedirs(MODELS_DIR, exist_ok=True)
    os.makedirs(OUTPUTS_DIR, exist_ok=True)
    os.makedirs(VOICES_DIR, exist_ok=True)

    return {"status": "ok", "models_dir": MODELS_DIR, "outputs_dir": OUTPUTS_DIR}


def handle_load_model(params):
    """Load a model into memory. Unloads any existing model first."""
    global _current_model, _current_model_path

    model_id = params.get("model_id")
    model_path = params.get("model_path")

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

    # Skip reload if same model already loaded
    if _current_model is not None and _current_model_path == model_path:
        return {"success": True, "model_path": model_path, "cached": True}

    # Unload existing model
    if _current_model is not None:
        _current_model = None
        gc.collect()

    _ensure_mlx()
    send_progress(10, "Loading model...")

    _current_model = _load_model_fn(model_path)
    _current_model_path = model_path

    send_progress(100, "Model loaded")

    return {
        "success": True,
        "model_path": model_path,
    }


def handle_unload_model(params):
    """Unload current model and free memory."""
    global _current_model, _current_model_path

    _current_model = None
    _current_model_path = None
    gc.collect()

    return {"success": True}


def handle_generate(params):
    """Generate audio from text. Requires a model to be loaded."""
    global _current_model

    if _current_model is None:
        raise RuntimeError("No model loaded. Call load_model first.")

    _ensure_mlx()

    text = (params.get("text") or "").strip()
    if not text:
        raise ValueError("Missing required param: text")

    output_path = params.get("output_path")
    voice = params.get("voice")
    instruct = params.get("instruct")
    speed = params.get("speed")
    ref_audio = params.get("ref_audio")
    ref_text = params.get("ref_text")
    temperature = params.get("temperature", 0.6)
    max_tokens = params.get("max_tokens")

    # Create temp dir for generation
    temp_dir = os.path.join(OUTPUTS_DIR, f"temp_{int(time.time())}_{os.getpid()}")
    os.makedirs(temp_dir, exist_ok=True)

    send_progress(20, "Generating audio...")

    try:
        # Build generation kwargs based on mode
        gen_kwargs = {
            "model": _current_model,
            "text": text,
            "output_path": temp_dir,
            "verbose": False,
            "temperature": float(temperature),
        }
        if max_tokens is not None:
            gen_kwargs["max_tokens"] = int(max_tokens)

        if ref_audio:
            # Voice cloning mode
            gen_kwargs["ref_audio"] = ref_audio
            if ref_text:
                gen_kwargs["ref_text"] = ref_text
        elif voice:
            # Custom voice mode
            gen_kwargs["voice"] = voice
            if instruct:
                gen_kwargs["instruct"] = instruct
            if speed is not None:
                gen_kwargs["speed"] = float(speed)
        elif instruct:
            # Voice design mode (instruct only, no voice)
            gen_kwargs["instruct"] = instruct

        _generate_audio_fn(**gen_kwargs)

        send_progress(80, "Saving audio...")

        # Move generated file to output location
        source_file = os.path.join(temp_dir, "audio_000.wav")
        if not os.path.exists(source_file):
            raise RuntimeError("Generation produced no audio file")

        if output_path:
            # Ensure parent dir exists
            parent_dir = os.path.dirname(output_path)
            if parent_dir:
                os.makedirs(parent_dir, exist_ok=True)
            shutil.move(source_file, output_path)
            final_path = output_path
        else:
            # Auto-generate output path
            subfolder = "CustomVoice"
            if ref_audio:
                subfolder = "Clones"
            elif not voice:
                subfolder = "VoiceDesign"
            final_path = make_output_path(subfolder, text)
            shutil.move(source_file, final_path)

        duration = get_audio_duration(final_path)

        send_progress(100, "Done")

        return {
            "audio_path": final_path,
            "duration_seconds": round(duration, 2),
        }

    finally:
        # Free MLX GPU memory pool between generations
        if _mx is not None:
            _mx.metal.clear_cache()
        # Clean up temp dir
        if os.path.exists(temp_dir):
            shutil.rmtree(temp_dir, ignore_errors=True)


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
    clean_wav = convert_audio_if_needed(audio_path)
    if not clean_wav:
        raise RuntimeError("Could not process audio file")

    target_wav = os.path.join(VOICES_DIR, f"{safe_name}.wav")
    target_txt = os.path.join(VOICES_DIR, f"{safe_name}.txt")

    shutil.copy(clean_wav, target_wav)

    transcript = params.get("transcript", "")
    if transcript:
        with open(target_txt, "w", encoding="utf-8") as f:
            f.write(transcript)

    # Clean up temp conversion file
    if clean_wav != audio_path and os.path.exists(clean_wav):
        os.remove(clean_wav)

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
            "downloaded": path is not None,
            "size_bytes": size_bytes,
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
