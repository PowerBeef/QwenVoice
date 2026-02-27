<div align="center">
  <img src="docs/logo.png" alt="Qwen Voice Logo" width="128">

  # Qwen Voice

  **Native macOS frontend for Qwen3-TTS on Apple Silicon**

  ![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
  ![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-M1%2FM2%2FM3%2FM4-orange)
  ![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138)
  ![Release](https://img.shields.io/github/v/release/PowerBeef/QwenVoice)

  </div>

  ## Overview

  Qwen Voice is a native SwiftUI macOS application that brings state-of-the-art text-to-speech to Apple Silicon Macs with no Python install, no terminal, and no dependencies required of the user — just download and run.

  It runs the Qwen3-TTS model family entirely offline via Apple's MLX framework, delivering fast, low-latency, low-heat inference on M-series chips. The app communicates with a Python backend over JSON-RPC 2.0 via stdin/stdout, managed transparently as a background process.

  ## Features

  ### Custom Voice & Voice Design

  Generate speech using 4 built-in English speakers (Ryan, Aiden, Serena, Vivian) or create entirely new voice identities from a text description (e.g. "deep narrator", "excited child"). Both modes are controlled entirely through natural language instructions — there are no sliders or SSML tags. The underlying discrete multi-codebook language model natively interprets prompts to modulate breath, pitch, resonance, and emotional delivery.

  ### Voice Cloning

  Clone any voice from a short 5–10 second audio sample (WAV, MP3, or AIFF). Optionally provide a transcript of the reference audio to improve accuracy.

  ### Model Manager

  Download and manage MLX models directly from HuggingFace inside the app. No browser or command line needed. Uses a native URLSession-based downloader with real-time progress tracking.

  ### Generation History

  Every generation is persisted to a local SQLite database (via GRDB). The History view supports sorting by date, duration, voice, mode, or a custom manual drag-reorder. Items can be searched, exported, or deleted via a context menu. Instant in-app playback is available for every entry.

  ### Batch Generation

  Submit multiple text entries for sequential generation in a single session.

  ### Additional Features

  - **Temperature & max-token controls** — Fine-tune the model's sampling behaviour from the UI
  - - **Waveform visualisation** — Live waveform rendered for generated audio clips
    - - **Reveal in Finder** — Jump directly to any generated file (Cmd+Shift+R)
      - - **Keyboard shortcuts** — Cmd+Return to generate, Space to play/pause, Cmd+. to stop, Cmd+Shift+O to open the output folder
        - - **CLI companion** — A standalone Python CLI in `cli/` for headless or scripted use
         
          - ## Tone & Emotion Control
         
          - A standout feature of both Custom Voice and Voice Design modes is the absence of traditional parametric controls. The entire control surface is probabilistic and driven by natural language. Examples:
         
          - > "Speak in an incredulous tone, but with a hint of panic beginning to creep into your voice."
            >
            > > "A composed middle-aged male announcer with a deep, rich and magnetic voice."
            > >
            > > ## Requirements
            > >
            > > | Requirement | Detail |
            > > |---|---|
            > > | macOS | 14.0+ (Sonoma) |
            > > | Chip | Apple Silicon (M1 / M2 / M3 / M4) |
            > > | RAM | 4–8 GB free depending on model |
            > >
            > > ## Install
            > >
            > > 1. Download `QwenVoice.dmg` from [Releases](https://github.com/PowerBeef/QwenVoice/releases)
            > > 2. 2. Drag to `/Applications`
            > >    3. 3. Remove the quarantine attribute (the app is unsigned):
            > >       4.    ```sh
            > >                xattr -cr "/Applications/Qwen Voice.app"
            > >                ```
            > >             4. Open the app → go to the **Models** tab → download a model → start generating
            > >         
            > >             5. ## Models
            > >         
            > >             6. | Model | Mode | Size | HuggingFace Repo |
            > >             7. |---|---|---|---|
            > >             8. | Custom Voice | Custom Voice | 1.7B (8-bit) | [mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit) |
            > > | Voice Design | Voice Design | 1.7B (8-bit) | [mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit) |
            > > | Voice Cloning | Voice Cloning | 1.7B (8-bit) | [mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit) |
            > >
            > > All models are 8-bit quantised for efficient memory use and natively support natural language instruction inputs.
            > >
            > > ## Building from Source
            > >
            > > **Prerequisites:** Xcode 15+, XcodeGen, macOS 14+
            > >
            > > ```sh
            > > git clone https://github.com/PowerBeef/QwenVoice.git
            > > cd QwenVoice
            > > xcodegen generate
            > > open QwenVoice.xcodeproj
            > > ```
            > >
            > > Build and run from Xcode. On first launch in dev mode, the app automatically creates a Python venv at `~/Library/Application Support/QwenVoice/python/` and installs all dependencies (mlx, mlx-audio, transformers, soundfile, huggingface-hub). The setup progress is shown in a guided `SetupView` before the main interface appears.
            > >
            > > **Release build:**
            > > ```sh
            > > ./scripts/release.sh
            > > ```
            > >
            > > This bundles Python 3.13 (arm64) + ffmpeg into the app, builds with `xcodebuild`, and produces a DMG at `build/QwenVoice.dmg`.
            > >
            > > ## Architecture & Tech Stack
            > >
            > > Qwen Voice uses a **two-process architecture**:
            > >
            > > **SwiftUI Frontend** (`Sources/`) manages the UI, SQLite history, model downloads, and audio playback. Key components:
            > >
            > > - `PythonBridge` — Launches and manages the Python subprocess, sends JSON-RPC 2.0 requests over stdin/stdout, and handles async continuations for each pending call. Exposes typed Swift methods for every backend operation (`generateCustom`, `generateDesign`, `generateClone`, `enrollVoice`, `loadModel`, etc.)
            > > - - `PythonEnvironmentManager` — Handles the full Python environment lifecycle: architecture check, bundled-Python fast path, venv creation, pip dependency installation with retry logic, SHA-256 marker-file validation to avoid reinstalling on every launch, and import validation before marking setup complete.
            > >   - - `HuggingFaceDownloader` — A native `URLSession`-based downloader that queries the HuggingFace tree API, resolves LFS sizes, and streams each file to disk with per-file and aggregate progress callbacks. No `huggingface-cli` dependency.
            > >     - - `DatabaseService` — SQLite persistence via GRDB with schema migrations, multi-field sort, full-text search, drag-reorder (sortOrder column), and export support.
            > >       - - `AudioPlayerViewModel` / `AudioService` — AVFoundation-backed audio player with play/pause/stop and waveform data extraction.
            > >         - - `ModelManagerViewModel` — Tracks download state for all three models and triggers `PythonBridge.loadModel` on selection.
            > >          
            > >           - **Python Backend** (`Sources/Resources/backend/server.py`) runs as a persistent subprocess and exposes a JSON-RPC 2.0 interface over stdin/stdout. It loads MLX model weights on demand and handles `generate`, `enroll_voice`, `list_voices`, `delete_voice`, `get_model_info`, `load_model`, `unload_model`, `ping`, and `init` methods. MLX memory is explicitly freed between generations to minimise RAM pressure.
            > >          
            > >           - **Output directory layout** (under `~/Library/Application Support/QwenVoice/`):
            > >          
            > >           - ```
            > > models/          ← downloaded MLX model weights
            > > outputs/
            > >   CustomVoice/   ← generated audio from Custom Voice mode
            > >   VoiceDesign/   ← generated audio from Voice Design mode
            > >   Clones/        ← generated audio from Voice Cloning mode
            > > voices/          ← enrolled voice reference audio
            > > history.sqlite   ← generation history database
            > > python/          ← auto-created Python venv (dev mode)
            > > ```
            > >
            > > **Swift package dependencies:** [GRDB.swift](https://github.com/groue/GRDB.swift) (≥ 7.0.0)
            > >
            > > **Python dependencies:** `mlx`, `mlx-audio`, `transformers`, `numpy`, `soundfile`, `huggingface-hub`, `ffmpeg` (bundled binary in release)
            > >
            > > ## CLI
            > >
            > > A standalone Python CLI is available in `cli/` for headless or scripted use:
            > >
            > > ```sh
            > > cd cli
            > > python3 -m venv .venv && source .venv/bin/activate
            > > pip install -r requirements.txt
            > > python main.py
            > > ```
            > >
            > > Supports Custom Voice, Voice Design, and Voice Cloning modes interactively.
            > >
            > > ## Keyboard Shortcuts
            > >
            > > | Shortcut | Action |
            > > |---|---|
            > > | Cmd+Return | Generate speech |
            > > | Space | Play / Pause |
            > > | Cmd+. | Stop playback |
            > > | Cmd+Shift+O | Open output folder in Finder |
            > > | Cmd+Shift+R | Reveal current file in Finder |
            > >
            > > ## Credits
            > >
            > > - [qwen3-tts-apple-silicon](https://github.com/kapi2800/qwen3-tts-apple-silicon) by @kapi2800 — MLX-based inference backend structure
            > > - - [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS) by Alibaba/Qwen team — the underlying model family
