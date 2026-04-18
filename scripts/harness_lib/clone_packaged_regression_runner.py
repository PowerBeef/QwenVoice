"""Retired packaged clone regression helper retained for classifier compatibility."""

from __future__ import annotations

import time
from typing import Any

from .output import build_suite_result, build_test_result

SIMILAR_RATIO_THRESHOLD = 1.15
SIMILAR_DELTA_THRESHOLD_MS = 150
KEY_MEDIAN_METRICS = (
    "clone_fast_ready_ms",
    "first_preview_prepared_ms",
    "first_chunk_ms",
)


def run_clone_packaged_regression_bench(
    *,
    output_dir: str | None = None,
    legacy_app_bundle: str | None = None,
    legacy_dmg: str | None = None,
    current_app_bundle: str | None = None,
    current_dmg: str | None = None,
) -> dict[str, Any]:
    start = time.perf_counter()
    results = [
        build_test_result(
            "clone_packaged_regression_retired",
            passed=True,
            skip_reason="Packaged clone regression automation depended on the retired localhost UI control plane.",
            details={
                "output_dir": output_dir,
                "legacy_app_bundle": legacy_app_bundle,
                "legacy_dmg": legacy_dmg,
                "current_app_bundle": current_app_bundle,
                "current_dmg": current_dmg,
            },
        )
    ]
    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("clone_packaged_regression", results, duration_ms)


def classify_packaged_clone_regression(medians: dict[str, dict[str, Any]]) -> dict[str, Any]:
    slower_metrics = [
        metric
        for metric in KEY_MEDIAN_METRICS
        if _is_materially_slower(
            medians.get("legacy", {}).get(metric),
            medians.get("current", {}).get(metric),
        )
    ]

    if slower_metrics:
        source = "packaged_app_regression"
        reason = (
            "The current packaged app is materially slower than the legacy 1.2.2 packaged app "
            "on one or more clone user-experience medians."
        )
    else:
        source = "local_state_or_machine_environment"
        reason = (
            "The current and legacy packaged apps are within the configured similarity threshold "
            "on clone priming and preview medians, which points away from a packaged app regression."
        )

    return {
        "source": source,
        "reason": reason,
        "slower_metrics": slower_metrics,
        "similar_ratio_threshold": SIMILAR_RATIO_THRESHOLD,
        "similar_delta_threshold_ms": SIMILAR_DELTA_THRESHOLD_MS,
        "legacy": medians.get("legacy", {}),
        "current": medians.get("current", {}),
    }


def _is_materially_slower(legacy_value: Any, current_value: Any) -> bool:
    try:
        legacy_f = float(legacy_value)
        current_f = float(current_value)
    except (TypeError, ValueError):
        return False

    if current_f - legacy_f <= SIMILAR_DELTA_THRESHOLD_MS:
        return False
    if legacy_f <= 0:
        return current_f > SIMILAR_DELTA_THRESHOLD_MS
    return current_f > legacy_f * SIMILAR_RATIO_THRESHOLD
