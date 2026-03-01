# AGENTS.md

## Scope

This file applies to the project repository at `/Users/patricedery/Coding_Projects/QwenVoice`.

Run repo-level commands from this directory:

```bash
cd /Users/patricedery/Coding_Projects/QwenVoice
```

## Project Summary

Qwen Voice is a native macOS SwiftUI app for running Qwen3-TTS locally on Apple Silicon. The app is split into:

1. A SwiftUI frontend that owns UI state, model downloads, playback, and local persistence.
2. A long-lived Python backend (`Sources/Resources/backend/server.py`) that runs MLX inference and communicates with Swift over newline-delimited JSON-RPC 2.0 on `stdin`/`stdout`.

The app targets macOS 14+, Apple Silicon only, and uses Swift 5.9.

## Source Of Truth

Trust the code first, then `project.yml`, then prose docs.

`README.md`, `CLAUDE.md`, and `GEMINI.md` are useful, but some details are stale relative to the current codebase. Examples of drift that already exist:

- Older notes may still refer to the former nested repo path.
- The checked-in `.xcodeproj` and `project.yml` are not perfectly aligned on asset catalog wiring.
- Some feature descriptions in prose are broader than the code currently implements.

When in doubt, verify behavior in `Sources/`, `QwenVoiceUITests/`, and `scripts/`.

## Repository Layout

### App code

- `Sources/QwenVoiceApp.swift`: app entry point, environment bootstrapping, app support directory creation, app-level commands.
- `Sources/ContentView.swift`: root `NavigationSplitView`, sidebar routing, view switching.
- `Sources/Models/`: shared model types (`TTSModel`, `Generation`, `Voice`, `RPCMessage`, `EmotionPreset`).
- `Sources/Services/`: backend bridge, Python environment setup, downloads, database, audio, waveform.
- `Sources/ViewModels/`: `ModelManagerViewModel`, `AudioPlayerViewModel`.
- `Sources/Views/`: setup flow, generate flows, library views, settings, shared components.
- `Sources/Resources/backend/server.py`: Python JSON-RPC server.
- `Sources/Resources/requirements.txt`: app/backend Python dependencies bundled for the GUI app.
- `Sources/Resources/vendor/`: vendored wheels for faster/offline setup. The app now vendors a repacked `mlx_audio-0.3.1.post1` wheel that includes the QwenVoice speed helper module.

### Tests

- `QwenVoiceUITests/`: macOS XCUITests. Current snapshot is 9 `*Tests.swift` files plus `QwenVoiceUITestBase.swift`.

### Build and release

- `project.yml`: XcodeGen source of truth. Prefer editing this over the generated `.xcodeproj`.
- `QwenVoice.xcodeproj/`: generated project; do not hand-edit unless you are intentionally repairing generated output.
- `scripts/`: build, test, bundling, release, and utility scripts.

### Secondary CLI

- `cli/`: standalone Python CLI workflow. Useful for reference and manual backend experiments, but it is not the source of truth for the shipped app UX.

## Architecture

### Swift frontend

The Swift app is state-driven and environment-object based:

- `QwenVoiceApp` owns `PythonBridge`, `AudioPlayerViewModel`, `PythonEnvironmentManager`, and `ModelManagerViewModel`.
- `PythonEnvironmentManager` gates app launch through `SetupView` until Python is usable.
- Once ready, `ContentView` swaps between `CustomVoiceView`, `VoiceCloningView`, `HistoryView`, `VoicesView`, `ModelsView`, and `PreferencesView`.

The UI currently follows a consistent design language:

- `AppTheme` centralizes accent colors and glass styling.
- `glassCard()` is the standard card treatment.
- `contentColumn()` constrains primary content to `LayoutConstants.contentMaxWidth` (currently 700).
- `TextInputView` is the shared prompt input for generation screens.
- The persistent playback UI is `SidebarPlayerView`, not a bottom bar.

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
- GPU cache is explicitly cleared after generation (`_mx.metal.clear_cache()`).
- Voice names are sanitized before file writes/deletes.
- Model folders may be resolved through Hugging Face `snapshots/` subdirectories (`get_smart_path`).

### Swift/Python contract

If you change any RPC shape or backend behavior, update both sides:

1. `Sources/Resources/backend/server.py`
2. `Sources/Services/PythonBridge.swift`
3. `Sources/Models/RPCMessage.swift` if new data types are needed
4. Any affected views/view models/tests

Also keep model definitions mirrored across:

1. `Sources/Models/TTSModel.swift`
2. `Sources/Resources/backend/server.py` (`MODELS`)

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
  history.sqlite
  python/
    .setup-complete
```

Key implications:

- `history.sqlite` is managed by `DatabaseService`.
- The Python venv is disposable and rebuilt by `PythonEnvironmentManager`.
- The `.setup-complete` marker stores a SHA-256 of `Sources/Resources/requirements.txt`.

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

# Run all UI tests
./scripts/run_tests.sh

# List test classes
./scripts/run_tests.sh --list

# Run one test class
./scripts/run_tests.sh SidebarNavigation

# Release build + DMG
./scripts/release.sh
```

### XcodeGen rule

Use `./scripts/regenerate_project.sh`, not bare `xcodegen generate`, because XcodeGen overwrites `Sources/QwenVoice.entitlements` and the script restores it.

### Release packaging rule

`scripts/release.sh` bundles Python and `ffmpeg`, builds the app, then injects the bundled `Sources/Resources/python` and `Sources/Resources/ffmpeg` into the built `.app` because those paths are excluded from the normal Xcode resource phase.

## Current Implementation Conventions

### UI and accessibility

- Maintain `accessibilityIdentifier` coverage for interactive UI and primary assertions.
- Current naming convention is `"{viewScope}_{elementName}"` (for example `customVoice_title`, `models_download_pro_custom`, `sidebar_backendStatus`).
- If you rename identifiers, update the XCUITests in the same change.

### Generation flow

- The generate views always call `pythonBridge.loadModel(id:)` before generating.
- Successful generations are immediately persisted through `DatabaseService.shared.saveGeneration`.
- Successful generations currently call `audioPlayer.playFile(...)` directly.

This means the `PreferencesView` `autoPlay` toggle is not wired into generation behavior yet. Do not assume it changes anything unless you implement that plumbing.

### Output path handling

- The generation views use `makeOutputPath(...)`, which delegates to `AudioService.makeOutputPath(...)`.
- That helper always writes under `QwenVoiceApp.outputsDir`.

This means the `PreferencesView` `outputDirectory` setting is also UI-only at the moment. Do not assume it affects where files are saved unless you wire it through.

### Database reality

`DatabaseService` is simpler than some docs suggest. It currently provides:

- migrations for `generations` and `sortOrder`
- save/fetch/search/delete helpers

The `sortOrder` column exists, but the current `HistoryView` still renders `fetchAllGenerations()` ordered by `createdAt.desc`, and search is done in-memory in the view. If you implement drag reordering or DB-backed search, update both the database layer and the view logic.

### Models and tiers

- The shipping app currently exposes only the three 1.7B "pro" models.
- `Generation.modelTier` still exists, but generation flows currently write `"pro"` only.
- Treat older "lite" references in comments/docs as legacy unless you are intentionally reintroducing a lighter tier.

## Dependency Rules

There are two Python dependency files with different roles:

1. `Sources/Resources/requirements.txt`: GUI app/backend dependencies. This is what `PythonEnvironmentManager` hashes and installs.
2. `cli/requirements.txt`: CLI environment. This currently pins `mlx-audio` to a git commit, while the app requirements use `mlx-audio==0.3.1.post1`.

If you change backend Python dependencies:

1. Decide whether the GUI app, the CLI, or both need the change.
2. Update the correct requirements file(s).
3. If the GUI app’s `mlx-audio` version changes, update the vendored wheel in `Sources/Resources/vendor/` to match. Use `./scripts/build_mlx_audio_wheel.sh` to rebuild the repacked wheel.
4. Expect the app venv to rebuild because the requirements hash changes.

## Known Gotchas

- `PythonEnvironmentManager` intentionally avoids `/usr/bin/python3` because macOS can treat it as a stub that opens installer UX. `PythonBridge.findPython()` still falls back to `/usr/bin/python3` as a last resort. Be careful when changing interpreter discovery.
- The checked-in `project.yml` references `Sources/Assets.xcassets`, while the checked-in `QwenVoice.xcodeproj/project.pbxproj` still references top-level `Assets.xcassets`. If you touch assets or regenerate the project, verify which catalog is intended to be authoritative and keep the project state coherent.
- Older notes may still refer to legacy `audioPlayer_*` accessibility identifiers, but the live player view uses `sidebarPlayer_*`.
- The repo already contains other assistant-facing docs (`CLAUDE.md`, `GEMINI.md`). Keep them in sync if you make broad architectural or workflow changes.
- The inner git worktree may contain unrelated user changes. Check `git status` before editing and do not revert work you did not make.

## High-Value Change Patterns

### If you add a new generation mode

Update all of:

1. `Sources/Models/TTSModel.swift`
2. `Sources/Resources/backend/server.py` model definitions and generation dispatch
3. `Sources/ContentView.swift` / sidebar routing if it needs a new surface
4. The relevant SwiftUI view(s)
5. UI tests and any user-facing docs

### If you add a new RPC method

Update all of:

1. `server.py` handler
2. `METHODS` dispatch table
3. `PythonBridge` convenience wrapper
4. Call sites in Swift
5. Tests that assert the related UI state

### If you add or rename files in `Sources/`

1. Update `project.yml` if the change affects generated project structure or resources.
2. Regenerate with `./scripts/regenerate_project.sh`.
3. Verify entitlements were preserved.

## Practical Review Checklist

Before finishing changes, verify:

1. The change is made from the repo root (`/Users/patricedery/Coding_Projects/QwenVoice`).
2. `project.yml` remains the intended source of truth.
3. Swift and Python stay in sync for any cross-process change.
4. Accessibility identifiers remain stable or tests were updated.
5. If Python dependencies changed, the venv marker and vendored wheel implications were considered.
