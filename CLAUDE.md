# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build (from QwenVoice/ directory)
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build

# Clean build
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice clean build

# Launch the built app (dynamically resolves DerivedData path)
open "$(xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice -showBuildSettings 2>/dev/null | grep '^ *BUILT_PRODUCTS_DIR' | sed 's/.*= //')/Qwen Voice.app"

# Regenerate .xcodeproj after adding/removing Swift files
xcodegen generate
# WARNING: XcodeGen overwrites Sources/QwenVoice.entitlements — restore it after regenerating

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

**51 tests** across 10 files: sidebar navigation (9), custom voice (17), voice cloning (8), models (4), history (3), voices (3), preferences (3), generation flow (1, skipped without model), debug (2). Voice Design functionality is accessed via the "Custom" chip in the Custom Voice tab.

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
3. Dev project venv relative to source file — resolves to `cli/.venv/bin/python3`
4. System Python at `/opt/homebrew/bin/python3`, `/usr/local/bin/python3`, `/usr/bin/python3`

### Model download
Models are downloaded via `HuggingFaceDownloader.swift` using native URLSession (no external CLI tools). `ModelManagerViewModel.swift` manages download/delete state. Models land in `~/Library/Application Support/QwenVoice/models/<folder-name>/`. The `get_smart_path()` function in `server.py` handles the `snapshots/` subdirectory that HuggingFace Hub sometimes creates. There are 3 models (all Pro 1.7B 8-bit): Custom Voice, Voice Design, Voice Cloning.

### Key files
| File | Role |
|------|------|
| `Sources/Resources/backend/server.py` | Python JSON-RPC server; all ML inference happens here |
| `Sources/Services/PythonBridge.swift` | Swift JSON-RPC client; spawns Python, handles async continuations |
| `Sources/Models/TTSModel.swift` | Model registry (3 Pro models), `GenerationMode` enum, speaker list |
| `Sources/Models/RPCMessage.swift` | JSON-RPC 2.0 codec — `RPCValue` enum for type-safe JSON |
| `Sources/Models/EmotionPreset.swift` | Predefined emotion/tone presets |
| `Sources/Services/DatabaseService.swift` | GRDB SQLite — stores generation history at `history.sqlite` |
| `Sources/Services/AudioService.swift` | Audio playback |
| `Sources/Services/WaveformService.swift` | Waveform data extraction for visualization |
| `Sources/ViewModels/ModelManagerViewModel.swift` | Download/delete model state, `ModelStatus` enum |
| `Sources/ViewModels/AudioPlayerViewModel.swift` | Playback state, current file, duration |
| `Sources/Services/HuggingFaceDownloader.swift` | Native URLSession model downloader (replaces huggingface-cli) |
| `Sources/Services/PythonEnvironmentManager.swift` | First-boot venv creation, SHA256 marker validation |
| `Sources/QwenVoiceApp.swift` | @main entry point, window setup, app directories, keyboard shortcuts |
| `Sources/ContentView.swift` | `SidebarItem` enum + `NavigationSplitView` root; `Notification.Name.navigateToModels` handled here |
| `Sources/Views/SetupView.swift` | First-boot Python setup UI (states: checking → settingUp → ready/failed) |
| `Sources/Views/Components/AppTheme.swift` | Glassmorphism helpers (`glassCard()`), monochromatic colors |
| `Sources/Views/Components/TextInputView.swift` | Shared chat-style input bar (text field + circular generate button) |
| `Sources/Views/Components/LayoutConstants.swift` | Shared layout dimensions |
| `project.yml` | XcodeGen config — edit this instead of `.xcodeproj` |

### Project structure
```
Sources/
├── QwenVoiceApp.swift              # @main entry point
├── ContentView.swift               # Root NavigationSplitView + sidebar routing
├── Models/
│   ├── TTSModel.swift              # Model registry, GenerationMode enum, speakers
│   ├── Generation.swift            # GRDB history record
│   ├── Voice.swift                 # Voice cloning reference
│   ├── RPCMessage.swift            # JSON-RPC 2.0 codec
│   └── EmotionPreset.swift         # Emotion preset definitions
├── Services/
│   ├── PythonBridge.swift          # JSON-RPC client, subprocess spawning
│   ├── PythonEnvironmentManager.swift  # Venv setup, SHA256 marker
│   ├── DatabaseService.swift       # GRDB SQLite
│   ├── HuggingFaceDownloader.swift # Native URLSession downloader
│   ├── AudioService.swift          # Audio playback
│   └── WaveformService.swift       # Waveform extraction
├── ViewModels/
│   ├── ModelManagerViewModel.swift  # Download/delete state
│   └── AudioPlayerViewModel.swift   # Playback state
├── Views/
│   ├── SetupView.swift             # First-boot Python setup
│   ├── Sidebar/SidebarView.swift
│   ├── Generate/
│   │   ├── CustomVoiceView.swift   # Preset speakers + Voice Design (via chip)
│   │   └── VoiceCloningView.swift  # Clone from reference audio
│   ├── Library/
│   │   ├── HistoryView.swift       # Generation history
│   │   └── VoicesView.swift        # Enrolled voices
│   ├── Settings/
│   │   ├── ModelsView.swift        # Download/delete models
│   │   └── PreferencesView.swift
│   └── Components/
│       ├── AppTheme.swift          # Glassmorphism, colors
│       ├── TextInputView.swift     # Shared chat-style input
│       ├── AudioPlayerBar.swift    # Waveform + playback controls
│       ├── EmotionPickerView.swift # Emotion preset buttons
│       ├── BatchGenerationSheet.swift  # Batch mode modal
│       ├── WaveformView.swift      # Waveform visualization
│       ├── FlowLayout.swift        # Wrapping layout for chips
│       └── LayoutConstants.swift   # Shared dimensions
├── Resources/
│   ├── backend/server.py           # Python JSON-RPC backend
│   └── Assets.xcassets/            # App icon, colors
├── Info.plist
└── QwenVoice.entitlements          # Sandboxing disabled, unsigned code loading
```

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
Two generate views (`CustomVoiceView`, `VoiceCloningView`) share the same structure. Voice Design is accessed via the "Custom" chip in `CustomVoiceView` (no separate view).
- `isModelDownloaded` computed property checks `QwenVoiceApp.modelsDir/<model.folder>` on disk
- Orange warning banner + disabled Generate/Batch buttons when model not present
- "Go to Models" posts `Notification.Name.navigateToModels` → `ContentView` switches sidebar
- `TextInputView` is the shared chat-style input bar (text field + circular generate button), embedded inside each view's controls glass card

### RPC methods (server.py ↔ PythonBridge.swift)

| Method | Params | Purpose |
|--------|--------|---------|
| `ping` | — | Healthcheck |
| `init` | `app_support_dir` | Configure paths (called on startup) |
| `load_model` | `model_id` or `model_path` | Load 1.7B model to GPU (unloads previous) |
| `unload_model` | — | Free GPU memory |
| `generate` | `text` + (`voice`\|`instruct`\|`ref_audio`) | Generate audio (mode by param presence) |
| `convert_audio` | `input_path`, `output_path?` | Convert to 24kHz mono WAV |
| `list_voices` | — | List enrolled voices |
| `enroll_voice` | `name`, `audio_path`, `transcript?` | Save voice reference (.wav + .txt) |
| `delete_voice` | `name` | Delete enrolled voice files |
| `get_model_info` | — | Model metadata & download status |
| `get_speakers` | — | Speaker map (4 English speakers) |

**Mode detection in `generate`:** `ref_audio` present → clone, `voice` present → custom, `instruct` only → design. `speed` parameter scales generation speed (Custom Voice only).

### Scripts

| Script | Purpose |
|--------|---------|
| `scripts/release.sh` | Full release: bundle Python/ffmpeg → build → DMG. Flags: `--skip-deps`, `--skip-build` |
| `scripts/bundle_python.sh` | Download & install Python 3.13 standalone (arm64) |
| `scripts/bundle_ffmpeg.sh` | Embed ffmpeg binary from Homebrew releases |
| `scripts/regenerate_project.sh` | XcodeGen + entitlements backup/restore |
| `scripts/create_dmg.sh` | Create DMG distribution |
| `scripts/run_tests.sh` | Run XCUITests (accepts class name or `--list`) |
| `scripts/test_download.sh` | Test HuggingFace download flow |

### Dependencies
- **Swift:** GRDB 7.0.0 (SQLite) — only SPM package
- **Python:** `mlx-audio` (pinned git commit), `mlx`/`mlx-lm`/`mlx-metal`, `transformers`, `librosa`, `soundfile`, `huggingface_hub`, `audioop-lts` (3.13+ only)
- **System:** ffmpeg (brew or bundled), Python 3.11–3.14

## Distribution

- **GitHub repo:** PowerBeef/QwenVoice
- **Version:** 1.0.2 (build 3)
- The app is unsigned (`CODE_SIGN_IDENTITY="-"`) — users must run `xattr -cr "/Applications/Qwen Voice.app"` after installing from the DMG
- Release build: `./scripts/release.sh` (bundles Python 3.13 + ffmpeg, creates DMG)
- Models are NOT bundled in the DMG (~2.7 GB total) — users download in-app via ModelsView
- **Entitlements:** Sandboxing disabled, unsigned executable memory allowed, library validation disabled — required for Python subprocess execution and MLX .dylib loading

## Data Corrections

- 3 Pro (1.7B) models only — Lite (0.6B) tier was removed (Pro runs fine on all Apple Silicon Macs with 8GB+ RAM)
- There are 4 English preset speakers: ryan, aiden, serena, vivian
- Instruction control (`instruct` param) is probabilistic — complex multi-dimensional requests may not be followed precisely

## Gotchas

- **SourceKit false errors** on cross-file Swift references are expected until the project is opened in Xcode — the build still succeeds.
- The compiled binary is tiny (~58KB); the actual Swift code compiles into `Qwen Voice.debug.dylib` in debug builds.
- macOS 14.0+ deployment target; Swift 5.9; Apple Silicon only (arm64).
- **Changing `requirements.txt` invalidates the venv marker** — the app will redo full setup on next launch. After editing requirements, either let the app rebuild the venv or manually: recreate the venv, `pip install -r requirements.txt`, and write `shasum -a 256 requirements.txt | awk '{print $1}'` to `python/.setup-complete`.
- **`audioop-lts` is 3.13+ only** — it backports the `audioop` stdlib module removed in 3.13. The environment marker in `requirements.txt` ensures pip skips it on 3.12 where `audioop` is built-in.
- **No auto-restart on backend crash** — if the Python process terminates, `PythonBridge.isReady` becomes `false` and generation views disable. The user must quit and reopen the app.
- **XcodeGen overwrites entitlements** — always use `scripts/regenerate_project.sh` instead of `xcodegen generate` directly.
- **Audio sample rate:** 24000 Hz for all generated audio.
