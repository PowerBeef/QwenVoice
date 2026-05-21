# Vocello for macOS 26

Vocello is the next-generation version of QwenVoice, rebranded as the 2.0 macOS 26 release line.

[![Website](https://img.shields.io/badge/Website-vocello.vercel.app-7b61ff?style=flat-square&logo=vercel)](https://vocello.vercel.app/)
[![Vocello 2.0.0](https://img.shields.io/badge/Vocello-2.0.0-7b61ff?style=flat-square)](https://github.com/PowerBeef/QwenVoice/releases/tag/v2.0.0)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-111827?style=flat-square&logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-111827?style=flat-square&logo=apple)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Downloads](https://img.shields.io/github/downloads/PowerBeef/QwenVoice/v2.0.0/total?label=2.0.0%20downloads&style=flat-square)](https://github.com/PowerBeef/QwenVoice/releases/tag/v2.0.0)

**The easiest way to generate private, high-quality AI voices entirely on your Mac.**

Vocello is a local, private AI voice-generation app for Apple Silicon Macs. Write a script, choose how the voice should sound, and generate speech without a subscription or cloud credit meter. Visit the official site at [vocello.vercel.app](https://vocello.vercel.app/) for the full product overview.

| If you want... | Get this build | Notes |
| --- | --- | --- |
| Vocello 2.0.0 for Apple Silicon Macs (macOS 26+) | **Vocello 2.0.0** - [Download](https://github.com/PowerBeef/QwenVoice/releases/tag/v2.0.0) | Stable, signed + notarized release. Recommended download. |
| A build for macOS 15 | **QwenVoice 1.2.3** - [Download Legacy](https://github.com/PowerBeef/QwenVoice/releases/tag/v1.2.3) | Legacy build for macOS 15. No 2.x backport planned. |

<p align="center">
  <img src="docs/readme_banner_vocello.png" alt="Vocello banner with abstract voice waves and the Vocello logo" width="920">
</p>

## Why Try Vocello

- **Private by default.** After models are installed, generation runs locally and your scripts, history, and generated audio stay in local app storage unless you export them.
- **No subscription meter.** Download the models you want, then generate on your Mac without paying per line or waiting on a cloud queue.
- **Three voice workflows.** Use a built-in speaker, describe a new voice, or clone from a reference clip you own or have permission to use.
- **Built for Apple Silicon.** Vocello 2.0 uses a native Swift + MLX backend instead of the older bundled Python runtime, keeping it local, private, self-contained, and Mac-like.

## Screenshots

<table>
  <tr>
    <td width="50%">
      <img src="docs/screenshots/vocello-custom-voice.png" alt="Custom Voice screen">
      <br>
      <strong>Custom Voice</strong><br>
      Pick a built-in speaker, set delivery, and generate a clean spoken line.
    </td>
    <td width="50%">
      <img src="docs/screenshots/vocello-voice-design.png" alt="Voice Design screen">
      <br>
      <strong>Voice Design</strong><br>
      Describe the voice you want in natural language, then write the script.
    </td>
  </tr>
  <tr>
    <td width="50%">
      <img src="docs/screenshots/vocello-voice-cloning.png" alt="Voice Cloning screen">
      <br>
      <strong>Voice Cloning</strong><br>
      Use a saved voice or import a permitted reference clip with an optional transcript.
    </td>
    <td width="50%">
      <img src="docs/screenshots/vocello-model-downloads.png" alt="Model downloads settings screen">
      <br>
      <strong>Model Downloads</strong><br>
      Install and manage Speed and Quality packages for each voice mode.
    </td>
  </tr>
</table>

## What You Can Do

### Custom Voice

Choose one of the built-in speakers, pick a delivery style, and turn a script into speech quickly. This is the simplest path when you want a consistent voice right away.

### Voice Design

Describe a voice in plain language: a calm narrator, an energetic host, a warm documentary voice, or something more specific. Vocello uses that description to shape the generated voice.

### Voice Cloning

Generate speech from a short reference clip. Vocello supports WAV, MP3, AIFF, M4A, FLAC, and OGG reference audio, plus an optional transcript for better accuracy. Only clone voices you own or have permission to use.

### Model Downloads

Settings is focused on model packages: download, repair, reveal, or delete Speed and Quality models for each voice mode. Generation screens own the Speed/Quality choice so model management stays out of the way while you write.

## Install

1. Download [`Vocello-macos26.dmg`](https://github.com/PowerBeef/QwenVoice/releases/tag/v2.0.0).
2. Open the DMG and drag `Vocello.app` to `/Applications`.
3. Open Vocello.
4. Go to Settings -> Model downloads and install the voice models you want.
5. Generate from Custom Voice, Voice Design, or Voice Cloning.

No Python setup or local server is required. Install the app, download models from Settings, and generate locally.

The DMG is signed by `Developer ID Application: PATRICE DERY` and Apple-notarized with a stapled ticket, so the first launch opens with a double-click — no right-click bypass needed. If you want to verify out of band:

```sh
xcrun stapler validate Vocello-macos26.dmg     # "The validate action worked!"
spctl --assess --type install -vv Vocello-macos26.dmg   # accepted, source=Notarized Developer ID
```

A `release-metadata.txt` (commit SHA, Xcode version, SDK, marketing version, build number) is attached to the same release for build provenance.

## Requirements

For Vocello 2.0.0:

- macOS 26.0+
- Apple Silicon Mac
- Voice models installed from Settings -> Model downloads

Model downloads come in two sizes:

- `Speed` models are smaller 4-bit packages for faster startup and lower memory use.
- `Quality` models are larger 8-bit packages for Macs with more headroom.

For macOS 15, use [QwenVoice v1.2.3](https://github.com/PowerBeef/QwenVoice/releases/tag/v1.2.3). No 2.x backport to macOS 15 is planned.

## Release Status

Vocello 2.0.0 is the first stable release of the macOS 26 line. Every GitHub Release from here on ships a notarized + stapled DMG, signed by Developer ID Application: PATRICE DERY — installing it is a normal double-click flow, no Gatekeeper workarounds.

The iPhone app is maintained in this repository, but it is not a public download yet. When ready, it will ship through the App Store or TestFlight, not GitHub Releases.

## Local-First Privacy

- Speech generation runs on-device after models are installed.
- Generated audio and history stay in local app storage unless you export them.
- Model downloads come from Hugging Face when you install a voice model.
- Voice cloning should only be used with voices you own or have permission to use.

## For Developers

The `main` branch contains the current Vocello codebase. The current stable release is tagged as [`v2.0.0`](https://github.com/PowerBeef/QwenVoice/releases/tag/v2.0.0).

Vocello 2.0's native Swift + MLX engine is hosted outside the UI process and replaces the legacy Python-backed runtime.

```sh
git clone https://github.com/PowerBeef/QwenVoice.git
cd QwenVoice
./scripts/regenerate_project.sh
open QwenVoice.xcodeproj
```

Useful checks:

```sh
./scripts/check_project_inputs.sh
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
```

More technical details live in the maintained docs:

- [`docs/README.md`](docs/README.md) - documentation index
- [`docs/reference/current-state.md`](docs/reference/current-state.md) - current repo facts
- [`docs/reference/release-readiness.md`](docs/reference/release-readiness.md) - release policy and signoff gates
- [`docs/reference/privacy-storage.md`](docs/reference/privacy-storage.md) - local storage and deletion details
- [`docs/qwen_tone.md`](docs/qwen_tone.md) - tone and prompt-writing guidance
- [`CONTRIBUTING.md`](CONTRIBUTING.md) - contributor workflow

## License

QwenVoice is available under the [MIT License](LICENSE).

## Credits

QwenVoice and Vocello build on:

- [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)
- [mlx-audio](https://github.com/Blaizzy/mlx-audio)
- [MLX](https://github.com/ml-explore/mlx)
- [GRDB.swift](https://github.com/groue/GRDB.swift)
