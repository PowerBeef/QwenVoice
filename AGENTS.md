# AGENTS.md

This file applies to the repository at `/Users/patricedery/Coding_Projects/QwenVoice`.

Run repo-level commands from:

```bash
cd /Users/patricedery/Coding_Projects/QwenVoice
```

## Project Summary

QwenVoice is a native macOS SwiftUI app for running Qwen3-TTS locally on Apple Silicon. It uses:

1. a SwiftUI frontend for UI state, downloads, playback, persistence, and setup
2. a long-lived Python backend at `Sources/Resources/backend/server.py` that communicates with Swift over newline-delimited JSON-RPC 2.0 on `stdin`/`stdout`

The app targets macOS 15+, Apple Silicon only, and currently ships six sidebar destinations:

1. Custom Voice
2. Voice Cloning
3. History
4. Voices
5. Models
6. Preferences

Voice Design is currently embedded inside `CustomVoiceView` and is reached by switching to the `Custom` speaker chip.

## Source of Truth

Trust the live code and manifest before prose:

1. `Sources/`
2. `QwenVoiceUITests/`
3. `QwenVoiceTests/`
4. `backend_tests/`
5. `scripts/`
6. `project.yml`
7. prose docs

Shared current repo facts live in [`docs/reference/current-state.md`](docs/reference/current-state.md). Keep this file, `CLAUDE.md`, and `GEMINI.md` aligned with it.

## Documentation Boundaries

- `README.md` is the public GitHub landing page.
- `docs/README.md` is the internal docs index.
- `docs/reference/` holds stable current-state reference docs.
- Generated/vendor docs under `Sources/Resources/python/`, `cli/.venv/`, and dependency package directories are out of scope.

## Core Architecture

### Swift frontend

- `QwenVoiceApp.swift` owns the shared app services and creates the app-support directories.
- `ContentView.swift` hosts the `NavigationSplitView` and routes between the six shipped surfaces.
- `PythonEnvironmentManager` gates launch through `SetupView` until Python is usable.
- `CustomVoiceView` contains both normal Custom Voice and Voice Design behavior.
- `VoiceCloningView` and `CustomVoiceView` can both present `BatchGenerationSheet`.

### Python backend

`server.py` currently handles:

- `ping`
- `init`
- `load_model`
- `unload_model`
- `generate`
- `convert_audio`
- `list_voices`
- `enroll_voice`
- `delete_voice`
- `get_model_info`
- `get_speakers`

The shipping GUI uses non-streaming generation flows. Backend streaming preview and advanced sampling parameters remain benchmark/internal only.
The backend MLX cache policy defaults to `adaptive`. Use `QWENVOICE_CACHE_POLICY=always` only as a conservative diagnostic override.

### Shared contract

Static TTS contract data lives in `Sources/Resources/qwenvoice_contract.json`.

That manifest is the source of truth for:

- model registry
- speakers
- default speaker
- output subfolders
- required model files
- Hugging Face repos

Update the manifest first when models/speakers/tiers/output folders change.

## Runtime Data Layout

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

### Common commands

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

### Current test inventory

- UI tests: 11 files / 31 test methods
- Unit tests: 4 files / 16 test methods
- Python backend tests: 13 `unittest` cases

See [`docs/reference/testing.md`](docs/reference/testing.md) for the current test commands, suites, and caveats.

### Release workflow reality

GitHub Actions currently has:

- `.github/workflows/project-inputs.yml`
- `.github/workflows/release-dual-ui.yml`

The old single-release workflow is gone. The GitHub release workflow builds:

- `QwenVoice-macos26.dmg`
- `QwenVoice-macos15.dmg`

Local `./scripts/release.sh` still produces `build/QwenVoice.dmg` by default unless an explicit output name is provided.

## High-Value Change Patterns

### If you change the RPC contract

Update:

1. `Sources/Resources/backend/server.py`
2. `Sources/Services/PythonBridge.swift`
3. `Sources/Models/RPCMessage.swift` if payload types change
4. affected views, tests, and docs

### If you change models or speakers

Update:

1. `Sources/Resources/qwenvoice_contract.json`
2. Swift or Python consumers that rely on those fields
3. docs/tests that assert current names or counts

### If you add or rename source files

1. update `project.yml` if needed
2. run `./scripts/regenerate_project.sh`
3. verify the generated `.xcodeproj` did not pick up `__pycache__` or `.pyc` paths

## Practical Review Checklist

Before finishing:

1. confirm Swift and Python still agree on any cross-process change
2. keep accessibility identifiers stable or update UI tests in the same change
3. prefer the manifest over duplicated constants
4. prefer `./scripts/regenerate_project.sh` over raw `xcodegen generate`
5. keep `README.md`, `docs/reference/current-state.md`, `CLAUDE.md`, and `GEMINI.md` aligned when broad repo facts change
