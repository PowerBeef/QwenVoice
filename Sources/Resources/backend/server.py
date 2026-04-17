#!/usr/bin/env python3
"""
QwenVoice — Python JSON-RPC backend.

Reads JSON-RPC 2.0 requests from stdin, dispatches to handlers,
writes JSON-RPC responses to stdout. One model in memory at a time.
"""

import json
import os
import sys
import warnings

BACKEND_DIR = os.path.dirname(os.path.realpath(__file__))
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

from audio_io import AudioIOManager
from backend_state import BackendState
from clone_context import CloneContextManager
from generation_pipeline import GenerationPipeline
from output_paths import OutputPathResolver
from rpc_handlers import BackendRPCHandlers
from rpc_transport import JSONRPCTransport

os.environ["TOKENIZERS_PARALLELISM"] = "false"
warnings.filterwarnings("ignore", category=UserWarning)
warnings.filterwarnings("ignore", category=FutureWarning)

_original_stderr = sys.stderr


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


def _env_flag(name, default=False):
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw not in {"0", "false", "False"}


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
    "clone_prime": {
        "text": "Voice warmup.",
        "max_tokens": 48,
        "run_generation": True,
    },
}
NORMALIZED_CLONE_REF_CACHE_LIMIT = 32
NORMALIZED_CLONE_REF_MAX_AGE_SECONDS = 30 * 24 * 60 * 60
EXPERIMENTAL_CLONE_REF_TRIM = _env_flag(
    "QWENVOICE_EXPERIMENTAL_CLONE_REF_TRIM", default=False
)


def _resolve_resources_dir():
    script_dir = os.path.dirname(os.path.realpath(__file__))
    for candidate in (script_dir, os.path.dirname(script_dir)):
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
        raise RuntimeError(
            "qwenvoice_contract.json must define at least one speaker group"
        )

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
        raise RuntimeError(
            "qwenvoice_contract.json defaultSpeaker is not present in speakers"
        )

    return contract


CONTRACT = _load_contract()
MODELS = {model["id"]: model for model in CONTRACT["models"]}
MODELS_BY_MODE = {model["mode"]: model for model in CONTRACT["models"]}
SPEAKER_MAP = CONTRACT["speakers"]
DEFAULT_SPEAKER = CONTRACT["defaultSpeaker"]

STATE = BackendState()
TRANSPORT = JSONRPCTransport(stdout=sys.stdout, original_stderr=_original_stderr)
OUTPUT_PATHS = OutputPathResolver(
    STATE, MODELS, MODELS_BY_MODE, filename_max_len=FILENAME_MAX_LEN
)
AUDIO_IO = AudioIOManager(STATE, RESOURCES_DIR, sample_rate=SAMPLE_RATE)
CLONE_CONTEXT = CloneContextManager(
    STATE,
    AUDIO_IO,
    clone_context_cache_capacity=CLONE_CONTEXT_CACHE_CAPACITY,
    normalized_clone_ref_cache_limit=NORMALIZED_CLONE_REF_CACHE_LIMIT,
    normalized_clone_ref_max_age_seconds=NORMALIZED_CLONE_REF_MAX_AGE_SECONDS,
    experimental_trim_enabled=EXPERIMENTAL_CLONE_REF_TRIM,
)
GENERATION_PIPELINE = GenerationPipeline(
    STATE,
    TRANSPORT,
    OUTPUT_PATHS,
    AUDIO_IO,
    CLONE_CONTEXT,
    default_speaker=DEFAULT_SPEAKER,
    cache_policy=CACHE_POLICY,
    default_streaming_interval=DEFAULT_STREAMING_INTERVAL,
    prewarm_profiles=PREWARM_PROFILES,
)
HANDLERS = BackendRPCHandlers(
    state=STATE,
    transport=TRANSPORT,
    output_paths=OUTPUT_PATHS,
    audio_io=AUDIO_IO,
    clone_context=CLONE_CONTEXT,
    generation_pipeline=GENERATION_PIPELINE,
    models=MODELS,
    models_by_mode=MODELS_BY_MODE,
    speaker_map=SPEAKER_MAP,
    default_speaker=DEFAULT_SPEAKER,
    cache_policy=CACHE_POLICY,
    original_stderr=_original_stderr,
)


def process_request(line):
    HANDLERS.process_request(line)


def main():
    TRANSPORT.send_notification("ready", {"version": "1.0.0"})

    for line in sys.stdin:
        line = line.strip()
        if line:
            process_request(line)


if __name__ == "__main__":
    main()
