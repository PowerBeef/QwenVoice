## Screenshots

### Custom Voice

![Custom Voice screenshot](docs/screenshots/readme_custom_voice.png)

### Voice Design

![Voice Design screenshot](docs/screenshots/readme_voice_design.png)

### Voice Cloning

![Voice Cloning screenshot](docs/screenshots/readme_voice_cloning.png)

## Overview

QwenVoice is a native macOS app for offline Qwen3-TTS on Apple Silicon. The repo is now native-only: the shipped app, local source build, maintained harness, and release packaging flow all use the Swift/MLX runtime in `Sources/QwenVoiceNative/` and `third_party_patches/mlx-audio-swift/`.

## Shipped Modes

### Custom Voice

Generate speech with the app’s built-in English speakers:

- Ryan
- Aiden
- Serena
- Vivian

### Voice Design

Describe the voice you want, then shape the delivery before generating.

### Voice Cloning

Clone a voice from a short reference clip. The app accepts WAV, MP3, AIFF, M4A, FLAC, OGG, and WebM input and can also use an optional transcript for better cloning accuracy.

## What the App Does Not Expose

- no temperature or max-token controls
- no streaming batch UI

Single-generation flows use live streaming preview and sidebar playback. Batch generation remains sequential and final-file-based in the GUI.

## Features

- Native model downloads from Hugging Face
- Live streaming preview for single generations
- Local generation history stored in SQLite via GRDB
- Batch generation for multi-line jobs
- Sidebar waveform playback UI
- Configurable output directory and autoplay preference

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
2. Open the app normally. Official GitHub workflow releases are signed, notarized, and stapled.
3. macOS may still show the standard first-open “downloaded from the Internet” confirmation prompt.
4. Go to **Models**, download a model, and generate speech

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
- Xcode 26+ for the default `QW_UI_LIQUID` checkout
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
python3 scripts/harness.py validate
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer native
```

### Local release packaging

For a local release build and DMG:

```sh
./scripts/release.sh
```

That script builds a native-only Release app, verifies that no backend/python runtime assets leaked into the bundle, and by default produces `build/QwenVoice.dmg`.

## Tone and Emotion Control

Custom Voice and Voice Design are guided by natural-language instructions rather than SSML-style sliders or markup.

See [`qwen_tone.md`](qwen_tone.md) for supplemental prompt-writing guidance. For current repo truth about shipped behavior, trust this README plus [`docs/reference/current-state.md`](docs/reference/current-state.md) over supplemental prose.

## Architecture

QwenVoice uses a native app architecture:

- **SwiftUI frontend** in `Sources/` for UI, downloads, persistence, and playback
- **Native MLX runtime** in `Sources/QwenVoiceNative/` plus `third_party_patches/mlx-audio-swift/` for inference and clone support
- **Manifest-backed metadata** in `Sources/Resources/qwenvoice_contract.json` for models, speakers, output folders, and required files

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

## More Docs

- [`docs/README.md`](docs/README.md) — documentation index
- [`docs/reference/current-state.md`](docs/reference/current-state.md) — current repo facts
- [`docs/reference/engineering-status.md`](docs/reference/engineering-status.md) — current strengths and caveats

## Credits

QwenVoice builds on:

- [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)
- [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift)
- [MLX](https://github.com/ml-explore/mlx)
- [GRDB.swift](https://github.com/groue/GRDB.swift)
