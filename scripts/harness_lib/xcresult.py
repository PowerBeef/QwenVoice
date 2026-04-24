"""xcresulttool parsing helpers for harness JSON details."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any

from .paths import PROJECT_DIR


def summarize_xcresult(result_bundle_path: Path, *, stage: str) -> dict[str, Any] | None:
    """Return compact build or test summary JSON from an `.xcresult` bundle."""
    if not result_bundle_path.exists():
        return None

    if stage == "build":
        command = [
            "xcrun",
            "xcresulttool",
            "get",
            "build-results",
            "--path",
            str(result_bundle_path),
            "--compact",
        ]
    else:
        command = [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            str(result_bundle_path),
            "--compact",
        ]

    proc = subprocess.run(
        command,
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return {
            "error": f"xcresulttool exited with {proc.returncode}",
            "stderr_tail": proc.stderr.splitlines()[-20:],
        }

    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {
            "error": "xcresulttool produced unreadable JSON",
            "stdout_tail": proc.stdout.splitlines()[-20:],
        }
