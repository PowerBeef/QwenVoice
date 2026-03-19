"""JSON output envelope and stderr helpers for the QwenVoice harness."""

from __future__ import annotations

import sys
from datetime import datetime, timezone
from typing import Any

from . import HARNESS_VERSION


def eprint(*args: Any, **kwargs: Any) -> None:
    """Print to stderr."""
    print(*args, file=sys.stderr, **kwargs)


def build_envelope(
    subcommand: str,
    suites: list[dict[str, Any]],
    duration_ms: int,
) -> dict[str, Any]:
    """Build the top-level JSON result envelope."""
    overall_pass = all(
        suite.get("fail_count", 0) == 0 for suite in suites
    )
    return {
        "harness_version": HARNESS_VERSION,
        "subcommand": subcommand,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "duration_ms": duration_ms,
        "overall_pass": overall_pass,
        "suites": suites,
    }


def build_suite_result(
    name: str,
    results: list[dict[str, Any]],
    duration_ms: int,
) -> dict[str, Any]:
    """Build a per-suite summary."""
    pass_count = sum(1 for r in results if r.get("passed"))
    skip_count = sum(1 for r in results if r.get("skip_reason"))
    fail_count = len(results) - pass_count - skip_count
    return {
        "name": name,
        "pass_count": pass_count,
        "fail_count": fail_count,
        "skip_count": skip_count,
        "duration_ms": duration_ms,
        "results": results,
    }


def build_test_result(
    name: str,
    passed: bool,
    skip_reason: str | None = None,
    error: str | None = None,
    duration_ms: int = 0,
    details: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build a single test result entry."""
    result: dict[str, Any] = {
        "name": name,
        "passed": passed,
        "duration_ms": duration_ms,
    }
    if skip_reason:
        result["skip_reason"] = skip_reason
    if error:
        result["error"] = error
    if details:
        result["details"] = details
    return result
