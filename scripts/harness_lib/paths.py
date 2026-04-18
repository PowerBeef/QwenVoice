"""Shared path resolution for the QwenVoice harness."""

from __future__ import annotations

import os
import shutil
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parents[2]
CONTRACT_PATH = PROJECT_DIR / "Sources" / "Resources" / "qwenvoice_contract.json"
STUB_BACKEND_TRANSPORT_PATH = PROJECT_DIR / "Sources" / "Services" / "StubBackendTransport.swift"
APP_SUPPORT_DIR = Path(
    os.environ.get(
        "QWENVOICE_APP_SUPPORT_DIR",
        str(Path.home() / "Library" / "Application Support" / "QwenVoice"),
    )
)
APP_MODELS_DIR = APP_SUPPORT_DIR / "models"


def resolve_ffmpeg_binary() -> str | None:
    """Find the best available ffmpeg binary."""
    configured = os.environ.get("QWENVOICE_FFMPEG_PATH")
    if configured and Path(configured).exists():
        return configured
    repo_binary = PROJECT_DIR / "Sources" / "Resources" / "ffmpeg"
    if repo_binary.exists():
        return str(repo_binary)
    which_ffmpeg = shutil.which("ffmpeg")
    if which_ffmpeg:
        return which_ffmpeg
    return None


def ensure_directory(path: Path) -> Path:
    """Create a directory and parents if they do not already exist."""
    path.mkdir(parents=True, exist_ok=True)
    return path
