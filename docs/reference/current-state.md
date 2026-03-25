# QwenVoice Current State

This document is the shared factual reference for the current QwenVoice repository state.

## Product Surface

- App type: native macOS SwiftUI app for Qwen3-TTS on Apple Silicon
- Deployment target: macOS 15+
- Product name: `QwenVoice`
- Version source: `project.yml`
- Current version/build: `1.1.7` / `10`

## Shipped UI

The app currently exposes six sidebar destinations in the main window, plus a dedicated macOS Settings window:

1. Custom Voice
2. Voice Design
3. Voice Cloning
4. History
5. Saved Voices
6. Models
Voice Design now has its own sidebar destination and screen (`VoiceDesignView`) alongside `CustomVoiceView` and `VoiceCloningView`. `ContentView` owns persisted generation drafts above the individual screens so Custom Voice, Voice Design, and Voice Cloning preserve authored inputs while the inactive views themselves can unmount across sidebar navigation. `PreferencesView` now lives in the app's `Settings` scene instead of the main sidebar.

The shipping SwiftUI app uses live streaming preview for single-generation flows:

- Custom Voice
- Voice Design
- Voice Cloning

Batch generation remains sequential and non-streaming in the shipped GUI. Advanced sampling parameters remain available for benchmark/internal tooling only.

The backend MLX cache policy currently defaults to `adaptive` via `QWENVOICE_CACHE_POLICY`. Set `QWENVOICE_CACHE_POLICY=always` only for conservative diagnostics or regression comparison runs.

Interactive latency instrumentation now uses Instruments-native signposts around model load, first streamed chunk, final file readiness, and autoplay start. Idle model warm-up is handled through a dedicated `prewarm_model` backend RPC instead of being folded into `load_model`.

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

The UI-oriented harness layers (`test --layer ui`, `design`, and `perf`) now default to live backend mode with an isolated app-support fixture. Those runs reuse the installed runtime and models from `~/Library/Application Support/QwenVoice/`, but keep writable outputs, cache, defaults, and copied library state inside the disposable fixture root. In live UI test mode, readiness means the main window is mounted, the environment is ready, and the backend initialization handshake has completed.

## Current Documentation Boundaries

- `README.md` is the public GitHub landing page.
- `CLAUDE.md` is the repo-operating doc and should stay aligned with this file.
- `cli/README.md` documents the standalone CLI, which has a broader speaker map than the shipped GUI.
