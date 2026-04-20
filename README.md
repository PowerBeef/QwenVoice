<p align="center">
  <img src="docs/readme_banner_vocello.png" alt="Vocello banner" width="100%">
</p>

# Vocello

Vocello is a native macOS app for creating voices locally on Apple Silicon. It brings Qwen3-TTS into a polished desktop workflow for Custom Voice, Voice Design, and Voice Cloning, with generation that stays on your machine instead of disappearing into a remote service.

If you care about privacy, creative control, and a tool that feels at home on the Mac, Vocello is built for exactly that.

## Why Vocello

- Your work stays local. Vocello is built for offline voice creation on Apple Silicon, so generation happens on your Mac.
- It feels like a real app, not a research demo. The goal is a focused desktop tool you can actually build with.
- The workflow is unified. Designing a voice, refining a voice, and cloning a voice all live in one place.

## What You Can Do

- **Custom Voice**: shape reusable voices with a workflow built for iteration, not just one-off outputs.
- **Voice Design**: guide tone, character, and style to create voices that feel intentional.
- **Voice Cloning**: build from a reference voice while keeping the rest of the process inside the same local app.
- **Local generation and export**: generate on macOS, keep your outputs on disk, and work without a repo-owned backend service.

## Available Today

- Public release platform: macOS
- Runtime: Apple Silicon native, offline local generation
- Distribution: signed and notarized DMG on GitHub Releases
- iPhone support: active in the codebase, but not part of the current public release milestone

## Install Vocello

Download the current macOS release from [GitHub Releases](https://github.com/PowerBeef/QwenVoice/releases).

Vocello is currently focused on making the shared core rock-solid on Mac first, which is why the public release is macOS-only right now.

Requirements:

- Apple Silicon Mac
- macOS 26 or newer for the current checkout and maintained release line

## Why macOS First

Vocello is available on macOS today, and the current release cycle is intentionally focused on making the new shared core stable, fast, and dependable on one platform before widening the release surface again.

The repository still carries the `QwenVoice` name for technical continuity, while the product people download and use is `Vocello`. iPhone support remains in active development inside the repo, but the public release path is centered on macOS for now.

## Built On

Vocello builds on:

- [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)
- [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift)
- [MLX](https://github.com/ml-explore/mlx)
- [GRDB.swift](https://github.com/groue/GRDB.swift)

## For Contributors

- [AGENTS.md](AGENTS.md)
- [docs/README.md](docs/README.md)
- [docs/reference/current-state.md](docs/reference/current-state.md)
- [docs/reference/engineering-status.md](docs/reference/engineering-status.md)
- [docs/reference/release-readiness.md](docs/reference/release-readiness.md)
- [docs/reference/vendoring-runtime.md](docs/reference/vendoring-runtime.md)
