# AGENTS.md

This is the primary repo guide for coding agents working in QwenVoice.
Read this before tool-specific supplements such as `CLAUDE.md`.

## Repo Overview

QwenVoice is a native macOS SwiftUI app for offline Qwen3-TTS on Apple Silicon.
The repo has three important layers:

- `Sources/` contains the shipping macOS app.
- `Sources/Resources/backend/server.py` contains the long-lived Python JSON-RPC backend used by the app.
- `Sources/Resources/qwenvoice_contract.json` is the shared Swift/Python contract for models, speakers, output subfolders, and required files.

There is also a standalone CLI in `cli/`, but it is not the source of truth for the shipped GUI UX.

## Source Of Truth

When repo facts disagree, trust sources in this order:

1. `Sources/` for live app behavior and runtime rules
2. `project.yml` for XcodeGen project structure, build flags, and version/build numbers
3. `scripts/` for validation, testing, packaging, and release behavior
4. `docs/reference/current-state.md` and `docs/reference/engineering-status.md` for maintained repo facts
5. Other prose docs such as `README.md`, `qwen_tone.md`, and dated report placeholders

Important exception:

- `Sources/Resources/qwenvoice_contract.json` is the source of truth for shared model and speaker metadata even though it lives under `Sources/Resources/`.

Prefer code, manifests, and scripts over prose whenever they disagree.

## Safe Edit Boundaries

- `project.yml` drives `QwenVoice.xcodeproj`. Prefer editing `project.yml` and regenerating the project over hand-editing generated Xcode project files.
- `Sources/Resources/python/`, `Sources/Resources/ffmpeg/`, and most contents of `Sources/Resources/vendor/` are generated or vendored runtime assets. Update them through the packaging or vendoring scripts, not by ad hoc manual edits.
- `third_party_patches/mlx-audio/` and `Sources/Resources/backend/mlx_audio_qwen_speed_patch.py` are coupled through the helper-sync workflow. Keep them aligned.
- App data under `~/Library/Application Support/QwenVoice/` is runtime state, not repo source.
- Watch for accidental `__pycache__` and `.pyc` paths when regenerating or reviewing changes.

## Project-Local Skills

QwenVoice now has repo-tracked local skills under `.agents/skills/`. Prefer these when the task matches their scope instead of rediscovering the same repo-specific workflows from scratch:

- `qwenvoice-packaged-validation` for packaged-app validation, dual-UI release artifact checks, bundled dependency proof, screenshot-capture prompt issues, and full automated validation requests.
- `qwenvoice-release-publish` for version/build bumps, checked-in release notes, CI gate waiting, `release-dual-ui` dispatch, and GitHub release verification.
- `qwenvoice-vendored-runtime` for `mlx-audio`, backend helper overlay and runtime packaging changes, `build_mlx_audio_wheel.sh`, bundled Python and ffmpeg flows, and packaged runtime verification.
- `qwenvoice-doc-sync` for README, AGENTS, current-state, and release-notes sync against `Sources/`, `project.yml`, and `scripts/`.

These local skills complement, rather than replace, the user-wide skills that are already useful in this repo:

- `swift-concurrency-expert`
- `swiftui-liquid-glass`
- `swiftui-performance-audit`
- `swiftui-view-refactor`
- `simplify-code`
- `github`
- `gh-fix-ci`
- `app-store-changelog`

## Architecture Boundaries

- `Sources/QwenVoiceApp.swift` creates shared app services and owns the separate Settings scene.
- `Sources/ContentView.swift` owns `NavigationSplitView`, main-window toolbar/search/titlebar chrome, and the activated-screen lifecycle that preserves drafts across sidebar navigation.
- `Sources/Services/PythonEnvironmentManager.swift` owns dev-venv setup, bundled-runtime validation, readiness state, and backend restart policy. Do not casually change Python version search order, marker behavior, or bundled-runtime checks.
- `Sources/Services/PythonBridge.swift` owns the long-lived Python subprocess, JSON-RPC request/response flow, timeouts, streaming chunk notifications, and backend error handling.
- `Sources/Resources/backend/server.py` owns backend RPC handlers, model lifecycle, clone preparation, audio conversion, streaming output, and runtime capability detection.
- `Sources/ViewModels/AudioPlayerViewModel.swift` isolates timer-frequency playback state in nested `PlaybackProgress`. Do not move high-frequency playback fields back onto the parent observable object.
- `Sources/Services/DatabaseService.swift` is `@MainActor`. Access it from MainActor-isolated code.
- `cli/main.py` is a separate terminal app with cwd-based paths and a broader speaker map than the shipped GUI. Do not copy CLI assumptions into the app contract or app docs.

Large coordinator files deserve small, surgical changes and focused verification:

- `Sources/Services/PythonBridge.swift`
- `Sources/Resources/backend/server.py`
- `Sources/Services/PythonEnvironmentManager.swift`
- `scripts/harness_lib/test_runner.py`

## UI And Build Constraints

- Preferences live in the app's Settings scene, not in the main sidebar flow.
- `SetupView` intentionally receives `envManager` as `@ObservedObject`, not `@EnvironmentObject`, because it is shown before environment injection is attached in `QwenVoiceApp`.
- Voice Cloning does not expose delivery or emotion controls. The base clone model ignores them.
- `Sources/Views/Components/TextInputView.swift` uses an `NSTextView` wrapper for placeholder alignment and scrollbar behavior. Do not replace it with SwiftUI `TextEditor`.
- macOS picker-style controls often surface as `MenuButton` and `MenuItem` in XCUI, not ordinary buttons.
- The UI has dual compile-time profiles: `QW_UI_LIQUID` and `QW_UI_LEGACY_GLASS`.
- `QW_UI_LIQUID` still needs a macOS 26 SDK. Keep shared styling centralized in `Sources/Views/Components/AppTheme.swift`, and avoid `Shape.fill(...).glassEffect(...)` chains that fail on older compiler and SDK combinations.

## Required Workflows

Start with repo truth first:

- Search with `rg`, inspect source, manifests, and scripts before assuming docs are current.
- Prefer repo scripts and `xcodebuild` over improvised one-off workflows.

Core commands:

```bash
# Validate repo inputs and fast sanity
./scripts/check_project_inputs.sh
python3 scripts/harness.py validate

# Regenerate project after adding, removing, or renaming tracked source files
./scripts/regenerate_project.sh

# Build
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build

# Swift unit tests
python3 scripts/harness.py test --layer swift

# Pure Python layers
python3 scripts/harness.py test --layer pipeline
python3 scripts/harness.py test --layer server
python3 scripts/harness.py test --layer contract

# Integration, UI, design, and perf checks
python3 scripts/harness.py test --layer rpc
python3 scripts/harness.py test --layer ui
python3 scripts/harness.py test --layer design
python3 scripts/harness.py test --layer perf

# Packaged release validation
python3 scripts/harness.py test --layer release --artifacts-root <dir> --ui-backend-mode live --ui-data-root fixture

# Diagnostics and release packaging
python3 scripts/harness.py diagnose
./scripts/release.sh
./scripts/verify_release_bundle.sh
```

Notes:

- `scripts/harness.py` is the primary testing and diagnostics entrypoint.
- `python3 scripts/harness.py test --layer all` runs the normal combined layers and excludes `ui`, `design`, and `perf`.
- `python3 scripts/harness.py test --layer ui`, `design`, and `perf` now default to `--ui-backend-mode live --ui-data-root fixture`, which reuses the installed runtime/models while isolating writable app state in a disposable fixture root.
- `QWENVOICE_UI_TEST_APPEARANCE=light|dark|system` is the supported appearance override for UI and design runs. When appearance is forced, `python3 scripts/harness.py test --layer design` resolves baselines from `tests/screenshots/baselines/<appearance>/`.
- Packaged validation should prefer the harness packaged or release lanes plus `./scripts/verify_release_bundle.sh` over ad hoc manual app launches. Prefer `qwenvoice-packaged-validation` when that is the main task.
- Local builds on this machine are for dev/testing only and should target the macOS 26 / `QW_UI_LIQUID` surface. Prefer `xcodebuild` or dev-app validation for that path.
- Do not use local packaging on this machine as proof for release artifacts, and never treat a local macOS 15 package build as valid release validation.
- Official `QwenVoice-macos26.dmg` and `QwenVoice-macos15.dmg` release artifacts must be produced by the GitHub `Release Dual UI` workflow, then validated from the resulting workflow artifacts or downloaded DMGs.
- Release signing and notarization belong in the GitHub workflow as well. Import the Developer ID Application certificate and App Store Connect API key credentials in Actions, sign each runner's `.app`, notarize and staple each runner's DMG, and do not treat local packaging as release-signing proof.
- For App Store Connect API key auth, keep `APPLE_NOTARY_ISSUER_ID` optional: include it for Team keys and omit it for Individual keys.
- Screenshot-based UI validation should default to `QWENVOICE_UITEST_CAPTURE_MODE=content`. This is the correct automated comparison path, but it is not the highest-fidelity representation of Liquid Glass; for explicit visual-fidelity checks, use real window capture instead of treating content capture as the source of truth for appearance polish.
- Run forced `light` and `dark` `design` lanes sequentially, not in parallel, because they share the UI app and transport and can interfere with each other.
- Tagged publishes should use the `release-dual-ui` workflow with checked-in release notes and the release inputs, including `release_notes_path`. Prefer `qwenvoice-release-publish` for that flow.
- Vendored runtime work should patch through the repo-owned vendoring flow, not by hand-editing bundled runtime assets. Prefer `qwenvoice-vendored-runtime` when the task centers on `mlx-audio`, bundled Python, or packaged dependency behavior.
- For doc refreshes after behavior or workflow changes, prefer `qwenvoice-doc-sync`.
- Benchmarks exist under `scripts/harness.py bench ...` and typically require the app Python environment plus installed models.
- For clone-helper regression isolation, use `python3 scripts/harness.py bench --category clone_regression`. It runs the 1.2.2 helper and current helper in separate serialized backend processes on the same saved reference.
- For performance or regression profiling, prefer tiny prompts and serialized `benchmark=true` runs. Do not add heavy profiling lanes to `bench --category all`.

## When Changing X, Also Update Y

- RPC contract or payload shape changes:
  Update `Sources/Resources/backend/server.py`, `Sources/Services/PythonBridge.swift`, `Sources/Models/RPCMessage.swift` if needed, affected Swift views/view models, and relevant docs/tests.
- Model registry, speakers, output folders, or required model files:
  Update `Sources/Resources/qwenvoice_contract.json` first, then Swift/Python consumers, then contract-facing docs and tests.
- Adding or renaming source files:
  Update `project.yml`, run `./scripts/regenerate_project.sh`, and confirm generated project files did not capture `__pycache__` or `.pyc` paths.
- `clone_delivery_pipeline.py` behavior:
  Run `python3 scripts/harness.py test --layer pipeline` and update backend call sites if the pipeline interface changed.
- Pure backend helpers in `server.py`:
  Run `python3 scripts/harness.py test --layer server`.
- Playback or streaming behavior:
  Review `Sources/ViewModels/AudioPlayerViewModel.swift`, `Sources/Services/PythonBridge.swift`, and `Sources/Services/GenerationPersistence.swift` together.
- Generation persistence or autoplay:
  Prefer `Sources/Services/GenerationPersistence.swift` over duplicating logic inside individual generation views.
- History or database access:
  Keep `Sources/Services/DatabaseService.swift` and affected library views in sync, and respect MainActor isolation.
- Appearance-sensitive UI or design-baseline work:
  Keep `QWENVOICE_UI_TEST_APPEARANCE=light` and `dark` coverage green, and refresh the matching committed baselines under `tests/screenshots/baselines/light/` and `tests/screenshots/baselines/dark/` when the intended visual output changes.
- Packaged validation, release artifacts, or bundled dependency checks:
  Prefer `qwenvoice-packaged-validation`, validate through the harness packaged or release lanes, use `./scripts/verify_release_bundle.sh`, and default screenshot checks to `QWENVOICE_UITEST_CAPTURE_MODE=content`.
- GitHub release publication or hosted release notes:
  Prefer `qwenvoice-release-publish`, require a checked-in notes file, and keep the `release-dual-ui` workflow inputs aligned, including `release_notes_path`.
- Vendored runtime or `mlx-audio` changes:
  Prefer `qwenvoice-vendored-runtime`, keep `scripts/build_mlx_audio_wheel.sh`, `third_party_patches/mlx-audio/`, `Sources/Resources/backend/mlx_audio_qwen_speed_patch.py`, `docs/reference/vendoring-runtime.md`, and the release verification flow aligned.
- Broad repo facts that users or contributors rely on:
  Prefer `qwenvoice-doc-sync`, and update `docs/reference/current-state.md`, `docs/README.md`, and any top-level guidance docs that claim the changed behavior.

## CLI Boundary

The root guide is app-first.
For CLI-only work, also read:

- `cli/README.md`
- `cli/CLAUDE.md`

Keep these boundaries in mind:

- The CLI is a standalone interactive terminal app, not the app backend.
- The CLI still carries its own speaker map in `cli/main.py`.
- The GUI app contract lives in `Sources/Resources/qwenvoice_contract.json`, not in CLI constants.

## Current Documentation Warnings

There is known doc drift in the repo today:

- Older local clones may still have stale references to `./scripts/run_tests.sh`, `./scripts/run_backend_tests.sh`, or `docs/reference/testing.md`; those are not valid repo entrypoints.

Use the harness commands in this file and the existing reference docs instead of following those stale test references.

## Operational Safety

- Avoid running multiple `QwenVoice` app instances at once while debugging model loads or playback.
- Prefer killing an old instance before launching a new build.
- Prefer asking before launching the full app unless the task clearly requires it.
- Never run local macOS 15 release packaging on this machine. Use GitHub workflow artifacts for that surface.
- Never run more than one heavy model load, generation, or benchmark at a time.
- Never run clone/custom comparisons side by side or in parallel processes.
- For clone-mode investigations, cold and warm runs may share one backend process only when intentionally measuring cache reuse. Do not overlap that process with any other model process.
- If comparing two implementations, run them in separate serial passes, not concurrently.
- Unload the current model and let the backend fully exit before starting the next heavy comparison run.
- Verify idle state with a lightweight process check before starting another heavy run, especially before clone benchmarks or helper/runtime comparisons.

## Before Finishing

- Confirm Swift and Python still agree on cross-process behavior after any RPC or contract change.
- Prefer manifest-backed data over duplicated constants.
- Keep accessibility identifiers stable when UI control types change.
- If you changed main-window chrome, navigation, or search behavior, verify the ownership still lives in `ContentView`.
- If you changed Preferences behavior, remember it lives in a separate Settings window.
- Run the most relevant harness layer plus `python3 scripts/harness.py validate` before calling work complete.
