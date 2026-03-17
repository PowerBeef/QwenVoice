# AGENTS.md

This file applies to the repository at `/Users/patricedery/Coding_Projects/QwenVoice`.

Run repo-level commands from:

```bash
cd /Users/patricedery/Coding_Projects/QwenVoice
```

## Project Summary

QwenVoice is a native macOS SwiftUI app for running Qwen3-TTS locally on Apple Silicon. It uses:

1. a SwiftUI frontend for UI state, downloads, playback, persistence, and setup
2. a long-lived Python backend at `Sources/Resources/backend/server.py` that communicates with Swift over newline-delimited JSON-RPC 2.0 on `stdin`/`stdout`

The app targets macOS 15+, Apple Silicon only, and currently ships six main-window sidebar destinations plus a dedicated macOS Settings window:

1. Custom Voice
2. Voice Design
3. Voice Cloning
4. History
5. Saved Voices
6. Models
Voice Design is a standalone generation destination backed by `VoiceDesignView`. `CustomVoiceView` is now the preset-speaker-only surface. Preferences live in `PreferencesView` inside the app's `Settings` scene instead of the main sidebar.
The current UI direction is native macOS first: the main shell uses `NavigationSplitView`, generation screens are compact editor-first workflows, and library/management surfaces are list-first with toolbar-driven actions.

## Source of Truth

Trust the live code and manifest before prose:

1. `Sources/`
2. `QwenVoiceUITests/`
3. `QwenVoiceTests/`
4. `backend_tests/`
5. `scripts/`
6. `project.yml`
7. prose docs

Shared current repo facts live in [`docs/reference/current-state.md`](docs/reference/current-state.md). Keep this file aligned with it.

## Codex Workflow

This repository is a native macOS SwiftUI app. For normal QwenVoice work, prefer repo scripts and shell `xcodebuild` flows for build, test, and validation.

- Default execution order for this repo:
  1. local repo truth first (`rg`, source, tests, scripts, manifests)
  2. shell/script `xcodebuild` flows for normal build and test work
  3. `xcode-mcp` when project/file/build-setting inspection is faster or less ambiguous than shell discovery
  4. `XcodeBuildMCP` only when a visual build/run/log/screenshot workflow is genuinely helpful
- Do not default to iOS simulator workflows. `ios-debugger-agent` and simulator-heavy `XcodeBuildMCP` flows are only for explicitly requested iOS/simulator work or a compatible visual debugging workflow.
- Use browser-facing MCPs only for web docs, hosted tools, or browser tasks. They are not the default path for the native app UI.
- If a preferred skill or MCP is unavailable in the current session, fall back to shell commands and the repo scripts rather than blocking.

### Native UI and UI-test notes

- The main app window and the Settings window are separate scenes. Do not assume Preferences is part of sidebar routing or that opening the app to a preferences fixture automatically makes the Settings scene frontmost.
- The main-window detail stack keeps previously visited sidebar screens alive for draft preservation. Window titlebar chrome for the main scene must therefore be owned by `ContentView`, not by cached child screens, or hidden views can leak toolbar/search controls across tabs.
- When testing or automating Preferences, explicitly open the Settings window (`Cmd-,` / `showSettingsWindow:` path) and be prepared to scroll within the Settings form before interacting with lower maintenance controls.
- On macOS, SwiftUI `Picker` and `Menu` controls often surface as `MenuButton` plus `MenuItem` in XCUI. Do not assume these controls are exposed as plain `.button` elements.
- History uses shell-owned toolbar-native search and sort controls, including a native AppKit-backed toolbar search field. UI tests should prefer the dedicated helpers/fallbacks in `QwenVoiceUITestBase` instead of assuming a fixed search-field hierarchy or a specific XCUI element class for the sort control.
- Preserve accessibility identifiers whenever control types change; many of the deterministic feature-matrix tests depend on stable IDs even when native control wrappers shift.
- `QwenVoiceUITestBase` now uses an explicit launch-profile model. UI-test classes can control backend mode (`stub` vs `live`), state isolation, and launch policy (`sharedPerClass` vs `freshPerTest`) through `launchProfile`, and the default is now `freshPerTest` unless a class explicitly opts into shared sessions.
- `StubbedQwenVoiceUITestBase` is the default base for smoke/layout/navigation/availability UI tests. It launches the app in `QWENVOICE_UI_TEST_BACKEND_MODE=stub` with isolated app-support/defaults state so these tests avoid live backend/bootstrap cost.
- Test-only readiness sentinels now distinguish a visible window shell from a ready main window or ready Settings window. `QwenVoiceUITestBase` waits on those markers instead of treating `window.exists` as sufficient launch success.
- Live backend macOS UI tests are now the exception rather than the default. Keep them for explicit end-to-end generation/integration coverage such as `GenerationFlowTests`, not for basic screen availability or layout assertions.

### Run / UI-test discipline

- Before any app launch or macOS UI-test run, explicitly terminate previous `QwenVoice`, backend `server.py`, `QwenVoiceUITests-Runner`, and repo `xcodebuild` processes.
- Never run parallel macOS UI suites for this repo.
- Keep at most one live app/test instance at a time.
- Clean up those same processes again after the run completes.
- Treat this discipline as part of reliable validation on QwenVoice, not optional housekeeping; it protects both machine stability and UI automation determinism.
- `./scripts/run_tests.sh` now enforces this more aggressively: it performs repo-process cleanup and a short cooldown before runs, classifies XCTest infrastructure failures separately from assertion failures, and retries a single affected smoke filter or targeted run once after an automation bootstrap failure.
- For smoke validation, prefer `./scripts/run_tests.sh --suite smoke` over ad hoc multi-test invocations. The smoke suite now runs sequentially, retries the current filter once on automation bootstrap failures, and then stops early if the infrastructure failure repeats.
- For interrupted or unstable runs, inspect the generated `progress.txt`, `latest-progress.txt`, and `infrastructure-failure.txt` files under `build/test/results/` before assuming an app regression.

### MCP routing

- `desktop-commander` for local file inspection, structured file operations, and search when it is more effective than raw shell output.
- `xcode-mcp` for project structure, file, and build-setting inspection when shell discovery is noisy or ambiguous.
- `XcodeBuildMCP` for build/run/log/screenshot workflows when a visual Xcode-driven path is genuinely helpful, but not as the default execution path for everyday macOS validation.
- `apple-docs` is the first choice for Apple API, SwiftUI, AppKit, and platform guidance.
- `context7` is for third-party framework and library documentation.
- `github` is for hosted repository state, PR metadata, and remote issue context. Normal local git inspection and commits still belong in shell commands.
- `playwright` and `chrome-devtools` for browser-based docs or tools, not the native QwenVoice UI.
- `openaiDeveloperDocs` only when the task is specifically about OpenAI APIs or OpenAI documentation.

## Documentation Boundaries

- `README.md` is the public GitHub landing page.
- `docs/README.md` is the internal docs index.
- `docs/reference/` holds stable current-state reference docs.
- Generated/vendor docs under `Sources/Resources/python/`, `cli/.venv/`, and dependency package directories are out of scope.

## Core Architecture

### Swift frontend

- `QwenVoiceApp.swift` owns the shared app services and creates the app-support directories.
- `ContentView.swift` hosts the `NavigationSplitView`, routes between the six main-window surfaces, and owns the main-window titlebar/title/toolbar chrome that varies by selected sidebar destination.
- `PythonEnvironmentManager` gates launch through `SetupView` until Python is usable.
- `CustomVoiceView` owns preset-speaker Custom Voice generation, while `VoiceDesignView` owns standalone Voice Design generation.
- `VoiceCloningView`, `CustomVoiceView`, and `VoiceDesignView` can present `BatchGenerationSheet`.
- `GenerationWorkflowView` and related shared components drive the compact editor-first generation layout.
- `HistoryView`, `VoicesView`, and `ModelsView` are list-first management surfaces. Their window-level toolbar/search affordances are driven by the shell in `ContentView`, while the views themselves keep list state, sheets, alerts, and row behavior.

### Python backend

`server.py` currently handles:

- `ping`
- `init`
- `load_model`
- `prewarm_model`
- `unload_model`
- `generate`
- `convert_audio`
- `list_voices`
- `enroll_voice`
- `delete_voice`
- `get_model_info`
- `get_speakers`

The shipping GUI uses live streaming preview for single-generation flows and keeps batch generation sequential/non-streaming. Advanced sampling parameters remain benchmark/internal only.
The backend MLX cache policy defaults to `adaptive`. Use `QWENVOICE_CACHE_POLICY=always` only as a conservative diagnostic override.

### Shared contract

Static TTS contract data lives in `Sources/Resources/qwenvoice_contract.json`.

That manifest is the source of truth for:

- model registry
- speakers
- default speaker
- output subfolders
- required model files
- Hugging Face repos

Update the manifest first when models/speakers/tiers/output folders change.

## Runtime Data Layout

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
  history.sqlite
  python/
    .setup-complete
```

If the user sets a custom output directory in Preferences, generated audio may be written outside the default `outputs/` tree.

## Build, Test, and Release

### Common commands

```bash
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice clean build
./scripts/regenerate_project.sh
./scripts/check_project_inputs.sh
./scripts/run_tests.sh
./scripts/run_tests.sh --suite smoke
./scripts/run_tests.sh --suite ui
./scripts/run_tests.sh --suite integration
./scripts/run_tests.sh --suite all
./scripts/run_tests.sh --suite debug
./scripts/run_tests.sh --suite feature-matrix
./scripts/run_tests.sh --list
./scripts/run_tests.sh --class SidebarNavigation
./scripts/run_tests.sh --test CustomVoiceViewTests/testCustomVoiceScreenCoreLayout
./scripts/run_backend_tests.sh
./scripts/run_full_app_automation.sh
./scripts/release.sh
```

### Current test inventory

- UI tests: 19 files / 58 test methods
- Unit tests: 4 files / 23 test methods
- Python backend tests: 35 `unittest` cases

Current automation split:

- smoke/layout/navigation/availability UI tests default to stub-backed isolated launches
- feature-matrix UI tests remain deterministic stub-backed coverage
- live backend UI coverage is intentionally narrower and reserved for explicit generation/integration paths

See [`docs/reference/testing.md`](docs/reference/testing.md) for the current test commands, suites, and caveats.

### Release workflow reality

GitHub Actions currently has:

- `.github/workflows/project-inputs.yml`
- `.github/workflows/release-dual-ui.yml`

The old single-release workflow is gone. The GitHub release workflow builds:

- `QwenVoice-macos26.dmg`
- `QwenVoice-macos15.dmg`

Local `./scripts/release.sh` still produces `build/QwenVoice.dmg` by default unless an explicit output name is provided.

## High-Value Change Patterns

### If you change the RPC contract

Update:

1. `Sources/Resources/backend/server.py`
2. `Sources/Services/PythonBridge.swift`
3. `Sources/Models/RPCMessage.swift` if payload types change
4. affected views, tests, and docs

### If you change models or speakers

Update:

1. `Sources/Resources/qwenvoice_contract.json`
2. Swift or Python consumers that rely on those fields
3. docs/tests that assert current names or counts

### If you add or rename source files

1. update `project.yml` if needed
2. run `./scripts/regenerate_project.sh`
3. verify the generated `.xcodeproj` did not pick up `__pycache__` or `.pyc` paths

## Practical Review Checklist

Before finishing:

1. confirm Swift and Python still agree on any cross-process change
2. keep accessibility identifiers stable or update UI tests in the same change
3. prefer the manifest over duplicated constants
4. prefer `./scripts/regenerate_project.sh` over raw `xcodegen generate`
5. keep `README.md`, `docs/reference/current-state.md`, and `AGENTS.md` aligned when broad repo facts change
6. if a change touches Preferences, validate the separate Settings-window path rather than only the main window
7. if a change touches picker-like controls, verify the actual macOS XCUI exposure (`MenuButton` / `MenuItem` vs. button assumptions)
8. if a change touches main-window toolbar or search chrome, verify the controls are owned by `ContentView` and disappear immediately when leaving the active sidebar destination
9. if a change required app launches or UI tests, verify cleanup happened before and after the run
10. if a change touched UI automation, confirm the implementation and tests did not rely on hidden cached screens, leaked toolbar ownership, or incorrect assumptions about menu-backed macOS controls
11. if a task involved docs or research, confirm the chosen MCP/skill matched the source type (Apple docs vs. third-party docs vs. GitHub vs. OpenAI docs)
