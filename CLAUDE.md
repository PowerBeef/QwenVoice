# CLAUDE.md

This file gives Claude-oriented guidance for working in the QwenVoice repository.

Repo root:

```bash
cd /Users/patricedery/Coding_Projects/QwenVoice
```

## Start Here

Current repo facts are centralized in:

- [`docs/reference/current-state.md`](docs/reference/current-state.md)
- [`docs/reference/testing.md`](docs/reference/testing.md)
- [`docs/reference/engineering-status.md`](docs/reference/engineering-status.md)

Use those files as the shared factual baseline instead of duplicating repo state here.

## Repo Summary

QwenVoice is a native macOS SwiftUI app for local Qwen3-TTS on Apple Silicon.

- SwiftUI frontend owns UI, downloads, playback, persistence, and setup
- Python backend at `Sources/Resources/backend/server.py` owns MLX inference
- Swift/Python static contract data is shared through `Sources/Resources/qwenvoice_contract.json`

The shipping app currently exposes:

1. Custom Voice
2. Voice Cloning
3. History
4. Voices
5. Models
6. Preferences

Voice Design currently lives inside `CustomVoiceView` behind the `Custom` speaker chip.

## Commands

```bash
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice clean build
./scripts/regenerate_project.sh
./scripts/check_project_inputs.sh
./scripts/run_tests.sh
./scripts/run_tests.sh --suite ui
./scripts/run_tests.sh --suite integration
./scripts/run_tests.sh --suite debug
./scripts/run_backend_tests.sh
./scripts/release.sh
```

## Important Reality Checks

- The GitHub single-release workflow is gone; only `project-inputs.yml` and `release-dual-ui.yml` remain.
- The shipping GUI uses live streaming preview for single-generation paths; batch remains sequential and non-streaming.
- Backend advanced sampling parameters and internal batch/benchmark paths remain benchmark/internal only.
- The backend MLX cache policy defaults to `adaptive`; use `QWENVOICE_CACHE_POLICY=always` only for conservative diagnostics.
- Local `./scripts/release.sh` produces `build/QwenVoice.dmg` by default; GitHub dual-release builds produce `QwenVoice-macos26.dmg` and `QwenVoice-macos15.dmg`.
- Current test inventory is no longer UI-only; the repo also has `QwenVoiceTests/` and `backend_tests/`.

## Editing Guidance

- Trust `project.yml` over the generated `.xcodeproj`.
- Prefer `./scripts/regenerate_project.sh` over raw `xcodegen generate`.
- If models, speakers, tiers, required files, or output folders change, update `Sources/Resources/qwenvoice_contract.json` first.
- If an RPC method changes, update Swift, Python, tests, and docs together.
