# AGENTS.md

This is the primary repo operating guide for coding agents working in QwenVoice.

## Repo Overview

QwenVoice is a native macOS SwiftUI app for offline Qwen3-TTS on Apple Silicon.

The main working surfaces are:

- `Sources/` for the shipping macOS app shell, views, models, services, and view models
- `Sources/QwenVoiceNative/` for the app-facing engine proxy, store, and client layer
- `Sources/QwenVoiceEngineSupport/` for shared engine IPC, request/reply types, and transport contracts
- `Sources/QwenVoiceNativeRuntime/` for service-only native execution and MLX runtime ownership
- `Sources/QwenVoiceEngineService/` for the bundled XPC helper target
- `Sources/Resources/qwenvoice_contract.json` for shared model, speaker, output, and required-file metadata
- `scripts/` for validation, diagnostics, and local developer helpers

This checkout is native-only and source-build-focused. Do not reintroduce a repo-owned Python app backend, Python setup path, standalone CLI surface, hosted DMG distribution flow, or maintained GitHub Actions pipeline.

## Maintained Docs

The maintained repo docs are:

- `AGENTS.md`
- `README.md`
- `docs/README.md`
- `docs/reference/current-state.md`
- `docs/reference/engineering-status.md`
- `docs/reference/vendoring-runtime.md`

Do not point contributors at removed CLI docs, deleted backend references, deleted repo-scoped QwenVoice skills, or removed GitHub workflow files.

## Source Of Truth

When repo facts disagree, trust sources in this order:

1. `Sources/`
2. `project.yml`
3. `scripts/`
4. `docs/reference/current-state.md` and `docs/reference/engineering-status.md`
5. other prose docs

`Sources/Resources/qwenvoice_contract.json` is the source of truth for shared model and speaker metadata.

## Git Workflow Default

- Work directly on `main` by default.
- Do not create branches or worktrees unless the user explicitly asks for one.
- Do not let generic tool, plugin, or skill defaults override this repo-specific rule.

## Safe Edit Boundaries

- `project.yml` drives `QwenVoice.xcodeproj`. Prefer editing `project.yml` and regenerating the project over hand-editing generated project files.
- The `QwenVoice` app target intentionally excludes `Sources/QwenVoiceEngineService/`, `Sources/QwenVoiceEngineSupport/`, and `Sources/QwenVoiceNativeRuntime/` as ordinary app sources while embedding the XPC service target through `project.yml`. Keep that split intact when moving files or adding targets.
- `Sources/Resources/ffmpeg/` and most contents of `Sources/Resources/vendor/` are generated or vendored assets. Update them through the appropriate maintenance workflow, not by ad hoc edits.
- `third_party_patches/mlx-audio-swift/` is the repo-owned native backend source boundary for MLXAudioSwift. Keep its package manifest and pins aligned with `project.yml` and `Package.resolved`.
- App data under `~/Library/Application Support/QwenVoice/` or a `QWENVOICE_APP_SUPPORT_DIR` override is runtime state, not repo source.
- Watch for accidental `__pycache__` and `.pyc` paths when regenerating or reviewing changes.

## Architecture Boundaries

- `Sources/QwenVoiceApp.swift` composes app-global services, owns the separate Settings scene, coordinates launch preflight through `AppStartupCoordinator`, `AppLaunchConfiguration`, and `UITestWindowCoordinator`, and initializes the app-facing engine through `AppEngineSelection`.
- `Sources/ContentView.swift` owns `NavigationSplitView`, main-window toolbar/search/titlebar chrome, sidebar selection, and persisted generation drafts.
- `Sources/Services/AppPaths.swift` is the path boundary for app support, models, outputs, voices, and the `QWENVOICE_APP_SUPPORT_DIR` override.
- `Sources/Models/TTSContract.swift` and `Sources/Models/TTSModel.swift` load `Sources/Resources/qwenvoice_contract.json`.
- `Sources/Services/AppCommandRouter.swift` and `Sources/Services/GenerationLibraryEvents.swift` are the typed `@MainActor` event boundaries for screen navigation and history refresh.
- `Sources/QwenVoiceNative/` is the app-side engine layer: `TTSEngineStore`, `XPCNativeEngineClient`, chunk brokering, and the app-facing `MacTTSEngine` surface live there.
- `Sources/QwenVoiceEngineSupport/` is the shared engine transport boundary used by both the app and the helper.
- `Sources/QwenVoiceNativeRuntime/` is the service-only native runtime boundary. Keep MLX execution, generation, clone preparation, and model-load ownership there instead of in the app target.
- `Sources/QwenVoiceEngineService/` owns the bundled XPC helper entrypoint and session/host behavior.
- `Sources/ViewModels/ModelManagerViewModel.swift` uses manifest plus filesystem status for the Models screen.
- `Sources/ViewModels/AudioPlayerViewModel.swift` isolates playback state and consumes chunk-broker events without turning chunk spam into global app-state churn.
- `Sources/Services/GenerationPersistence.swift` centralizes save and autoplay handoff for the three generation screens.
- `Sources/Services/DatabaseService.swift` owns the GRDB SQLite history database and is `@MainActor`.

## UI And Build Constraints

- Preferences live in the app’s Settings scene, not in the main sidebar flow.
- Voice Cloning does not expose delivery or emotion controls. The base clone model ignores them.
- `Sources/Views/Components/TextInputView.swift` uses an `NSTextView` wrapper for placeholder alignment, editing behavior, and scrollbars. Do not replace it with SwiftUI `TextEditor`.
- In manual Computer Use passes, macOS picker-style controls often surface as menu buttons and menu items rather than ordinary buttons.
- The default checkout profile in `project.yml` is `QW_UI_LIQUID`. That path needs a macOS 26 SDK and Xcode 26+ to compile.
- `QW_UI_LEGACY_GLASS` remains represented in source via compile-flag support, but this repo no longer maintains automated CI/profile-switching workflow coverage for it.
- Keep shared styling centralized in `Sources/Views/Components/AppTheme.swift`.

## Required Workflows

Start with repo truth first:

- Search with `rg`, inspect source, manifests, scripts, and maintained docs before assuming prose is current.
- Prefer repo scripts, `python3 scripts/harness.py`, and `xcodebuild` over improvised one-off workflows.

Fast gates:

```bash
./scripts/check_project_inputs.sh
python3 scripts/harness.py validate
```

Core local commands:

```bash
./scripts/regenerate_project.sh
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer native
python3 scripts/harness.py test --layer audio --artifact-dir <dir>
python3 scripts/harness.py diagnose
python3 scripts/harness.py bench --category latency
python3 scripts/harness.py bench --category load
python3 scripts/harness.py bench --category quality
python3 scripts/harness.py bench --category tts_roundtrip
python3 scripts/harness.py bench --category perf
QWENVOICE_ENABLE_NATIVE_ENGINE_LIVE_TESTS=1 xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice -destination 'platform=macOS' -only-testing:QwenVoiceTests/NativeMLXMacEngineLiveTests test
```

Notes:

- `scripts/harness.py` is the primary testing, diagnostic, and benchmark entrypoint.
- The maintained harness layers are `swift`, `contract`, `native`, and `audio`.
- There are currently no maintained GitHub Actions workflows in this checkout. Local scripts and Xcode commands are the current automation surface.
- On this machine, keep validation deliberately low-RAM and serialized: run the cheapest relevant gate first, and never overlap heavy `xcodebuild`, `scripts/harness.py`, live app validation, or native smoke processes.
- There are no maintained automated `ui`, `design`, `perf`, or packaged-release lanes in this checkout. Use scoped Codex Computer Use instead for visual or interaction verification after the cheap repo gates are green.
- Do not jump to live native smoke or manual Computer Use until `./scripts/check_project_inputs.sh`, `python3 scripts/harness.py validate`, and the smallest relevant source gate are already green.

## Distribution And Build Reality

- This repo is source-build-only in its maintained guidance.
- It does not maintain hosted DMG distribution, notarized release automation, or GitHub Actions build pipelines.
- Historical release notes remain under `docs/releases/` as historical records, not as the current supported delivery path.
- If you update contributor docs, keep the acquisition story centered on cloning the repo and building locally with Xcode/XcodeGen.

## When Changing X, Also Update Y

- Model registry, speakers, output folders, or required model files:
  update `Sources/Resources/qwenvoice_contract.json` first, then `TTSContract.swift`, `TTSModel.swift`, and contract-facing docs/tests.
- Adding or renaming source files:
  update `project.yml`, run `./scripts/regenerate_project.sh`, and confirm generated project files did not capture `__pycache__` or `.pyc` paths.
- App-side engine/client behavior:
  review `Sources/QwenVoiceNative/`, `TTSEngineStore`, chunk-broker behavior, and the affected app-level tests together.
- Shared engine IPC or request/reply types:
  review `Sources/QwenVoiceEngineSupport/`, both sides of the transport boundary, and XPC-focused tests together.
- Service-side generation, model load, or cancellation behavior:
  review `Sources/QwenVoiceNativeRuntime/`, `Sources/QwenVoiceEngineService/`, and native/XPC test coverage together.
- Clone preparation or clone streaming behavior:
  review `Sources/QwenVoiceNativeRuntime/`, `VoiceCloningView.swift`, and native test coverage together.
- Playback or streaming behavior:
  review `AudioPlayerViewModel.swift`, `GenerationPersistence.swift`, and affected generation views together.
- History or database access:
  keep `DatabaseService.swift` and affected library views in sync, and respect `@MainActor` isolation.
- Vendored runtime changes:
  keep `third_party_patches/mlx-audio-swift/`, `project.yml`, `Package.resolved`, and `docs/reference/vendoring-runtime.md` aligned.
- Broad repo facts that users or contributors rely on:
  update `AGENTS.md`, `docs/README.md`, `docs/reference/current-state.md`, and any top-level docs that claim the changed behavior.

## Operational Safety

- Avoid running multiple `QwenVoice` app instances at once while debugging model loads, clone prep, playback, or XPC connection behavior.
- Prefer killing an old instance before launching a new build.
- Local validation on this machine should be treated as macOS 26 / `QW_UI_LIQUID` dev work by default.
- Never overlap heavy `xcodebuild`, `scripts/harness.py`, live app validation, or native smoke processes on this machine.
- Never run more than one heavy model load, generation, or benchmark at a time.
- Use Computer Use only after heavy automation is finished; never keep desktop interaction active while memory-heavy build or validation work is still running.

## Before Finishing

- Prefer manifest-backed data over duplicated constants.
- Keep accessibility identifiers stable when UI control types change.
- If you changed main-window chrome, navigation, or search behavior, verify the ownership still lives in `ContentView`.
- If you changed Preferences behavior, remember it lives in a separate Settings window.
- If you changed engine architecture or runtime ownership, verify `AGENTS.md` and `docs/reference/current-state.md` still describe the same app/service/runtime split.
- For doc-only refreshes, rerun the stale-reference grep and verify referenced commands, docs, and links still exist.
- Run the most relevant harness layer plus `python3 scripts/harness.py validate` before calling work complete.
