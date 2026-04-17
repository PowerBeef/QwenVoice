# QwenVoice Current State

This document is the shared factual reference for the current QwenVoice repository state.

## Product Surface

- App type: native macOS SwiftUI app for Qwen3-TTS on Apple Silicon
- Deployment target: macOS 15+
- Product name: `QwenVoice`
- Version source: `project.yml`
- Current version/build: `1.2.3` / `15`

## Shipped UI

The app currently exposes six sidebar destinations in the main window, plus a dedicated macOS Settings window:

1. Custom Voice
2. Voice Design
3. Voice Cloning
4. History
5. Saved Voices
6. Models

Voice Design has its own sidebar destination and screen (`VoiceDesignView`) alongside `CustomVoiceView` and `VoiceCloningView`. `ContentView` owns persisted generation drafts above the individual screens so Custom Voice, Voice Design, and Voice Cloning preserve authored inputs while inactive views can unmount across sidebar navigation. `PreferencesView` lives in the app's `Settings` scene instead of the main sidebar.

The shipping SwiftUI app uses live streaming preview for single-generation flows:

- Custom Voice
- Voice Design
- Voice Cloning

Batch generation remains sequential and non-streaming in the shipped GUI even though the native engine now supports homogeneous-by-mode Custom Voice, Voice Design, and Voice Cloning batches internally. Mixed-mode native batches are rejected explicitly. Advanced sampling parameters remain available for benchmark and internal tooling only.

The backend MLX cache policy currently defaults to `adaptive` via `QWENVOICE_CACHE_POLICY`. Set `QWENVOICE_CACHE_POLICY=always` only for conservative diagnostics or regression comparison runs.

Interactive latency instrumentation uses Instruments-native signposts around model load, first streamed chunk, final file readiness, and autoplay start. Idle model warm-up is handled through a dedicated `prewarm_model` backend RPC instead of being folded into `load_model`.

The app shell and runtime coordination are split across explicit helper components instead of living inline in the largest entrypoints:

- `QwenVoiceApp.swift` composes `AppStartupCoordinator.swift`, `BackendLaunchCoordinator.swift`, `AppCommandRouter.swift`, and `GenerationLibraryEvents.swift`, while `AppLaunchConfiguration.swift` and `UITestWindowCoordinator.swift` own UI-test launch flags and window automation details
- UI-test launches now opt out of AppKit state restoration so harness stub/live runs deterministically create a fresh main window instead of depending on persisted window state
- `AppPaths.swift` is the path boundary for app-support, model, output, and voice directories, including the `QWENVOICE_APP_SUPPORT_DIR` override used by fixture-backed UI runs
- `PythonEnvironmentManager.swift` is the published-state façade over `PythonRuntimeDiscovery.swift`, `PythonRuntimeProvisioner.swift`, `RequirementsInstaller.swift`, `PythonRuntimeValidator.swift`, and `EnvironmentSetupStateMachine.swift`
- `PythonBridge.swift` composes `PythonProcessManager.swift`, `PythonJSONRPCTransport.swift`, `GenerationStreamCoordinator.swift`, `ModelLoadCoordinator.swift`, `ClonePreparationCoordinator.swift`, `PythonBridgeActivityCoordinator.swift`, `PythonBridge+GenerationFlows.swift`, and `StubBackendTransport.swift`
- `Sources/QwenVoiceNative/` now builds against the repo-owned local Swift package at `third_party_patches/mlx-audio-swift/`, alongside `MLXSwift` and `SwiftHuggingFace`, for native backend runtime and synthesis work
- `AppEngineSelection.swift` now defaults the app-facing `TTSEngineStore` engine to `NativeMLXMacEngine` for normal runs, keeps `QWENVOICE_APP_ENGINE=python` as the rollback path, and forces the adapter-backed engine path during stub UI harness runs so fixture-backed preview events remain deterministic
- Native app-engine support now covers Custom Voice, Voice Design, and Voice Cloning generation, along with truthful clone priming and homogeneous-by-mode native batch execution behind the stable `MacTTSEngine` / `TTSEngineStore` boundary
- `Sources/Resources/backend/server.py` is the Python wiring layer over `backend_state.py`, `rpc_transport.py`, `output_paths.py`, `audio_io.py`, `clone_context.py`, `generation_pipeline.py`, and `rpc_handlers.py`
- `TestStateServer.swift` and `TestStateProvider.swift` provide the localhost HTTP state-query boundary used by UI automation and screenshot capture flows
- Shipped app bundles treat `Contents/Resources/backend/` as the canonical production Python backend directory. `server_compat.py` remains harness-only and must not ship in app bundles or release artifacts.

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
    stream_sessions/
  history.sqlite
  python/
    .setup-complete
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

- `Project Inputs` for checked-in project and backend resource validation
- `Test Suite` for unit, contract, pipeline, server, audio, packaged-build, runtime-parity, UI smoke, perf, strict-concurrency, and alternate-profile compile coverage
- `Release Dual UI` for building, signing, notarizing, and optionally publishing the two shipped DMGs

The dual-release workflow builds:

- `QwenVoice-macos26.dmg` for the modern liquid UI profile
- `QwenVoice-macos15.dmg` for the legacy glass UI profile

`Release Dual UI` currently has three stages:

- `build-release`
- `notarize-release`
- `publish-release`

Intermediate artifacts are uploaded as `qwenvoice-dual-ui-build-<run-number>-<variant>[-label]`. The final notarized artifact bundle is uploaded as `qwenvoice-dual-ui-<run-number>-final[-label]` and is the preferred source for downloaded release validation.

Those two shipped release artifacts are workflow-built outputs. The GitHub workflow is also the intended source of truth for Developer ID signing and DMG notarization and stapling on both runners. QwenVoice prefers App Store Connect API key auth for notarization, with `issuer` included for Team keys and omitted for Individual keys. Local builds on the maintainer machine are for macOS 26 dev and testing only, not authoritative release proof for either variant.

Local `./scripts/release.sh` still produces `build/QwenVoice.dmg` by default unless an explicit output name is provided, but local packaging should be treated as script and runtime validation rather than the source of truth for shipped release artifacts.

`./scripts/check_project_inputs.sh` validates that the checked-in Xcode project has not captured `__pycache__` or `.pyc` references and that the backend resource contract remains clean.

`project.yml` now carries both runtime vendoring surfaces:

- the Python-side `third_party_patches/mlx-audio/` helper overlay flow
- the native backend `third_party_patches/mlx-audio-swift/` local package consumed by `QwenVoiceNative`

`QWENVOICE_APP_ENGINE=native|python` is the internal app-engine override. Normal app launches now default to `native`, while `python` remains the rollback path.

`QWENVOICE_ENABLE_NATIVE_ENGINE_LIVE_TESTS=1` enables the opt-in `NativeMLXMacEngineLiveTests` smoke against an installed `pro_custom` model.

`python3 scripts/harness.py test --layer all` runs the normal combined source layers (`pipeline`, `server`, `contract`, `rpc`, `swift`, `audio`) and excludes `ui`, `design`, `perf`, and `release`.

The UI-oriented harness layers (`test --layer ui`, `design`, and `perf`) default to live backend mode with an isolated app-support fixture. Those runs reuse the installed runtime and models from `~/Library/Application Support/QwenVoice/`, but keep writable outputs, cache, defaults, and copied library state inside the disposable fixture root. In live UI test mode, readiness means the main window is mounted, the environment is ready, and the backend initialization handshake has completed.

CI still uses stub mode for the UI smoke lane and macOS 26 screenshot-capture smoke when it does not need live model coverage. Stub mode deliberately keeps the adapter-backed engine path even if `QWENVOICE_APP_ENGINE=native` is set, because the stub harness assertions depend on deterministic Python-adapter preview events rather than real native synthesis.

`QWENVOICE_UI_TEST_APPEARANCE=light|dark|system` is the supported appearance override for UI and design harness runs. When appearance is forced away from `system`, `python3 scripts/harness.py test --layer design` resolves baselines from `tests/screenshots/baselines/<appearance>/` so light and dark visual regressions can be tracked independently. The repo also keeps shared fallback baselines under `tests/screenshots/baselines/` for system and default comparisons. Run the forced `light` and `dark` design lanes sequentially, not in parallel, because they share the same UI app and test transport.

Screenshot-based harness runs default to permissionless in-app window-content capture via `QWENVOICE_UITEST_CAPTURE_MODE=content`. That is the normal automated comparison path, but it is not the highest-fidelity view of Liquid Glass. For explicit appearance-polish or visual-fidelity checks, use real window capture instead of treating `content` capture as the source of truth. The legacy system capture path remains available only as an explicit opt-in with `QWENVOICE_UITEST_CAPTURE_MODE=system`; true pre-approval for that macOS permission requires device-management and PPPC policy, not an app-side setting.

Maintainer and agent workflows remain harness-first. Repo scripts, targeted harness lanes, and `xcodebuild` are the source of truth for validation; desktop-native tools are secondary aids for UI- and interaction-specific investigation. When a session exposes macOS automation or visual tooling, prefer structured app orchestration for launch and focus control, and treat generated mockups or diagrams as communication aids rather than validation evidence.

On the maintainer machine, validation is intentionally low-RAM and serialized: run one heavy validation job at a time, start with cheap source gates before live or packaged proof, and treat live native smoke plus packaged/release validation as later-stage confirmation rather than default first steps.

## Current Documentation Boundaries

- `AGENTS.md` is the primary repo-operating guide for agents and maintainers.
- `docs/README.md` is the index of the maintained documentation set.
- `docs/reference/current-state.md`, `docs/reference/engineering-status.md`, and `docs/reference/vendoring-runtime.md` are the maintained reference docs.
- `README.md` is the public GitHub landing page.
- `cli/README.md` documents the standalone CLI, which has a broader speaker map than the shipped GUI.

The maintained docs in this checkout are the files listed above. Do not assume older supplementary docs still exist.
