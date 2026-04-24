## Screenshots

<img width="1868" height="1676" alt="QwenVoice screenshot" src="https://github.com/user-attachments/assets/311ea30b-9196-4f36-93f4-5db439c5a2ba" />

## Overview

QwenVoice is the public repository for an offline Apple-platform Qwen3-TTS app with Custom Voice, Voice Design, and Voice Cloning.

The currently shipped public release is **QwenVoice v1.2.3** for macOS. The next macOS release ships under the **Vocello** app name while this repository, shared core, and many internal modules keep the QwenVoice identity for continuity.

## Version Matrix

| Surface | Public name | Artifact | Minimum OS / tools | Runtime | Status |
|---|---|---|---|---|---|
| Shipped release | QwenVoice v1.2.3 | Assets attached to the v1.2.3 GitHub Release | See the v1.2.3 release notes | SwiftUI app with the shipped legacy runtime | Current public download |
| Current `main` | QwenVoice repo / Vocello app | Local builds produce `Vocello.app` | macOS 26.0+, iOS 26.0+, Xcode 26.0 | Native Swift/MLX shared core with macOS XPC isolation and iPhone extension isolation | Active development |
| Next macOS release | Vocello | `Vocello-macos26.dmg` | macOS 26.0+ | Native Swift/MLX macOS runtime hosted out of process | Current release target |
| iPhone track | Vocello for iPhone | App Store / TestFlight only | iOS 26.0+, iPhone 15 Pro minimum target | 4-bit Speed variants in an engine extension | Maintained but deferred |

The public landing page remains QwenVoice-led until the Vocello-branded macOS release ships. iPhone is in active development, but it is not a public release surface for the current macOS-first milestone.

## Shipped Modes

### Custom Voice

Generate speech with the app's built-in English speakers:

- Ryan
- Aiden
- Serena
- Vivian

### Voice Design

Voice Design is a standalone destination. Describe the voice you want, then shape tone before generating.

### Voice Cloning

Clone a voice from a short reference clip. The app accepts WAV, MP3, AIFF, M4A, FLAC, and OGG input and can also use an optional transcript for better cloning accuracy. Only clone voices you own or have permission to use.

## What the App Does Not Expose

- no temperature or max-token controls
- no streaming batch UI

Single-generation flows use live streaming preview and sidebar playback. Batch generation remains sequential and final-file-based.

## Features

- Native model downloads from Hugging Face
- Live streaming preview for single generations
- Local generation history stored in SQLite via GRDB
- Batch generation for multi-line jobs
- Sidebar waveform playback UI
- Configurable output directory and autoplay preference
- macOS XPC process isolation for native generation on current `main`
- iPhone engine-extension isolation for the deferred iPhone track

## Requirements

### Current `main`

| Requirement | Detail |
|---|---|
| macOS | 26.0+ |
| iOS | 26.0+ for the maintained iPhone targets |
| Chip | Apple Silicon |
| RAM | 8 GB+ on macOS; iPhone 15 Pro is the stated iPhone floor |
| Tools | Xcode 26.0 and XcodeGen |

### Shipped QwenVoice v1.2.3

The shipped v1.2.3 build predates the current native `main` release track. Use the v1.2.3 GitHub Release notes and attached assets as the source of truth for that historical build.

## Install from GitHub Releases

Download the current public release from [Releases](https://github.com/PowerBeef/QwenVoice/releases).

For the next macOS release, the public artifact is expected to be:

- `Vocello-macos26.dmg`

Then:

1. Open the DMG.
2. Drag `Vocello.app` to `/Applications`.
3. Open the app, go to **Models**, download a model, and generate speech.

## Models

Static model metadata comes from [`Sources/Resources/qwenvoice_contract.json`](Sources/Resources/qwenvoice_contract.json).

| Mode | 8-bit Quality folder | 4-bit Speed folder | Hugging Face repos |
|---|---|---|---|
| Custom Voice | `Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit` | `Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit` | `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-*` |
| Voice Design | `Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit` | `Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit` | `mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-*` |
| Voice Cloning | `Qwen3-TTS-12Hz-1.7B-Base-8bit` | `Qwen3-TTS-12Hz-1.7B-Base-4bit` | `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-*` |

macOS can expose 8-bit Quality where runtime admission allows it and uses 4-bit Speed for constrained hardware. iPhone uses the 4-bit Speed variants only.

## Building from Source

Source-build prerequisites for current `main`:

- macOS 26.0+
- Apple Silicon
- Xcode 26.0
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
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer native
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
```

The harness stores isolated build products and `.xcresult` bundles under `build/harness/`. The macOS UI smoke lane is available with `python3 scripts/harness.py test --layer e2e`; for release signoff on a controlled Mac, run it strictly with `QWENVOICE_E2E_STRICT=1`.

Benchmarks are opt-in:

```sh
python3 scripts/harness.py bench --category latency --runs 3
python3 scripts/harness.py bench --category load --runs 3
```

## Local Release Packaging

For a local unsigned macOS release build and DMG:

```sh
./scripts/release.sh --preflight full
./scripts/verify_release_bundle.sh build/Vocello.app
./scripts/verify_packaged_dmg.sh build/Vocello-macos26.dmg build/release-metadata.txt
```

## Tone and Emotion Control

Custom Voice and Voice Design are guided by natural-language instructions rather than SSML-style sliders or markup.

See [`docs/qwen_tone.md`](docs/qwen_tone.md) for app-oriented guidance on tone and prompt writing.

## Architecture

Current `main` uses a native Apple-platform architecture:

- `Sources/` contains the macOS app shell, shared app models/services/views, and the shipping Mac target.
- `Sources/QwenVoiceCore/` contains shared Apple-platform runtime semantics, contract types, model variants, and iOS extension transport.
- `Sources/QwenVoiceNative/` contains the macOS app-facing engine proxy/store/client layer.
- `Sources/QwenVoiceEngineSupport/` contains shared macOS engine IPC and transport types.
- `Sources/QwenVoiceEngineService/` contains the bundled macOS XPC helper.
- `Sources/QwenVoiceNativeRuntime/` remains as retained compatibility and regression coverage.
- `Sources/iOS/`, `Sources/iOSSupport/`, and `Sources/iOSEngineExtension/` contain the deferred iPhone app, support layer, and isolated engine extension.
- `Sources/SharedSupport/` contains shared playback and generation-persistence surfaces.

The current codebase does not maintain a repo-owned Python backend, Python setup path, or standalone CLI surface.

Default macOS runtime data layout:

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

See [`docs/reference/privacy-storage.md`](docs/reference/privacy-storage.md) for local storage, privacy, and deletion details.

## More Docs

- [`docs/README.md`](docs/README.md) - documentation index
- [`docs/reference/current-state.md`](docs/reference/current-state.md) - current repo facts
- [`docs/reference/engineering-status.md`](docs/reference/engineering-status.md) - current strengths and caveats
- [`docs/reference/release-readiness.md`](docs/reference/release-readiness.md) - macOS-first release policy and signoff gates
- [`docs/reference/privacy-storage.md`](docs/reference/privacy-storage.md) - local storage, privacy, and deletion details
- [`CONTRIBUTING.md`](CONTRIBUTING.md) - contributor workflow

## License

QwenVoice is available under the [MIT License](LICENSE).

## Credits

QwenVoice builds on:

- [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)
- [mlx-audio](https://github.com/Blaizzy/mlx-audio)
- [MLX](https://github.com/ml-explore/mlx)
- [GRDB.swift](https://github.com/groue/GRDB.swift)
