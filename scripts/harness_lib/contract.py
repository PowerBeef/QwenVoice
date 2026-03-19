"""Contract loader and validators for qwenvoice_contract.json."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .paths import CONTRACT_PATH, APP_MODELS_DIR


def load_contract() -> dict[str, Any]:
    """Load and return the contract manifest."""
    with open(CONTRACT_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def model_ids() -> list[str]:
    """Return all model IDs from the contract."""
    contract = load_contract()
    return [m["id"] for m in contract["models"]]


def speaker_list() -> list[str]:
    """Return a flat list of all speakers, grouped alphabetically."""
    contract = load_contract()
    speakers: list[str] = []
    for group_name in sorted(contract["speakers"].keys()):
        speakers.extend(contract["speakers"][group_name])
    return speakers


def model_folder(model_id: str) -> str:
    """Return the folder name for a given model ID."""
    contract = load_contract()
    for m in contract["models"]:
        if m["id"] == model_id:
            return m["folder"]
    raise KeyError(f"Unknown model_id: {model_id}")


def model_is_installed(model_id: str) -> bool:
    """Check whether all required files exist for a given model."""
    contract = load_contract()
    for m in contract["models"]:
        if m["id"] == model_id:
            model_dir = APP_MODELS_DIR / m["folder"]
            if not model_dir.is_dir():
                return False
            return all(
                (model_dir / rp).exists() for rp in m["requiredRelativePaths"]
            )
    return False


def models_dir() -> Path:
    """Return the app models directory path."""
    return APP_MODELS_DIR
