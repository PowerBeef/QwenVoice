#!/usr/bin/env python3
"""Reference-free DELIVERY acoustic analyzer (deterministic, numpy-only).

The committed, deterministic alternative to the agy-as-ear review for *delivery*
and *pitch* decisions. The agy multimodal judge proved too unreliable to decide
on (it flips its verdict on byte-identical audio and abstains under load), so for
delivery/pitch we measure the acoustics directly instead. Dev/benchmark tool only
(no Python ships in the app; this never runs in the product).

Extracts the acoustic dimensions a delivery instruction actually targets:
  - pitch : median F0 (Hz) over voiced frames, + p10/p90 -> f0_range (intonation)
  - rate  : syllable-nuclei per second (energy-envelope peaks), voiced frac, duration
  - level : RMS (dBFS) -- reported but UNRELIABLE here: the engine's
            PCM16StreamLimiter normalizes output level, so a "louder" instruction
            barely moves RMS. Lean on F0 + rate + duration, which are
            gain-independent.

Pure numpy + stdlib `wave`. Engine output is 24 kHz mono Int16. Deterministic:
same WAV -> byte-identical numbers, every time.

How it is used (paired neutral-vs-instructed A/B):
  For each seed, generate a NEUTRAL take (no delivery) and an INSTRUCTED take
  (--delivery "...") with the same speaker/variant/text/seed, then compare:
  a real high-arousal delivery effect shows up as F0 up + rate up + duration down
  (+ wider F0 range) relative to the same-seed neutral. Compare candidate wordings
  by their per-seed paired win-rate on that arousal signal. See the §I.3 writeup in
  benchmarks/OPTIMIZATION.md.

Usage:
  analyze_delivery.py <wav> [<wav> ...] [--json]
"""
import sys, json, wave
import numpy as np

F0_MIN, F0_MAX = 70.0, 400.0      # voice F0 search band (Hz)
FRAME_MS, HOP_MS = 40.0, 10.0
VOICING_AC = 0.30                  # normalized autocorr peak threshold for "voiced"


def read_wav(path):
    with wave.open(path, "rb") as w:
        sr = w.getframerate()
        n = w.getnframes()
        ch = w.getnchannels()
        sw = w.getsampwidth()
        raw = w.readframes(n)
    if sw != 2:
        raise ValueError(f"expected 16-bit PCM, got sampwidth={sw}")
    x = np.frombuffer(raw, dtype="<i2").astype(np.float64)
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return x, sr


def frame_sig(x, frame, hop):
    if len(x) < frame:
        return np.empty((0, frame))
    n = 1 + (len(x) - frame) // hop
    idx = np.arange(frame)[None, :] + hop * np.arange(n)[:, None]
    return x[idx]


def f0_autocorr(frame, sr):
    """Normalized-autocorrelation F0 for one frame. Returns (f0_hz, ac_peak) or (0,0)."""
    f = frame - frame.mean()
    win = np.hanning(len(f))
    f = f * win
    energy = np.dot(f, f)
    if energy < 1e-6:
        return 0.0, 0.0
    ac = np.correlate(f, f, mode="full")[len(f) - 1:]
    ac0 = ac[0]
    if ac0 <= 0:
        return 0.0, 0.0
    lag_min = max(1, int(sr / F0_MAX))
    lag_max = min(len(ac) - 1, int(sr / F0_MIN))
    if lag_max <= lag_min:
        return 0.0, 0.0
    seg = ac[lag_min:lag_max + 1]
    k = int(np.argmax(seg))
    peak = seg[k] / ac0
    lag = lag_min + k
    # parabolic interpolation around the peak for sub-sample accuracy
    if 0 < k < len(seg) - 1:
        a, b, c = seg[k - 1], seg[k], seg[k + 1]
        denom = (a - 2 * b + c)
        if denom != 0:
            lag = lag + 0.5 * (a - c) / denom
    return (sr / lag if lag > 0 else 0.0), float(peak)


def analyze(path):
    x, sr = read_wav(path)
    dur = len(x) / sr
    frame = int(sr * FRAME_MS / 1000)
    hop = int(sr * HOP_MS / 1000)
    frames = frame_sig(x, frame, hop)
    if len(frames) == 0:
        return {"clip": path.split("/")[-1], "error": "too_short", "durationSec": round(dur, 3)}

    # RMS per frame (dBFS, full-scale = 32768 for Int16). Unreliable for "louder"
    # judgements -- the engine limiter normalizes level.
    rms = np.sqrt((frames ** 2).mean(axis=1))
    rms_db = 20 * np.log10(np.maximum(rms, 1e-9) / 32768.0)

    # F0 + voicing per frame
    f0 = np.zeros(len(frames))
    acp = np.zeros(len(frames))
    for i, fr in enumerate(frames):
        f0[i], acp[i] = f0_autocorr(fr, sr)
    voiced = (acp >= VOICING_AC) & (f0 > 0)
    f0v = f0[voiced]
    # Octave-error rejection: autocorrelation F0 occasionally jumps an octave,
    # which wildly inflates the range. Anchor on the median and keep only frames
    # within [0.5x, 2x] of it for percentile/range stats.
    if len(f0v):
        med0 = float(np.median(f0v))
        f0v = f0v[(f0v >= 0.5 * med0) & (f0v <= 2.0 * med0)]

    # Speaking-rate proxy: count syllable nuclei as peaks in the smoothed energy
    # envelope. Smooth RMS with a ~50ms moving average, find prominent local maxima.
    env = rms / (rms.max() + 1e-9)
    k = max(1, int(50 / HOP_MS))
    kern = np.ones(k) / k
    env_s = np.convolve(env, kern, mode="same")
    thr = 0.15  # ignore near-silence wiggles
    peaks = 0
    for i in range(1, len(env_s) - 1):
        if env_s[i] > env_s[i - 1] and env_s[i] >= env_s[i + 1] and env_s[i] > thr:
            peaks += 1
    syl_rate = peaks / dur if dur > 0 else 0.0

    def pct(a, p):
        return float(np.percentile(a, p)) if len(a) else 0.0

    return {
        "clip": path.split("/")[-1],
        "durationSec": round(dur, 3),
        "f0_median_hz": round(float(np.median(f0v)), 1) if len(f0v) else 0.0,
        "f0_p10_hz": round(pct(f0v, 10), 1),
        "f0_p90_hz": round(pct(f0v, 90), 1),
        "f0_range_hz": round(pct(f0v, 90) - pct(f0v, 10), 1) if len(f0v) else 0.0,
        "voiced_frac": round(float(voiced.mean()), 3),
        "rms_mean_db": round(float(rms_db.mean()), 1),
        "rms_voiced_db": round(float(rms_db[voiced].mean()), 1) if voiced.any() else 0.0,
        "rms_p90_db": round(pct(rms_db, 90), 1),
        "syllable_rate_hz": round(syl_rate, 2),
        "n_voiced_frames": int(voiced.sum()),
    }


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    as_json = "--json" in sys.argv[1:]
    out = [analyze(p) for p in args]
    if as_json:
        print(json.dumps(out, indent=2))
    else:
        if not out:
            print("usage: analyze_delivery.py <wav> [...] [--json]"); return
        keys = ["clip", "durationSec", "f0_median_hz", "f0_range_hz", "voiced_frac",
                "rms_voiced_db", "rms_p90_db", "syllable_rate_hz"]
        w = {k: max(len(k), max((len(str(r.get(k, ""))) for r in out), default=0)) for k in keys}
        print("  ".join(k.ljust(w[k]) for k in keys))
        for r in out:
            print("  ".join(str(r.get(k, "")).ljust(w[k]) for k in keys))


if __name__ == "__main__":
    main()
