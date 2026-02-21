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

**58 tests** across 10 files: sidebar navigation (10), custom voice (13), voice design (9), voice cloning (9), models (6), history (3), voices (3), preferences (3), generation flow (1, skipped without model), debug (2).

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
2. Project venv at `~/Coding_Projects/QwenVoice/Qwen-Voice/.venv/bin/python3` (development)
3. System Python at `/opt/homebrew/bin/python3` etc.

### Model download
Models are downloaded via `huggingface-cli` spawned as a subprocess in `ModelManagerViewModel.swift`. They land in `~/Library/Application Support/QwenVoice/models/<folder-name>/`. The `get_smart_path()` function in `server.py` handles the `snapshots/` subdirectory that HuggingFace Hub sometimes creates.

### Key files
| File | Role |
|------|------|
| `QwenVoice/Resources/backend/server.py` | Python JSON-RPC server; all ML inference happens here |
| `QwenVoice/Services/PythonBridge.swift` | Swift JSON-RPC client; spawns Python, handles async continuations |
| `QwenVoice/Models/TTSModel.swift` | Model registry (6 models), `ModelTier`, `GenerationMode` enums |
| `QwenVoice/Services/DatabaseService.swift` | GRDB SQLite — stores generation history at `history.sqlite` |
| `QwenVoice/ViewModels/ModelManagerViewModel.swift` | Download/delete model state via `huggingface-cli` |
| `QwenVoice/ContentView.swift` | `SidebarItem` enum + `NavigationSplitView` root; `Notification.Name.navigateToModels` handled here |
| `project.yml` | XcodeGen config — edit this instead of `.xcodeproj` |

### App Support directory layout
```
~/Library/Application Support/QwenVoice/
  models/          ← downloaded model folders
  outputs/
    CustomVoice/   ← generated .wav files
    VoiceDesign/
    Clones/
  voices/          ← enrolled voice .wav + .txt transcript pairs
  history.sqlite   ← GRDB generation history
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

- Only 5 models are exposed in the Swift UI — `lite_design` (Voice Design Lite 0.6B) does not exist on HuggingFace
- There are 9 unique preset speakers across 4 languages (some like `vivian`/`serena` appear in both English and Chinese)

## Gotchas

- **SourceKit false errors** on cross-file Swift references are expected until the project is opened in Xcode — the build still succeeds.
- The compiled binary is tiny (~58KB); the actual Swift code compiles into `Qwen Voice.debug.dylib` in debug builds.
- macOS 14.0+ deployment target; Swift 5.9; Apple Silicon only (arm64).
