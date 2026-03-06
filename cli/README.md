# QwenVoice CLI

This directory contains the standalone Python CLI companion for QwenVoice.

It is useful for headless/manual experiments, but it is not the source of truth for the shipped macOS app UX.

## What the CLI Supports

- Custom Voice
- Voice Design
- Voice Cloning

Unlike the shipped GUI, the CLI still exposes the broader speaker map defined in `cli/main.py`, including English, Chinese, Japanese, and Korean speaker names.

## Setup

Run all commands from the repo root unless otherwise noted:

```bash
cd /Users/patricedery/Coding_Projects/QwenVoice/cli
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
brew install ffmpeg
```

## Models

Download these model folders from `mlx-community` on Hugging Face and place them under `cli/models/`:

- `Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit`
- `Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit`
- `Qwen3-TTS-12Hz-1.7B-Base-8bit`

The CLI uses `os.getcwd()` for paths, so run it from the `cli/` directory if you want the default `models/`, `voices/`, and `outputs/` folders to resolve correctly.

## Run

```bash
cd /Users/patricedery/Coding_Projects/QwenVoice/cli
source .venv/bin/activate
python main.py
```

## Runtime Layout

When run from `cli/`, the CLI reads and writes:

```text
cli/
  models/
  outputs/
    CustomVoice/
    VoiceDesign/
    Clones/
  voices/
```

## Notes

- `main.py` is a standalone interactive terminal app, not a server.
- The GUI backend was originally refactored from this CLI flow, but the GUI now uses the manifest-backed contract in `Sources/Resources/qwenvoice_contract.json`.
- The GUI and CLI intentionally differ in speaker exposure: the app ships four English speakers, while the CLI still exposes the broader map in `cli/main.py`.
