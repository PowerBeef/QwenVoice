"""Pixel-level screenshot comparison for design regression testing."""

import os


def compare_screenshots(baseline_path, capture_path, diff_path, max_diff_percent=1.0):
    """Compare two PNG screenshots and generate a diff image.

    Returns dict with: name, diff_percent, threshold_percent, passed, diff_path.
    """
    try:
        return _compare_with_pillow(baseline_path, capture_path, diff_path, max_diff_percent)
    except ImportError:
        return _compare_bytes(baseline_path, capture_path, max_diff_percent)


def _compare_with_pillow(baseline_path, capture_path, diff_path, max_diff_percent):
    from PIL import Image, ImageChops
    import numpy as np

    baseline = Image.open(baseline_path).convert("RGB")
    capture = Image.open(capture_path).convert("RGB")

    # Resize capture to match baseline if dimensions differ
    if baseline.size != capture.size:
        capture = capture.resize(baseline.size, Image.LANCZOS)

    baseline_arr = np.array(baseline, dtype=np.int16)
    capture_arr = np.array(capture, dtype=np.int16)

    diff_arr = np.abs(baseline_arr - capture_arr)
    # A pixel is "different" if any channel differs by more than 10
    different_pixels = np.any(diff_arr > 10, axis=2)
    total_pixels = different_pixels.size
    diff_count = int(np.sum(different_pixels))
    diff_percent = round((diff_count / total_pixels) * 100, 4) if total_pixels > 0 else 0.0

    # Generate diff highlight image
    diff_highlight = np.zeros_like(baseline_arr, dtype=np.uint8)
    diff_highlight[different_pixels] = [255, 0, 0]  # Red for differences
    diff_highlight[~different_pixels] = (baseline_arr[~different_pixels] * 0.3).astype(np.uint8)

    diff_image = Image.fromarray(diff_highlight)
    os.makedirs(os.path.dirname(diff_path), exist_ok=True)
    diff_image.save(diff_path)

    return {
        "diff_percent": diff_percent,
        "threshold_percent": max_diff_percent,
        "passed": diff_percent <= max_diff_percent,
        "diff_path": diff_path,
        "total_pixels": total_pixels,
        "different_pixels": diff_count,
    }


def _compare_bytes(baseline_path, capture_path, max_diff_percent):
    """Fallback: exact byte comparison when PIL is unavailable."""
    with open(baseline_path, "rb") as f:
        baseline_bytes = f.read()
    with open(capture_path, "rb") as f:
        capture_bytes = f.read()

    is_identical = baseline_bytes == capture_bytes
    return {
        "diff_percent": 0.0 if is_identical else 100.0,
        "threshold_percent": max_diff_percent,
        "passed": is_identical,
        "diff_path": None,
        "method": "byte_comparison",
        "note": "Install Pillow for pixel-level diffing: pip install Pillow",
    }
