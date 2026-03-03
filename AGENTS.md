# AGENTS.md

## Scope

This file applies to the project repository at `/Users/patricedery/Coding_Projects/QwenVoice`.

Run repo-level commands from this directory:

```bash
cd /Users/patricedery/Coding_Projects/QwenVoice
```

## Project Summary

Qwen Voice is a native macOS SwiftUI app for running Qwen3-TTS locally on Apple Silicon. The app is split into:

1. A SwiftUI frontend that owns UI state, model downloads, playback, local persistence, and setup UX.
2. A long-lived Python backend (`Sources/Resources/backend/server.py`) that runs MLX inference and communicates with Swift over newline-delimited JSON-RPC 2.0 on `stdin`/`stdout`.

The app targets macOS 14+, Apple Silicon only, and uses Swift 5.9.

The current shipped UI exposes six sidebar surfaces:

1. Custom Voice
2. Voice Cloning
3. History
4. Voices
5. Models
6. Preferences

There is no standalone Voice Design screen. Voice Design is currently reached inside `CustomVoiceView` by switching to the "Custom" speaker chip, which flips the active generation mode from `.custom` to `.design`.

## Source Of Truth

Trust the code first, then `project.yml`, then scripts/docs.

When there is drift, prefer these sources in this order:

1. `Sources/`
2. `QwenVoiceUITests/`
3. `scripts/`
4. `project.yml`
5. prose docs (`README.md`, `CLAUDE.md`, `GEMINI.md`)

Important drift that exists right now:

- The checked-in `.xcodeproj` and `project.yml` still disagree on asset catalog wiring.
- Older notes may still describe Voice Design as its own screen, but it is currently folded into `CustomVoiceView`.
- Older notes may still say `autoPlay` and `outputDirectory` are UI-only, but the live code now uses both settings.
- Older notes may still describe a bottom playback bar, but the live player is the sidebar inset (`SidebarPlayerView`).
- `Sources/Resources/python/` is a generated bundled runtime artifact, not the primary source of truth for dependency intent.

When in doubt, verify behavior directly in code before trusting prose.

## Repository Layout

### App code

- `Sources/QwenVoiceApp.swift`: app entry point, environment bootstrapping, app support directory creation, backend startup, app-level commands.
- `Sources/ContentView.swift`: root `NavigationSplitView`, sidebar routing, detail view switching.
- `Sources/Models/`: shared model types (`TTSModel`, `Generation`, `Voice`, `RPCMessage`, `EmotionPreset`).
- `Sources/Services/`: backend bridge, Python environment setup, downloads, database, audio, waveform.
- `Sources/ViewModels/`: `ModelManagerViewModel`, `AudioPlayerViewModel`.
- `Sources/Views/`: setup flow, generation flows, library views, settings, and shared components.
- `Sources/Resources/backend/server.py`: Python JSON-RPC server.
- `Sources/Resources/requirements.txt`: GUI app/backend Python dependencies. This is the dependency file that drives setup hashing.
- `Sources/Resources/vendor/`: vendored wheels for faster/offline setup. The app currently vendors a repacked `mlx_audio-0.3.1.post1` wheel with the QwenVoice speed patch included.
- `Sources/Resources/python/`: checked-in bundled Python runtime used for release packaging. Treat this as a generated artifact, not hand-edited source.

### Tests

- `QwenVoiceUITests/`: macOS XCUITests. Current snapshot is 9 `*Tests.swift` files plus `QwenVoiceUITestBase.swift`.
- `GenerationFlowTests.swift` is the only integration-style end-to-end UI generation test; it skips when required models/backend state are unavailable.

### Build and release

- `project.yml`: XcodeGen source of truth. Prefer editing this over the generated `.xcodeproj`.
- `QwenVoice.xcodeproj/`: generated project; do not hand-edit unless you are intentionally repairing generated output.
- `scripts/`: build, test, bundling, release, benchmark, and utility scripts.

### Secondary CLI

- `cli/`: standalone Python CLI workflow. Useful for manual backend experiments and dependency comparison, but it is not the source of truth for the shipped app UX.

## Architecture

### Swift frontend

The Swift app is state-driven and environment-object based:

- `QwenVoiceApp` owns `PythonBridge`, `AudioPlayerViewModel`, `PythonEnvironmentManager`, and `ModelManagerViewModel`.
- `PythonEnvironmentManager` gates app launch through `SetupView` until Python is usable.
- Once ready, `ContentView` routes between `CustomVoiceView`, `VoiceCloningView`, `HistoryView`, `VoicesView`, `ModelsView`, and `PreferencesView`.
- `CustomVoiceView` contains both the normal Custom Voice path and the Voice Design path. The `isCustomSpeaker` toggle determines whether the active mode is `.custom` or `.design`.
- Both generation screens can open `BatchGenerationSheet`.

The UI currently follows a consistent design language:

- `AppTheme` centralizes accent colors, glass styling, the animated aurora background, and shared button/chip styles.
- `glassCard()` is the standard card treatment.
- `contentColumn()` constrains primary content to `LayoutConstants.contentMaxWidth` (currently 700).
- `TextInputView` is the shared prompt input for generation screens.
- The persistent playback UI is `SidebarPlayerView`, rendered inside the sidebar safe-area inset.
- Backend state, progress, and error/crash messaging are surfaced through `SidebarStatusView`.

### Python backend

`server.py` handles:

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

Important backend traits:

- Only one model is kept in memory at a time.
- MLX imports are lazy (`_ensure_mlx()`).
- GPU cache is explicitly cleared after requests (`_mx.clear_cache()` / `POST_REQUEST_CACHE_CLEAR`).
- Voice names are sanitized before file writes/deletes.
- Model folders may be resolved through Hugging Face `snapshots/` subdirectories (`get_smart_path`).
- Clone reference audio is normalized into a persistent cache under `cache/normalized_clone_refs`.
- Prepared clone context is cached in a bounded in-memory LRU (`CLONE_CONTEXT_CACHE_CAPACITY`).
- `generate` supports streaming preview notifications (`generation_chunk`) for custom/design requests and optional benchmark timing payloads.

Current backend/frontend reality:

- `convert_audio` and `get_speakers` are implemented on the backend, but the shipping Swift UI does not currently call them.
- `PythonBridge` already has streaming generation helpers, but the current SwiftUI views use the non-streaming generation methods.

### Swift/Python contract

If you change any RPC shape or backend behavior, update both sides:

1. `Sources/Resources/backend/server.py`
2. `Sources/Services/PythonBridge.swift`
3. `Sources/Models/RPCMessage.swift` if new data types are needed
4. Any affected views/view models/tests

Also keep model definitions mirrored across:

1. `Sources/Models/TTSModel.swift`
2. `Sources/Resources/backend/server.py` (`MODELS`)

Speaker definitions are also effectively mirrored today:

1. `Sources/Models/TTSModel.swift` (`TTSModel.speakers`)
2. `Sources/Resources/backend/server.py` (`SPEAKER_MAP`)

The Swift UI does not currently fetch speakers from `get_speakers`, so changing only the backend speaker map will not update the picker.

## Runtime Data Layout

The app writes under:

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

Key implications:

- `history.sqlite` is managed by `DatabaseService`.
- `cache/normalized_clone_refs/` persists normalized clone reference WAVs for reuse.
- The `python/` directory is only used for the app-support virtualenv path (primarily development or non-bundled runtime setups).
- In packaged builds, `PythonEnvironmentManager` prefers the bundled runtime in app resources (`python/bin/python3`) and does not rely on the app-support venv.
- The `.setup-complete` marker stores a SHA-256 of `Sources/Resources/requirements.txt` when the app-support venv path is used.
- If the user sets a custom output directory in Preferences, generated audio may be written outside `~/Library/Application Support/QwenVoice/outputs/`, even though the default folders are still pre-created there on launch.

## Build, Test, And Release

Run all commands from `/Users/patricedery/Coding_Projects/QwenVoice`.

### Common commands

```bash
# Build
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build

# Clean build
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice clean build

# Safe project regeneration (preferred over raw xcodegen)
./scripts/regenerate_project.sh

# Run default smoke UI suite
./scripts/run_tests.sh

# Run a named suite
./scripts/run_tests.sh --suite smoke
./scripts/run_tests.sh --suite ui
./scripts/run_tests.sh --suite integration
./scripts/run_tests.sh --suite all
./scripts/run_tests.sh --suite debug

# List test classes
./scripts/run_tests.sh --list

# Run one test class
./scripts/run_tests.sh --class SidebarNavigation

# Run one test method
./scripts/run_tests.sh --test CustomVoiceViewTests/testCustomVoiceScreenCoreLayout

# Run a probe
./scripts/run_tests.sh --probe launch-speed
./scripts/run_tests.sh --probe generation-benchmark

# Release build + DMG
./scripts/release.sh
```

### Test runner behavior

- `scripts/run_tests.sh` defaults to the `smoke` suite.
- It caches `xcodebuild build-for-testing` output under `build/test/` and reuses it when the source fingerprint is unchanged.
- `--probe generation-benchmark` delegates to `scripts/run_generation_benchmark.sh`.

### XcodeGen rule

Use `./scripts/regenerate_project.sh`, not bare `xcodegen generate`, because XcodeGen overwrites `Sources/QwenVoice.entitlements` and the script restores it.

### Release packaging rule

`scripts/release.sh` currently:

1. Bundles Python with `bundle_python.sh` unless `--skip-deps` is used.
2. Bundles `ffmpeg` with `bundle_ffmpeg.sh` unless `--skip-deps` is used.
3. Regenerates the Xcode project.
4. Builds the Release app.
5. Copies the built `.app` from DerivedData into `build/`.
6. Injects `Sources/Resources/python` and `Sources/Resources/ffmpeg` into the built `.app` because those paths are excluded from the normal Xcode resource phase.
7. Removes `vendor`, `__pycache__`, `.pyc`, and `.whl` artifacts from the packaged app resources.
8. Verifies the bundle and creates the DMG.

## Current Implementation Conventions

### UI and accessibility

- Maintain `accessibilityIdentifier` coverage for interactive UI and primary assertions.
- Current naming convention is `"{viewScope}_{elementName}"` (for example `customVoice_title`, `models_download_pro_custom`, `sidebar_backendStatus`).
- Root screen identifiers follow `screen_*`.
- Sidebar items follow `sidebar_*`.
- If you rename identifiers, update the XCUITests in the same change.

### Generation flow

- The generate views and `BatchGenerationSheet` always call `pythonBridge.loadModel(id:)` before generating.
- Successful generations are immediately persisted through `DatabaseService.shared.saveGeneration`.
- Successful generations post `Notification.Name.generationSaved`, and `HistoryView` reloads from that notification.
- Successful single-item generations only auto-play when `AudioService.shouldAutoPlay` is true.
- `BatchGenerationSheet` does not auto-play results.

Current mode routing details:

- `CustomVoiceView` uses `.custom` when a built-in speaker is selected.
- `CustomVoiceView` uses `.design` when the "Custom" speaker mode is active.
- The visible screen title remains "Custom Voice" in both cases.

### Output path handling

- The generation views and batch sheet use `makeOutputPath(...)`, which delegates to `AudioService.makeOutputPath(...)`.
- `AudioService.makeOutputPath(...)` now honors the `PreferencesView` `outputDirectory` setting.
- If `outputDirectory` is empty, output falls back to `QwenVoiceApp.outputsDir`.
- `QwenVoiceApp.setupAppSupport()` still pre-creates the default app-support output folders on launch even when a custom output directory is configured.

### Database reality

`DatabaseService` is simpler than some older docs suggest. It currently provides:

- migrations for `generations` and `sortOrder`
- save
- fetch all
- delete one
- delete all

Notably:

- There is no DB-backed search helper.
- `HistoryView` fetches all rows ordered by `createdAt.desc`.
- Search is done in-memory inside `HistoryView`.
- The `sortOrder` column exists but is not used by the current UI.

### Models and tiers

- The shipping app currently exposes only the three 1.7B "pro" models.
- `TTSModel.all` includes `pro_custom`, `pro_design`, and `pro_clone`.
- `pro_design` is downloadable and usable, but it is surfaced through `CustomVoiceView` instead of a dedicated sidebar destination.
- `Generation.modelTier` still exists, but generation flows currently write `"pro"` only.
- `PythonBridge.getModelInfo()` and backend `get_model_info` exist, but the current `ModelsView` uses `ModelManagerViewModel` filesystem checks rather than the RPC.

### Preferences and Python environment

- `PreferencesView.autoPlay` is live. `CustomVoiceView` and `VoiceCloningView` check `AudioService.shouldAutoPlay` before calling `audioPlayer.playFile(...)`.
- `PreferencesView.outputDirectory` is live via `AudioService.makeOutputPath(...)`.
- The Python action in Preferences is runtime-dependent:
  - With bundled Python present, the UI shows "Restart Backend" and `PythonEnvironmentManager.resetEnvironment()` only revalidates/restarts.
  - Without bundled Python, the UI shows "Reset Environment" and deletes the app-support venv before rebuilding it.

## Dependency Rules

There are two Python dependency files with different roles:

1. `Sources/Resources/requirements.txt`: GUI app/backend dependencies. This is what `PythonEnvironmentManager` hashes and installs for the app-support venv path.
2. `cli/requirements.txt`: CLI environment. This currently pins `mlx-audio` to a git commit, while the app requirements use `mlx-audio==0.3.1.post1`.

If you change backend Python dependencies:

1. Decide whether the GUI app, the CLI, or both need the change.
2. Update the correct requirements file(s).
3. If the GUI app’s `mlx-audio` version changes, update the vendored wheel in `Sources/Resources/vendor/` to match. Use `./scripts/build_mlx_audio_wheel.sh` to rebuild the repacked wheel.
4. If you refresh the bundled runtime checked into `Sources/Resources/python/`, also refresh `Sources/Resources/python/.qwenvoice-runtime-manifest.json`. The normal path is `./scripts/bundle_python.sh` or the release pipeline.
5. Expect the app-support venv marker to invalidate because the requirements hash changes.

## Known Gotchas

- `PythonEnvironmentManager` intentionally avoids `/usr/bin/python3` because macOS can treat it as an installer stub. The live `PythonBridge.findPython()` fallback no longer includes `/usr/bin/python3`.
- The checked-in `project.yml` references `Sources/Assets.xcassets`, while the checked-in `QwenVoice.xcodeproj/project.pbxproj` still references top-level `Assets.xcassets`. If you touch assets or regenerate the project, verify which catalog is intended to be authoritative and keep the project state coherent.
- Broad recursive searches can get polluted by generated artifacts in `Sources/Resources/python/`, vendored caches, and `__pycache__`. Prefer search patterns that exclude them (for example `rg -g '!Sources/Resources/python/**' -g '!**/__pycache__/**' ...`) when you want real project sources.
- Older notes may still refer to legacy `audioPlayer_*` accessibility identifiers, but the live player view uses `sidebarPlayer_*`.
- Some backend/frontend features are partially wired:
  - backend `get_speakers` exists, but Swift uses hardcoded speakers
  - backend model info RPC exists, but `ModelsView` does filesystem checks
  - streaming generation helpers exist in `PythonBridge`, but the current SwiftUI screens use non-streaming methods
- The repo already contains other assistant-facing docs (`CLAUDE.md`, `GEMINI.md`). Keep them in sync if you make broad architectural or workflow changes.
- The inner git worktree may contain unrelated user changes. Check `git status` before editing and do not revert work you did not make.

## High-Value Change Patterns

### If you add a new generation mode

Update all of:

1. `Sources/Models/TTSModel.swift`
2. `Sources/Resources/backend/server.py` model definitions and generation dispatch
3. The relevant SwiftUI surface (`CustomVoiceView`, `VoiceCloningView`, or a new screen)
4. `Sources/ContentView.swift` and `Sources/Views/Sidebar/SidebarView.swift` if the mode needs its own navigation destination
5. `Sources/Views/Components/BatchGenerationSheet.swift` if batch generation should support it
6. UI tests and any user-facing docs

### If you add a new RPC method

Update all of:

1. `server.py` handler
2. `METHODS` dispatch table
3. `PythonBridge` convenience wrapper if the method is part of the app-facing contract
4. Call sites in Swift
5. Tests that assert the related UI state

### If you change speaker options

Update all of:

1. `Sources/Models/TTSModel.swift` (`TTSModel.speakers`)
2. `Sources/Resources/backend/server.py` (`SPEAKER_MAP`)
3. Any UI text/tests that assume the current speaker list

### If you add or rename files in `Sources/`

1. Update `project.yml` if the change affects generated project structure or resources.
2. Regenerate with `./scripts/regenerate_project.sh`.
3. Verify entitlements were preserved.

## Practical Review Checklist

Before finishing changes, verify:

1. The change is made from the repo root (`/Users/patricedery/Coding_Projects/QwenVoice`).
2. `project.yml` remains the intended source of truth.
3. Swift and Python stay in sync for any cross-process change.
4. If you changed speakers, the duplicated Swift/backend speaker lists stay aligned.
5. Accessibility identifiers remain stable or tests were updated.
6. If you ran broad searches, you excluded generated runtime artifacts when that mattered.
7. If Python dependencies changed, the venv marker, bundled runtime, and vendored wheel implications were considered.
