# AGENTS.md

This is the primary repo guide for coding agents working in QwenVoice.
Treat it as the standalone maintainer and agent operating guide for this checkout.

## Repo Overview

QwenVoice is a native macOS SwiftUI app for offline Qwen3-TTS on Apple Silicon.
The repo has four important working surfaces:

- `Sources/` contains the shipping macOS app, shared models, services, and views.
- `Sources/Resources/backend/` contains the retained Python JSON-RPC backend used for source/debug compatibility and the standalone CLI. It is no longer bundled into shipped app resources.
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

Supplemental prose such as `qwen_tone.md` may still be useful, but it is not part of the maintained reference set.

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
- `Sources/Resources/python/`, `Sources/Resources/ffmpeg/`, and most contents of `Sources/Resources/vendor/` are generated or vendored source/debug runtime assets. They are not part of the shipped native app bundle. Update them through the packaging or vendoring scripts, not by ad hoc manual edits.
- `Sources/Resources/backend/server_compat.py` is harness-only compatibility glue. Do not treat it as bundled production backend source.
- `third_party_patches/mlx-audio/` and `Sources/Resources/backend/mlx_audio_qwen_speed_patch.py` are coupled through the helper-sync workflow. Keep them aligned.
- `third_party_patches/mlx-audio-swift/` is the repo-owned native backend source boundary for MLXAudioSwift. Treat it as maintained source, keep its package manifest and pins aligned with `project.yml` and `Package.resolved`, and do not mix it into the Python wheel overlay flow.
- App data under `~/Library/Application Support/QwenVoice/` or a `QWENVOICE_APP_SUPPORT_DIR` override is runtime state, not repo source.
- Watch for accidental `__pycache__` and `.pyc` paths when regenerating or reviewing changes.

## Project-Local Skills

QwenVoice has repo-tracked local skills under `.agents/skills/`. Prefer these when the task matches their scope instead of rediscovering the same repo-specific workflows from scratch:

- `qwenvoice-packaged-validation` for packaged-app validation, dual-UI release artifact checks, native bundle proof, screenshot-capture prompt issues, and full automated validation requests
- `qwenvoice-release-publish` for version/build bumps, checked-in release notes, CI gate waiting, `release-dual-ui` dispatch, and GitHub release verification
- `qwenvoice-vendored-runtime` for `mlx-audio`, `mlx-audio-swift`, backend helper overlay and runtime packaging changes, `build_mlx_audio_wheel.sh`, source/debug Python compatibility flows, and packaged native-bundle verification
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

## Desktop Tooling Workflow

Keep QwenVoice repo-truth-first and harness-first even when richer desktop tooling is available in the current Codex session.

- Start with `Sources/`, `project.yml`, `scripts/`, and the repo-local skills before using desktop-native tools.
- Run the smallest relevant repo check first. Prefer `./scripts/check_project_inputs.sh`, `python3 scripts/harness.py validate`, targeted `python3 scripts/harness.py test --layer ...`, and `xcodebuild` over manual app inspection.
- Hard prohibition: do not use the legacy invasive QwenVoice UI automation workflow in this checkout, and do not reintroduce any XCUI-driven `ui`, `design`, or `perf` automation lane. Do not run localhost test-control routes, background app-driving automation, automated screenshot/design capture flows, or checked-in XCUI app-driving suites, even if older scripts or docs still mention them.
- Use repo-local skills as the first specialization layer:
  - `qwenvoice-packaged-validation` for packaged builds, release-artifact validation, native bundle proof, and manual Computer Use follow-through after cheap repo gates
  - `qwenvoice-vendored-runtime` for vendored Python, ffmpeg, `mlx-audio`, `mlx-audio-swift`, backend helper overlay, and packaged runtime changes
  - `qwenvoice-doc-sync` for contributor and repo docs
  - `qwenvoice-release-publish` for versioning and release publication flows
- Use Codex Computer Use instead when visual or interaction truth matters after repo checks have already narrowed the problem. Good fits include main-window chrome, sidebar/search/toolbar behavior, Settings scene issues, sheet presentation, playback controls, menu-style picker behavior, and packaged-app visual confirmation after automated validation.
- When using Computer Use, follow this order: run `./scripts/check_project_inputs.sh`, `python3 scripts/harness.py validate`, and the smallest relevant source gate first, then inspect the live app state and interact only with the exact flow under investigation.
- Prefer AppleScript or equivalent structured macOS automation over click-based interaction when the task is operational rather than visual. Good fits include launching or quitting `QwenVoice`, focusing the app, preparing stable window state, ensuring only one app instance is running, coordinating Finder or file-chooser flows, and setting up reproducible packaging-validation runs.
- Use native image generation for architecture diagrams, UI mockups, and explanatory visuals only. Do not treat generated images as evidence that a QwenVoice implementation is correct.
- For Apple-platform API lookup, prefer Apple docs tools when they are actually exposed in the session.
- Only rely on tools that are surfaced in the current session. Treat configured-but-unavailable MCP servers as optional accelerators, not as assumptions baked into the repo workflow.

## Architecture Boundaries

- `Sources/QwenVoiceApp.swift` composes shared app services, owns the separate Settings scene, coordinates launch preflight through `AppStartupCoordinator`, `BackendLaunchCoordinator`, `AppLaunchConfiguration`, and `UITestWindowCoordinator`, and selects the app-facing TTS engine through `AppEngineSelection`.
- `Sources/ContentView.swift` owns `NavigationSplitView`, main-window toolbar/search/titlebar chrome, sidebar selection, and the persisted generation drafts that survive navigation between generation screens.
- `Sources/Services/AppPaths.swift` is the path boundary for app support, models, outputs, voices, and the `QWENVOICE_APP_SUPPORT_DIR` override used by harness and fixture-backed runs.
- `Sources/Models/TTSContract.swift` and `Sources/Models/TTSModel.swift` load `Sources/Resources/qwenvoice_contract.json`. Change the manifest first for model, speaker, output-subfolder, or required-file updates.
- `Sources/Services/AppCommandRouter.swift` and `Sources/Services/GenerationLibraryEvents.swift` are the typed MainActor event boundaries for screen navigation and history refresh. Keep harness-only `NotificationCenter` traffic inside the explicit test-support surfaces.
- `Sources/Services/PythonEnvironmentManager.swift` is the source/debug Python-readiness façade. Runtime discovery and setup live in `PythonRuntimeDiscovery.swift`, `PythonRuntimeProvisioner.swift`, `RequirementsInstaller.swift`, `PythonRuntimeValidator.swift`, and `EnvironmentSetupStateMachine.swift`. Do not casually change Python version search order, bundled-runtime validation, or `.setup-complete` marker behavior.
- `Sources/Services/PythonBridge.swift` remains the source/debug backend façade. Process launch, JSON-RPC transport, streaming state, model-load dedupe, clone priming, sidebar activity, and mode-specific flows live in `PythonProcessManager.swift`, `PythonJSONRPCTransport.swift`, `GenerationStreamCoordinator.swift`, `ModelLoadCoordinator.swift`, `ClonePreparationCoordinator.swift`, `PythonBridgeActivityCoordinator.swift`, `PythonBridge+GenerationFlows.swift`, and `StubBackendTransport.swift`.
- The backend RPC surface already includes app-visible coordination methods such as `prewarm_model`, `prepare_clone_reference`, `prime_clone_reference`, `get_model_info`, `get_speakers`, `list_voices`, `enroll_voice`, and `delete_voice`. If you change those payloads or semantics, keep Swift, Python, harness, and docs in sync.
- `Sources/Resources/backend/server.py` is the thin Python entrypoint and wiring layer for the retained source/debug backend. Backend behavior is split across `backend_state.py`, `rpc_transport.py`, `output_paths.py`, `audio_io.py`, `clone_context.py`, `generation_pipeline.py`, and `rpc_handlers.py`. Shipped app bundles must not include `Contents/Resources/backend/`.
- `Sources/Services/GenerationPersistence.swift` centralizes save and autoplay handoff for the three generation screens. `Sources/Services/DatabaseService.swift` owns the GRDB SQLite history database and is `@MainActor`; keep persistence and library-refresh behavior aligned.
- `Sources/QwenVoiceNative/` plus `third_party_patches/mlx-audio-swift/` are the native backend boundary. Keep native runtime, load-state, and synthesis work there. The shipped app now defaults `TTSEngineStore` to `NativeMLXMacEngine` through `AppEngineSelection`, while `QWENVOICE_APP_ENGINE=python` remains the source/debug compatibility path. `UITestStubMacEngine` remains available only for fixture-backed manual desktop-control runs and lightweight packaged startup smoke support.
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
- In manual Computer Use passes, macOS picker-style controls often surface as menu buttons and menu items rather than ordinary buttons.
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

# Opt-in live native engine smoke against an installed pro_custom model
QWENVOICE_ENABLE_NATIVE_ENGINE_LIVE_TESTS=1 xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice -destination 'platform=macOS' -only-testing:QwenVoiceTests/NativeMLXMacEngineLiveTests test

# Swift / Python / contract / audio / RPC layers
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer pipeline
python3 scripts/harness.py test --layer server
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer rpc
python3 scripts/harness.py test --layer audio

# Packaged release-artifact validation
python3 scripts/harness.py test --layer release --artifacts-root <dir>

# Diagnostics and targeted benchmarks
python3 scripts/harness.py diagnose
python3 scripts/harness.py bench --category clone_regression
python3 scripts/harness.py bench --category tts_roundtrip
```

Notes:

- `scripts/harness.py` is the primary testing, diagnostic, and benchmark entrypoint.
- On this machine, keep validation deliberately low-RAM and serialized: run the cheapest relevant gate first, and never overlap heavy `xcodebuild`, `scripts/harness.py`, `./scripts/release.sh`, live app validation, or native smoke processes.
- `python3 scripts/harness.py test --layer all` runs the normal combined source layers (`pipeline`, `server`, `contract`, `rpc`, `swift`, `audio`) and excludes `release`.
- There are no maintained automated `ui`, `design`, or `perf` harness lanes in this checkout. Use scoped Codex Computer Use instead for any visual or interaction verification after the cheap repo gates are green.
- `QWENVOICE_APP_ENGINE=native|python` is the internal app-engine override. Normal app runs default to `native`, `python` remains the source/debug compatibility path, and manual fixture-backed desktop-control runs can still opt into `UITestStubMacEngine` when deterministic app-shell behavior is useful.
- Do not jump to `QWENVOICE_ENABLE_NATIVE_ENGINE_LIVE_TESTS=1 ... NativeMLXMacEngineLiveTests ...`, `./scripts/release.sh`, `python3 scripts/harness.py test --layer release ...`, or a manual Computer Use pass until `./scripts/check_project_inputs.sh`, `python3 scripts/harness.py validate`, and the smallest relevant targeted source gate are already green.
- If a command starts a broad cold rebuild of the native MLX stack and that rebuild is not strictly required to answer the question, stop and re-scope instead of letting it continue.
- `AppPaths.appSupportDir` respects `QWENVOICE_APP_SUPPORT_DIR`; the harness sets that for fixture-backed runs. Do not hardcode `~/Library/Application Support/QwenVoice/` in new test flows if they are supposed to be isolated.
- `QWENVOICE_UI_TEST_APPEARANCE=light|dark|system` remains available when you need a stable light or dark manual Computer Use pass.
- `python3 scripts/harness.py test --layer release ...` is for workflow-built artifacts and packaged startup smoke. Prefer a downloaded or extracted final artifact bundle from `Release Dual UI`, not local ad hoc DMGs and not the intermediate build-only artifact set.
- `python3 scripts/harness.py bench ...` typically requires the app runtime plus installed models. Prefer tiny prompts and serialized `benchmark=true` runs for profiling and regression isolation.
- `python3 scripts/harness.py bench --category tts_roundtrip` also requires a locally available ASR evaluator. Set `QWENVOICE_TTS_ROUNDTRIP_ASR_MODEL` to an installed local path or cached Hugging Face repo if you want to override the default candidate list; otherwise the benchmark skips cleanly.

## CI And Release Workflows

The active GitHub workflows are:

- `Project Inputs` for checked-in project and resource validation
- `Test Suite` for source tests, strict-concurrency and alternate-profile compilation, packaged builds, and source-backend compatibility
- `Release Dual UI` for building, signing, notarizing, and optionally publishing the shipped DMGs

Release facts:

- Official shipped DMGs are `QwenVoice-macos26.dmg` and `QwenVoice-macos15.dmg`.
- `Release Dual UI` has three stages: `build-release`, `notarize-release`, and `publish-release`.
- Intermediate build artifacts are uploaded as `qwenvoice-dual-ui-build-<run-number>-<variant>[-label]`.
- Final notarized artifact bundles are uploaded as `qwenvoice-dual-ui-<run-number>-final[-label]` and are the preferred source for downloaded release validation.
- Shipped app bundles and notarized DMGs must not contain `Contents/Resources/backend`, `Contents/Resources/python`, or bundled `Contents/Resources/ffmpeg`.
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
- App-support path handling or manual fixture behavior:
  Review `AppPaths.swift`, `UITestAutomationSupport.swift`, `UITestWindowCoordinator.swift`, `scripts/harness_lib/ui_test_support.py`, and any packaged startup smoke or Computer Use launch guidance together.
- Appearance-sensitive UI work:
  Use scoped Computer Use passes for light and dark checks when the changed flow depends on appearance, and keep any documented manual screenshot workflow aligned.
- Packaged validation, release artifacts, or native bundle-boundary checks:
  Prefer `qwenvoice-packaged-validation`, validate through the harness packaged and release lanes, use `./scripts/verify_release_bundle.sh`, and rely on Computer Use rather than automated XCUI or screenshot-diff proof for visual confirmation.
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
- Never overlap heavy `xcodebuild`, `scripts/harness.py`, `./scripts/release.sh`, live app validation, or native smoke processes on this machine.
- Always start with the smallest relevant gate: `./scripts/check_project_inputs.sh`, `python3 scripts/harness.py validate`, then the narrowest targeted `python3 scripts/harness.py test --layer ...` or targeted `xcodebuild`.
- Never restart or re-enable the legacy invasive QwenVoice UI automation workflow after it has been stopped. If visual verification is needed, use scoped Computer Use interaction instead of automated app-driving or localhost test-control tooling.
- Treat live native smoke, local packaging, packaged-release validation, and any manual Computer Use pass as later-stage proof, not default first steps.
- Never run more than one heavy model load, generation, or benchmark at a time.
- Never run clone or custom comparisons side by side or in parallel processes.
- For clone-mode investigations, cold and warm runs may share one backend process only when intentionally measuring cache reuse. Do not overlap that process with any other model process.
- If comparing two implementations or two packaged apps, run them in separate serial passes, not concurrently.
- Unload the current model and let the backend fully exit before starting the next heavy comparison run.
- Verify idle state with a lightweight process check before starting another heavy run, especially before clone benchmarks or helper/runtime comparisons.
- If a heavy command begins a cold rebuild of the full MLX/native stack and that rebuild is not essential to answer the question, abort it and re-scope to a cheaper lane.
- Use Computer Use only after heavy automation is finished; never keep desktop interaction active while memory-heavy build or validation work is still running.

## Before Finishing

- Confirm Swift and Python still agree on cross-process behavior after any RPC or contract change.
- Prefer manifest-backed data over duplicated constants.
- Keep accessibility identifiers stable when UI control types change.
- If you changed main-window chrome, navigation, or search behavior, verify the ownership still lives in `ContentView`.
- If you changed Preferences behavior, remember it lives in a separate Settings window.
- For doc-only refreshes, rerun the stale-reference grep and verify referenced commands, workflows, artifact names, and doc links still exist.
- Run the most relevant harness layer plus `python3 scripts/harness.py validate` before calling work complete.
