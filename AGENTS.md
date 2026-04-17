# AGENTS.md

This is the primary repo guide for coding agents working in QwenVoice.
Treat it as the standalone maintainer and agent operating guide for this checkout.

## Repo Overview

QwenVoice is a native macOS SwiftUI app for offline Qwen3-TTS on Apple Silicon.
The repo has four important working surfaces:

- `Sources/` contains the shipping macOS app, shared models, services, and views.
- `Sources/Resources/backend/` contains the long-lived Python JSON-RPC backend bundled into the app.
- `Sources/Resources/qwenvoice_contract.json` is the shared Swift/Python contract for models, speakers, output subfolders, and required files.
- `scripts/` plus `.github/workflows/` define validation, packaging, CI, and release behavior.

There is also a standalone CLI in `cli/`, but it is not the source of truth for the shipped GUI UX.

## Maintained Docs

The maintained repo docs in this checkout are:

- `AGENTS.md` for agent and maintainer guidance
- `docs/README.md` for the docs index
- `docs/reference/current-state.md` for shared repo facts
- `docs/reference/engineering-status.md` for current strengths and caveats
- `docs/reference/vendoring-runtime.md` for packaged runtime and vendoring flows
- `README.md` for the public GitHub landing page
- `cli/README.md` for the standalone CLI surface

Do not point contributors at missing supplementary docs. Use the maintained files above instead.

## Source Of Truth

When repo facts disagree, trust sources in this order:

1. `Sources/` for live app behavior and runtime rules
2. `project.yml` for XcodeGen project structure, compile flags, and version/build numbers
3. `scripts/` plus `.github/workflows/` for validation, packaging, CI, and release behavior
4. `docs/reference/current-state.md` and `docs/reference/engineering-status.md` for maintained repo facts
5. Other prose docs such as `README.md`, `docs/README.md`, `qwen_tone.md`, and historical release notes

Important exception:

- `Sources/Resources/qwenvoice_contract.json` is the source of truth for shared model and speaker metadata even though it lives under `Sources/Resources/`.

Prefer code, manifests, and scripts over prose whenever they disagree.

## Safe Edit Boundaries

- `project.yml` drives `QwenVoice.xcodeproj`. Prefer editing `project.yml` and regenerating the project over hand-editing generated project files.
- `Sources/Resources/python/`, `Sources/Resources/ffmpeg/`, and most contents of `Sources/Resources/vendor/` are generated or vendored runtime assets. Update them through the packaging or vendoring scripts, not by ad hoc manual edits.
- `Sources/Resources/backend/server_compat.py` is harness-only compatibility glue. Do not treat it as bundled production backend source.
- `third_party_patches/mlx-audio/` and `Sources/Resources/backend/mlx_audio_qwen_speed_patch.py` are coupled through the helper-sync workflow. Keep them aligned.
- `third_party_patches/mlx-audio-swift/` is the repo-owned native backend source boundary for MLXAudioSwift. Treat it as maintained source, keep its package manifest and pins aligned with `project.yml` and `Package.resolved`, and do not mix it into the Python wheel overlay flow.
- App data under `~/Library/Application Support/QwenVoice/` or a `QWENVOICE_APP_SUPPORT_DIR` override is runtime state, not repo source.
- Watch for accidental `__pycache__` and `.pyc` paths when regenerating or reviewing changes.

## Project-Local Skills

QwenVoice has repo-tracked local skills under `.agents/skills/`. Prefer these when the task matches their scope instead of rediscovering the same repo-specific workflows from scratch:

- `qwenvoice-packaged-validation` for packaged-app validation, dual-UI release artifact checks, bundled dependency proof, screenshot-capture prompt issues, and full automated validation requests
- `qwenvoice-release-publish` for version/build bumps, checked-in release notes, CI gate waiting, `release-dual-ui` dispatch, and GitHub release verification
- `qwenvoice-vendored-runtime` for `mlx-audio`, `mlx-audio-swift`, backend helper overlay and runtime packaging changes, `build_mlx_audio_wheel.sh`, bundled Python and ffmpeg flows, and packaged runtime verification
- `qwenvoice-doc-sync` for README, AGENTS, current-state, and release-notes sync against `Sources/`, `project.yml`, and `scripts/`

These local skills complement, rather than replace, the user-wide skills that are already useful in this repo:

- `swift-concurrency-expert`
- `swiftui-liquid-glass`
- `swiftui-performance-audit`
- `swiftui-view-refactor`
- `review-and-simplify-changes`
- `github:github`
- `github:gh-fix-ci`
- `app-store-changelog`

## Architecture Boundaries

- `Sources/QwenVoiceApp.swift` composes shared app services, owns the separate Settings scene, and bootstraps UI-test automation via `TestStateServer`, `AppStartupCoordinator`, `BackendLaunchCoordinator`, `AppLaunchConfiguration`, and `UITestWindowCoordinator`.
- `Sources/ContentView.swift` owns `NavigationSplitView`, main-window toolbar/search/titlebar chrome, sidebar selection, and the persisted generation drafts that survive navigation between generation screens.
- `Sources/Services/AppPaths.swift` is the path boundary for app support, models, outputs, voices, and the `QWENVOICE_APP_SUPPORT_DIR` override used by harness and fixture-backed runs.
- `Sources/Models/TTSContract.swift` and `Sources/Models/TTSModel.swift` load `Sources/Resources/qwenvoice_contract.json`. Change the manifest first for model, speaker, output-subfolder, or required-file updates.
- `Sources/Services/AppCommandRouter.swift` and `Sources/Services/GenerationLibraryEvents.swift` are the typed MainActor event boundaries for screen navigation and history refresh. Keep harness-only `NotificationCenter` traffic inside the explicit test-support surfaces.
- `Sources/Services/PythonEnvironmentManager.swift` is the readiness and restart façade. Runtime discovery and setup live in `PythonRuntimeDiscovery.swift`, `PythonRuntimeProvisioner.swift`, `RequirementsInstaller.swift`, `PythonRuntimeValidator.swift`, and `EnvironmentSetupStateMachine.swift`. Do not casually change Python version search order, bundled-runtime validation, or `.setup-complete` marker behavior.
- `Sources/Services/PythonBridge.swift` remains the app-facing backend façade. Process launch, JSON-RPC transport, streaming state, model-load dedupe, clone priming, sidebar activity, and mode-specific flows live in `PythonProcessManager.swift`, `PythonJSONRPCTransport.swift`, `GenerationStreamCoordinator.swift`, `ModelLoadCoordinator.swift`, `ClonePreparationCoordinator.swift`, `PythonBridgeActivityCoordinator.swift`, `PythonBridge+GenerationFlows.swift`, and `StubBackendTransport.swift`.
- The backend RPC surface already includes app-visible coordination methods such as `prewarm_model`, `prepare_clone_reference`, `prime_clone_reference`, `get_model_info`, `get_speakers`, `list_voices`, `enroll_voice`, and `delete_voice`. If you change those payloads or semantics, keep Swift, Python, harness, and docs in sync.
- `Sources/Resources/backend/server.py` is the thin Python entrypoint and wiring layer. Production backend behavior is split across `backend_state.py`, `rpc_transport.py`, `output_paths.py`, `audio_io.py`, `clone_context.py`, `generation_pipeline.py`, and `rpc_handlers.py`. The shipped app bundles that production backend under `QwenVoice.app/Contents/Resources/backend/`.
- `Sources/Services/GenerationPersistence.swift` centralizes save and autoplay handoff for the three generation screens. `Sources/Services/DatabaseService.swift` owns the GRDB SQLite history database and is `@MainActor`; keep persistence and library-refresh behavior aligned.
- `Sources/Services/TestStateServer.swift` and `Sources/Services/TestStateProvider.swift` are the UI-test HTTP and query boundary. Keep UI-test state exposure, screenshot hooks, and window-activation telemetry there rather than leaking it into normal product flows.
- `Sources/QwenVoiceNative/` plus `third_party_patches/mlx-audio-swift/` are the native backend boundary. Keep native runtime, load-state, and synthesis work there, while the shipped app still boots `TTSEngineStore` with `PythonBridgeMacTTSEngineAdapter` until an explicit app-engine cutover lands.
- `Sources/ViewModels/ModelManagerViewModel.swift` still uses manifest plus filesystem status for the shipping Models screen. Backend `get_model_info` exists and is harness-tested, but it is not yet the primary model-status source for `ModelsView`.
- `Sources/ViewModels/AudioPlayerViewModel.swift` isolates timer-frequency playback state in nested `PlaybackProgress`. Do not move high-frequency playback fields back onto the parent observable object.
- `cli/main.py` is a separate terminal app with cwd-based paths and a broader speaker map than the shipped GUI. Do not copy CLI assumptions into the app contract or app docs.

Large coordinator files still deserve small, surgical changes and focused verification:

- `Sources/Services/PythonBridge.swift`
- `Sources/Services/PythonEnvironmentManager.swift`
- `Sources/Resources/backend/server.py`
- `scripts/harness_lib/test_runner.py`

## UI And Build Constraints

- Preferences live in the app's Settings scene, not in the main sidebar flow.
- `SetupView` intentionally receives `envManager` as `@ObservedObject`, not `@EnvironmentObject`, because it is shown before environment injection is attached in `QwenVoiceApp`.
- Voice Cloning does not expose delivery or emotion controls. The base clone model ignores them.
- `Sources/Views/Components/TextInputView.swift` uses an `NSTextView` wrapper for placeholder alignment, editing behavior, and scrollbars. Do not replace it with SwiftUI `TextEditor`.
- macOS picker-style controls often surface as `MenuButton` and `MenuItem` in XCUI, not ordinary buttons.
- The default checkout profile in `project.yml` is `QW_UI_LIQUID`. That path needs a macOS 26 SDK and Xcode 26+ to compile.
- `QW_UI_LEGACY_GLASS` remains supported and is validated through CI and explicit profile switching rather than the default checkout config. `scripts/set_ci_ui_profile.sh` is the repo-owned helper that patches `project.yml` for macOS 15 CI runs.
- Keep shared styling centralized in `Sources/Views/Components/AppTheme.swift`, and avoid `Shape.fill(...).glassEffect(...)` chains that fail across older compiler and SDK combinations.

## Required Workflows

Start with repo truth first:

- Search with `rg`, inspect source, manifests, scripts, and workflows before assuming docs are current.
- Prefer repo scripts, `python3 scripts/harness.py`, and `xcodebuild` over improvised one-off workflows.

Fast gates:

```bash
./scripts/check_project_inputs.sh
python3 scripts/harness.py validate
```

`./scripts/check_project_inputs.sh` verifies that the checked-in Xcode project has not captured `__pycache__` or `.pyc` references and that the backend resource contract is still clean.

Core local commands:

```bash
# Regenerate project after adding, removing, or renaming tracked source files
./scripts/regenerate_project.sh

# Build the default checkout profile
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build

# Swift / Python / contract / audio / RPC layers
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer pipeline
python3 scripts/harness.py test --layer server
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer rpc
python3 scripts/harness.py test --layer audio

# UI, design, and perf
python3 scripts/harness.py test --layer ui
python3 scripts/harness.py test --layer design
python3 scripts/harness.py test --layer perf

# Packaged release-artifact validation
python3 scripts/harness.py test --layer release --artifacts-root <dir> --ui-backend-mode live --ui-data-root fixture

# Diagnostics and targeted benchmarks
python3 scripts/harness.py diagnose
python3 scripts/harness.py bench --category clone_regression
python3 scripts/harness.py bench --category tts_roundtrip
```

Notes:

- `scripts/harness.py` is the primary testing, diagnostic, and benchmark entrypoint.
- `python3 scripts/harness.py test --layer all` runs the normal combined source layers (`pipeline`, `server`, `contract`, `rpc`, `swift`, `audio`) and excludes `ui`, `design`, `perf`, and `release`.
- `ui`, `design`, and `perf` default to `--ui-backend-mode live --ui-data-root fixture`. Those runs reuse installed runtime and models while isolating writable app state under a disposable fixture root.
- Use `--ui-backend-mode stub` when you want UI smoke coverage without requiring installed models or a live backend. CI uses stub mode for the `ui` smoke lane and macOS 26 screenshot-capture smoke.
- `AppPaths.appSupportDir` respects `QWENVOICE_APP_SUPPORT_DIR`; the harness sets that for fixture-backed runs. Do not hardcode `~/Library/Application Support/QwenVoice/` in new test flows if they are supposed to be isolated.
- `QWENVOICE_UI_TEST_APPEARANCE=light|dark|system` is the supported appearance override for UI and design runs. When appearance is forced, `design` compares against `tests/screenshots/baselines/<appearance>/`; the repo also keeps shared fallback baselines under `tests/screenshots/baselines/` for system and default comparisons.
- Screenshot-based UI validation should default to `QWENVOICE_UITEST_CAPTURE_MODE=content`. This is the correct automated comparison path, but it is not the highest-fidelity representation of Liquid Glass. Use `system` capture only for explicit visual-fidelity checks, and treat Screen Recording and TCC failures there as environment limits rather than general app regressions.
- Run forced `light` and `dark` `design` lanes sequentially, not in parallel, because they share the UI app and test transport.
- `python3 scripts/harness.py test --layer release ...` is for workflow-built artifacts. Prefer a downloaded or extracted final artifact bundle from `Release Dual UI`, not local ad hoc DMGs and not the intermediate build-only artifact set.
- `python3 scripts/harness.py bench ...` typically requires the app runtime plus installed models. Prefer tiny prompts and serialized `benchmark=true` runs for profiling and regression isolation.
- `python3 scripts/harness.py bench --category tts_roundtrip` also requires a locally available ASR evaluator. Set `QWENVOICE_TTS_ROUNDTRIP_ASR_MODEL` to an installed local path or cached Hugging Face repo if you want to override the default candidate list; otherwise the benchmark skips cleanly.

## CI And Release Workflows

The active GitHub workflows are:

- `Project Inputs` for checked-in project and resource validation
- `Test Suite` for source tests, strict-concurrency and alternate-profile compilation, packaged builds, runtime parity, UI smoke, and perf audit
- `Release Dual UI` for building, signing, notarizing, and optionally publishing the shipped DMGs

Release facts:

- Official shipped DMGs are `QwenVoice-macos26.dmg` and `QwenVoice-macos15.dmg`.
- `Release Dual UI` has three stages: `build-release`, `notarize-release`, and `publish-release`.
- Intermediate build artifacts are uploaded as `qwenvoice-dual-ui-build-<run-number>-<variant>[-label]`.
- Final notarized artifact bundles are uploaded as `qwenvoice-dual-ui-<run-number>-final[-label]` and are the preferred source for downloaded release validation.
- Tagged publishes should provide `release_notes_path` and publish the checked-in notes file instead of hand-maintaining separate hosted release text.
- Release signing and notarization belongs in GitHub Actions, not local packaging. The workflow uses App Store Connect API key auth; `APPLE_NOTARY_ISSUER_ID` is required for Team keys and omitted for Individual keys.
- Local `./scripts/release.sh` output is useful for macOS 26 debug and runtime validation, but it is not authoritative release proof for either shipped variant.

Local packaging commands:

```bash
./scripts/release.sh
./scripts/verify_release_bundle.sh build/QwenVoice.app
./scripts/verify_packaged_dmg.sh build/QwenVoice.dmg build/release-metadata.txt
```

## When Changing X, Also Update Y

- RPC contract or payload shape changes:
  Update `Sources/Resources/backend/rpc_handlers.py`, `Sources/Services/PythonBridge.swift`, `Sources/Models/RPCMessage.swift` if needed, affected Swift views and view models, and relevant docs and tests.
- Model registry, speakers, output folders, or required model files:
  Update `Sources/Resources/qwenvoice_contract.json` first, then `TTSContract.swift`, `TTSModel.swift`, Python consumers, and contract-facing docs and tests.
- Model status or speaker metadata surfaces:
  Keep `ModelManagerViewModel.swift`, `PythonBridge.getModelInfo()/getSpeakers()`, backend `handle_get_model_info` / `handle_get_speakers`, and harness RPC tests aligned.
- Adding or renaming source files:
  Update `project.yml`, run `./scripts/regenerate_project.sh`, and confirm generated project files did not capture `__pycache__` or `.pyc` paths.
- Clone-reference preparation, clone prewarm, or clone streaming behavior:
  Review `generation_pipeline.py`, `clone_context.py`, `PythonBridge.swift`, `VoiceCloningView.swift`, and the `server` and `rpc` harness tests together.
- Pure backend helpers or JSON-RPC dispatch in the Python backend:
  Run `python3 scripts/harness.py test --layer server`.
- Playback or streaming behavior:
  Review `AudioPlayerViewModel.swift`, `PythonBridge.swift`, `GenerationStreamCoordinator.swift`, and `GenerationPersistence.swift` together.
- Generation persistence or autoplay:
  Prefer `Sources/Services/GenerationPersistence.swift` over duplicating logic inside individual generation views.
- History or database access:
  Keep `DatabaseService.swift` and affected library views in sync, and respect MainActor isolation.
- App-support path handling or UI fixture behavior:
  Review `AppPaths.swift`, `UITestAutomationSupport.swift`, `TestStateServer.swift`, `scripts/harness_lib/ui_test_support.py`, and affected UI tests together.
- Appearance-sensitive UI or design-baseline work:
  Keep `QWENVOICE_UI_TEST_APPEARANCE=light` and `dark` coverage green, and refresh the matching committed baselines under `tests/screenshots/baselines/light/` and `tests/screenshots/baselines/dark/`. If the shared system and default baselines are still used for the affected flow, refresh `tests/screenshots/baselines/` too.
- Packaged validation, release artifacts, or bundled dependency checks:
  Prefer `qwenvoice-packaged-validation`, validate through the harness packaged and release lanes, use `./scripts/verify_release_bundle.sh`, and default screenshot checks to `QWENVOICE_UITEST_CAPTURE_MODE=content`.
- GitHub release publication or hosted release notes:
  Prefer `qwenvoice-release-publish`, require a checked-in notes file, and keep the `Release Dual UI` inputs aligned, including `release_notes_path`.
- Vendored runtime or `mlx-audio` changes:
  Prefer `qwenvoice-vendored-runtime`, keep `scripts/build_mlx_audio_wheel.sh`, `third_party_patches/mlx-audio/`, `third_party_patches/mlx-audio-swift/`, `Sources/Resources/backend/mlx_audio_qwen_speed_patch.py`, `project.yml`, `Package.resolved`, `docs/reference/vendoring-runtime.md`, and the release verification flow aligned.
- Broad repo facts that users or contributors rely on:
  Prefer `qwenvoice-doc-sync`, and update `AGENTS.md`, `docs/README.md`, `docs/reference/current-state.md`, and any top-level docs that claim the changed behavior.

## CLI Boundary

The root guide is app-first.
For CLI-only work, also read:

- `cli/README.md`
- `cli/main.py`

Keep these boundaries in mind:

- The CLI is a standalone interactive terminal app, not the app backend.
- The CLI still carries its own speaker map in `cli/main.py`.
- The GUI app contract lives in `Sources/Resources/qwenvoice_contract.json`, not in CLI constants.

## Current Documentation Warnings

There is known doc drift in older local clones and outside references:

- Older references may still point at legacy one-off shell test wrappers or a removed testing reference page.
- Older guidance may still assume supplementary tool-specific docs that are not checked in here.

Use the harness commands in this file and the maintained docs listed above instead of stale references.

## Operational Safety

- Avoid running multiple `QwenVoice` app instances at once while debugging model loads, clone prep, or playback.
- Prefer killing an old instance before launching a new build.
- Prefer asking before launching the full app unless the task clearly requires it.
- Local source and packaged validation on this machine should be treated as macOS 26 / `QW_UI_LIQUID` dev work by default. macOS 15 coverage is CI and profile-driven unless you intentionally switch the compile flag and SDK surface.
- Never treat a local macOS 15 package build as authoritative release validation.
- Never run more than one heavy model load, generation, or benchmark at a time.
- Never run clone or custom comparisons side by side or in parallel processes.
- For clone-mode investigations, cold and warm runs may share one backend process only when intentionally measuring cache reuse. Do not overlap that process with any other model process.
- If comparing two implementations or two packaged apps, run them in separate serial passes, not concurrently.
- Unload the current model and let the backend fully exit before starting the next heavy comparison run.
- Verify idle state with a lightweight process check before starting another heavy run, especially before clone benchmarks or helper/runtime comparisons.

## Before Finishing

- Confirm Swift and Python still agree on cross-process behavior after any RPC or contract change.
- Prefer manifest-backed data over duplicated constants.
- Keep accessibility identifiers stable when UI control types change.
- If you changed main-window chrome, navigation, or search behavior, verify the ownership still lives in `ContentView`.
- If you changed Preferences behavior, remember it lives in a separate Settings window.
- For doc-only refreshes, rerun the stale-reference grep and verify referenced commands, workflows, artifact names, and doc links still exist.
- Run the most relevant harness layer plus `python3 scripts/harness.py validate` before calling work complete.
