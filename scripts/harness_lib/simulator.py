"""Simulator selection helpers for Xcode-backed iOS harness lanes."""

from __future__ import annotations

import json
import subprocess
from typing import Any

from .paths import PROJECT_DIR


def resolve_ios_simulator_destination() -> str | None:
    """Return the preferred available iPhone simulator destination string."""
    proc = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return None

    try:
        devices_by_runtime = json.loads(proc.stdout).get("devices", {})
    except json.JSONDecodeError:
        return None

    candidates: list[dict[str, Any]] = []
    for runtime, devices in devices_by_runtime.items():
        if "iOS" not in runtime:
            continue
        for device in devices:
            name = device.get("name", "")
            if not name.startswith("iPhone"):
                continue
            if not device.get("isAvailable", True):
                continue
            candidates.append(device)

    if not candidates:
        return None

    preferred_names = (
        "iPhone 17 Pro",
        "iPhone 17 Pro Max",
        "iPhone 17",
        "iPhone 16 Pro",
        "iPhone 15 Pro",
    )
    candidates.sort(
        key=lambda device: (
            0 if device.get("state") == "Booted" else 1,
            next(
                (
                    index
                    for index, preferred_name in enumerate(preferred_names)
                    if device.get("name") == preferred_name
                ),
                len(preferred_names),
            ),
            device.get("name", ""),
        )
    )
    return f"platform=iOS Simulator,id={candidates[0]['udid']}"
