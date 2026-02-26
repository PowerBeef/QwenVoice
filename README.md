<div align="center">
  <img src="docs/logo.png" alt="Qwen Voice Logo" width="128">

# Qwen Voice

**Native macOS frontend for Qwen3-TTS on Apple Silicon**

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-M1%2FM2%2FM3%2FM4-orange)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138)
![Release](https://img.shields.io/github/v/release/PowerBeef/QwenVoice)

</div>

## Overview

Qwen Voice brings state-of-the-art text-to-speech to your Mac with three generation modes in a native SwiftUI interface featuring a premium monochromatic liquid glass aesthetic and fluid micro-animations. No Python install, no terminal, no dependencies — just download and run.

Built natively for Apple Silicon using Apple's MLX framework for highly optimized, low-latency, and low-heat offline inference.

## Screenshots

<div align="center">
  <img src="docs/screenshot1.png" alt="Qwen Voice Generation" width="49%">
  <img src="docs/screenshot2.png" alt="Qwen Voice Models" width="49%">
</div>

## Features

### Custom Voice
Generate speech with 9 preset speakers across 4 languages (English, Chinese, Japanese, Korean). Control emotion and delivery dynamically with natural language instructions.

### Voice Design
Create entirely new voice identities by describing them (e.g., "deep narrator", "excited child") and generate speech with your custom persona.

### Voice Cloning
Clone a voice from a short 5-10 second audio sample (WAV/MP3/AIFF) to generate accurate synthesized speech.

### More
- **Model Manager** — Download and manage MLX models directly from HuggingFace in-app.
- **Generation History** — SQLite-backed history log (via GRDB) with instant playback.
- **Batch Generation** — Generate multiple utterances at once.
- **Keyboard Shortcuts** — `Cmd+Return` generate, `Space` play/pause, `Cmd+Shift+O` open output folder.

## Tone & Emotion Control Mechanism

A standout feature of the QwenVoice Custom Voice and Voice Design modes is the absence of traditional parametric controls like SSML. The entire control surface is probabilistic and driven by **Natural Language Instructions**.

You can pass descriptions like:
- `"Speak in an incredulous tone, but with a hint of panic beginning to creep into your voice."`
- `"A composed middle-aged male announcer with a deep, rich and magnetic voice..."`

The underlying discrete multi-codebook language model natively interprets these prompts to accurately modulate breath, pitch, resonance, and emotional delivery.

## Requirements

| Requirement | Detail |
|-------------|--------|
| macOS | 14.0+ (Sonoma) |
| Chip | Apple Silicon (M1 / M2 / M3 / M4) |
| RAM | 4–8 GB free depending on model |

## Install

1. Download **QwenVoice.dmg** from [Releases](https://github.com/PowerBeef/QwenVoice/releases)
2. Drag to `/Applications`
3. Remove the quarantine attribute (the app is unsigned):
   ```bash
   xattr -cr "/Applications/Qwen Voice.app"
   ```
4. Open the app → go to the **Models** tab → download a model → start generating

## Models

| Model | Mode | Tier | HuggingFace Repo |
|-------|------|------|------------------|
| Custom Voice | Custom Voice | Pro 1.7B | `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit` |
| Voice Design | Voice Design | Pro 1.7B | `mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit` |
| Voice Cloning | Voice Cloning | Pro 1.7B | `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit` |

Pro models produce high quality output and natively support natural language instruction inputs.

## Building from Source

**Prerequisites:** Xcode 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), macOS 14+

```bash
git clone https://github.com/PowerBeef/QwenVoice.git
cd QwenVoice/QwenVoice
xcodegen generate
open QwenVoice.xcodeproj
```

Build and run from Xcode. On first launch in dev mode, the app auto-creates a Python venv at `~/Library/Application Support/QwenVoice/python/` and installs dependencies.

**Release build:**

```bash
./scripts/release.sh
```

This bundles Python 3.13 + ffmpeg into the app, builds with `xcodebuild`, and creates a DMG at `build/QwenVoice.dmg`.

## Architecture & Tech Stack

Qwen Voice relies on a **Two-Process Architecture**:
1. **SwiftUI Frontend**: Acts as the elegant visual interface. It manages routing, maintains SQLite generation logs, and downloads remote MLX payloads.
2. **Python Backend**: The hardware-accelerated MLX-based inference operates in a distinct, continuous process via `server.py`. The Swift application automatically launches this background process and communicates with it via **JSON-RPC 2.0** over `stdin/stdout`.

The release build bundles a standalone Python 3.13 (arm64) environment and `ffmpeg` native binaries so zero system configurations are required of users.

## Credits

- [qwen3-tts-apple-silicon](https://github.com/kapi2800/qwen3-tts-apple-silicon) by [@kapi2800](https://github.com/kapi2800) — MLX-based inference backend structure
- [Qwen3-TTS](https://huggingface.co/Qwen) by Alibaba/Qwen team — the underlying model family
