"""Shared path resolution for the QwenVoice harness."""

from __future__ import annotations

import shutil
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parents[2]
SERVER_PATH = PROJECT_DIR / "Sources" / "Resources" / "backend" / "server.py"
CONTRACT_PATH = PROJECT_DIR / "Sources" / "Resources" / "qwenvoice_contract.json"
APP_REQUIREMENTS_PATH = PROJECT_DIR / "Sources" / "Resources" / "requirements.txt"
CLI_REQUIREMENTS_PATH = PROJECT_DIR / "cli" / "requirements.txt"
BUILD_MLX_AUDIO_WHEEL_SCRIPT = PROJECT_DIR / "scripts" / "build_mlx_audio_wheel.sh"
PYTHON_BRIDGE_PATH = PROJECT_DIR / "Sources" / "Services" / "PythonBridge.swift"
BUNDLED_PYTHON_ROOT = PROJECT_DIR / "Sources" / "Resources" / "python"
BUNDLED_PYTHON_BIN = BUNDLED_PYTHON_ROOT / "bin" / "python3"
BUNDLED_RUNTIME_MANIFEST = BUNDLED_PYTHON_ROOT / ".qwenvoice-runtime-manifest.json"
APP_SUPPORT_DIR = Path.home() / "Library" / "Application Support" / "QwenVoice"
APP_VENV_PYTHON = APP_SUPPORT_DIR / "python" / "bin" / "python3"
APP_MODELS_DIR = APP_SUPPORT_DIR / "models"
BACKEND_DIR = PROJECT_DIR / "Sources" / "Resources" / "backend"
PIPELINE_PATH = BACKEND_DIR / "clone_delivery_pipeline.py"


def resolve_backend_python(explicit: str | None = None) -> str:
    """Resolve the Python interpreter for the backend."""
    if explicit:
        return explicit
    if APP_VENV_PYTHON.exists():
        return str(APP_VENV_PYTHON)
    raise RuntimeError(
        f"App venv Python not found at {APP_VENV_PYTHON}. "
        "Run the app once to set up the Python environment, or pass --python explicitly."
    )


def resolve_ffmpeg_binary() -> str | None:
    """Find the best available ffmpeg binary."""
    import os

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
    """Create a directory (and parents) if it doesn't exist."""
    path.mkdir(parents=True, exist_ok=True)
    return path
