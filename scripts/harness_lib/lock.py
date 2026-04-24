"""Advisory locking for heavy harness lanes."""

from __future__ import annotations

import contextlib
import fcntl
import os
import sys
from collections.abc import Iterator

from .paths import HARNESS_ROOT

HARNESS_LOCK_PATH = HARNESS_ROOT / ".lock"


@contextlib.contextmanager
def heavy_run_lock(label: str) -> Iterator[None]:
    """Fail fast when another heavy harness or Xcode lane is already running."""
    HARNESS_LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    lock_file = open(HARNESS_LOCK_PATH, "w", encoding="utf-8")
    try:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.stderr.write(
                f"harness.py: another heavy run holds {HARNESS_LOCK_PATH} - "
                f"refusing to overlap with current request ({label}).\n"
                "Wait for the other run or remove the lock file if stale.\n"
            )
            sys.exit(75)
        lock_file.write(f"pid={os.getpid()} label={label}\n")
        lock_file.flush()
        yield
    finally:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
        lock_file.close()
