# AGENTS.md

This is the primary repo guide for coding agents working in QwenVoice.

## Repo Overview

QwenVoice is a native macOS SwiftUI app for offline Qwen3-TTS on Apple Silicon.

The main working surfaces are:

- `Sources/` for the shipping macOS app, shared models, services, and views
- `Sources/QwenVoiceNative/` for the native MLX runtime, generation, clone support, and load-state coordination
- `Sources/Resources/qwenvoice_contract.json` for shared model, speaker, output, and required-file metadata
- `scripts/` plus `.github/workflows/` for validation, packaging, CI, and release behavior

This checkout is native-only. Do not reintroduce a repo-owned Python app backend, Python setup path, or standalone CLI surface.

## Maintained Docs

The maintained repo docs are:

- `AGENTS.md`
- `README.md`
- `docs/README.md`
- `docs/reference/current-state.md`
- `docs/reference/engineering-status.md`
- `docs/reference/vendoring-runtime.md`

Do not point contributors at removed CLI docs or deleted backend references.

## Source Of Truth

When repo facts disagree, trust sources in this order:

1. `Sources/`
2. `project.yml`
3. `scripts/` plus `.github/workflows/`
4. `docs/reference/current-state.md` and `docs/reference/engineering-status.md`
5. other prose docs

`Sources/Resources/qwenvoice_contract.json` is the source of truth for shared model and speaker metadata.

## Safe Edit Boundaries

- `project.yml` drives `QwenVoice.xcodeproj`. Prefer editing `project.yml` and regenerating the project over hand-editing generated project files.
- `Sources/Resources/ffmpeg/` and most contents of `Sources/Resources/vendor/` are generated or vendored assets. Update them through the packaging or vendoring scripts, not by ad hoc edits.
- `third_party_patches/mlx-audio-swift/` is the repo-owned native backend source boundary for MLXAudioSwift. Keep its package manifest and pins aligned with `project.yml` and `Package.resolved`.
- App data under `~/Library/Application Support/QwenVoice/` or a `QWENVOICE_APP_SUPPORT_DIR` override is runtime state, not repo source.
- Watch for accidental `__pycache__` and `.pyc` paths when regenerating or reviewing changes.

## Project-Local Skills

QwenVoice has repo-tracked local skills under `.agents/skills/`. Prefer these when the task matches their scope:

- `qwenvoice-packaged-validation` for packaged-app validation, release artifact checks, and native bundle proof
- `qwenvoice-release-publish` for version/build bumps, checked-in release notes, CI gate waiting, and GitHub release verification
- `qwenvoice-vendored-runtime` for `mlx-audio-swift`, native runtime packaging changes, and bundle-boundary verification
- `qwenvoice-doc-sync` for README, AGENTS, and maintained doc sync against `Sources/`, `project.yml`, and `scripts/`

Useful shared skills in this repo:

- `swift-concurrency-expert`
- `swiftui-liquid-glass`
- `swiftui-performance-audit`
- `swiftui-view-refactor`
- `review-and-simplify-changes`

## Architecture Boundaries

- `Sources/QwenVoiceApp.swift` composes shared app services, owns the separate Settings scene, coordinates launch preflight through `AppStartupCoordinator`, `AppLaunchConfiguration`, and `UITestWindowCoordinator`, and selects the app-facing TTS engine through `AppEngineSelection`.
- `Sources/ContentView.swift` owns `NavigationSplitView`, main-window toolbar/search/titlebar chrome, sidebar selection, and persisted generation drafts.
- `Sources/Services/AppPaths.swift` is the path boundary for app support, models, outputs, voices, and the `QWENVOICE_APP_SUPPORT_DIR` override.
- `Sources/Models/TTSContract.swift` and `Sources/Models/TTSModel.swift` load `Sources/Resources/qwenvoice_contract.json`.
- `Sources/Services/AppCommandRouter.swift` and `Sources/Services/GenerationLibraryEvents.swift` are the typed MainActor event boundaries for screen navigation and history refresh.
- `Sources/QwenVoiceNative/` plus `third_party_patches/mlx-audio-swift/` are the native runtime boundary.
- `Sources/ViewModels/ModelManagerViewModel.swift` uses manifest plus filesystem status for the Models screen.
- `Sources/ViewModels/AudioPlayerViewModel.swift` isolates timer-frequency playback state in nested `PlaybackProgress`.
- `Sources/Services/GenerationPersistence.swift` centralizes save and autoplay handoff for the three generation screens.
- `Sources/Services/DatabaseService.swift` owns the GRDB SQLite history database and is `@MainActor`.

## UI And Build Constraints

- Preferences live in the app’s Settings scene, not in the main sidebar flow.
- Voice Cloning does not expose delivery or emotion controls. The base clone model ignores them.
- `Sources/Views/Components/TextInputView.swift` uses an `NSTextView` wrapper for placeholder alignment, editing behavior, and scrollbars. Do not replace it with SwiftUI `TextEditor`.
- In manual Computer Use passes, macOS picker-style controls often surface as menu buttons and menu items rather than ordinary buttons.
- The default checkout profile in `project.yml` is `QW_UI_LIQUID`. That path needs a macOS 26 SDK and Xcode 26+ to compile.
- `QW_UI_LEGACY_GLASS` remains supported and is validated through CI and explicit profile switching rather than the default checkout config.
- Keep shared styling centralized in `Sources/Views/Components/AppTheme.swift`.

## Required Workflows

Start with repo truth first:

- Search with `rg`, inspect source, manifests, scripts, and workflows before assuming docs are current.
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
python3 scripts/harness.py test --layer release --artifacts-root <dir>
python3 scripts/harness.py diagnose
python3 scripts/harness.py bench --category release
QWENVOICE_ENABLE_NATIVE_ENGINE_LIVE_TESTS=1 xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice -destination 'platform=macOS' -only-testing:QwenVoiceTests/NativeMLXMacEngineLiveTests test
```

Notes:

- `scripts/harness.py` is the primary testing, diagnostic, and benchmark entrypoint.
- On this machine, keep validation deliberately low-RAM and serialized: run the cheapest relevant gate first, and never overlap heavy `xcodebuild`, `scripts/harness.py`, `./scripts/release.sh`, live app validation, or native smoke processes.
- There are no maintained automated `ui`, `design`, or `perf` harness lanes in this checkout. Use scoped Codex Computer Use instead for visual or interaction verification after the cheap repo gates are green.
- Do not jump to live native smoke, local packaging, or manual Computer Use until `./scripts/check_project_inputs.sh`, `python3 scripts/harness.py validate`, and the smallest relevant source gate are already green.

## CI And Release Workflows

The active GitHub workflows are:

- `Project Inputs` for checked-in project and resource validation
- `Test Suite` for source tests, strict-concurrency and alternate-profile compilation, and packaged builds
- `Release Dual UI` for building, signing, notarizing, and optionally publishing the shipped DMGs

Release facts:

- Official shipped DMGs are `QwenVoice-macos26.dmg` and `QwenVoice-macos15.dmg`.
- `Release Dual UI` has three stages: `build-release`, `notarize-release`, and `publish-release`.
- Shipped app bundles and notarized DMGs must not contain `Contents/Resources/backend`, `Contents/Resources/python`, or bundled `Contents/Resources/ffmpeg`.
- Release signing and notarization belongs in GitHub Actions, not local packaging.

Local packaging commands:

```bash
./scripts/release.sh
./scripts/verify_release_bundle.sh build/QwenVoice.app
./scripts/verify_packaged_dmg.sh build/QwenVoice.dmg build/release-metadata.txt
```

## When Changing X, Also Update Y

- Model registry, speakers, output folders, or required model files:
  update `Sources/Resources/qwenvoice_contract.json` first, then `TTSContract.swift`, `TTSModel.swift`, and contract-facing docs/tests.
- Adding or renaming source files:
  update `project.yml`, run `./scripts/regenerate_project.sh`, and confirm generated project files did not capture `__pycache__` or `.pyc` paths.
- Clone preparation or clone streaming behavior:
  review `Sources/QwenVoiceNative/`, `VoiceCloningView.swift`, and native test coverage together.
- Playback or streaming behavior:
  review `AudioPlayerViewModel.swift`, `GenerationPersistence.swift`, and affected generation views together.
- History or database access:
  keep `DatabaseService.swift` and affected library views in sync, and respect MainActor isolation.
- Packaged validation or release artifact changes:
  prefer `qwenvoice-packaged-validation`, validate through the harness release lane, use `./scripts/verify_release_bundle.sh`, and rely on Computer Use rather than automated XCUI proof for visual confirmation.
- Vendored runtime changes:
  prefer `qwenvoice-vendored-runtime`, keep `third_party_patches/mlx-audio-swift/`, `project.yml`, `Package.resolved`, `docs/reference/vendoring-runtime.md`, and the release verification flow aligned.
- Broad repo facts that users or contributors rely on:
  prefer `qwenvoice-doc-sync`, and update `AGENTS.md`, `docs/README.md`, `docs/reference/current-state.md`, and any top-level docs that claim the changed behavior.

## Operational Safety

- Avoid running multiple `QwenVoice` app instances at once while debugging model loads, clone prep, or playback.
- Prefer killing an old instance before launching a new build.
- Local validation on this machine should be treated as macOS 26 / `QW_UI_LIQUID` dev work by default. macOS 15 coverage is CI and profile-driven unless you intentionally switch the compile flag and SDK surface.
- Never overlap heavy `xcodebuild`, `scripts/harness.py`, `./scripts/release.sh`, live app validation, or native smoke processes on this machine.
- Never run more than one heavy model load, generation, or benchmark at a time.
- Use Computer Use only after heavy automation is finished; never keep desktop interaction active while memory-heavy build or validation work is still running.

## Before Finishing

- Prefer manifest-backed data over duplicated constants.
- Keep accessibility identifiers stable when UI control types change.
- If you changed main-window chrome, navigation, or search behavior, verify the ownership still lives in `ContentView`.
- If you changed Preferences behavior, remember it lives in a separate Settings window.
- For doc-only refreshes, rerun the stale-reference grep and verify referenced commands, workflows, artifact names, and doc links still exist.
- Run the most relevant harness layer plus `python3 scripts/harness.py validate` before calling work complete.
