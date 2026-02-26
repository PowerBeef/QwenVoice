# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Qwen3-TTS Manager — a CLI tool for running Qwen3-TTS text-to-speech locally on Apple Silicon Macs using the MLX framework. Supports three modes: **Custom Voice** (preset speakers with emotion/speed control), **Voice Design** (create voices from text descriptions), and **Voice Cloning** (clone voices from reference audio). Each mode uses a Pro (1.7B) model.

This CLI is the standalone predecessor to the macOS GUI app in `../QwenVoice/`. The GUI app's `server.py` backend is a JSON-RPC refactor of this `main.py`.

## Setup & Run

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
brew install ffmpeg          # required for audio conversion
python main.py               # launches the interactive CLI menu
```

Models are downloaded from `mlx-community` on HuggingFace:
```bash
huggingface-cli download mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit --local-dir models/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit
```
Repeat for each model. Folder names must match exactly. **Note:** `lite_design` (0.6B VoiceDesign, choice "5") is defined in `MODELS` but does not exist on HuggingFace.

## Architecture

Single-file app (`main.py`) with no tests or build system. Key structure:

- **Model registry** (`MODELS` dict, line ~36): Maps menu choices 1-3 to model folders and modes (`custom`, `design`, `clone_manager`)
- **Session runners**: `run_custom_session()`, `run_design_session()`, `run_clone_manager()` — each loads a model via `mlx_audio`, enters a generate loop, and saves output
- **Speakers**: 9 preset voices across 4 languages — English (ryan, aiden, serena, vivian), Chinese (vivian, serena, uncle_fu, dylan, eric), Japanese (ono_anna), Korean (sohee)
- **Audio pipeline**: `generate_audio()` from `mlx_audio` writes to a temp dir → `save_audio_file()` moves to `outputs/<subfolder>/` → auto-plays via `afplay`
- **Voice persistence**: Enrolled voices stored as paired `.wav`/`.txt` files in `voices/`

## Key Dependencies

- `mlx_audio` (pinned to a specific git commit) — provides `load_model` and `generate_audio`
- `mlx` / `mlx-lm` / `mlx-metal` — Apple Silicon ML framework
- `ffmpeg` (system) — audio format conversion via subprocess

## Directory Layout

- `models/` — downloaded HuggingFace model folders (not in repo, user-provided)
- `voices/` — enrolled voice reference files (`.wav` + `.txt` transcript pairs)
- `outputs/` — generated audio organized by subfolder (`CustomVoice/`, `VoiceDesign/`, `Clones/`)

## Conventions

- All paths are constructed relative to `os.getcwd()` (constants at top of `main.py`)
- Audio sample rate is 24000 Hz
- Model folders may contain a `snapshots/` subdirectory from HuggingFace Hub downloads; `get_smart_path()` handles this transparently
- The app is fully interactive (terminal input) — no CLI flags or API server

## Data Corrections

- Emotion/tone instructions work on 1.7B models (CustomVoice and VoiceDesign)
- See `qwen_tone.md` in the project root for detailed guidance on writing effective emotion instructions
