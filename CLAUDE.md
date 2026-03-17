# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Summary

QwenVoice is a native macOS SwiftUI app (macOS 15+, Apple Silicon only) that runs Qwen3-TTS inference locally. It uses a two-process architecture:

1. **SwiftUI frontend** (`Sources/`) — UI, model downloads, playback, history persistence (SQLite via GRDB)
2. **Python backend** (`Sources/Resources/backend/server.py`) — MLX inference, communicates with Swift over newline-delimited JSON-RPC 2.0 on `stdin`/`stdout`

## Build Commands

```bash
# Regenerate .xcodeproj from project.yml (required after adding/removing source files)
./scripts/regenerate_project.sh

# Validate project inputs
./scripts/check_project_inputs.sh

# Build
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice clean build

# Local release DMG
./scripts/release.sh
```

## Test Commands

```bash
# UI test suites (XCUITest on macOS)
./scripts/run_tests.sh                                               # default
./scripts/run_tests.sh --suite smoke                                 # one test per UI class, stub-backed
./scripts/run_tests.sh --suite ui                                    # non-generation UI coverage
./scripts/run_tests.sh --suite integration                           # GenerationFlowTests (live backend)
./scripts/run_tests.sh --suite all                                   # ui + integration
./scripts/run_tests.sh --suite feature-matrix                        # deterministic fixture-driven coverage
./scripts/run_tests.sh --list                                        # list available tests
./scripts/run_tests.sh --class SidebarNavigation                     # single class
./scripts/run_tests.sh --test CustomVoiceViewTests/testCustomVoiceScreenCoreLayout  # single test

# Python backend tests
./scripts/run_backend_tests.sh

# Full automation stack
./scripts/run_full_app_automation.sh
```

**Before any UI test run:** terminate any running `QwenVoice`, `server.py`, `QwenVoiceUITests-Runner`, and `xcodebuild` processes. Never run parallel macOS UI suites. Check `build/test/results/progress.txt`, `latest-progress.txt`, and `infrastructure-failure.txt` to distinguish XCTest infrastructure failures from assertion failures.

## Architecture

### Source of Truth Priority

1. `Sources/` (live Swift code)
2. `QwenVoiceUITests/`, `QwenVoiceTests/`, `backend_tests/`
3. `project.yml` (XcodeGen manifest — drives `.xcodeproj`)
4. `docs/reference/current-state.md`
5. Prose docs

### Swift Frontend

- `QwenVoiceApp.swift` — app entry, shared services, app-support directory creation
- `ContentView.swift` — `NavigationSplitView` shell; routes the six sidebar destinations; owns all main-window titlebar/toolbar/search chrome (not child views)
- `PythonEnvironmentManager` — gates launch through `SetupView` until Python venv is ready
- `CustomVoiceView` — preset-speaker generation; `VoiceDesignView` — standalone voice design generation; `VoiceCloningView` — clone-from-reference generation
- All three generation views can present `BatchGenerationSheet`; single-generation flows use live streaming preview
- `GenerationWorkflowView` and related shared components drive the compact editor-first generation layout
- `HistoryView`, `VoicesView`, `ModelsView` — list-first management surfaces; toolbar/search affordances are owned by `ContentView`, not by these views
- `PreferencesView` lives in the app's `Settings` scene (opened via Cmd-,), not the main sidebar

### Python Backend RPC

`server.py` handles: `ping`, `init`, `load_model`, `prewarm_model`, `unload_model`, `generate`, `convert_audio`, `list_voices`, `enroll_voice`, `delete_voice`, `get_model_info`, `get_speakers`.

### Shared Contract

`Sources/Resources/qwenvoice_contract.json` is the source of truth for model registry, speakers, default speaker, output subfolders, required model files, and Hugging Face repos. Both Swift (`TTSContract.swift`, `TTSModel.swift`) and Python (`server.py`) load it. **Update the manifest first** when models/speakers/tiers change.

### Runtime Data Layout

```
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

## Key Change Patterns

### RPC contract change
Update together: `server.py` → `PythonBridge.swift` → `RPCMessage.swift` (if payload types change) → affected views, tests, docs.

### Models or speakers change
Update together: `qwenvoice_contract.json` → Swift/Python consumers → docs/tests asserting names or counts.

### Adding or renaming source files
1. Update `project.yml` if needed
2. Run `./scripts/regenerate_project.sh`
3. Verify the generated `.xcodeproj` did not pick up `__pycache__` or `.pyc` paths

## UI Test Conventions

- Most smoke/layout/navigation tests use `StubbedQwenVoiceUITestBase` (launches with `QWENVOICE_UI_TEST_BACKEND_MODE=stub`, isolated app-support/defaults state)
- Live backend UI tests are reserved for explicit integration/generation coverage (`GenerationFlowTests`)
- `QwenVoiceUITestBase` defaults to `freshPerTest` launches; use `launchProfile` to control backend mode and state isolation
- macOS `Picker`/`Menu` controls surface as `MenuButton`/`MenuItem` in XCUI — do not assume `.button` elements
- History uses a native AppKit-backed toolbar search field — use helpers in `QwenVoiceUITestBase` rather than assuming a fixed element hierarchy
- Main-window toolbar/search chrome is owned by `ContentView`; hidden cached screens must not leak toolbar controls across tabs
- Accessibility identifiers must stay stable across control-type changes — many feature-matrix tests depend on them
- When testing Preferences, explicitly open the Settings window (Cmd-, path), not the main sidebar

## Project File Management

`project.yml` is the XcodeGen source for `QwenVoice.xcodeproj`. Always use `./scripts/regenerate_project.sh` (not raw `xcodegen generate`) when regeneration is needed. Current version: `1.1.7` / build `10`.

## Documentation

- `docs/reference/current-state.md` — shared factual reference; keep aligned with `AGENTS.md`
- `docs/reference/testing.md` — full test inventory and runner behavior
- `qwen_tone.md` — tone/emotion guidance for Custom Voice and Voice Design
