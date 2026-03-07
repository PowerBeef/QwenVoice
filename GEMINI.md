# GEMINI.md

This file gives Gemini-oriented guidance for working in the QwenVoice repository.

Repo root:

```bash
cd /Users/patricedery/Coding_Projects/QwenVoice
```

## Shared Reference

Use these files as the factual baseline for repo state:

- [`docs/reference/current-state.md`](docs/reference/current-state.md)
- [`docs/reference/testing.md`](docs/reference/testing.md)
- [`docs/reference/engineering-status.md`](docs/reference/engineering-status.md)

This file is intentionally short so repo facts do not drift across multiple assistant guides.

## Project Summary

QwenVoice is a native macOS SwiftUI app for running Qwen3-TTS locally on Apple Silicon.

- Swift frontend manages UI, downloads, playback, persistence, and setup
- Python backend (`Sources/Resources/backend/server.py`) handles MLX inference over JSON-RPC 2.0
- Static contract data comes from `Sources/Resources/qwenvoice_contract.json`

The shipped UI currently includes six destinations:

1. Custom Voice
2. Voice Cloning
3. History
4. Voices
5. Models
6. Preferences

Voice Design remains embedded inside `CustomVoiceView`.

## Commands

```bash
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build
./scripts/regenerate_project.sh
./scripts/check_project_inputs.sh
./scripts/run_tests.sh
./scripts/run_tests.sh --suite ui
./scripts/run_backend_tests.sh
./scripts/release.sh
```

## Current Repo Reality

- The shipping app does not expose streaming preview or temperature/max-token controls.
- Backend streaming and advanced sampling parameters remain benchmark/internal only.
- The backend MLX cache policy defaults to `adaptive`; use `QWENVOICE_CACHE_POLICY=always` only for conservative diagnostics.
- The repo now has UI tests, Swift unit tests, and Python backend tests.
- GitHub Actions now uses the dual-release workflow only.
- Local release packaging and GitHub release artifact names differ; do not assume every DMG is named `QwenVoice.dmg`.

## Editing Reminders

- Prefer `project.yml` over the generated `.xcodeproj`.
- Prefer the manifest over duplicated model/speaker metadata.
- Keep README and the shared docs/reference files aligned when making broad repo changes.
