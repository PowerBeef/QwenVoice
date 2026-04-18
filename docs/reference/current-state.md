# QwenVoice Current State

This document is the shared factual reference for the current QwenVoice repository state.

## Product Surface

- App type: native macOS SwiftUI app for Qwen3-TTS on Apple Silicon
- Deployment target: macOS 15+
- Product name: `QwenVoice`
- Version source: `project.yml`
- Current version/build: `1.2.3` / `15`

## Shipped UI

The app exposes six sidebar destinations in the main window, plus a dedicated macOS Settings window:

1. Custom Voice
2. Voice Design
3. Voice Cloning
4. History
5. Saved Voices
6. Models

Single-generation flows use live streaming preview for:

- Custom Voice
- Voice Design
- Voice Cloning

Batch generation remains sequential and non-streaming in the shipped GUI even though the native runtime supports homogeneous-by-mode native batches internally.

The app shell and runtime coordination are split across explicit helper components:

- `QwenVoiceApp.swift` composes `AppStartupCoordinator.swift`, `AppCommandRouter.swift`, `GenerationLibraryEvents.swift`, `AppLaunchConfiguration.swift`, and `UITestWindowCoordinator.swift`
- `ContentView.swift` owns the navigation split view, toolbar/search chrome, and persisted generation drafts
- `AppPaths.swift` is the path boundary for app-support, model, output, and voice directories, including `QWENVOICE_APP_SUPPORT_DIR`
- `AppEngineSelection.swift` always selects the native engine for normal runs and can still use `UITestStubMacEngine` during fixture-backed manual desktop-control runs
- `Sources/QwenVoiceNative/` plus `third_party_patches/mlx-audio-swift/` are the native runtime boundary
- shipped app bundles must not include `Contents/Resources/backend/`, `Contents/Resources/python/`, or bundled `Contents/Resources/ffmpeg`

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

Swift loads that manifest through:

- `Sources/Models/TTSContract.swift`
- `Sources/Models/TTSModel.swift`

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
    stream_sessions/
  history.sqlite
```

If the user sets a custom output directory in Preferences, generated audio may be written outside the default `outputs/` tree.

Saved-voice native clone preparation may also persist prepared prompt artifacts under `voices/<voiceID>.clone_prompt/<modelID>/` after the prompt is built successfully.

## Build, Test, and Release

Project and workflow source of truth:

- `project.yml` for XcodeGen-managed project structure
- `.github/workflows/project-inputs.yml`
- `.github/workflows/test-suite.yml`
- `.github/workflows/release-dual-ui.yml`

The active GitHub workflows are:

- `Project Inputs` for checked-in project and native app resource validation
- `Test Suite` for unit, contract, native runtime, strict-concurrency, packaged-build, and alternate-profile compile coverage
- `Release Dual UI` for building, signing, notarizing, and optionally publishing the two shipped DMGs

The dual-release workflow builds:

- `QwenVoice-macos26.dmg` for the modern liquid UI profile
- `QwenVoice-macos15.dmg` for the legacy glass UI profile

Key local checks:

```sh
./scripts/check_project_inputs.sh
python3 scripts/harness.py validate
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer native
```

`QWENVOICE_ENABLE_NATIVE_ENGINE_LIVE_TESTS=1` enables the opt-in `NativeMLXMacEngineLiveTests` smoke against an installed `pro_custom` model.

The repo no longer keeps maintained automated XCUI `ui`, `design`, or `perf` lanes. Visual and interaction truth comes from local Codex Computer Use passes after the cheap source gates are green.

## Current Documentation Boundaries

- `AGENTS.md` is the primary repo-operating guide for agents and maintainers.
- `docs/README.md` is the index of the maintained documentation set.
- `docs/reference/current-state.md`, `docs/reference/engineering-status.md`, and `docs/reference/vendoring-runtime.md` are the maintained reference docs.
- `README.md` is the public GitHub landing page.
- `qwen_tone.md` is a supplemental guidance doc, not a maintained reference doc.
