# QwenVoice For macOS

QwenVoice is a native macOS app for offline Qwen3-TTS on Apple Silicon.

The current public release is the macOS app published from this repository. It supports:

- Custom Voice
- Voice Design
- Voice Cloning

Install the current release from [GitHub Releases](https://github.com/PowerBeef/QwenVoice/releases).

## Current Public Release

- Platform: macOS
- Runtime: native local generation on Apple Silicon
- Distribution: signed and notarized DMG on GitHub Releases

## Requirements

- Apple Silicon Mac
- macOS 26 or newer for the current checkout and maintained release line

## Status

The currently available public product remains the shipped macOS app.

A major internal refactor is underway for the next version. More details will be shared later, but the short version is that QwenVoice is being prepared for a much bigger step forward.

## Maintained Docs

- [AGENTS.md](AGENTS.md)
- [docs/README.md](docs/README.md)
- [docs/reference/current-state.md](docs/reference/current-state.md)
- [docs/reference/engineering-status.md](docs/reference/engineering-status.md)
- [docs/reference/vendoring-runtime.md](docs/reference/vendoring-runtime.md)

## Credits

QwenVoice builds on:

- [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)
- [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift)
- [MLX](https://github.com/ml-explore/mlx)
- [GRDB.swift](https://github.com/groue/GRDB.swift)
