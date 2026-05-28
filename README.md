# Vocello for macOS 26

Vocello is a local voice studio for Apple Silicon Macs. Write a script, choose how the voice should sound, and generate locally. Full product overview at [vocello.vercel.app](https://vocello.vercel.app/).

[![Website](https://img.shields.io/badge/Website-vocello.vercel.app-7b61ff?style=flat-square&logo=vercel)](https://vocello.vercel.app/)
[![Vocello 2.0.0](https://img.shields.io/badge/Vocello-2.0.0-7b61ff?style=flat-square)](https://github.com/PowerBeef/QwenVoice/releases/tag/v2.0.0)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-111827?style=flat-square&logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-111827?style=flat-square&logo=apple)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Downloads](https://img.shields.io/github/downloads/PowerBeef/QwenVoice/v2.0.0/total?label=2.0.0%20downloads&style=flat-square)](https://github.com/PowerBeef/QwenVoice/releases/tag/v2.0.0)

*Formerly QwenVoice, now Vocello 2.0 on macOS 26.*

<p align="center">
  <img src="docs/readme_banner_vocello.png" alt="Vocello banner with abstract voice waves and the Vocello logo" width="920">
</p>

| If you want... | Get this build | Notes |
| --- | --- | --- |
| Vocello 2.0.0 for Apple Silicon Macs (macOS 26+) | **Vocello 2.0.0** - [Download](https://github.com/PowerBeef/QwenVoice/releases/tag/v2.0.0) | Signed, notarized, stable. |
| A build for macOS 15 | **QwenVoice 1.2.3** - [Download Legacy](https://github.com/PowerBeef/QwenVoice/releases/tag/v1.2.3) | Legacy build for macOS 15. No 2.x backport planned. |

## Why Vocello

- **Private by default.** After models are installed, generation runs locally and your scripts, history, and generated audio stay in local app storage unless you export them.
- **No subscription meter.** Download the models you want, then generate on your Mac without paying per line or waiting on a cloud queue.
- **Three voice workflows.** Use a built-in speaker, describe a new voice, or clone from a reference clip you own or have permission to use.
- **Built for Apple Silicon.** Vocello 2.0 uses a native Swift + MLX backend instead of the older bundled Python runtime, keeping generation local, private, and Mac-like.

## Three voice workflows

<table>
  <tr>
    <td width="50%">
      <img src="docs/screenshots/vocello-custom-voice.png" alt="Custom Voice screen">
      <br>
      <strong>Custom Voice</strong><br>
      Pick one of nine built-in Qwen3 speaker presets, set delivery, and generate a clean spoken line. The fastest path when you want a consistent voice right away.
    </td>
    <td width="50%">
      <img src="docs/screenshots/vocello-voice-design.png" alt="Voice Design screen">
      <br>
      <strong>Voice Design</strong><br>
      Describe the voice you want in plain language, then write the script. Vocello shapes the take from that brief.
    </td>
  </tr>
  <tr>
    <td width="50%">
      <img src="docs/screenshots/vocello-voice-cloning.png" alt="Voice Cloning screen">
      <br>
      <strong>Voice Cloning</strong><br>
      Generate speech from a short reference clip (WAV, MP3, AIFF, M4A, FLAC, or OGG) with an optional transcript. Only clone voices you own or have permission to use.
    </td>
    <td width="50%">
      <img src="docs/screenshots/vocello-model-downloads.png" alt="Model downloads settings screen">
      <br>
      <strong>Model downloads</strong><br>
      Install and manage Speed and Quality packages for each voice mode from Settings. Generation screens own the Speed/Quality choice while you write.
    </td>
  </tr>
</table>

## Install

1. Download [`Vocello-macos26.dmg`](https://github.com/PowerBeef/QwenVoice/releases/tag/v2.0.0).
2. Open the DMG and drag `Vocello.app` to `/Applications`.
3. Open Vocello.
4. Go to **Settings → Model downloads** and install the voice models you want.
5. Generate from Custom Voice, Voice Design, or Voice Cloning.

No Python setup or local server is required. Install the app, download models from Settings, and generate locally.

The DMG is signed with an Apple Developer ID certificate and notarized with a stapled ticket, so the first launch opens with a double-click (no right-click bypass). To verify the signature:

```sh
xcrun stapler validate Vocello-macos26.dmg     # "The validate action worked!"
spctl --assess --type install -vv Vocello-macos26.dmg   # accepted, source=Notarized Developer ID
```

A `release-metadata.txt` (commit SHA, Xcode version, SDK, marketing version, build number) is attached to the same release for build provenance.

## Requirements

- macOS 26.0+
- Apple Silicon Mac
- Voice models installed from **Settings → Model downloads**

**Speed** models are smaller 4-bit packages for faster startup and lower memory use. **Quality** models are larger 8-bit packages for Macs with more headroom.

Vocello 2.0.0 is the first stable release of the macOS 26 line. For macOS 15, use [QwenVoice v1.2.3](https://github.com/PowerBeef/QwenVoice/releases/tag/v1.2.3). No 2.x backport to macOS 15 is planned.

Every GitHub Release from here on ships a notarized, stapled DMG signed with a Developer ID certificate. Installing it is a normal double-click flow with no Gatekeeper workarounds.

The iPhone app is maintained in this repository but is not a public download yet. When ready, it will ship through the App Store or TestFlight, not GitHub Releases.

## Local-first privacy

- Speech generation runs locally after models are installed.
- Generated audio and history stay in local app storage unless you export them.
- Model downloads come from Hugging Face when you install a voice model.
- Voice cloning should only be used with voices you own or have permission to use.

## Build from source

The `main` branch contains the current Vocello codebase. The stable release is tagged [`v2.0.0`](https://github.com/PowerBeef/QwenVoice/releases/tag/v2.0.0).

Vocello 2.0's native Swift + MLX engine runs outside the UI process and replaces the legacy Python-backed runtime.

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

More technical details:

- [`docs/README.md`](docs/README.md) - documentation index
- [`docs/reference/current-state.md`](docs/reference/current-state.md) - current repo facts
- [`docs/reference/release-readiness.md`](docs/reference/release-readiness.md) - release policy and signoff gates
- [`docs/reference/privacy-storage.md`](docs/reference/privacy-storage.md) - local storage and deletion details
- [`CONTRIBUTING.md`](CONTRIBUTING.md) - contributor workflow

## License

QwenVoice is available under the [MIT License](LICENSE).

## Built on

Vocello builds on [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS), [mlx-audio](https://github.com/Blaizzy/mlx-audio), [MLX](https://github.com/ml-explore/mlx), and [GRDB.swift](https://github.com/groue/GRDB.swift).
