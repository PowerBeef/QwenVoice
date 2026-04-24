"""Deterministic fixture staging helpers for harness-driven app launches."""

from __future__ import annotations

import shutil
import tempfile
from pathlib import Path

from .contract import load_contract
from .paths import ensure_directory


def create_fixture_root(prefix: str) -> Path:
    """Create a disposable app-support fixture root with the standard layout."""
    root = Path(tempfile.mkdtemp(prefix=prefix))
    create_base_directories(root)
    return root


def create_base_directories(root: Path) -> None:
    """Create the app-support directories expected by UI and stub-engine runs."""
    for relative in (
        "models",
        "python",
        "outputs/CustomVoice",
        "outputs/VoiceDesign",
        "outputs/Clones",
        "voices",
        "cache/normalized_clone_refs",
        "cache/stream_sessions",
    ):
        ensure_directory(root / relative)


def install_stub_models(root: Path) -> None:
    """Create zero-byte contract-required files for the stub backend."""
    contract = load_contract()
    models_root = root / "models"
    for model in contract.get("models", []):
        folder = model.get("folder")
        if not folder:
            continue
        model_root = models_root / folder
        ensure_directory(model_root)
        for relative_path in model.get("requiredRelativePaths", []):
            file_path = model_root / relative_path
            ensure_directory(file_path.parent)
            file_path.touch(exist_ok=True)


def mirror_item(source: Path, destination: Path) -> None:
    """Mirror a file or directory with a symlink when possible, copy fallback otherwise."""
    if not source.exists():
        return
    if destination.exists() or destination.is_symlink():
        if destination.is_dir() and not destination.is_symlink():
            shutil.rmtree(destination, ignore_errors=True)
        else:
            destination.unlink(missing_ok=True)
    try:
        destination.symlink_to(source, target_is_directory=source.is_dir())
    except OSError:
        if source.is_dir():
            shutil.copytree(source, destination, dirs_exist_ok=True)
        else:
            shutil.copy2(source, destination)


def copy_optional_tree(source: Path, destination: Path) -> None:
    """Copy a directory only when it exists."""
    if not source.exists():
        return
    if destination.exists():
        shutil.rmtree(destination, ignore_errors=True)
    shutil.copytree(source, destination, dirs_exist_ok=True)


def copy_optional_file(source: Path, destination: Path) -> None:
    """Copy a file only when it exists."""
    if not source.exists():
        return
    ensure_directory(destination.parent)
    shutil.copy2(source, destination)
