## Screenshots

<img width="1868" height="1676" alt="QwenVoice screenshot" src="https://github.com/user-attachments/assets/311ea30b-9196-4f36-93f4-5db439c5a2ba" />

## Overview

QwenVoice is a native macOS app for Qwen3-TTS with custom voices, voice design, and voice cloning, 100% offline on Apple Silicon.

It uses a SwiftUI frontend plus a long-lived Python backend that runs MLX inference locally. End users do not need to install Python or use the terminal when running the packaged app.

## A Note on What's Changing

A few things worth mentioning if you've been following the project.

**QwenVoice is becoming Vocello.** The name is changing, but the app isn't. Same custom voices, same voice design, same voice cloning, same fully offline approach on Apple Silicon. QwenVoice started as a way to run Qwen3-TTS locally on a Mac, and over time it has grown into its own thing with its own design decisions. Giving it a proper name is more about committing to the project for the long term than pivoting away from what it is today. If you install it today and come back in six months, it'll still feel like the same app — just with a cleaner identity.

**A leaner backend is on the way.** The build you can download right now still uses the SwiftUI frontend plus a long-lived Python process for MLX inference. The next release drops Python entirely and moves inference directly into Swift. For you that means smaller downloads, faster cold starts, no venv spin-up on first launch, and no Python prerequisite when building from source. Nothing about how you use the app changes.

**An iPhone version is coming.** Vocello for iPhone is in active development and will ship after the macOS rebrand lands. It's a full standalone app, not a Mac companion — the same offline, on-device generation you get on macOS, running the 4-bit model variants so everything fits comfortably on iPhone 15 Pro and newer. The iPhone app will be open source alongside the macOS app in this repo, and a signed, ready-to-run build will be published on the App Store so you don't have to build and sign it yourself. No cloud, no subscription.

None of this changes what you install today. v1.2.3 is still the current release, and the rest of this README describes that build. I'll update this page when the Vocello release is ready.

## Shipped Modes

### Custom Voice

Generate speech with the app’s built-in English speakers:

- Ryan
- Aiden
- Serena
- Vivian

### Voice Design

Voice Design is a standalone destination. Describe the voice you want, then shape tone before generating.

### Voice Cloning

Clone a voice from a short reference clip. The app accepts WAV, MP3, AIFF, M4A, FLAC, and OGG input and can also use an optional transcript for better cloning accuracy.

## What the App Does Not Expose

- no temperature or max-token controls
- no streaming batch UI

Single-generation flows in the shipping GUI use live streaming preview and sidebar playback. Batch generation remains sequential and final-file-based.

The backend still supports additional benchmark/internal advanced sampling parameters beyond what the shipped GUI exposes.

For normal app behavior, the backend cache policy defaults to `adaptive`. `QWENVOICE_CACHE_POLICY=always` remains available as a conservative diagnostic override for backend benchmarking and regression checks.

## Features

- Native model downloads from Hugging Face
- Live streaming preview for single generations
- Local generation history stored in SQLite via GRDB
- Batch generation for multi-line jobs
- Sidebar waveform playback UI
- Configurable output directory and autoplay preference
- Standalone CLI companion in [`cli/`](cli/)

## Requirements

| Requirement | Detail |
|---|---|
| macOS | 15.0+ |
| Chip | Apple Silicon |
| RAM | 8 GB+ recommended |

## Install from GitHub Releases

Download the appropriate DMG from [Releases](https://github.com/PowerBeef/QwenVoice/releases).

Current GitHub release builds are produced by the dual-release workflow and typically appear as:

- `QwenVoice-macos26.dmg` — modern liquid UI build
- `QwenVoice-macos15.dmg` — legacy glass UI build

Then:

1. Drag `QwenVoice.app` to `/Applications`
2. Remove the quarantine attribute because the app is unsigned:
   ```sh
   xattr -cr "/Applications/QwenVoice.app"
   ```
3. Open the app, go to **Models**, download a model, and generate speech

## Models

Static model metadata comes from [`Sources/Resources/qwenvoice_contract.json`](Sources/Resources/qwenvoice_contract.json).

| Mode | Model Folder | Hugging Face Repo |
|---|---|---|
| Custom Voice | `Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit` | [mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit) |
| Voice Design | `Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit` | [mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit) |
| Voice Cloning | `Qwen3-TTS-12Hz-1.7B-Base-8bit` | [mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit) |

## Building from Source

Source-build prerequisites:

- macOS 15+
- Apple Silicon
- Xcode 15+
- XcodeGen

```sh
git clone https://github.com/PowerBeef/QwenVoice.git
cd QwenVoice
./scripts/regenerate_project.sh
open QwenVoice.xcodeproj
```

Build the `QwenVoice` scheme from Xcode, or use:

```sh
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build
```

Useful local checks:

```sh
./scripts/check_project_inputs.sh
./scripts/run_tests.sh
./scripts/run_backend_tests.sh
```

### Development-mode Python behavior

In a clean source checkout, `Sources/Resources/python/` is usually absent. The app then creates a venv under `~/Library/Application Support/QwenVoice/python/` on first launch and installs the backend dependencies from `Sources/Resources/requirements.txt`.

Have a local Python 3.11-3.14 install available first. A typical setup is:

```sh
brew install python@3.13
```

### Local release packaging

For a local release build and DMG:

```sh
./scripts/release.sh
```

That script bundles Python and ffmpeg, builds the Release app, verifies the bundle, and by default produces `build/QwenVoice.dmg`.

## Tone and Emotion Control

Custom Voice and Voice Design are guided by natural-language instructions rather than SSML-style sliders or markup.

See [`qwen_tone.md`](qwen_tone.md) for the current app-oriented guidance on:

- what the shipped app exposes
- what the standalone CLI exposes
- what broader Qwen3-TTS ecosystem notes are informational only

## Architecture

QwenVoice uses a two-process architecture:

- **SwiftUI frontend** in `Sources/` for UI, downloads, persistence, and playback
- **Python backend** in `Sources/Resources/backend/server.py` for MLX inference over newline-delimited JSON-RPC 2.0

Static TTS contract data is shared by Swift and Python through `Sources/Resources/qwenvoice_contract.json`.

Default runtime output layout:

```text
~/Library/Application Support/QwenVoice/
  models/
  outputs/
    CustomVoice/
    VoiceDesign/
    Clones/
  voices/
  history.sqlite
```

## CLI Companion

A standalone Python CLI lives in [`cli/`](cli/) for headless or scripted workflows.

Start here:

- [`cli/README.md`](cli/README.md)

## More Docs

- [`docs/README.md`](docs/README.md) — documentation index
- [`docs/reference/current-state.md`](docs/reference/current-state.md) — current repo facts
- [`docs/reference/testing.md`](docs/reference/testing.md) — test inventory and commands
- [`docs/reference/engineering-status.md`](docs/reference/engineering-status.md) — current strengths and caveats

## Credits

QwenVoice builds on:

- [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)
- [mlx-audio](https://github.com/Blaizzy/mlx-audio)
- [MLX](https://github.com/ml-explore/mlx)
- [GRDB.swift](https://github.com/groue/GRDB.swift)
