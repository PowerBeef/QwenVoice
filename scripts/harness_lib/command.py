"""Subprocess helpers for the QwenVoice harness."""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any

from .paths import PROJECT_DIR


def run_command(
    command: list[str],
    *,
    cwd: Path = PROJECT_DIR,
    timeout: int | None = None,
) -> tuple[subprocess.CompletedProcess[str], dict[str, Any] | None]:
    """Run a command and return a CompletedProcess plus optional timeout details."""
    try:
        proc = subprocess.run(
            command,
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return proc, None
    except subprocess.TimeoutExpired as exc:
        stdout = output_to_text(exc.stdout)
        stderr = output_to_text(exc.stderr)
        return subprocess.CompletedProcess(
            args=command,
            returncode=124,
            stdout=stdout,
            stderr=stderr,
        ), {
            "timeout_seconds": timeout,
            "stdout_tail": tail_lines(stdout),
            "stderr_tail": tail_lines(stderr),
        }


def output_to_text(value: Any) -> str:
    """Decode subprocess output that may be bytes, text, or None."""
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def tail_lines(value: str, count: int = 20) -> list[str]:
    """Return the trailing lines used in JSON result details."""
    return value.splitlines()[-count:]
