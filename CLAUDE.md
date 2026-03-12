# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Start Here

Current repo facts are centralized in:

- [`docs/reference/current-state.md`](docs/reference/current-state.md) — version, models, speakers, runtime layout
- [`docs/reference/testing.md`](docs/reference/testing.md) — test inventory and commands
- [`docs/reference/engineering-status.md`](docs/reference/engineering-status.md) — strengths and caveats

Use those files as the shared factual baseline instead of duplicating repo state here.

## What This Is

QwenVoice is a native macOS SwiftUI app for local Qwen3-TTS on Apple Silicon. Two-process architecture:

- **SwiftUI frontend** (`Sources/`) — UI, model downloads, playback, persistence, first-launch setup
- **Python backend** (`Sources/Resources/backend/server.py`) — MLX inference via a long-lived subprocess
- **Shared contract** (`Sources/Resources/qwenvoice_contract.json`) — source of truth for models, speakers, tiers, HuggingFace repos, required files

The app ships six sidebar destinations: Custom Voice, Voice Cloning, History, Voices, Models, Preferences. Voice Design is embedded inside `CustomVoiceView` behind a mode switch (Preset Speaker / Voice Design).

## Commands

```bash
# Build
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice clean build

# Project regeneration (always use this, not raw xcodegen generate)
./scripts/regenerate_project.sh

# Tests
./scripts/run_tests.sh                                              # all UI tests
./scripts/run_tests.sh --suite ui                                   # non-generation UI
./scripts/run_tests.sh --suite integration                          # generation flows
./scripts/run_tests.sh --suite debug                                # accessibility checks
./scripts/run_tests.sh --suite feature-matrix                       # deterministic fixture-driven
./scripts/run_tests.sh --class SidebarNavigation                    # single test class
./scripts/run_tests.sh --test CustomVoiceViewTests/testCustomVoiceScreenCoreLayout  # single test
./scripts/run_backend_tests.sh                                      # Python backend tests

# Validation & release
./scripts/check_project_inputs.sh
./scripts/release.sh                    # produces build/QwenVoice.dmg
```

## Architecture

### Swift/Python Communication

`PythonBridge.swift` spawns `server.py` as a subprocess and communicates via JSON-RPC 2.0 over stdin/stdout. Key RPC methods: `ping`, `init`, `load_model`, `prewarm_model`, `unload_model`, `generate`, `convert_audio`, `list_voices`, `enroll_voice`, `delete_voice`, `get_model_info`, `get_speakers`.

**Streaming protocol:** Single-generation flows use live streaming. The backend emits `generation_chunk` notifications with chunk WAV files written to a session directory. `AudioPlayerViewModel` picks up chunks via `.generationChunkReceived` notifications for real-time playback. Batch generation remains sequential and non-streaming.

**Interactive latency tooling:** The app emits Instruments-native signposts around model load, first streamed chunk, final file readiness, and autoplay start. Idle model warm-up now uses a separate `prewarm_model` RPC instead of hiding warm-up inside `load_model`.

**Progress notifications:** The backend sends `progress` notifications with `percent` and `message` fields. `PythonBridge` maps these to UI phases: `loadingModel` (0-15%), `preparing` (15-30%), `generating` (30-95%), `saving` (95-100%).

**Timeouts:** 300s for generation/model operations, 10s for ping.

### App Bootstrap Flow

`QwenVoiceApp` → `PythonEnvironmentManager` checks/creates venv → `SetupView` shows progress → `ContentView` with `NavigationSplitView`. The environment manager searches Homebrew Python paths (3.13→3.14→3.12→3.11), skips `/usr/bin/python3` (macOS stub), validates MLX import, and tracks a SHA256 marker of `requirements.txt` for invalidation.

### Key Source Layout

```
Sources/
  Services/
    PythonBridge.swift ............... RPC communication + generation orchestration
    PythonEnvironmentManager.swift ... Venv lifecycle (check/create/validate)
    DatabaseService.swift ............ GRDB SQLite (history.sqlite)
    HuggingFaceDownloader.swift ...... URLSession model downloads with atomic moves
    AudioPlayerViewModel.swift ....... Dual-mode: file playback + live streaming via AVAudioEngine
    ModelManagerViewModel.swift ...... Download state per model, epoch-based cancellation
    BatchGenerationRunner.swift ...... Sequential multi-line generation
  Models/
    TTSContract.swift ................ Loads qwenvoice_contract.json
    TTSModel.swift ................... Model registry + availability checks
    Generation.swift ................. GRDB record for history
    RPCMessage.swift ................. RPCRequest/RPCResponse/RPCValue types
  Views/
    Generate/ ....................... CustomVoiceView, VoiceCloningView
    Library/ ........................ HistoryView, VoicesView
    Settings/ ....................... ModelsView, PreferencesView
    Components/ .................... BatchGenerationSheet, EmotionPickerView, SidebarPlayerView
```

### Backend Internals

`server.py` loads one model at a time. Key optimization: prepared clone context cache (max 8 entries) for fast voice cloning. Normalized reference audio is cached under `cache/normalized_clone_refs/` (SHA256-keyed, max 32 entries, 30-day expiry). The MLX cache policy defaults to `adaptive` via `QWENVOICE_CACHE_POLICY`.

## Editing Guidance

- **Project config:** Trust `project.yml` over the generated `.xcodeproj`. Always use `./scripts/regenerate_project.sh` — raw `xcodegen generate` overwrites `Sources/QwenVoice.entitlements`.
- **Contract changes:** If models, speakers, tiers, required files, or output folders change, update `qwenvoice_contract.json` first, then update Swift/Python consumers and tests.
- **RPC changes:** Update `server.py`, `PythonBridge.swift`, `RPCMessage.swift`, affected views, tests, and docs together.
- **New/renamed source files:** Update `project.yml` if needed, run `./scripts/regenerate_project.sh`, verify no `__pycache__`/`.pyc` paths leaked into `.xcodeproj`.
- **Doc alignment:** When broad repo facts change, keep `README.md`, `docs/reference/current-state.md`, `CLAUDE.md`, `AGENTS.md`, and `GEMINI.md` aligned.

## Key Patterns

- **Animations:** All gated through `AppLaunchConfiguration.performAnimated()` / `.appAnimation()` — zero raw `withAnimation` calls.
- **State management:** `@MainActor` isolation on all services, `@EnvironmentObject` for DI, `@Published` for reactivity.
- **View recreation:** `ContentView` uses `.id(selectedItem)` to force full view recreation on sidebar navigation.
- **UI testing:** `UITestAutomationSupport` provides stub backend mode (`QWENVOICE_UI_TEST_BACKEND_MODE=stub`) that generates synthetic audio without Python.
- **Only SPM dependency:** GRDB 7.0.0.

## Gotchas

- `PythonBridge.call()` throws `PythonBridgeError.timeout(seconds:)` — callers must handle.
- `DatabaseService.saveGeneration` throws `DatabaseServiceError.notInitialized(reason)` — callers must handle.
- No auto-restart on Python backend crash — `cancelAllPending(error: .processTerminated)` fires for waiting continuations.
- `HuggingFaceDownloader` uses `NSLock`-guarded atomic temp-file moves to UUID paths.
- `VoiceCloningView` validates audio extensions via `allowedAudioExtensions` set — add new formats there.
- Both `enroll_voice` and `delete_voice` sanitize the name param in `server.py`.
- App is unsigned — end users need `xattr -cr` after install.
- Clone context cache is cleared on model load/unload.
- Runtime helper import: local file → wheel module → silent fallback to standard generation.
- GitHub has only two workflows: `project-inputs.yml` (validation) and `release-dual-ui.yml` (dual DMG builds for macos26/macos15).
