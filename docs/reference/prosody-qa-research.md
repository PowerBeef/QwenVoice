# Prosody QA Research Notes

> Research for improving Vocello's automated tone/tempo/cadence quality gate.
> Date: 2026-06-15

## Current pipeline

Vocello already has three audio QA layers:

1. **Signal-level QC** (`AudioQualityGate.swift` / `AudioQCReport`): deterministic, reference-free checks for clipping, DC offset, dropouts, discontinuities, silence, and duration.
2. **Delivery adherence** (`scripts/analyze_delivery.py` + `scripts/delivery_adherence.py`): deterministic, paired neutral-vs-instructed A/B using median F0, F0 range, syllable rate, and duration deltas.
3. **Listening review** (manual): the final arbiter for subtle perceptual quality (timbre, naturalness). An earlier external-model listening pass was removed after proving unreliable.

The gap: none of the automated layers reliably catches **monotone delivery**, **rushed/slurred cadence**, **unnatural pauses**, or **weak emotional differentiation** within a single take.

## Research findings

### Objective TTS prosody metrics in literature

Common objective metrics used in expressive/instructional TTS papers:

| Metric | What it measures | Reference-free | Notes |
|--------|------------------|----------------|-------|
| **F0 MSE / RMSE** | Frame-level pitch error vs ground truth | No | Needs reference audio |
| **F0 correlation (Pearson)** | Similarity of F0 contour to reference | No | Needs reference + alignment |
| **GPE (Gross Pitch Error)** | % frames with F0 off by > threshold | No | Standard in pitch trackers |
| **VDE (Voicing Decision Error)** | % frames misclassified voiced/unvoiced | No | Standard |
| **F0 std / range** | Intonation variability | Yes | Already used partially |
| **Duration std / pause ratio** | Rhythmic variability | Yes | Good for cadence |
| **MCD (Mel Cepstral Distortion)** | Spectral distance to reference | No | Captures quality, not prosody specifically |
| **STOI / PESQ / POLQA** | Perceptual quality/intelligibility | Mostly no | Speech-enhancement oriented |
| **F0 contour turning-point rate** | Prosodic dynamics | Yes | Captures monotone vs expressive |
| **Local syllable-rate CV** | Speaking-rate variability | Yes | Catches rushed/slurred |
| **RMS envelope dynamics** | Stress/energy variation | Yes | Complements F0 |

Key papers:

- *InstructTTS* (2023): uses MCD, SSIM, STOI for quality and GPE/VDE/FPE for prosody similarity.
- *InstructTTSEval* (2025): notes the lack of automated metrics for instruction-based acoustic control and uses Gemini as a judge.
- *SponTTS* (2024): uses **F0 std** and **duration std** to quantify spontaneous vs reading-style prosody.
- *TTScore-pro* (2025): uses discrete FACodec prosody tokens to evaluate pitch-pattern naturalness.

Takeaway: the most practical, reference-free prosody metrics are **F0 contour statistics**, **pause/duration structure**, and **speaking-rate variability**.

### Reference-free perceptual quality predictors

DNN-based reference-free metrics exist but are mostly trained for speech enhancement / general quality, not specifically for TTS prosody or instruction adherence:

| Tool | Output | License / Dependency | Fit for Vocello |
|------|--------|----------------------|-----------------|
| **DNSMOS** | MOS + SIG/BAK/OVRL | Microsoft research, ONNX model | General quality, not prosody-specific |
| **NISQA** | MOS + noisiness/discontinuity/coloration/loudness | Apache-ish, via torchmetrics; needs librosa | General quality, limited prosody |
| **UTMOS / SSL-MOS** | MOS | Various, SSL-based | General quality |
| **SQUIM** | MOS + PESQ + STOI | torchaudio, reference-free | General quality |

These could be added as an optional general-quality signal, but they do not solve the tone/tempo/cadence diagnosis problem directly and introduce heavy dependencies.

### Python tooling options

| Tool | Capabilities | License | Notes |
|------|--------------|---------|-------|
| **numpy + stdlib `wave`** | Everything if hand-rolled | Permissive | Current approach; slow to develop but zero deps |
| **librosa** | Pitch (YIN/piptrack), onset, RMS/MFCC, tempogram, silence detection, resampling | MIT | Best balance: robust, well-maintained, permissive |
| **parselmouth** | Full Praat pitch/formant/intensity/HNR/jitter/shimmer | GPL-linked (Praat) | Very robust pitch/pause, but GPL dependency risky for a commercial-adjacent product |
| **openSMILE** | ComParE / GeMAPS feature sets (6k+ features) | audEERING dual license; commercial use restricted | Too heavy and license-restricted |
| **torchaudio + SQUIM** | Neural MOS estimates | PyTorch | Heavy dependency, not prosody-specific |

Constraint: the target machine has **8 GB RAM** and `librosa` is not installed. Loading heavy neural quality models (DNSMOS/NISQA/SQUIM) would also push memory and add weakly prosody-specific dependencies.

Final choice: **numpy + stdlib `wave`** (zero new dependencies, tiny memory). Hand-rolled pitch tracking (NCF), syllable-nuclei detection, and pause/energy analysis are sufficient for a dev/benchmark gate and keep the pipeline deterministic and privacy-safe.

## Implemented solution

### New scripts

- **`scripts/analyze_prosody.py`** — numpy-only reference-free prosody analyzer:
  - **F0 contour**: median/mean/std/range/p10/p90, voiced fraction, rising/falling rates, turning-point rate.
  - **Speaking rate**: syllable-nuclei rate, local-rate mean/std/CV/p10/p90.
  - **Pauses**: count, total/mean/max duration, pause-to-speech ratio.
  - **Energy**: RMS mean/std/dynamic range, envelope roughness.
- **`scripts/prosody_quality_gate.py`** — flags monotone, rushed, flat/slurred, and pause-issue takes with conservative thresholds. Run per-clip or import `evaluate(path)`.
- **`scripts/bench_delivery_prosody.py`** — post-processes `vocello bench --delivery` WAVs, pairs each instructed take with its neutral reference, and writes `diagnostics/bench-prosody.json`.

### Updated scripts

- **`scripts/delivery_adherence.py`** — now computes paired deltas on the richer prosody feature set and reports `prosodyEffect` + `prosodyPosRate` alongside the existing arousal score. Added `--data-dir` for non-default model locations.
- **`scripts/summarize_generation_telemetry.py`** — reads `bench-prosody.json` and renders `prosN`, `prosEff`, `dF0Std`, `dRateCV`, `dPauseR`, `dRough` in the delivery-cells table.
- **`Sources/VocelloCLI/BenchCommand.swift`** — `vocello bench --delivery` now automatically invokes `scripts/bench_delivery_prosody.py` after aggregation.

### Usage

```bash
# Per-clip prosody gate
scripts/prosody_quality_gate.py outputs/some_take.wav

# Delivery A/B with richer prosody deltas
scripts/delivery_adherence.py --presets happy.strong,excited.strong --seeds 4 --data-dir ~/Library/Application\ Support/QwenVoice

# Bench with delivery cells + automatic prosody analysis
build/vocello bench --delivery happy.strong,calm.normal --modes custom,design
```

Manual listening remains the optional final review layer; it is not used for automated gates.

### Calibration note

Thresholds in `prosody_quality_gate.py` and weights in `delivery_adherence.py` are intentionally conservative defaults. They should be calibrated against a labeled corpus of good/bad Vocello takes once enough examples are collected.
