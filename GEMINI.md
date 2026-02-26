# QwenVoice - Project Analysis & Documentation

This document provides a comprehensive analysis of the **QwenVoice** project architecture, directory structure, tech stack, and dependencies.

## 1. Project Overview

**QwenVoice** is a native macOS frontend application dedicated to running [Qwen3-TTS](https://huggingface.co/Qwen) inference locally on Apple Silicon (M1/M2/M3/M4). By leveraging Apple's **MLX** framework, the project delivers highly optimized, low-latency, and low-heat offline text-to-speech generation.

The app supports three distinct generation modes:
1. **Custom Voice**: Generate speech using 9 built-in preset speakers across 4 languages (English, Chinese, Japanese, Korean) with natural language emotion control.
2. **Voice Design**: Create entirely new voice identities by describing them (e.g., "deep narrator", "excited child").
3. **Voice Cloning**: Clone a voice using a short 5-10 second reference audio clip.

**Additional Features:**
- **Model Manager**: Download and manage MLX models directly from HuggingFace in-app.
- **Generation History**: SQLite-backed history log with instant playback via GRDB.
- **Batch Generation**: Generate multiple utterances at once.
- **Keyboard Shortcuts**: `Cmd+Return` generate, `Space` play/pause, `Cmd+Shift+O` open output folder.

## 2. Directory Structure

The project is cleanly separated into a two-process design, delineating the Swift user interface from the Python machine learning inference engine.

```plaintext
.
├── QwenVoice/               # Swift Native macOS Frontend
│   ├── QwenVoice/           # Application source code (SwiftUI)
│   │   ├── Views/           # SwiftUI Views (ContentView, SetupView, Generate, Library, Settings)
│   │   │   └── Components/  # UI Components & AppTheme (Glassmorphism design system)
│   │   ├── ViewModels/      # ViewModels (AudioPlayerViewModel, etc.)
│   │   ├── Services/        # Logic & Bridges (PythonBridge.swift)
│   │   ├── Models/          # Data Models (TTSModel.swift)
│   │   └── Resources/       # Bundled backend scripts (server.py)
│   ├── QwenVoiceUITests/    # UI testing suite
│   ├── Assets.xcassets/     # UI Assets and App Icons
│   ├── scripts/             # Build and release scripts
│   ├── project.yml          # XcodeGen configuration file
│   └── README.md            # Frontend documentation
│
├── Qwen-Voice/              # Python MLX Inference Backend & CLI
│   ├── main.py              # CLI manager for processing text-to-speech
│   ├── models/              # Directory for downloaded MLX models (when used via CLI)
│   ├── outputs/             # Generated audio outputs
│   ├── voices/              # Saved / enrolled custom voice samples
│   ├── requirements.txt     # Python backend dependencies
│   └── README.md            # Backend documentation
│
├── docs/                    # General documentation folder
└── qwen_tone.md             # Detailed guide on ML emotion & tone instructions
```

## 3. Tech Stack & Dependencies

### Frontend (macOS App)
- **Language**: Swift 5.9
- **Target**: macOS 14.0+ (Sonoma)
- **Framework**: SwiftUI
- **UI/UX Design**: Premium glassmorphism aesthetic with vibrant gradients, translucent materials, and fluid micro-animations driven by a centralized `AppTheme`.
- **Project Generation**: XcodeGen (`project.yml`)
- **Key Dependencies**: 
  - `GRDB.swift` (v7.0.0): Used to provide a SQLite-backed generation history with instant playback capabilities.

### Backend (Inference Engine)
- **Language**: Python 3.10+
- **Environment**: Standalone Python 3.13 (bundled during release)
- **Audio Processing**: ffmpeg (for WAV/MP3/AIFF conversions)
- **Key Python Packages** (from `requirements.txt`):
  - **Apple MLX Ecosystem**: `mlx==0.30.3`, `mlx-audio`, `mlx-lm==0.30.5`, `mlx-metal` (Powering the hardware-accelerated inference).
  - **Transformers & HuggingFace**: `transformers==5.0.0rc3`, `huggingface_hub`, `tokenizers`, `safetensors`.
  - **Audio Processing**: `librosa`, `soundfile`, `sounddevice`, `audioread`.
  - **Core Utilities**: `numpy`, `scipy`, `scikit-learn`.

## 4. Codebase Architecture

The app uses a **Two-Process Architecture**:
1. **SwiftUI Frontend**: Acts as the visual interface. It handles model management, maintains the SQLite generation log, captures user inputs, and routes different UI modules like Custom Voice, Voice Cloning, History, and Model management.
2. **Python Backend**: The MLX-based inference operates continuously in a separate process. The Swift frontend starts a persistent Python backend via `server.py` located in Resources, and communicates via **JSON-RPC 2.0** over standard input/output (`stdin/stdout`) handled by `PythonBridge.swift`. (Notably, `main.py` serves as a standalone CLI interaction).
3. **Release Packaging**: When built for release using `scripts/release.sh`, the project automatically bundles the Python 3.13 arm64 environment and `ffmpeg` directly into the `.app` bundle, ensuring a standalone experience without requiring system-level dependencies from the end user.

## 5. Tone & Emotion Control Mechanism

A standout feature of the Qwen3-TTS 1.7B Pro models (Custom Voice and Voice Design) documented in `qwen_tone.md` is the absence of traditional parametric controls like SSML (Speech Synthesis Markup Language). 
Instead, the entire control surface is probabilistic and driven by **Natural Language Instructions** natively understood by the language model.

Users pass descriptions like:
- `"Speak in an incredulous tone, but with a hint of panic beginning to creep into your voice."`
- `"A composed middle-aged male announcer with a deep, rich and magnetic voice..."`

The underlying discrete multi-codebook language model interprets these prompts to accurately modulate breath, pitch, resonance, and emotional delivery. Be aware that **only 1.7B parameter models** support the `instruct` parameter control, while the **0.6B models** lack this feature entirely in exchange for smaller RAM usage natively optimized for Apple Silicon natively.
