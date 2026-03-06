# QwenVoice Current State

This document is the shared factual reference for the current QwenVoice repository state.

## Product Surface

- App type: native macOS SwiftUI app for Qwen3-TTS on Apple Silicon
- Deployment target: macOS 15+
- Product name: `QwenVoice`
- Version source: `project.yml`
- Current version/build: `1.1.6` / `9`

## Shipped UI

The app currently exposes six sidebar destinations:

1. Custom Voice
2. Voice Cloning
3. History
4. Voices
5. Models
6. Preferences

Voice Design is not a separate sidebar screen. It is accessed inside `CustomVoiceView` by switching to the `Custom` speaker chip, which changes the active generation mode from `.custom` to `.design`.

The shipping SwiftUI app uses non-streaming generation flows. Backend streaming preview and advanced sampling parameters remain available for benchmark/internal tooling only.

## Models, Speakers, and Contract Ownership

Static TTS contract data lives in `Sources/Resources/qwenvoice_contract.json`.

That manifest is the source of truth for:

- model registry
- default speaker
- grouped speakers
- model tier
- output subfolders
- required model files
- Hugging Face repos

Swift and Python both load the same manifest:

- Swift: `Sources/Models/TTSContract.swift` and `Sources/Models/TTSModel.swift`
- Python: `Sources/Resources/backend/server.py`

The shipped app currently exposes three 1.7B models:

- Custom Voice
- Voice Design
- Voice Cloning

The shipped app currently exposes four built-in English speakers:

- `ryan`
- `aiden`
- `serena`
- `vivian`

## Runtime Layout

Default app data lives under:

```text
~/Library/Application Support/QwenVoice/
  models/
  outputs/
    CustomVoice/
    VoiceDesign/
    Clones/
  voices/
  cache/
    normalized_clone_refs/
  history.sqlite
  python/
    .setup-complete
```

If the user sets a custom output directory in Preferences, generated audio may be written outside the default `outputs/` tree.

## Build, Test, and Release

Project source of truth:

- `project.yml` for XcodeGen-managed project structure
- `.github/workflows/project-inputs.yml`
- `.github/workflows/release-dual-ui.yml`

The old single-release workflow is gone. GitHub now exposes:

- one validation workflow (`Project Inputs`)
- one manual dual-release workflow (`Release Dual UI`)

The dual-release workflow builds:

- `QwenVoice-macos26.dmg` for the modern liquid UI profile
- `QwenVoice-macos15.dmg` for the legacy glass UI profile

Local `./scripts/release.sh` still produces `build/QwenVoice.dmg` by default unless an explicit output name is provided.

## Test Inventory

Current tracked test coverage:

- UI tests: 11 `*Tests.swift` files / 31 test methods in `QwenVoiceUITests/`
- Unit tests: 4 `*Tests.swift` files / 14 test methods in `QwenVoiceTests/`
- Python backend tests: 8 `unittest` cases under `backend_tests/`

Primary commands:

- `./scripts/run_tests.sh`
- `./scripts/run_tests.sh --suite ui`
- `./scripts/run_tests.sh --suite integration`
- `./scripts/run_tests.sh --suite debug`
- `./scripts/run_backend_tests.sh`

## Current Documentation Boundaries

- `README.md` is the public GitHub landing page.
- `AGENTS.md`, `CLAUDE.md`, and `GEMINI.md` are repo-operating docs and should stay aligned with this file.
- `cli/README.md` documents the standalone CLI, which has a broader speaker map than the shipped GUI.
