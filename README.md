# Vocello Beta 1 for macOS 26

Vocello is a local, private AI voice-generation app for Apple Silicon Macs. Write a script, choose how the voice should sound, and generate speech on your Mac with no cloud credit meter.

**Public beta:** [Download Vocello 2.0.0 beta 1](https://github.com/PowerBeef/QwenVoice/releases/tag/v2.0.0-beta.1) for macOS 26.

**Stable fallback:** need macOS 15 support or a non-beta build? [Get QwenVoice v1.2.3](https://github.com/PowerBeef/QwenVoice/releases/tag/v1.2.3).

<p align="center">
  <img src="docs/screenshots/vocello-custom-voice.png" alt="Vocello Custom Voice screen showing speaker, delivery, model, and script controls" width="920">
</p>

## Why Try Vocello

- **Create voices three ways.** Use a built-in speaker, describe a new voice, or clone from a reference clip you own or have permission to use.
- **Keep generation local.** After models are installed, speech generation runs on your Mac and your generated audio stays in local app storage.
- **Choose Speed or Quality.** Pick compact 4-bit models for faster startup, or larger 8-bit models when your Mac has the headroom.
- **Stay in a native Mac workflow.** Model downloads, playback, history, saved voices, and output folders live inside one quiet macOS app.

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

## Install The Beta

1. Download [`Vocello-macos26.dmg`](https://github.com/PowerBeef/QwenVoice/releases/tag/v2.0.0-beta.1).
2. Open the DMG and drag `Vocello.app` to `/Applications`.
3. Open Vocello.
4. Go to Settings -> Model downloads and install the voice models you want.
5. Generate from Custom Voice, Voice Design, or Voice Cloning.

You can verify the download with `Vocello-macos26.dmg.sha256` from the same release.

## Requirements

For Vocello 2.0.0 beta 1:

- macOS 26.0+
- Apple Silicon Mac
- Voice models installed from Settings -> Model downloads

For macOS 15 or a stable non-beta build, use [QwenVoice v1.2.3](https://github.com/PowerBeef/QwenVoice/releases/tag/v1.2.3).

## Beta Notes

Vocello 2.0.0 beta 1 is public beta software. Voice quality, tone control, model downloads, and performance may still be refined before a stable 2.0 release.

The withdrawn 2.0 RC1 build is not restored or advertised. Beta 1 is a newer public beta with backend hardening, clearer model management, Speed/Quality selection on generation screens, and targeted delivery-control fixes.

The iPhone app is maintained in this repository, but it is not a public download yet. When ready, it will ship through the App Store or TestFlight, not GitHub Releases.

## Local-First Privacy

- Speech generation runs on-device after models are installed.
- Generated audio and history stay in local app storage unless you export them.
- Model downloads come from Hugging Face when you install a voice model.
- Voice cloning should only be used with voices you own or have permission to use.

## For Developers

The `main` branch contains the current Vocello codebase. The public beta release is tagged as [`v2.0.0-beta.1`](https://github.com/PowerBeef/QwenVoice/releases/tag/v2.0.0-beta.1).

```sh
git clone https://github.com/PowerBeef/QwenVoice.git
cd QwenVoice
./scripts/regenerate_project.sh
open QwenVoice.xcodeproj
```

Useful checks:

```sh
./scripts/check_project_inputs.sh
./scripts/qa.sh validate
./scripts/qa.sh test --layer contract
./scripts/qa.sh test --layer swift
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
