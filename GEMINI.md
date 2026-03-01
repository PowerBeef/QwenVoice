# QwenVoice - Project Analysis & Documentation

This document provides a comprehensive analysis of the **QwenVoice** project architecture, directory structure, tech stack, and dependencies.

The repo root is `/Users/patricedery/Coding_Projects/QwenVoice`. Older notes that refer to a nested `QwenVoice/QwenVoice` path are stale.

## 1. Project Overview

**QwenVoice** is a native macOS frontend application dedicated to running [Qwen3-TTS](https://huggingface.co/Qwen) inference locally on Apple Silicon (M1/M2/M3/M4). By leveraging Apple's **MLX** framework, the project delivers highly optimized, low-latency, and low-heat offline text-to-speech generation.

The app supports three distinct generation modes:
1. **Custom Voice**: Generate speech using 4 English preset speakers (ryan, aiden, serena, vivian) with natural language emotion and speed control.
2. **Voice Design**: Create entirely new voice identities by describing them (e.g., "deep narrator", "excited child"). Accessed via the "Custom" chip toggle in the Custom Voice tab.
3. **Voice Cloning**: Clone a voice using a short 5-10 second reference audio clip.

**Additional Features:**
- **Model Manager**: Download and manage MLX models directly from HuggingFace in-app (native URLSession, no CLI tools).
- **Generation History**: SQLite-backed history log with instant playback via GRDB.
- **Batch Generation**: Generate multiple utterances at once.
- **Keyboard Shortcuts**: `Cmd+Return` generate, `Space` play/pause, `Cmd+Shift+O` open output folder.

## 2. Directory Structure

The project is cleanly separated into a two-process design, delineating the Swift user interface from the Python machine learning inference engine.

```plaintext
.
├── Sources/                 # Application source code (SwiftUI)
│   ├── QwenVoiceApp.swift      # @main entry point, window setup, app directories
│   ├── ContentView.swift       # Root NavigationSplitView + sidebar routing
│   ├── Views/                  # SwiftUI Views
│   │   ├── SetupView.swift     # First-boot Python setup UI
│   │   ├── Sidebar/SidebarView.swift
│   │   ├── Generate/           # CustomVoiceView, VoiceCloningView
│   │   ├── Library/            # HistoryView, VoicesView
│   │   ├── Settings/           # ModelsView, PreferencesView
│   │   └── Components/         # AppTheme, TextInputView, SidebarPlayerView, etc.
│   ├── ViewModels/             # ModelManagerViewModel, AudioPlayerViewModel
│   ├── Services/               # PythonBridge, PythonEnvironmentManager, DatabaseService, etc.
│   ├── Models/                 # TTSModel, Generation, Voice, RPCMessage, EmotionPreset
│   ├── Assets.xcassets/        # Current app asset catalog source
│   └── Resources/
│       └── backend/server.py   # Python JSON-RPC backend (all inference)
├── QwenVoiceUITests/        # UI testing suite (54 tests across 9 test files)
├── scripts/                 # Build and release scripts
│   ├── release.sh           # Full pipeline: bundle Python/ffmpeg → build → DMG
│   ├── bundle_python.sh     # Download & install Python 3.13 standalone (arm64)
│   ├── bundle_ffmpeg.sh     # Embed ffmpeg binary
│   ├── regenerate_project.sh # XcodeGen + entitlements backup/restore
│   ├── create_dmg.sh        # Create DMG distribution
│   ├── run_tests.sh         # Run XCUITests
│   └── test_download.sh     # Test HuggingFace download flow
├── project.yml              # XcodeGen configuration file
├── README.md                # User-facing documentation
├── cli/                     # Python CLI tool (standalone predecessor to GUI)
│   ├── main.py              # Interactive TTS menu (9 speakers across 4 languages)
│   ├── requirements.txt     # Python dependencies
│   └── README.md            # CLI documentation
│
├── docs/                    # Documentation and plan archives
├── qwen_tone.md             # Detailed guide on ML emotion & tone instructions
├── CLAUDE.md                # Claude Code context
└── GEMINI.md                # This file — Gemini context
```

**App Support Directory at Runtime:**
```
~/Library/Application Support/QwenVoice/
├── python/            # Venv (created by PythonEnvironmentManager)
│   └── .setup-complete  # SHA256 hash of requirements.txt
├── models/            # Downloaded model folders
├── outputs/
│   ├── CustomVoice/   # Generated .wav files
│   ├── VoiceDesign/
│   └── Clones/
├── voices/            # Enrolled voice .wav + .txt transcript pairs
└── history.sqlite     # GRDB generation history
```

## 3. Tech Stack & Dependencies

### Frontend (macOS App)
- **Language**: Swift 5.9
- **Target**: macOS 14.0+ (Sonoma), Apple Silicon only (arm64)
- **Framework**: SwiftUI
- **UI/UX Design**: Premium monochromatic liquid glass aesthetic with a single soft blue-indigo accent, single ambient glow aurora background, tinted-glass chip style, and fluid micro-animations driven by a centralized `AppTheme`. Playback is currently handled by `SidebarPlayerView` in the sidebar.
- **Project Generation**: XcodeGen (`project.yml`)
- **Key Dependencies**:
  - `GRDB.swift` (v7.0.0): SQLite-backed generation history — the only SPM package.

### Backend (Inference Engine)
- **Language**: Python 3.11–3.14 (prefers 3.13)
- **Environment**: Standalone Python 3.13 (bundled during release); auto-created venv in dev
- **Audio Processing**: ffmpeg (for WAV/MP3/AIFF conversions)
- **Key Python Packages** (from `requirements.txt`):
  - **Apple MLX Ecosystem**: `mlx==0.30.3`, a repacked `mlx-audio==0.3.1.post1` for the app backend (`Sources/Resources/requirements.txt`), `mlx-audio` pinned to a git commit for the standalone CLI (`cli/requirements.txt`), `mlx-lm==0.30.5`, `mlx-metal` (hardware-accelerated inference)
  - **Transformers & HuggingFace**: `transformers==5.0.0rc3`, `huggingface_hub`, `tokenizers`, `safetensors`
  - **Audio Processing**: `librosa`, `soundfile`, `sounddevice`, `audioread`
  - **Core Utilities**: `numpy`, `scipy`, `scikit-learn`
  - **Python 3.13+ only**: `audioop-lts` (backports removed stdlib module)

## 4. Codebase Architecture

The app uses a **Two-Process Architecture**:
1. **SwiftUI Frontend**: Acts as the visual interface. It handles model management, maintains the SQLite generation log, captures user inputs, and routes different UI modules like Custom Voice, Voice Cloning, History, and Model management.
2. **Python Backend**: The MLX-based inference operates continuously in a separate process. The Swift frontend starts a persistent Python backend via `server.py` located in Resources, and communicates via **JSON-RPC 2.0** over standard input/output (`stdin/stdout`) handled by `PythonBridge.swift`. (Notably, `cli/main.py` serves as a standalone CLI alternative.)
3. **Release Packaging**: When built for release using `scripts/release.sh`, the project automatically bundles the Python 3.13 arm64 environment and `ffmpeg` directly into the `.app` bundle, ensuring a standalone experience without requiring system-level dependencies from the end user.

### Key Files
| File | Role |
|------|------|
| `Sources/Resources/backend/server.py` | Python JSON-RPC server; all ML inference happens here |
| `Sources/Services/PythonBridge.swift` | Swift JSON-RPC client; spawns Python, handles async continuations |
| `Sources/Models/TTSModel.swift` | Model registry (3 Pro models), `GenerationMode` enum, speaker list |
| `Sources/Models/RPCMessage.swift` | JSON-RPC 2.0 codec — `RPCValue` enum for type-safe JSON |
| `Sources/Services/DatabaseService.swift` | GRDB SQLite — stores generation history at `history.sqlite` |
| `Sources/Services/PythonEnvironmentManager.swift` | First-boot venv creation, SHA256 marker validation |
| `Sources/Services/HuggingFaceDownloader.swift` | Native URLSession model downloader (replaces huggingface-cli) |
| `Sources/ViewModels/ModelManagerViewModel.swift` | Download/delete model state, `ModelStatus` enum |
| `Sources/QwenVoiceApp.swift` | @main entry point, window setup, app directories, keyboard shortcuts |
| `Sources/ContentView.swift` | `SidebarItem` enum + `NavigationSplitView` root |
| `Sources/Views/Components/AppTheme.swift` | Glassmorphism helpers (`glassCard()`), monochromatic colors |
| `project.yml` | XcodeGen config — edit this instead of `.xcodeproj` |

### RPC Methods (server.py ↔ PythonBridge.swift)

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

### Python Environment Setup
- **Marker file:** `~/Library/Application Support/QwenVoice/python/.setup-complete` stores a SHA256 hash of `requirements.txt`. If missing or stale, the app recreates the venv from scratch.
- **Python discovery order:** Prefers 3.13 → 3.14 → 3.12 → 3.11.
- **Accepted versions:** Python 3.11–3.14.
- **Vendored wheels:** `PythonEnvironmentManager` checks for `Resources/vendor/` and passes `--find-links` for offline installs.

### Build & Run
```bash
# Build (from repo root)
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build

# Launch the built app (dynamically resolves DerivedData path)
open "$(xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice -showBuildSettings 2>/dev/null | grep '^ *BUILT_PRODUCTS_DIR' | sed 's/.*= //')/Qwen Voice.app"

# Safely regenerate .xcodeproj (backs up + restores entitlements)
./scripts/regenerate_project.sh

# Release build (bundles Python 3.13 + ffmpeg, creates DMG)
./scripts/release.sh
```

### Models

3 Pro (1.7B) 8-bit quantized models from `mlx-community`:

| Model | Mode | Folder | Size |
|-------|------|--------|------|
| Custom Voice | `.custom` | `Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit` | ~900 MB |
| Voice Design | `.design` | `Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit` | ~900 MB |
| Voice Cloning | `.clone` | `Qwen3-TTS-12Hz-1.7B-Base-8bit` | ~930 MB |

Models are NOT bundled — users download in-app via ModelsView.

## 5. Tone & Emotion Control Mechanism

A standout feature of the Qwen3-TTS 1.7B Pro models (Custom Voice and Voice Design) documented in `qwen_tone.md` is the absence of traditional parametric controls like SSML (Speech Synthesis Markup Language).
Instead, the entire control surface is probabilistic and driven by **Natural Language Instructions** natively understood by the language model.

Users pass descriptions like:
- `"Speak in an incredulous tone, but with a hint of panic beginning to creep into your voice."`
- `"A composed middle-aged male announcer with a deep, rich and magnetic voice..."`

The underlying discrete multi-codebook language model interprets these prompts to modulate breath, pitch, resonance, and emotional delivery. Note: instruction control is probabilistic — complex multi-dimensional requests may not be followed precisely.

## 6. Distribution

- **GitHub repo:** PowerBeef/QwenVoice
- **Version:** 1.0.2 (build 3)
- The app is unsigned (`CODE_SIGN_IDENTITY="-"`) — users must run `xattr -cr "/Applications/Qwen Voice.app"` after installing from the DMG
- **Entitlements:** Sandboxing disabled, unsigned executable memory allowed, library validation disabled — required for Python subprocess execution and MLX .dylib loading

## 7. Gotchas

- **SourceKit false errors** on cross-file Swift references are expected until the project is opened in Xcode — the build still succeeds.
- macOS 14.0+ deployment target; Swift 5.9; Apple Silicon only (arm64).
- **XcodeGen overwrites entitlements** — always use `scripts/regenerate_project.sh` instead of `xcodegen generate` directly.
- **Asset catalogs are in transition** — `project.yml` points at `Sources/Assets.xcassets`, while the checked-in `.xcodeproj` may still reference the top-level `Assets.xcassets`.
- **Changing `requirements.txt` invalidates the venv marker** — the app will redo full setup on next launch.
- **`audioop-lts` is 3.13+ only** — environment marker in `requirements.txt` skips it on 3.12 where `audioop` is built-in.
- **No auto-restart on backend crash** — if the Python process terminates, `PythonBridge.isReady` becomes `false` and generation views disable. User must quit and reopen.
- **Audio sample rate:** 24000 Hz for all generated audio.
