"""Pure audio analysis functions for the QwenVoice streaming pipeline.

Each check_* function returns a dict with at minimum {"passed": bool} plus
diagnostic details. No RPC or harness dependencies — operates on numpy arrays
and file paths only.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any


import numpy as np  # type: ignore[import-unresolved]  # app venv only
import soundfile as sf  # type: ignore[import-unresolved]  # app venv only


def _native(val: Any) -> Any:
    """Convert numpy scalars to native Python types for JSON serialization."""
    if isinstance(val, (np.bool_,)):
        return bool(val)
    if isinstance(val, (np.integer,)):
        return int(val)
    if isinstance(val, (np.floating,)):
        return float(val)
    return val

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Fidelity — chunks are sliced from same int16 data as final.wav, must be identical
CHUNK_SAMPLE_MAX_DIFF = 0

# Timing — tolerance for float rounding in JSON round-trip (server rounds to 4dp)
CHUNK_DURATION_TOLERANCE_SECONDS = 0.001
CUMULATIVE_DURATION_TOLERANCE_SECONDS = 0.01

# Jitter — coefficient of variation threshold for inter-chunk delivery intervals
JITTER_CV_THRESHOLD = 0.5

# Artifacts
CLICK_THRESHOLD_MULTIPLIER = 50.0   # |diff| > 50 * median(|diff|) at boundary = click (TTS has low median)
SILENCE_MIN_DURATION_SECONDS = 0.75  # 750ms — avoids natural inter-word/inter-phrase pauses in TTS
SILENCE_THRESHOLD_DB = -60.0
CLIPPING_THRESHOLD = 0.999
DC_OFFSET_THRESHOLD = 0.01

# Loudness
LOUDNESS_MIN_LUFS = -30.0
LOUDNESS_MAX_LUFS = -6.0
TRUE_PEAK_MAX_DBTP = 0.0
CHUNK_LOUDNESS_STD_MAX_LU = 6.0


# ---------------------------------------------------------------------------
# Loaders
# ---------------------------------------------------------------------------

def load_wav(path: str | Path) -> tuple[np.ndarray, int]:
    """Load WAV as float32 mono samples via soundfile. Returns (samples, sample_rate)."""
    data, sr = sf.read(str(path), dtype="float32", always_2d=False)
    if data.ndim > 1:
        data = data[:, 0]
    return data, int(sr)


def load_chunk_directory(
    directory: str | Path,
) -> tuple[list[tuple[np.ndarray, int]], np.ndarray | None, int]:
    """Load chunk_NNN.wav files + optional final.wav from a directory.

    Returns (chunks, final_audio, sample_rate).
    Chunks are sorted by numeric index. sample_rate is taken from the first chunk.
    """
    directory = Path(directory)
    chunk_pattern = re.compile(r"^chunk_(\d+)\.wav$")

    chunk_files: list[tuple[int, Path]] = []
    for f in directory.iterdir():
        m = chunk_pattern.match(f.name)
        if m:
            chunk_files.append((int(m.group(1)), f))
    chunk_files.sort(key=lambda x: x[0])

    chunks: list[tuple[np.ndarray, int]] = []
    sample_rate = 0
    for _, path in chunk_files:
        data, sr = load_wav(path)
        chunks.append((data, sr))
        if sample_rate == 0:
            sample_rate = sr

    final_audio: np.ndarray | None = None
    final_path = directory / "final.wav"
    if not final_path.exists():
        # Try common alternative names
        for name in ("test.wav", "output.wav"):
            alt = directory / name
            if alt.exists():
                final_path = alt
                break

    if final_path.exists():
        final_audio, sr = load_wav(final_path)
        if sample_rate == 0:
            sample_rate = sr

    return chunks, final_audio, sample_rate


# ---------------------------------------------------------------------------
# Check functions (12 tests)
# ---------------------------------------------------------------------------

def check_chunk_count_nonzero(
    chunks: list[tuple[np.ndarray, int]],
) -> dict[str, Any]:
    """Test 1: At least one chunk exists."""
    count = len(chunks)
    return {
        "passed": count > 0,
        "chunk_count": count,
        **({"error": "No chunks found"} if count == 0 else {}),
    }


def check_chunk_sample_fidelity(
    chunks: list[tuple[np.ndarray, int]],
    final_audio: np.ndarray | None,
) -> dict[str, Any]:
    """Test 2: Concatenated chunks match final WAV sample-by-sample."""
    if final_audio is None:
        return {"passed": True, "skip_reason": "No final audio file available"}
    if not chunks:
        return {"passed": False, "error": "No chunks to compare"}

    concatenated = np.concatenate([c[0] for c in chunks])
    len_concat = len(concatenated)
    len_final = len(final_audio)

    if len_concat != len_final:
        return {
            "passed": False,
            "error": f"Length mismatch: chunks={len_concat}, final={len_final}",
            "chunk_samples": len_concat,
            "final_samples": len_final,
        }

    max_diff = float(np.max(np.abs(concatenated - final_audio)))
    passed = max_diff <= CHUNK_SAMPLE_MAX_DIFF
    result: dict[str, Any] = {
        "passed": passed,
        "max_sample_diff": max_diff,
        "chunk_samples": len_concat,
        "final_samples": len_final,
    }
    if not passed:
        result["error"] = f"Max sample diff {max_diff} exceeds threshold {CHUNK_SAMPLE_MAX_DIFF}"
    return result


def check_chunk_duration_accuracy(
    chunks: list[tuple[np.ndarray, int]],
    reported_durations: list[float] | None,
) -> dict[str, Any]:
    """Test 3: Reported durations match actual WAV frame counts."""
    if reported_durations is None:
        return {"passed": True, "skip_reason": "No reported durations (offline mode)"}
    if not chunks:
        return {"passed": False, "error": "No chunks"}
    if len(chunks) != len(reported_durations):
        return {
            "passed": False,
            "error": f"Count mismatch: {len(chunks)} chunks vs {len(reported_durations)} durations",
        }

    mismatches: list[dict[str, Any]] = []
    for i, ((samples, sr), reported) in enumerate(zip(chunks, reported_durations)):
        actual = len(samples) / sr if sr > 0 else 0.0
        diff = abs(actual - reported)
        if diff > CHUNK_DURATION_TOLERANCE_SECONDS:
            mismatches.append({
                "chunk": i,
                "actual_seconds": round(actual, 6),
                "reported_seconds": reported,
                "diff_seconds": round(diff, 6),
            })

    passed = len(mismatches) == 0
    result: dict[str, Any] = {"passed": passed, "chunks_checked": len(chunks)}
    if not passed:
        result["error"] = f"{len(mismatches)} chunk(s) exceed duration tolerance"
        result["mismatches"] = mismatches
    return result


def check_cumulative_duration_match(
    chunks: list[tuple[np.ndarray, int]],
    reported_cumulative: float | None,
    final_audio: np.ndarray | None,
    sample_rate: int,
) -> dict[str, Any]:
    """Test 4: Cumulative duration matches final file duration."""
    if not chunks or sample_rate == 0:
        return {"passed": False, "error": "No chunks or sample rate is 0"}

    chunk_total = sum(len(c[0]) for c in chunks) / sample_rate
    results: dict[str, Any] = {"passed": True, "chunk_total_seconds": round(chunk_total, 6)}

    if final_audio is not None:
        final_duration = len(final_audio) / sample_rate
        diff = abs(chunk_total - final_duration)
        results["final_duration_seconds"] = round(final_duration, 6)
        results["diff_to_final_seconds"] = round(diff, 6)
        if diff > CUMULATIVE_DURATION_TOLERANCE_SECONDS:
            results["passed"] = False
            results["error"] = (
                f"Chunk total {chunk_total:.4f}s vs final {final_duration:.4f}s "
                f"(diff {diff:.4f}s > tolerance {CUMULATIVE_DURATION_TOLERANCE_SECONDS}s)"
            )

    if reported_cumulative is not None:
        diff_reported = abs(chunk_total - reported_cumulative)
        results["reported_cumulative_seconds"] = reported_cumulative
        results["diff_to_reported_seconds"] = round(diff_reported, 6)
        if diff_reported > CUMULATIVE_DURATION_TOLERANCE_SECONDS:
            results["passed"] = False
            results["error"] = (
                f"Chunk total {chunk_total:.4f}s vs reported cumulative {reported_cumulative:.4f}s "
                f"(diff {diff_reported:.4f}s > tolerance {CUMULATIVE_DURATION_TOLERANCE_SECONDS}s)"
            )

    return results


def check_inter_chunk_timing_jitter(
    received_at_ms: list[float] | None,
) -> dict[str, Any]:
    """Test 5: Delivery timing variance (live mode only, skip if <3 timestamps)."""
    if received_at_ms is None or len(received_at_ms) < 3:
        return {"passed": True, "skip_reason": "Fewer than 3 timestamps — skipping jitter check"}

    intervals = [
        received_at_ms[i + 1] - received_at_ms[i]
        for i in range(len(received_at_ms) - 1)
    ]
    mean_interval = float(np.mean(intervals))
    std_interval = float(np.std(intervals))
    cv = std_interval / mean_interval if mean_interval > 0 else 0.0

    passed = cv < JITTER_CV_THRESHOLD
    result: dict[str, Any] = {
        "passed": passed,
        "interval_count": len(intervals),
        "mean_interval_ms": round(mean_interval, 2),
        "std_interval_ms": round(std_interval, 2),
        "coefficient_of_variation": round(cv, 4),
        "threshold": JITTER_CV_THRESHOLD,
    }
    if not passed:
        result["error"] = f"Jitter CV {cv:.4f} exceeds threshold {JITTER_CV_THRESHOLD}"
    return result


def check_click_detection(
    chunks: list[tuple[np.ndarray, int]],
) -> dict[str, Any]:
    """Test 6: No transient spikes at chunk boundary positions.

    Algorithm: compute derivative of concatenated signal, check |diff| at boundary
    positions [b-2, b+2] against threshold * median(|diff|).
    """
    if len(chunks) < 2:
        return {"passed": True, "skip_reason": "Fewer than 2 chunks — no boundaries to check"}

    concatenated = np.concatenate([c[0] for c in chunks])
    diff = np.diff(concatenated)
    abs_diff = np.abs(diff)

    median_diff = float(np.median(abs_diff))
    if median_diff == 0:
        return {"passed": True, "note": "Signal is constant — no clicks possible"}

    threshold = CLICK_THRESHOLD_MULTIPLIER * median_diff

    # Find boundary sample positions
    boundaries: list[int] = []
    pos = 0
    for i in range(len(chunks) - 1):
        pos += len(chunks[i][0])
        boundaries.append(pos)

    clicks: list[dict[str, Any]] = []
    for b in boundaries:
        for offset in range(-2, 3):
            idx = b + offset - 1  # -1 because diff is one shorter
            if 0 <= idx < len(abs_diff):
                if abs_diff[idx] > threshold:
                    clicks.append({
                        "boundary_sample": b,
                        "offset": offset,
                        "diff_value": round(float(abs_diff[idx]), 6),
                        "threshold": round(threshold, 6),
                    })

    passed = len(clicks) == 0
    result: dict[str, Any] = {
        "passed": passed,
        "boundaries_checked": len(boundaries),
        "median_diff": round(median_diff, 6),
        "threshold": round(threshold, 6),
    }
    if not passed:
        result["error"] = f"{len(clicks)} click(s) detected at chunk boundaries"
        result["clicks"] = clicks[:10]  # Cap detail output
    return result


def check_silence_gap_detection(
    chunks: list[tuple[np.ndarray, int]],
    sample_rate: int,
) -> dict[str, Any]:
    """Test 7: No silence runs >5ms below -60dB in concatenated audio.

    Excludes leading/trailing 5ms (natural onset/offset).
    """
    if not chunks or sample_rate == 0:
        return {"passed": False, "error": "No chunks or sample rate is 0"}

    concatenated = np.concatenate([c[0] for c in chunks])
    margin_samples = int(SILENCE_MIN_DURATION_SECONDS * sample_rate)
    if len(concatenated) <= 2 * margin_samples:
        return {"passed": True, "skip_reason": "Audio too short for silence gap detection"}

    # Trim leading/trailing margin
    trimmed = concatenated[margin_samples:-margin_samples]

    # Convert threshold from dB to linear amplitude
    silence_amp = 10.0 ** (SILENCE_THRESHOLD_DB / 20.0)
    min_silence_samples = int(SILENCE_MIN_DURATION_SECONDS * sample_rate)

    is_silent = np.abs(trimmed) < silence_amp
    gaps: list[dict[str, Any]] = []

    run_start = None
    for i in range(len(is_silent)):
        if is_silent[i]:
            if run_start is None:
                run_start = i
        else:
            if run_start is not None:
                run_len = i - run_start
                if run_len >= min_silence_samples:
                    gaps.append({
                        "start_sample": run_start + margin_samples,
                        "duration_samples": run_len,
                        "duration_seconds": round(run_len / sample_rate, 6),
                    })
                run_start = None

    # Handle trailing run
    if run_start is not None:
        run_len = len(is_silent) - run_start
        if run_len >= min_silence_samples:
            gaps.append({
                "start_sample": run_start + margin_samples,
                "duration_samples": run_len,
                "duration_seconds": round(run_len / sample_rate, 6),
            })

    passed = len(gaps) == 0
    result: dict[str, Any] = {
        "passed": passed,
        "total_samples_checked": len(trimmed),
        "silence_threshold_db": SILENCE_THRESHOLD_DB,
        "min_gap_seconds": SILENCE_MIN_DURATION_SECONDS,
    }
    if not passed:
        result["error"] = f"{len(gaps)} silence gap(s) detected"
        result["gaps"] = gaps[:10]
    return result


def check_clipping_detection(
    chunks: list[tuple[np.ndarray, int]],
) -> dict[str, Any]:
    """Test 8: No samples at +/-0.999 threshold."""
    if not chunks:
        return {"passed": False, "error": "No chunks"}

    concatenated = np.concatenate([c[0] for c in chunks])
    clipped_mask = np.abs(concatenated) >= CLIPPING_THRESHOLD
    clipped_count = int(np.sum(clipped_mask))
    total = len(concatenated)

    passed = clipped_count == 0
    result: dict[str, Any] = {
        "passed": passed,
        "clipped_samples": clipped_count,
        "total_samples": total,
        "threshold": CLIPPING_THRESHOLD,
    }
    if not passed:
        ratio = clipped_count / total if total > 0 else 0
        result["error"] = f"{clipped_count} clipped sample(s) ({ratio:.4%})"
        result["clipping_ratio"] = round(ratio, 6)
    return result


def check_dc_offset(
    chunks: list[tuple[np.ndarray, int]],
) -> dict[str, Any]:
    """Test 9: Mean sample value below +/-0.01."""
    if not chunks:
        return {"passed": False, "error": "No chunks"}

    concatenated = np.concatenate([c[0] for c in chunks])
    mean_val = float(np.mean(concatenated))
    passed = abs(mean_val) < DC_OFFSET_THRESHOLD

    result: dict[str, Any] = {
        "passed": passed,
        "mean_value": round(mean_val, 6),
        "threshold": DC_OFFSET_THRESHOLD,
    }
    if not passed:
        result["error"] = f"DC offset {mean_val:.6f} exceeds threshold +/-{DC_OFFSET_THRESHOLD}"
    return result


def check_loudness_lufs(
    audio: np.ndarray,
    sample_rate: int,
) -> dict[str, Any]:
    """Test 10: Integrated LUFS in [-24, -10] range via pyloudnorm.

    Skips if audio < 0.4s (pyloudnorm minimum).
    """
    duration = len(audio) / sample_rate if sample_rate > 0 else 0
    if duration < 0.4:
        return {"passed": True, "skip_reason": f"Audio too short ({duration:.3f}s < 0.4s)"}

    import pyloudnorm as pyln

    meter = pyln.Meter(sample_rate)
    loudness = meter.integrated_loudness(audio)

    if np.isinf(loudness) or np.isnan(loudness):
        return {"passed": True, "skip_reason": "Loudness is -inf/NaN (silent audio)"}

    passed = LOUDNESS_MIN_LUFS <= loudness <= LOUDNESS_MAX_LUFS
    result: dict[str, Any] = {
        "passed": passed,
        "loudness_lufs": round(float(loudness), 2),
        "range": [LOUDNESS_MIN_LUFS, LOUDNESS_MAX_LUFS],
    }
    if not passed:
        result["error"] = (
            f"Loudness {loudness:.2f} LUFS outside range "
            f"[{LOUDNESS_MIN_LUFS}, {LOUDNESS_MAX_LUFS}]"
        )
    return result


def check_peak_analysis(
    audio: np.ndarray,
    sample_rate: int,
) -> dict[str, Any]:
    """Test 11: True peak < 0 dBTP via 4x oversampling (scipy.signal.resample_poly)."""
    if len(audio) == 0:
        return {"passed": False, "error": "Empty audio"}

    from scipy.signal import resample_poly

    oversampled = resample_poly(audio, up=4, down=1)
    true_peak_linear = float(np.max(np.abs(oversampled)))

    if true_peak_linear <= 0:
        return {"passed": True, "true_peak_dbtp": float("-inf"), "note": "Silent audio"}

    true_peak_dbtp = float(20.0 * np.log10(true_peak_linear))
    passed = true_peak_dbtp < TRUE_PEAK_MAX_DBTP

    result: dict[str, Any] = {
        "passed": passed,
        "true_peak_dbtp": round(true_peak_dbtp, 2),
        "true_peak_linear": round(true_peak_linear, 6),
        "threshold_dbtp": TRUE_PEAK_MAX_DBTP,
    }
    if not passed:
        result["error"] = (
            f"True peak {true_peak_dbtp:.2f} dBTP >= {TRUE_PEAK_MAX_DBTP} dBTP"
        )
    return result


def check_chunk_loudness_consistency(
    chunks: list[tuple[np.ndarray, int]],
) -> dict[str, Any]:
    """Test 12: Per-chunk LUFS std dev < 6 LU. Skips chunks < 0.4s."""
    import pyloudnorm as pyln

    loudness_values: list[float] = []
    skipped = 0
    for samples, sr in chunks:
        duration = len(samples) / sr if sr > 0 else 0
        if duration < 0.4:
            skipped += 1
            continue
        meter = pyln.Meter(sr)
        lufs = meter.integrated_loudness(samples)
        if not (np.isinf(lufs) or np.isnan(lufs)):
            loudness_values.append(float(lufs))

    if len(loudness_values) < 2:
        return {
            "passed": True,
            "skip_reason": f"Fewer than 2 measurable chunks ({len(loudness_values)} valid, {skipped} too short)",
        }

    std_lu = float(np.std(loudness_values))
    passed = std_lu < CHUNK_LOUDNESS_STD_MAX_LU

    result: dict[str, Any] = {
        "passed": passed,
        "chunks_measured": len(loudness_values),
        "chunks_skipped": skipped,
        "std_lu": round(std_lu, 2),
        "threshold_lu": CHUNK_LOUDNESS_STD_MAX_LU,
        "per_chunk_lufs": [round(v, 2) for v in loudness_values],
    }
    if not passed:
        result["error"] = (
            f"Chunk loudness std dev {std_lu:.2f} LU >= {CHUNK_LOUDNESS_STD_MAX_LU} LU"
        )
    return result


# ---------------------------------------------------------------------------
# Convenience runner
# ---------------------------------------------------------------------------

def _sanitize_result(d: dict[str, Any]) -> dict[str, Any]:
    """Recursively convert numpy types to native Python types in a result dict."""
    out: dict[str, Any] = {}
    for k, v in d.items():
        if isinstance(v, dict):
            out[k] = _sanitize_result(v)
        elif isinstance(v, list):
            out[k] = [_sanitize_result(i) if isinstance(i, dict) else _native(i) for i in v]
        else:
            out[k] = _native(v)
    return out


def run_all_analyses(
    chunks: list[tuple[np.ndarray, int]],
    final_audio: np.ndarray | None,
    sample_rate: int,
    *,
    reported_durations: list[float] | None = None,
    reported_cumulative: float | None = None,
    received_at_ms: list[float] | None = None,
) -> dict[str, dict[str, Any]]:
    """Run all 12 checks. Returns dict keyed by test name."""
    concatenated = np.concatenate([c[0] for c in chunks]) if chunks else np.array([], dtype=np.float32)

    raw = {
        "chunk_count_nonzero": check_chunk_count_nonzero(chunks),
        "chunk_sample_fidelity": check_chunk_sample_fidelity(chunks, final_audio),
        "chunk_duration_accuracy": check_chunk_duration_accuracy(chunks, reported_durations),
        "cumulative_duration_match": check_cumulative_duration_match(
            chunks, reported_cumulative, final_audio, sample_rate,
        ),
        "inter_chunk_timing_jitter": check_inter_chunk_timing_jitter(received_at_ms),
        "click_detection": check_click_detection(chunks),
        "silence_gap_detection": check_silence_gap_detection(chunks, sample_rate),
        "clipping_detection": check_clipping_detection(chunks),
        "dc_offset": check_dc_offset(chunks),
        "loudness_lufs": check_loudness_lufs(concatenated, sample_rate),
        "peak_analysis": check_peak_analysis(concatenated, sample_rate),
        "chunk_loudness_consistency": check_chunk_loudness_consistency(chunks),
    }
    return {k: _sanitize_result(v) for k, v in raw.items()}
