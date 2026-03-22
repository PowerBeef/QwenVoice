# CLAUDE.md

This file gives Claude-oriented guidance for the standalone CLI under `cli/`.

## Scope

This directory is the standalone Python CLI companion to QwenVoice. It is useful for manual experimentation, but it is not the source of truth for the shipped GUI app.

All paths below are relative to the `cli/` subdirectory of the repo root.

## Current CLI Reality

- Single-file interactive terminal app: `main.py`
- Modes: Custom Voice, Voice Design, Voice Cloning
- Model folders expected under `cli/models/`
- Outputs written under `cli/outputs/`
- Enrolled voices stored under `cli/voices/`
- Paths are based on `os.getcwd()`, so the CLI should be run from `cli/`

## Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
brew install ffmpeg
python main.py
```

Install from the `cli/` directory so the `--find-links ../Sources/Resources/vendor`
entry in `requirements.txt` can resolve the repo’s vendored `mlx-audio` wheel.

## Important Differences from the GUI

- The CLI still has its own `MODELS` and `SPEAKER_MAP` in `main.py`
- The CLI exposes a broader speaker map than the shipped GUI
- The GUI backend and app documentation should not assume the CLI speaker list is the shipped app speaker list

## When Editing

- Keep the CLI docs aligned with the actual `main.py` behavior
- Do not copy GUI-only assumptions into the CLI docs
- If a repo-wide model/speaker change is made, verify whether the CLI should intentionally stay different or be brought back in sync
