#!/usr/bin/env python3
"""Autonomous acoustic prosody analysis for voice cloning tone evaluation.

Compares neutral vs. guided WAV pairs using librosa-based feature extraction
to determine whether emotion guidance produces perceptible acoustic changes.
No cloud API required — runs entirely offline using quantitative signal analysis.

Three modes:
  --eval-dir DIR        Evaluate existing neutral/guided WAV pairs
  --compare A B         Compare two WAV files directly
  --generate            Generate fresh clips via backend RPC, then evaluate

Must be run with the app's bundled Python:
  ~/Library/Application\\ Support/QwenVoice/python/bin/python3 scripts/evaluate_clone_tone_acoustic.py ...
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import urllib.request
import wave
from datetime import datetime
from pathlib import Path
from typing import Any

import librosa
import numpy as np
from scipy.spatial.distance import cosine as cosine_distance
from scipy.stats import skew


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

PROJECT_DIR = Path(__file__).resolve().parents[1]
SERVER_PATH = PROJECT_DIR / "Sources" / "Resources" / "backend" / "server.py"
REQUIREMENTS_PATH = PROJECT_DIR / "Sources" / "Resources" / "requirements.txt"
VENDOR_DIR = PROJECT_DIR / "Sources" / "Resources" / "vendor"
APP_SUPPORT_DIR = Path.home() / "Library" / "Application Support" / "QwenVoice"
APP_VENV_PYTHON = APP_SUPPORT_DIR / "python" / "bin" / "python3"
APP_MODELS_DIR = APP_SUPPORT_DIR / "models"
DEFAULT_OUTPUT_ROOT = PROJECT_DIR / "build" / "tone-evals"

DEFAULT_SCRIPT = "The package is ready at the front desk for pickup."
KATHLEEN_BASE_URL = "https://raw.githubusercontent.com/rhasspy/dataset-voice-kathleen/master"
KATHLEEN_REFERENCE_STEMS = [
    "data/arctic_a0001_1592748600",
    "data/arctic_a0002_1592748556",
    "data/arctic_a0003_1592748511",
    "data/arctic_a0004_1592748478",
]

CLONE_EMOTION_INSTRUCT = {
    "happy": "Speak with a happy, cheerful tone.",
    "sad": "Speak in a sad, melancholic tone.",
    "angry": "Speak with an angry, frustrated tone.",
    "fearful": "Speak in a fearful, anxious tone.",
    "whisper": "Speak in a soft whisper.",
    "dramatic": "Speak with dramatic, theatrical emphasis.",
    "calm": "Speak in a calm, soothing tone.",
    "excited": "Speak with excited, energetic enthusiasm.",
}

DELIVERY_PROFILES = {
    "happy": {"preset_id": "happy", "intensity": "normal", "final_instruction": "Happy and upbeat tone"},
    "sad": {"preset_id": "sad", "intensity": "normal", "final_instruction": "Sad and melancholic tone"},
    "angry": {"preset_id": "angry", "intensity": "strong", "final_instruction": "Furious and intensely angry, sharp and forceful delivery"},
    "fearful": {"preset_id": "fearful", "intensity": "normal", "final_instruction": "Fearful, anxious tone"},
    "whisper": {"preset_id": "whisper", "intensity": "strong", "final_instruction": "Soft whisper"},
    "dramatic": {"preset_id": "dramatic", "intensity": "strong", "final_instruction": "Dramatic, theatrical emphasis"},
    "calm": {"preset_id": "calm", "intensity": "strong", "final_instruction": "Deeply serene, meditative voice with slow, deliberate pace"},
    "excited": {"preset_id": "excited", "intensity": "strong", "final_instruction": "Excited, energetic enthusiasm"},
}


# ---------------------------------------------------------------------------
# Emotion Signature Definitions
# ---------------------------------------------------------------------------

EMOTION_SIGNATURES: dict[str, dict[str, str]] = {
    "happy": {"f0_mean": "higher", "rms_mean": "higher", "spectral_centroid_mean": "higher", "onset_count": "higher", "f0_range": "wider"},
    "sad": {"f0_mean": "lower", "rms_mean": "lower", "f0_std": "lower", "spectral_centroid_mean": "lower", "onset_count": "lower"},
    "angry": {"f0_range": "wider", "rms_max": "higher", "spectral_bandwidth_mean": "wider", "onset_strength_mean": "higher", "zcr_mean": "higher"},
    "calm": {"f0_std": "lower", "f0_range": "narrower", "rms_std": "lower", "onset_count": "lower", "spectral_flatness_mean": "lower"},
    "whisper": {"rms_mean": "much_lower", "rms_max": "much_lower", "zcr_mean": "higher", "spectral_flatness_mean": "higher"},
    "excited": {"f0_mean": "higher", "f0_range": "wider", "rms_mean": "higher", "onset_count": "higher", "spectral_centroid_mean": "higher"},
    "dramatic": {"f0_range": "wider", "rms_std": "higher", "rms_dynamic_range_db": "wider", "onset_strength_mean": "higher"},
    "fearful": {"f0_std": "higher", "rms_std": "higher", "zcr_mean": "higher"},
}

# Direction aliases: "wider"/"narrower" map to "higher"/"lower" for delta checks
_DIRECTION_MAP = {
    "higher": "higher",
    "lower": "lower",
    "wider": "higher",
    "narrower": "lower",
    "much_lower": "much_lower",
    "much_higher": "much_higher",
}

# Thresholds
MFCC_DISTANCE_PASS = 10.0
MFCC_DISTANCE_STRONG = 30.0
DIRECTIONAL_PASS = 0.40
DIRECTIONAL_STRONG = 0.60
DELTA_THRESHOLD_PCT = 3.0
MUCH_DELTA_THRESHOLD_PCT = 25.0
SPEAKER_PRESERVED_COSINE = 0.998
SPEAKER_SHIFTED_COSINE = 0.990


# ---------------------------------------------------------------------------
# Feature Extraction
# ---------------------------------------------------------------------------

def extract_acoustic_features(wav_path: str | Path) -> dict[str, Any]:
    """Extract acoustic prosody features from a WAV file."""
    y, sr = librosa.load(str(wav_path), sr=None)
    duration = float(len(y)) / sr

    # Pitch (F0) via pyin
    f0, voiced_flag, _ = librosa.pyin(
        y, fmin=librosa.note_to_hz("C2"), fmax=librosa.note_to_hz("C7"), sr=sr,
    )
    f0_voiced = f0[~np.isnan(f0)] if f0 is not None else np.array([])
    voiced_ratio = float(len(f0_voiced)) / max(len(f0), 1) if f0 is not None else 0.0

    if len(f0_voiced) > 0:
        f0_mean = float(np.mean(f0_voiced))
        f0_std = float(np.std(f0_voiced))
        f0_range = float(np.ptp(f0_voiced))
        f0_median = float(np.median(f0_voiced))
        f0_skew = float(skew(f0_voiced)) if len(f0_voiced) > 2 else 0.0
    else:
        f0_mean = f0_std = f0_range = f0_median = f0_skew = 0.0

    # Energy (RMS)
    rms = librosa.feature.rms(y=y)[0]
    rms_mean = float(np.mean(rms))
    rms_std = float(np.std(rms))
    rms_max = float(np.max(rms))
    rms_min = float(np.min(rms)) if len(rms) > 0 else 0.0
    rms_dynamic_range_db = float(20.0 * np.log10(rms_max / max(rms_min, 1e-10))) if rms_max > 0 else 0.0

    # Spectral features
    spectral_centroid = librosa.feature.spectral_centroid(y=y, sr=sr)[0]
    spectral_bandwidth = librosa.feature.spectral_bandwidth(y=y, sr=sr)[0]
    spectral_flatness = librosa.feature.spectral_flatness(y=y)[0]

    # Zero crossing rate
    zcr = librosa.feature.zero_crossing_rate(y)[0]

    # MFCCs (13 coefficients)
    mfccs = librosa.feature.mfcc(y=y, sr=sr, n_mfcc=13)
    mfcc_means = [float(np.mean(mfccs[i])) for i in range(13)]

    # Onset / rhythm
    onset_env = librosa.onset.onset_strength(y=y, sr=sr)
    onsets = librosa.onset.onset_detect(y=y, sr=sr, onset_envelope=onset_env)
    onset_count = int(len(onsets))
    onset_strength_mean = float(np.mean(onset_env)) if len(onset_env) > 0 else 0.0

    return {
        "f0_mean": f0_mean,
        "f0_std": f0_std,
        "f0_range": f0_range,
        "f0_median": f0_median,
        "f0_skew": f0_skew,
        "rms_mean": rms_mean,
        "rms_std": rms_std,
        "rms_max": rms_max,
        "rms_dynamic_range_db": rms_dynamic_range_db,
        "spectral_centroid_mean": float(np.mean(spectral_centroid)),
        "spectral_bandwidth_mean": float(np.mean(spectral_bandwidth)),
        "spectral_flatness_mean": float(np.mean(spectral_flatness)),
        "zcr_mean": float(np.mean(zcr)),
        "mfcc_means": mfcc_means,
        "onset_count": onset_count,
        "onset_strength_mean": onset_strength_mean,
        "duration": duration,
        "voiced_ratio": voiced_ratio,
    }


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------

def _mfcc_euclidean_distance(features_a: dict, features_b: dict) -> float:
    vec_a = np.array(features_a["mfcc_means"])
    vec_b = np.array(features_b["mfcc_means"])
    return float(np.linalg.norm(vec_a - vec_b))


def _mfcc_cosine_similarity(features_a: dict, features_b: dict) -> float:
    vec_a = np.array(features_a["mfcc_means"])
    vec_b = np.array(features_b["mfcc_means"])
    dist = cosine_distance(vec_a, vec_b)
    return float(1.0 - dist)


def _check_directional_compliance(
    neutral_features: dict, guided_features: dict, emotion: str,
) -> dict[str, Any]:
    """Check whether feature deltas match expected emotion signature directions."""
    signature = EMOTION_SIGNATURES.get(emotion, {})
    if not signature:
        return {"score": 0.0, "matching_features": 0, "total_features": 0, "passed": False, "details": {}}

    matching = 0
    details: dict[str, dict[str, Any]] = {}

    for feature_name, expected_direction in signature.items():
        neutral_val = neutral_features.get(feature_name, 0.0)
        guided_val = guided_features.get(feature_name, 0.0)

        if abs(neutral_val) < 1e-10:
            delta_pct = 100.0 if abs(guided_val) > 1e-10 else 0.0
        else:
            delta_pct = ((guided_val - neutral_val) / abs(neutral_val)) * 100.0

        direction = _DIRECTION_MAP.get(expected_direction, expected_direction)
        matched = False

        if direction == "higher":
            matched = delta_pct > DELTA_THRESHOLD_PCT
        elif direction == "lower":
            matched = delta_pct < -DELTA_THRESHOLD_PCT
        elif direction == "much_lower":
            matched = delta_pct < -MUCH_DELTA_THRESHOLD_PCT
        elif direction == "much_higher":
            matched = delta_pct > MUCH_DELTA_THRESHOLD_PCT

        if matched:
            matching += 1

        details[feature_name] = {
            "expected": expected_direction,
            "delta_pct": round(delta_pct, 1),
            "matched": matched,
        }

    total = len(signature)
    score = matching / total if total > 0 else 0.0

    return {
        "score": round(score, 2),
        "matching_features": matching,
        "total_features": total,
        "passed": score >= DIRECTIONAL_PASS,
        "details": details,
    }


def _map_relative_contrast(mfcc_dist: float, directional_score: float) -> str:
    if mfcc_dist > MFCC_DISTANCE_STRONG and directional_score >= DIRECTIONAL_STRONG:
        return "stronger"
    if mfcc_dist > MFCC_DISTANCE_PASS and directional_score >= DIRECTIONAL_PASS:
        return "slightly_stronger"
    if mfcc_dist > MFCC_DISTANCE_PASS:
        return "no_clear_difference"
    return "weaker"


def _map_speaker_consistency(mfcc_cosine: float) -> str:
    if mfcc_cosine > SPEAKER_PRESERVED_COSINE:
        return "preserved"
    if mfcc_cosine > SPEAKER_SHIFTED_COSINE:
        return "slightly_shifted"
    return "changed"


def evaluate_pair(
    neutral_path: str | Path,
    guided_path: str | Path,
    emotion: str,
    scenario_id: str = "",
    requested_tone: str = "",
) -> dict[str, Any]:
    """Evaluate a neutral/guided WAV pair and return structured results."""
    neutral_features = extract_acoustic_features(neutral_path)
    guided_features = extract_acoustic_features(guided_path)

    mfcc_dist = _mfcc_euclidean_distance(neutral_features, guided_features)
    mfcc_cosine = _mfcc_cosine_similarity(neutral_features, guided_features)
    directional = _check_directional_compliance(neutral_features, guided_features, emotion)

    acoustic_passed = mfcc_dist > MFCC_DISTANCE_PASS
    strong_timbral_shift = mfcc_dist > MFCC_DISTANCE_STRONG
    overall_pass = acoustic_passed and (directional["passed"] or strong_timbral_shift)

    relative_contrast = _map_relative_contrast(mfcc_dist, directional["score"])
    speaker_consistency = _map_speaker_consistency(mfcc_cosine)

    if overall_pass and relative_contrast == "stronger":
        confidence = "high"
    elif overall_pass:
        confidence = "medium"
    else:
        confidence = "low"

    notes_parts = []
    if overall_pass:
        notes_parts.append(f"Acoustic analysis shows clear timbral differentiation (MFCC distance: {mfcc_dist:.1f}).")
        if directional["passed"]:
            notes_parts.append(
                f"Directional compliance: {directional['matching_features']}/{directional['total_features']} "
                f"features match expected '{emotion}' signature."
            )
        elif strong_timbral_shift:
            notes_parts.append("Strong timbral shift overrides low directional compliance.")
    else:
        if not acoustic_passed:
            notes_parts.append(f"Insufficient acoustic differentiation (MFCC distance: {mfcc_dist:.1f}, "
                               f"below threshold of {MFCC_DISTANCE_PASS}).")
        else:
            notes_parts.append(f"Acoustic shift detected (MFCC distance: {mfcc_dist:.1f}) but directional "
                               f"compliance too low ({directional['matching_features']}/{directional['total_features']} "
                               f"features match expected '{emotion}' signature).")

    return {
        "scenario_id": scenario_id or f"compare_{emotion}",
        "requested_tone": requested_tone or emotion,
        "method": "acoustic_prosody",
        "acoustic_differentiation": {
            "mfcc_euclidean_distance": round(mfcc_dist, 1),
            "mfcc_cosine_similarity": round(mfcc_cosine, 4),
            "passed": acoustic_passed,
        },
        "directional_compliance": directional,
        "relative_contrast": relative_contrast,
        "speaker_consistency": speaker_consistency,
        "confidence": confidence,
        "pass": overall_pass,
        "notes": " ".join(notes_parts),
    }


# ---------------------------------------------------------------------------
# Mode 1: Evaluate existing directory
# ---------------------------------------------------------------------------

def _parse_emotion_from_scenario_id(scenario_id: str) -> str:
    """Extract the base emotion from a scenario_id like 'transcripted_angry_strong'."""
    parts = scenario_id.replace("transcripted_", "").replace("no_transcript_", "").split("_")
    if parts:
        candidate = parts[0].lower()
        if candidate in EMOTION_SIGNATURES:
            return candidate
    return ""


def evaluate_directory(eval_dir: Path) -> dict[str, Any]:
    """Evaluate all scenario subdirectories containing neutral.wav + guided.wav pairs."""
    results = []
    scenario_dirs = sorted(
        d for d in eval_dir.iterdir() if d.is_dir() and (d / "neutral.wav").exists() and (d / "guided.wav").exists()
    )

    if not scenario_dirs:
        return {
            "method": "acoustic_prosody",
            "error": f"No valid scenario directories found in {eval_dir}",
            "scenario_count": 0,
            "pass_count": 0,
            "fail_count": 0,
            "overall_pass": False,
            "results": [],
        }

    for scenario_dir in scenario_dirs:
        scenario_id = scenario_dir.name
        neutral_path = scenario_dir / "neutral.wav"
        guided_path = scenario_dir / "guided.wav"

        # Try to load scenario metadata
        requested_tone = ""
        emotion = _parse_emotion_from_scenario_id(scenario_id)
        scenario_json = scenario_dir / "scenario.json"
        if scenario_json.exists():
            meta = json.loads(scenario_json.read_text(encoding="utf-8"))
            requested_tone = meta.get("requested_tone", "")
            # Extract emotion from requested_tone like "angry / strong"
            if requested_tone and not emotion:
                emotion = requested_tone.split("/")[0].strip().lower()

        if not emotion:
            emotion = "unknown"

        eprint(f"  Evaluating {scenario_id} (emotion: {emotion})...")
        result = evaluate_pair(neutral_path, guided_path, emotion, scenario_id, requested_tone)
        results.append(result)

        status = "PASS" if result["pass"] else "FAIL"
        eprint(f"    {status} — contrast: {result['relative_contrast']}, "
               f"MFCC dist: {result['acoustic_differentiation']['mfcc_euclidean_distance']:.1f}")

    pass_count = sum(1 for r in results if r["pass"])
    fail_count = len(results) - pass_count

    return {
        "method": "acoustic_prosody",
        "scenario_count": len(results),
        "pass_count": pass_count,
        "fail_count": fail_count,
        "overall_pass": fail_count == 0,
        "results": results,
    }


# ---------------------------------------------------------------------------
# Mode 3: Generate and evaluate (BackendClient)
# ---------------------------------------------------------------------------

# Import shared BackendClient and path utilities from the harness library.
# Falls back to inline definitions if harness_lib is not available.
_SCRIPTS_DIR = Path(__file__).resolve().parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from harness_lib.backend_client import BackendClient  # noqa: E402
from harness_lib.paths import (  # noqa: E402
    resolve_backend_python as _resolve_backend_python_shared,
    resolve_ffmpeg_binary as _resolve_ffmpeg_binary,
    ensure_directory as _ensure_directory,
)


def _resolve_backend_python(explicit: str) -> str:
    return _resolve_backend_python_shared(explicit or None)


def _download_url_to_file(url: str, destination: Path) -> Path:
    _ensure_directory(destination.parent)
    with urllib.request.urlopen(url) as response:
        data = response.read()
    destination.write_bytes(data)
    return destination


def _concatenate_wav_files(source_paths: list[Path], destination: Path) -> Path:
    if not source_paths:
        raise RuntimeError("No source WAV files for concatenation")
    params = None
    frames: list[bytes] = []
    for path in source_paths:
        with wave.open(str(path), "rb") as wf:
            current = (wf.getnchannels(), wf.getsampwidth(), wf.getframerate(), wf.getcomptype(), wf.getcompname())
            if params is None:
                params = current
            elif current != params:
                raise RuntimeError(f"Incompatible WAV parameters: {path}")
            frames.append(wf.readframes(wf.getnframes()))
    assert params is not None
    _ensure_directory(destination.parent)
    with wave.open(str(destination), "wb") as wf:
        wf.setnchannels(params[0])
        wf.setsampwidth(params[1])
        wf.setframerate(params[2])
        wf.setcomptype(params[3], params[4])
        for chunk in frames:
            wf.writeframes(chunk)
    return destination


def _prepare_kathleen_reference(references_dir: Path) -> tuple[Path, str]:
    """Download and concatenate Kathleen dataset clips. Returns (wav_path, transcript)."""
    kathleen_dir = _ensure_directory(references_dir / "kathleen")
    clip_paths: list[Path] = []
    transcripts: list[str] = []

    for stem in KATHLEEN_REFERENCE_STEMS:
        relative_wav = f"{stem}.wav"
        relative_txt = f"{stem}.txt"
        wav_path = kathleen_dir / Path(relative_wav).name
        txt_path = kathleen_dir / Path(relative_txt).name

        if not wav_path.exists():
            eprint(f"    Downloading {Path(relative_wav).name}...")
            _download_url_to_file(f"{KATHLEEN_BASE_URL}/{relative_wav}", wav_path)
        if not txt_path.exists():
            _download_url_to_file(f"{KATHLEEN_BASE_URL}/{relative_txt}", txt_path)

        clip_paths.append(wav_path)
        transcripts.append(txt_path.read_text(encoding="utf-8").strip())

    combined_text = " ".join(t for t in transcripts if t)
    if not combined_text:
        raise RuntimeError("Kathleen reference clips yielded no transcript text")

    seed_wav = _concatenate_wav_files(clip_paths, references_dir / "reference_seed.wav")
    seed_txt = references_dir / "reference_seed.txt"
    seed_txt.write_text(combined_text, encoding="utf-8")

    return seed_wav, combined_text


def generate_and_evaluate(output_dir: Path, python_path: str) -> dict[str, Any]:
    """Generate neutral + guided clips for each emotion, then run acoustic analysis."""
    run_dir = _ensure_directory(output_dir)
    references_dir = _ensure_directory(run_dir / "references")
    scenarios_dir = _ensure_directory(run_dir / "scenarios")
    log_dir = _ensure_directory(run_dir / "logs")

    eprint("Preparing Kathleen reference audio...")
    ref_wav, ref_text = _prepare_kathleen_reference(references_dir)

    eprint(f"Starting backend with Python: {python_path}")
    client = BackendClient(python_path, log_dir)
    client.start()

    try:
        eprint("Initializing backend...")
        client.call("init")

        eprint("Loading pro_clone model...")
        client.call("load_model", {"model_id": "pro_clone"})

        # Generate neutral baseline once
        neutral_dir = _ensure_directory(scenarios_dir / "_neutral_baseline")
        neutral_path = neutral_dir / "neutral.wav"

        if not neutral_path.exists():
            eprint("Generating neutral baseline...")
            result = client.call("generate", {
                "text": DEFAULT_SCRIPT,
                "ref_audio": str(ref_wav),
                "ref_text": ref_text,
                "output_path": str(neutral_path),
            })
            actual_path = result.get("audio_path", str(neutral_path))
            if actual_path != str(neutral_path) and Path(actual_path).exists():
                shutil.copy2(actual_path, neutral_path)
            eprint(f"  Neutral baseline saved: {neutral_path}")

        results = []
        for emotion, instruct in CLONE_EMOTION_INSTRUCT.items():
            profile = DELIVERY_PROFILES.get(emotion, {})
            intensity = profile.get("intensity", "normal")
            scenario_id = f"transcripted_{emotion}_{intensity}"
            scenario_dir = _ensure_directory(scenarios_dir / scenario_id)

            # Copy neutral baseline
            scenario_neutral = scenario_dir / "neutral.wav"
            if not scenario_neutral.exists():
                shutil.copy2(neutral_path, scenario_neutral)

            # Generate guided clip
            guided_path = scenario_dir / "guided.wav"
            if not guided_path.exists():
                eprint(f"Generating {emotion} ({intensity})...")
                gen_result = client.call("generate", {
                    "text": DEFAULT_SCRIPT,
                    "ref_audio": str(ref_wav),
                    "ref_text": ref_text,
                    "instruct": instruct,
                    "delivery_profile": profile,
                    "output_path": str(guided_path),
                })
                actual_path = gen_result.get("audio_path", str(guided_path))
                if actual_path != str(guided_path) and Path(actual_path).exists():
                    shutil.copy2(actual_path, guided_path)

            # Save scenario metadata
            scenario_meta = {
                "scenario_id": scenario_id,
                "requested_tone": f"{emotion} / {intensity}",
                "ref_audio": str(ref_wav),
                "ref_text": ref_text,
                "script": DEFAULT_SCRIPT,
                "path_kind": "transcripted",
            }
            (scenario_dir / "scenario.json").write_text(
                json.dumps(scenario_meta, indent=2) + "\n", encoding="utf-8",
            )

            # Evaluate
            eprint(f"  Evaluating {scenario_id}...")
            result = evaluate_pair(
                scenario_neutral, guided_path, emotion, scenario_id,
                requested_tone=f"{emotion} / {intensity}",
            )
            results.append(result)

            # Save per-scenario evaluation
            (scenario_dir / "evaluation.json").write_text(
                json.dumps(result, indent=2) + "\n", encoding="utf-8",
            )

            status = "PASS" if result["pass"] else "FAIL"
            eprint(f"    {status} — contrast: {result['relative_contrast']}, "
                   f"MFCC dist: {result['acoustic_differentiation']['mfcc_euclidean_distance']:.1f}")

    finally:
        eprint("Stopping backend...")
        client.stop()

    pass_count = sum(1 for r in results if r["pass"])
    fail_count = len(results) - pass_count

    return {
        "method": "acoustic_prosody",
        "scenario_count": len(results),
        "pass_count": pass_count,
        "fail_count": fail_count,
        "overall_pass": fail_count == 0,
        "results": results,
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def eprint(*args: Any, **kwargs: Any) -> None:
    print(*args, file=sys.stderr, **kwargs)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Acoustic prosody analysis for voice cloning tone evaluation.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--eval-dir", type=Path,
        help="Evaluate existing WAV pairs in scenario subdirectories.",
    )
    group.add_argument(
        "--compare", nargs=2, metavar=("NEUTRAL", "GUIDED"),
        help="Compare two WAV files directly.",
    )
    group.add_argument(
        "--generate", action="store_true",
        help="Generate fresh clips via backend RPC, then evaluate.",
    )
    parser.add_argument(
        "--emotion", default="",
        help="Emotion label for --compare mode (e.g. angry, happy).",
    )
    parser.add_argument(
        "--output-dir", type=Path, default=None,
        help="Output directory for --generate mode.",
    )
    parser.add_argument(
        "--python", default="",
        help="Explicit Python interpreter path for backend runtime.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    if args.compare:
        neutral_path, guided_path = args.compare
        emotion = args.emotion or "unknown"
        eprint(f"Comparing: {neutral_path} vs {guided_path} (emotion: {emotion})")
        result = evaluate_pair(neutral_path, guided_path, emotion)
        summary = {
            "method": "acoustic_prosody",
            "scenario_count": 1,
            "pass_count": 1 if result["pass"] else 0,
            "fail_count": 0 if result["pass"] else 1,
            "overall_pass": result["pass"],
            "results": [result],
        }
        print(json.dumps(summary, indent=2))

    elif args.eval_dir:
        eval_dir = args.eval_dir.resolve()
        if not eval_dir.is_dir():
            eprint(f"Error: {eval_dir} is not a directory")
            sys.exit(1)
        eprint(f"Evaluating scenarios in: {eval_dir}")
        summary = evaluate_directory(eval_dir)
        print(json.dumps(summary, indent=2))

    elif args.generate:
        python_path = _resolve_backend_python(args.python)
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        output_dir = args.output_dir or (DEFAULT_OUTPUT_ROOT / f"acoustic-run-{timestamp}")
        eprint(f"Generate-and-evaluate run: {output_dir}")
        summary = generate_and_evaluate(output_dir.resolve(), python_path)
        print(json.dumps(summary, indent=2))

    else:
        eprint("No mode selected. Use --eval-dir, --compare, or --generate.")
        sys.exit(1)

    # Exit code reflects overall pass/fail
    if not summary.get("overall_pass", False):
        sys.exit(1)


if __name__ == "__main__":
    main()
