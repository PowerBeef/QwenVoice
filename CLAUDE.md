# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build (from QwenVoice/ directory)
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build

# Clean build
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice clean build

# Launch the built app
open "/Users/patricedery/Library/Developer/Xcode/DerivedData/QwenVoice-ebuvxlbcxglgkscjzvpaqxyfmamn/Build/Products/Debug/Qwen Voice.app"

# Regenerate .xcodeproj after adding/removing Swift files
xcodegen generate
# WARNING: XcodeGen overwrites QwenVoice/QwenVoice.entitlements — restore it after regenerating

# Safely regenerate .xcodeproj (backs up + restores entitlements)
./scripts/regenerate_project.sh

# Bundle a standalone Python environment (for distribution)
./scripts/bundle_python.sh
```

## Testing

XCUITest end-to-end tests live in `QwenVoiceUITests/`. All tests work without downloaded models (800MB+ each); model-dependent tests use `XCTSkip`.

```bash
# Run all UI tests
./scripts/run_tests.sh

# Run a single test class
./scripts/run_tests.sh SidebarNavigation

# List available test classes
./scripts/run_tests.sh --list

# Or via xcodebuild directly
xcodebuild test -project QwenVoice.xcodeproj -scheme QwenVoiceUITests -destination 'platform=macOS'
```

**55 tests** across 10 files: sidebar navigation (10), custom voice (12), voice design (8), voice cloning (8), models (4), history (3), voices (3), preferences (3), generation flow (1, skipped without model), debug (2).

### Accessibility identifiers
All UI elements have `accessibilityIdentifier` values following the pattern `"{viewScope}_{elementName}"`. When adding new UI elements, follow this convention so tests can find them.

## Architecture

**Two-process design:** SwiftUI frontend + Python backend (`server.py`) communicating via JSON-RPC 2.0 over stdin/stdout pipes.

### Swift → Python communication flow
1. `QwenVoiceApp.swift` calls `pythonBridge.start()` on launch, which spawns `server.py` as a subprocess
2. `PythonBridge.swift` (JSON-RPC client) sends newline-delimited JSON requests; reads responses line-by-line
3. The Python process sends a `ready` notification on startup → sets `PythonBridge.isReady = true`
4. Progress updates arrive as `progress` notifications (no `id` field) before the final response
5. Only one model lives in GPU memory at a time; `load_model` unloads the previous before loading

### Python path resolution (dev vs. bundled)
`PythonBridge.findPython()` checks in order:
1. Bundled Python at `Resources/python/bin/python3` (production)
2. App Support venv at `~/Library/Application Support/QwenVoice/python/bin/python3` (auto-created by `PythonEnvironmentManager`)
3. Dev project venv relative to source file — resolves to `../Qwen-Voice/.venv/bin/python3`
4. System Python at `/opt/homebrew/bin/python3`, `/usr/local/bin/python3`, `/usr/bin/python3`

### Model download
Models are downloaded via `huggingface-cli` spawned as a subprocess in `ModelManagerViewModel.swift`. They land in `~/Library/Application Support/QwenVoice/models/<folder-name>/`. The `get_smart_path()` function in `server.py` handles the `snapshots/` subdirectory that HuggingFace Hub sometimes creates. There are 3 models (all Pro 1.7B 8-bit): Custom Voice, Voice Design, Voice Cloning.

### Key files
| File | Role |
|------|------|
| `QwenVoice/Resources/backend/server.py` | Python JSON-RPC server; all ML inference happens here |
| `QwenVoice/Services/PythonBridge.swift` | Swift JSON-RPC client; spawns Python, handles async continuations |
| `QwenVoice/Models/TTSModel.swift` | Model registry (3 Pro models), `GenerationMode` enum |
| `QwenVoice/Services/DatabaseService.swift` | GRDB SQLite — stores generation history at `history.sqlite` |
| `QwenVoice/ViewModels/ModelManagerViewModel.swift` | Download/delete model state via `huggingface-cli` |
| `QwenVoice/ContentView.swift` | `SidebarItem` enum + `NavigationSplitView` root; `Notification.Name.navigateToModels` handled here |
| `project.yml` | XcodeGen config — edit this instead of `.xcodeproj` |

### Python environment setup
`PythonEnvironmentManager.swift` handles first-boot venv creation. On launch, the app shows `SetupView` until the venv is ready, then switches to `ContentView`.

- **Marker file:** `~/Library/Application Support/QwenVoice/python/.setup-complete` stores a SHA256 hash of `requirements.txt`. If missing or stale, the app recreates the venv from scratch.
- **Vendored wheels:** `PythonEnvironmentManager` checks for a `Resources/vendor/` directory in the app bundle and passes it to `pip install --find-links` for offline/faster installs.
- **Python discovery order:** Prefers 3.13 → 3.14 → 3.12 → 3.11 (requirements target 3.13; `audioop-lts` has a `python_version >= "3.13"` marker).
- **Accepted versions:** Python 3.11–3.14.
- **If tests fail across the board** (all sidebar items not found), the venv is likely broken or the marker is missing — the app is stuck on `SetupView`. Fix: recreate the venv, install deps, write the marker hash.

### App Support directory layout
```
~/Library/Application Support/QwenVoice/
  python/            ← venv (created by PythonEnvironmentManager)
    .setup-complete  ← SHA256 hash of requirements.txt
  models/            ← downloaded model folders
  outputs/
    CustomVoice/     ← generated .wav files
    VoiceDesign/
    Clones/
  voices/            ← enrolled voice .wav + .txt transcript pairs
  history.sqlite     ← GRDB generation history
```

### Generate views pattern
All three generate views (`CustomVoiceView`, `VoiceDesignView`, `VoiceCloningView`) share the same structure:
- `isModelDownloaded` computed property checks `QwenVoiceApp.modelsDir/<model.folder>` on disk
- Orange warning banner + disabled Generate/Batch buttons when model not present
- "Go to Models" posts `Notification.Name.navigateToModels` → `ContentView` switches sidebar
- `TextInputView` is the shared text entry + Generate button component

### RPC methods (server.py ↔ PythonBridge.swift)
`ping`, `init`, `load_model`, `unload_model`, `generate`, `convert_audio`, `list_voices`, `enroll_voice`, `delete_voice`, `get_model_info`, `get_speakers`

The `generate` method handles all three modes via parameter presence: `ref_audio` → clone, `voice` → custom, `instruct` only → design.

## Distribution

- **GitHub repo:** PowerBeef/QwenVoice
- The app is unsigned — users must run `xattr -cr "/Applications/Qwen Voice.app"` after installing from the DMG
- Release build: `./scripts/release.sh` (bundles Python 3.13 + ffmpeg, creates DMG)

## Data Corrections

- 3 Pro (1.7B) models only — Lite (0.6B) tier was removed (Pro runs fine on all Apple Silicon Macs with 8GB+ RAM)
- There are 4 English preset speakers: ryan, aiden, serena, vivian

## Gotchas

- **SourceKit false errors** on cross-file Swift references are expected until the project is opened in Xcode — the build still succeeds.
- The compiled binary is tiny (~58KB); the actual Swift code compiles into `Qwen Voice.debug.dylib` in debug builds.
- macOS 14.0+ deployment target; Swift 5.9; Apple Silicon only (arm64).
- **Changing `requirements.txt` invalidates the venv marker** — the app will redo full setup on next launch. After editing requirements, either let the app rebuild the venv or manually: recreate the venv, `pip install -r requirements.txt`, and write `shasum -a 256 requirements.txt | awk '{print $1}'` to `python/.setup-complete`.
- **`audioop-lts` is 3.13+ only** — it backports the `audioop` stdlib module removed in 3.13. The environment marker in `requirements.txt` ensures pip skips it on 3.12 where `audioop` is built-in.
- **No auto-restart on backend crash** — if the Python process terminates, `PythonBridge.isReady` becomes `false` and generation views disable. The user must quit and reopen the app.
