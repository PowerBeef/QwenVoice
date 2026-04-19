# QwenVoice Current State

This document is the shared factual reference for the current QwenVoice repository state.

## Product Surface

- App type: native macOS SwiftUI app for Qwen3-TTS on Apple Silicon
- Deployment target: macOS 15+
- Product name: `QwenVoice`
- Version source: `project.yml`
- Current version/build: `1.2.3` / `15`
- Supported acquisition path in maintained docs: source build from this checkout

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
- `Sources/QwenVoiceNative/` is the app-facing engine layer: `TTSEngineStore`, `XPCNativeEngineClient`, and chunk-broker coordination live there
- `Sources/QwenVoiceEngineSupport/` defines the shared engine IPC, request/reply envelopes, and transport-facing types
- `Sources/QwenVoiceNativeRuntime/` owns service-only native execution, model load, generation, and clone preparation
- `Sources/QwenVoiceEngineService/` is the bundled XPC helper entrypoint embedded into the shipped app
- `third_party_patches/mlx-audio-swift/` remains the vendored MLXAudioSwift source boundary used by the service/runtime side
- local source builds still produce an app bundle embedding `Contents/XPCServices/QwenVoiceEngineService.xpc`

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

## Build And Test

Project and local automation source of truth:

- `project.yml` for XcodeGen-managed project structure
- `scripts/check_project_inputs.sh`
- `scripts/harness.py`

There are currently no active GitHub Actions workflows in this checkout.

Key local checks:

```sh
./scripts/check_project_inputs.sh
python3 scripts/harness.py validate
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer native
```

`QWENVOICE_ENABLE_NATIVE_ENGINE_LIVE_TESTS=1` enables the opt-in `NativeMLXMacEngineLiveTests` smoke against an installed `pro_custom` model.

The repo no longer keeps maintained automated XCUI `ui`, `design`, `perf`, or packaged-release lanes. Visual and interaction truth comes from local Codex Computer Use passes after the cheap source gates are green.

## Distribution

- Maintained docs present QwenVoice as a source-build-only project.
- This checkout does not maintain hosted DMG distribution or GitHub Actions release automation.
- Historical release notes remain under `docs/releases/` as past records, not as the current supported distribution path.

## Current Documentation Boundaries

- `AGENTS.md` is the primary repo-operating guide for agents and maintainers.
- `docs/README.md` is the index of the maintained documentation set.
- `docs/reference/current-state.md`, `docs/reference/engineering-status.md`, and `docs/reference/vendoring-runtime.md` are the maintained reference docs.
- `README.md` is the public GitHub landing page.
- `qwen_tone.md` is a supplemental guidance doc, not a maintained reference doc.
