<div align="center">
  <img src="docs/social_preview.png" alt="QwenVoice — Offline Text-to-Speech for Mac with Voice Cloning">
</div>

## Screenshots

<img width="1868" height="1676" alt="qwenvoice-screenshot" src="https://github.com/user-attachments/assets/311ea30b-9196-4f36-93f4-5db439c5a2ba" />


## Overview

QwenVoice is a native SwiftUI macOS application that brings state-of-the-art text-to-speech to Apple Silicon Macs with no Python install, no terminal, and no dependencies required of the user — just download and run.

It runs the Qwen3-TTS model family entirely offline via Apple's MLX framework, delivering fast, low-latency, low-heat inference on M-series chips. The app communicates with a Python backend over JSON-RPC 2.0 via stdin/stdout, managed transparently as a background process.

## Features

### Custom Voice & Voice Design

Generate speech using 4 built-in English speakers (Ryan, Aiden, Serena, Vivian) or create entirely new voice identities from a text description (e.g. "deep narrator", "excited child"). Both modes are controlled entirely through natural language instructions — there are no sliders or SSML tags. The underlying discrete multi-codebook language model natively interprets prompts to modulate breath, pitch, resonance, and emotional delivery.

### Voice Cloning

Clone any voice from a short 5–10 second audio sample (WAV, MP3, AIFF, M4A, FLAC, or OGG). Optionally provide a transcript of the reference audio to improve accuracy.

### Model Manager

Download and manage MLX models directly from HuggingFace inside the app. No browser or command line needed. Uses a native URLSession-based downloader with real-time progress tracking.

### Generation History

Every generation is persisted to a local SQLite database (via GRDB). The History view lists generations sorted by date (newest first) and supports text search filtering. Each entry can be played back instantly, revealed in Finder, or deleted.

### Batch Generation

Submit multiple text entries for sequential generation in a single session.

### Additional Features

- **Temperature & max-token controls** — Fine-tune the model's sampling behaviour from the UI
- **Waveform visualisation** — Live waveform rendered for generated audio clips (via AVFoundation + vDSP)
- **Reveal in Finder** — Jump directly to any generated file (Cmd+Shift+R)
- **Keyboard shortcuts** — Cmd+Return to generate, Space to play/pause, Cmd+. to stop, Cmd+Shift+O to open the output folder
- **CLI companion** — A standalone Python CLI in `cli/` for headless or scripted use

## Tone & Emotion Control

A standout feature of both Custom Voice and Voice Design modes is the absence of traditional parametric controls. The entire control surface is probabilistic and driven by natural language. Examples:

> "Speak in an incredulous tone, but with a hint of panic beginning to creep into your voice."

> "A composed middle-aged male announcer with a deep, rich and magnetic voice."

## Requirements

| Requirement | Detail |
|---|---|
| macOS | 14.0+ (Sonoma) |
| Chip | Apple Silicon (M1 / M2 / M3 / M4) |
| RAM | 8 GB+ recommended |

## Install

1. Download `QwenVoice.dmg` from [Releases](https://github.com/PowerBeef/QwenVoice/releases)
2. Drag to `/Applications`
3. Remove the quarantine attribute (the app is unsigned):
   ```sh
   xattr -cr "/Applications/QwenVoice.app"
   ```
4. Open the app → go to the **Models** tab → download a model → start generating

## Models

| Model | Mode | Size | HuggingFace Repo |
|---|---|---|---|
| Custom Voice | Custom Voice | 1.7B (8-bit) | [mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit) |
| Voice Design | Voice Design | 1.7B (8-bit) | [mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit) |
| Voice Cloning | Voice Cloning | 1.7B (8-bit) | [mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit) |

All models are 8-bit quantised for efficient memory use and natively support natural language instruction inputs.

## Building from Source

**Source build prerequisites:** Apple Silicon (M1 or later), macOS 14+, Xcode 15+, XcodeGen

If you do not already have XcodeGen installed, run `brew install xcodegen` first.

```sh
git clone https://github.com/PowerBeef/QwenVoice.git
cd QwenVoice
./scripts/regenerate_project.sh
open QwenVoice.xcodeproj
```

Build and run the `QwenVoice` scheme from Xcode.

If you want to verify the checked-in Xcode project metadata before building, run `./scripts/check_project_inputs.sh`.

**Dev-mode runtime dependencies:** In a clean source checkout, `Sources/Resources/python/` is usually absent, so most source builds will use the local-Python fallback on first launch. Have a local Python 3.11-3.14 install available first (for example `brew install python@3.13`). The app then creates a Python venv at `~/Library/Application Support/QwenVoice/python/`, installs the backend dependencies into it, and shows setup progress in `SetupView`.

For a packaged DMG rather than a normal local Xcode build, use:

**Release build:**
```sh
./scripts/release.sh
```

**Release packaging dependencies:** `./scripts/release.sh` downloads and bundles Python 3.13 (arm64) into `Sources/Resources/python/` and ffmpeg into `Sources/Resources/ffmpeg/` before building. Those resource directories are generated build assets and are intentionally not tracked in git, so a clean clone will not contain them until the bundle scripts run. The release flow also requires network access to fetch those artifacts.

After bundling those generated assets, the release script builds with `xcodebuild` and produces a DMG at `build/QwenVoice.dmg`.

## Architecture & Tech Stack

QwenVoice uses a **two-process architecture**:

**SwiftUI Frontend** (`Sources/`) manages the UI, SQLite history, model downloads, and audio playback. Key components:

- `PythonBridge` — Launches and manages the Python subprocess, sends JSON-RPC 2.0 requests over stdin/stdout, and handles async continuations for each pending call. Exposes typed Swift methods for every backend operation (`generateCustom`, `generateDesign`, `generateClone`, `enrollVoice`, `loadModel`, etc.)
- `PythonEnvironmentManager` — Handles the full Python environment lifecycle: architecture check, bundled-Python fast path, venv creation, pip dependency installation with retry logic, SHA-256 marker-file validation to avoid reinstalling on every launch, and import validation before marking setup complete.
- `HuggingFaceDownloader` — A native `URLSession`-based downloader that queries the HuggingFace tree API, resolves LFS sizes, and streams each file to disk with per-file and aggregate progress callbacks. No `huggingface-cli` dependency.
- `DatabaseService` — SQLite persistence via GRDB with schema migrations (v2 adds `sortOrder` column) and basic CRUD for generation history.
- `AudioPlayerViewModel` / `AudioService` — AVFoundation-backed audio player with play/pause/stop and waveform data extraction via vDSP.
- `ModelManagerViewModel` — Tracks download state for all three models and triggers `PythonBridge.loadModel` on selection.

**Python Backend** (`Sources/Resources/backend/server.py`) runs as a persistent subprocess and exposes a JSON-RPC 2.0 interface over stdin/stdout. It loads MLX model weights on demand and handles `generate`, `enroll_voice`, `list_voices`, `delete_voice`, `get_model_info`, `load_model`, `unload_model`, `ping`, and `init` methods. MLX memory is explicitly freed between generations to minimise RAM pressure.

**Output directory layout** (under `~/Library/Application Support/QwenVoice/`):

```
models/          ← downloaded MLX model weights
outputs/
  CustomVoice/   ← generated audio from Custom Voice mode
  VoiceDesign/   ← generated audio from Voice Design mode
  Clones/        ← generated audio from Voice Cloning mode
voices/          ← enrolled voice reference audio
history.sqlite   ← generation history database
python/          ← auto-created Python venv (dev mode)
```

**Swift package dependencies:** [GRDB.swift](https://github.com/groue/GRDB.swift) (≥ 7.0.0)

**Python dependencies:** `mlx`, `mlx-audio`, `transformers`, `numpy`, `soundfile`, `huggingface-hub`, `ffmpeg` (bundled binary in release)

## CLI

A standalone Python CLI is available in `cli/` for headless or scripted use:

```sh
cd cli
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python main.py
```

Supports Custom Voice, Voice Design, and Voice Cloning modes interactively.

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| Cmd+Return | Generate speech |
| Space | Play / Pause |
| Cmd+. | Stop playback |
| Cmd+Shift+O | Open output folder in Finder |
| Cmd+Shift+R | Reveal current file in Finder |

## Credits & Open Source Acknowledgements

QwenVoice is built on the shoulders of the following open source projects:

### Core Inference & Models

**[Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)** — Alibaba / Qwen Team  
The underlying text-to-speech model family. Qwen3-TTS is the discrete multi-codebook language model that performs all speech synthesis in this app. Released under the Apache 2.0 license.

**[mlx-audio](https://github.com/Blaizzy/mlx-audio)** — Prince Canuma ([@Blaizzy](https://github.com/Blaizzy))  
The Python library that provides MLX inference for Qwen3-TTS. Both `server.py` and `cli/main.py` call `mlx_audio.tts.utils.load_model` and `mlx_audio.tts.generate.generate_audio` directly — this is the primary inference engine. Released under the MIT license.

**[MLX](https://github.com/ml-explore/mlx)** — Apple ML Research  
The array framework for Apple Silicon that powers all on-device inference. Provides GPU/Neural Engine acceleration and the `mlx.metal.clear_cache()` call used to free VRAM between generations. Released under the MIT license.

**[mlx-community on HuggingFace](https://huggingface.co/mlx-community)**  
The community organisation that hosts the 8-bit quantised MLX model weights used by this app (`Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit`, `Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit`, `Qwen3-TTS-12Hz-1.7B-Base-8bit`).

### CLI Foundation

**[qwen3-tts-apple-silicon](https://github.com/kapi2800/qwen3-tts-apple-silicon)** — [@kapi2800](https://github.com/kapi2800)  
The `cli/main.py` in this repo is directly derived from kapi2800's project. The interactive menu structure, speaker map, voice enrolment flow, audio conversion helpers (`convert_audio_if_needed`, `get_smart_path`), and overall CLI architecture all originate from this work. The Python backend (`server.py`) was subsequently refactored from `cli/main.py` to expose a JSON-RPC 2.0 interface for the Swift frontend.

### Swift Dependencies

**[GRDB.swift](https://github.com/groue/GRDB.swift)** — Gwendal Roué ([@groue](https://github.com/groue))  
The SQLite toolkit used for generation history persistence and schema migrations. Integrated via Swift Package Manager. Released under the MIT license.

### Apple Frameworks (built-in)

The app also makes direct use of Apple's system frameworks: **SwiftUI** (UI layer), **AVFoundation** (audio playback), **Accelerate / vDSP** (waveform RMS computation in `WaveformService`), **CryptoKit** (SHA-256 marker-file hashing in `PythonEnvironmentManager`), and **Foundation** (process management, URLSession downloads, file I/O).
