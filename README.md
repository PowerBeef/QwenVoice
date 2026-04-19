## Screenshots

### Custom Voice

![Custom Voice screenshot](docs/screenshots/readme_custom_voice.png)

### Voice Design

![Voice Design screenshot](docs/screenshots/readme_voice_design.png)

### Voice Cloning

![Voice Cloning screenshot](docs/screenshots/readme_voice_cloning.png)

## Overview

QwenVoice is a native macOS app for offline Qwen3-TTS on Apple Silicon. The repo is native-only and source-build-focused: the app, maintained local harness, and current contributor workflow all use the Swift/MLX runtime split across `Sources/QwenVoiceNative/`, `Sources/QwenVoiceEngineSupport/`, `Sources/QwenVoiceNativeRuntime/`, and `third_party_patches/mlx-audio-swift/`.

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

## Get Started

This checkout is maintained as a source-build project rather than a hosted DMG/release pipeline. Clone the repo, regenerate the Xcode project, and build locally:

```sh
git clone https://github.com/PowerBeef/QwenVoice.git
cd QwenVoice
./scripts/regenerate_project.sh
open QwenVoice.xcodeproj
```

Then build the `QwenVoice` scheme from Xcode, or use:

```sh
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build
```

After launching the app:

1. Go to **Models**
2. Download a model
3. Generate speech from one of the three generation modes

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

Useful local checks:

```sh
./scripts/check_project_inputs.sh
python3 scripts/harness.py validate
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer native
```

## Tone and Emotion Control

Custom Voice and Voice Design are guided by natural-language instructions rather than SSML-style sliders or markup.

See [`qwen_tone.md`](qwen_tone.md) for supplemental prompt-writing guidance. For current repo truth about shipped behavior, trust this README plus [`docs/reference/current-state.md`](docs/reference/current-state.md) over supplemental prose.

## Architecture

QwenVoice uses a native app architecture:

- **SwiftUI frontend** in `Sources/` for UI, downloads, persistence, and playback
- **App-facing engine layer** in `Sources/QwenVoiceNative/` for the proxy/client/store surface used by the app
- **Shared engine IPC** in `Sources/QwenVoiceEngineSupport/`
- **Service-side runtime** in `Sources/QwenVoiceNativeRuntime/` and `Sources/QwenVoiceEngineService/`
- **Vendored MLXAudioSwift source** in `third_party_patches/mlx-audio-swift/`
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
