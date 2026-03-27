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
- `build/release-metadata.txt` and release metadata artifacts are generated outputs. Update their source scripts and workflows instead of hand-editing generated metadata.
- `third_party_patches/mlx-audio/` and `Sources/Resources/backend/mlx_audio_qwen_speed_patch.py` are coupled to the vendored `mlx-audio` wheel. Keep them aligned.
- App data under `~/Library/Application Support/QwenVoice/` is runtime state, not repo source.
- Watch for accidental `__pycache__` and `.pyc` paths when regenerating or reviewing changes.

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
- Screenshot-based harness runs now default to permissionless in-app window capture via `QWENVOICE_UITEST_CAPTURE_MODE=content`. Only opt into `QWENVOICE_UITEST_CAPTURE_MODE=system` when you explicitly need system capture and understand that unmanaged Macs will prompt for Screen Recording permission unless PPPC/MDM pre-approves it.

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
python3 scripts/harness.py test --layer release --artifacts-root build/release-downloads/<run-id>

# Diagnostics and release packaging
python3 scripts/harness.py diagnose
./scripts/release.sh
./scripts/verify_release_bundle.sh build/QwenVoice.app
```

Notes:

- `scripts/harness.py` is the primary testing and diagnostics entrypoint.
- `python3 scripts/harness.py validate` now includes runtime-alignment checks for the shipped Python stack and can be pointed at an explicit interpreter with `--python`.
- `python3 scripts/harness.py test --layer all` runs the normal combined layers and excludes `ui`, `design`, and `perf`.
- `python3 scripts/harness.py test --layer ui`, `design`, and `perf` now default to `--ui-backend-mode live --ui-data-root fixture`, which reuses the installed runtime/models while isolating writable app state in a disposable fixture root.
- `python3 scripts/harness.py test --layer release` targets packaged apps or downloaded release artifacts and verifies bundled runtime selection, bundled `ffmpeg`, packaged startup, and packaged UI/perf/generation coverage.
- `scripts/release.sh` and `scripts/verify_release_bundle.sh` are now strict gates: release packaging fails if bundled Python, bundled `ffmpeg`, the runtime manifest, or the backend entrypoint are missing, and verification asserts isolated startup from the packaged runtime.
- GitHub `Test Suite` includes a dedicated `runtime-parity` job that installs from `Sources/Resources/requirements.txt` with vendored wheels. If the shipped Python stack changes, keep that CI lane green.
- GitHub `release-dual-ui.yml` is the source of truth for publishing dual-UI releases. Bump `project.yml` version/build first, wait for green `Project Inputs` and `Test Suite` on that exact commit, create a checked-in release notes file such as `docs/releases/v1.2.md`, then dispatch the workflow with both a real `release_tag` and `release_notes_path`.
- Benchmarks exist under `scripts/harness.py bench ...` and typically require the app Python environment plus installed models.

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
- Vendored runtime or `mlx-audio` changes:
  Keep `scripts/build_mlx_audio_wheel.sh`, `third_party_patches/mlx-audio/`, `Sources/Resources/backend/mlx_audio_qwen_speed_patch.py`, `docs/reference/vendoring-runtime.md`, and the release verification flow aligned.
- Harness screenshot or UI capture behavior:
  Keep `Sources/QwenVoiceApp.swift`, `Sources/Services/UITestAutomationSupport.swift`, `Sources/Services/TestStateServer.swift`, and `scripts/harness_lib/ui_test_support.py` aligned so default test capture stays permissionless.
- Packaged release testing or bundled-runtime diagnostics:
  Keep `scripts/harness.py`, `scripts/harness_lib/test_runner.py`, `scripts/verify_release_bundle.sh`, `Sources/Services/TestStateProvider.swift`, and release workflows aligned.
- Broad repo facts that users or contributors rely on:
  Update `docs/reference/current-state.md`, `docs/README.md`, and any top-level guidance docs that claim the changed behavior.

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

- `README.md` still references `./scripts/run_tests.sh` and `./scripts/run_backend_tests.sh`, but those scripts are not present.
- `README.md` and `TEST_REPORT.md` still point to `docs/reference/testing.md`, but that file is not present.

Use the harness commands in this file and the existing reference docs instead of following those stale test references.

## Operational Safety

- Avoid running multiple `QwenVoice` app instances at once while debugging model loads or playback.
- Prefer killing an old instance before launching a new build.
- Prefer asking before launching the full app unless the task clearly requires it.

## Before Finishing

- Confirm Swift and Python still agree on cross-process behavior after any RPC or contract change.
- Prefer manifest-backed data over duplicated constants.
- Keep accessibility identifiers stable when UI control types change.
- If you changed main-window chrome, navigation, or search behavior, verify the ownership still lives in `ContentView`.
- If you changed Preferences behavior, remember it lives in a separate Settings window.
- Run the most relevant harness layer plus `python3 scripts/harness.py validate` before calling work complete.
