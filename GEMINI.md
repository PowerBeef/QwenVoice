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
- [`AGENTS.md`](AGENTS.md) for the detailed Codex skill and MCP routing used in this repository

This file is intentionally short so repo facts do not drift across multiple assistant guides.

## Project Summary

QwenVoice is a native macOS SwiftUI app for running Qwen3-TTS locally on Apple Silicon (targeting macOS 15+).

- Swift frontend manages UI, downloads, playback, persistence, and setup
- Python backend (`Sources/Resources/backend/server.py`) handles MLX inference over JSON-RPC 2.0
- Static contract data comes from `Sources/Resources/qwenvoice_contract.json`

The shipped UI currently includes six main-window destinations plus a dedicated Settings window:

1. Custom Voice
2. Voice Design
3. Voice Cloning
4. History
5. Voices
6. Models

Voice Design is a standalone generation destination backed by `VoiceDesignView`. `CustomVoiceView` owns preset-speaker generation.

## Commands

```bash
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice clean build
./scripts/regenerate_project.sh
./scripts/check_project_inputs.sh
./scripts/run_tests.sh
./scripts/run_tests.sh --suite smoke
./scripts/run_tests.sh --suite ui
./scripts/run_tests.sh --suite integration
./scripts/run_tests.sh --suite all
./scripts/run_tests.sh --suite debug
./scripts/run_tests.sh --suite feature-matrix
./scripts/run_tests.sh --list
./scripts/run_tests.sh --class SidebarNavigation
./scripts/run_tests.sh --test CustomVoiceViewTests/testCustomVoiceScreenCoreLayout
./scripts/run_backend_tests.sh
./scripts/run_full_app_automation.sh
./scripts/release.sh
```

## Current Repo Reality

- The shipping app exposes live streaming preview for single-generation flows. The GUI still does not expose temperature/max-token controls.
- Batch generation remains sequential/non-streaming in the GUI; backend advanced sampling and internal batch paths remain benchmark/internal only.
- The backend MLX cache policy defaults to `adaptive`; use `QWENVOICE_CACHE_POLICY=always` only for conservative diagnostics.
- Interactive latency measurement now uses Instruments signposts around model load, first streamed chunk, final file readiness, and autoplay start. Idle model warm-up uses a separate `prewarm_model` RPC.
- The repo now has UI tests, Swift unit tests, and Python backend tests. Use `QWENVOICE_UI_TEST_BACKEND_MODE=stub` for synthetic UI testing.
- GitHub Actions now uses the dual-release workflow only (`.github/workflows/release-dual-ui.yml`).
- Local release packaging and GitHub release artifact names differ; do not assume every DMG is named `QwenVoice.dmg` (dual workflow builds `macos26` and `macos15` dmgs).

## Editing Reminders

- Prefer `project.yml` over the generated `.xcodeproj`. Always use `./scripts/regenerate_project.sh`.
- Prefer the manifest over duplicated model/speaker metadata.
- Keep `README.md`, `docs/reference/current-state.md`, `AGENTS.md`, and `GEMINI.md` aligned when making broad repo changes.
