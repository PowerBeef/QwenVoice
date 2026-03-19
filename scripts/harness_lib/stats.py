"""Statistical helpers for benchmark summarization."""

from __future__ import annotations


def percentile(values: list[float], p: float) -> float:
    """Compute the p-th percentile of a sorted list of values."""
    if not values:
        return 0.0
    sorted_vals = sorted(values)
    k = (len(sorted_vals) - 1) * (p / 100.0)
    f = int(k)
    c = f + 1
    if c >= len(sorted_vals):
        return sorted_vals[-1]
    d = k - f
    return sorted_vals[f] + d * (sorted_vals[c] - sorted_vals[f])


def summarize_numeric(values: list[float]) -> dict[str, float]:
    """Compute summary statistics for a list of numeric values."""
    if not values:
        return {
            "mean": 0.0,
            "median": 0.0,
            "p95": 0.0,
            "min": 0.0,
            "max": 0.0,
            "cv": 0.0,
            "count": 0,
        }
    n = len(values)
    mean = sum(values) / n
    sorted_vals = sorted(values)
    median = sorted_vals[n // 2] if n % 2 == 1 else (sorted_vals[n // 2 - 1] + sorted_vals[n // 2]) / 2.0
    p95 = percentile(values, 95.0)
    min_val = min(values)
    max_val = max(values)
    if mean > 0:
        variance = sum((v - mean) ** 2 for v in values) / n
        std = variance ** 0.5
        cv = std / mean
    else:
        cv = 0.0

    return {
        "mean": round(mean, 2),
        "median": round(median, 2),
        "p95": round(p95, 2),
        "min": round(min_val, 2),
        "max": round(max_val, 2),
        "cv": round(cv, 4),
        "count": n,
    }
