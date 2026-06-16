#!/usr/bin/env python3
"""Audit speech-tokenizer decoder weight dtypes and memory footprint.

Scans every installed Qwen3-TTS model under ~/Library/Application Support/QwenVoice/models
and reports the dtype and size of speech_tokenizer/model.safetensors.
"""

import os
from pathlib import Path

import numpy as np
from safetensors import safe_open

MODELS_DIR = Path.home() / "Library/Application Support/QwenVoice/models"


def audit_model(model_dir: Path):
    st_path = model_dir / "speech_tokenizer" / "model.safetensors"
    if not st_path.exists():
        return None
    total_bytes = 0
    dtype_counts = {}
    shape_summary = []
    with safe_open(st_path, framework="np") as f:
        for k in sorted(f.keys()):
            sl = f.get_slice(k)
            shape = sl.get_shape()
            dtype = sl.get_dtype()
            bytes_per = {"F32": 4, "F16": 2, "BF16": 2, "I32": 4, "I16": 2, "I8": 1, "U8": 1, "BOOL": 1}.get(dtype, 4)
            n = int(np.prod(shape))
            total_bytes += n * bytes_per
            dtype_counts[dtype] = dtype_counts.get(dtype, 0) + n * bytes_per
            shape_summary.append((k, shape, dtype))
    return {
        "model": model_dir.name,
        "path": st_path,
        "total_bytes": total_bytes,
        "dtype_counts": dtype_counts,
        "tensors": shape_summary,
    }


def main():
    if not MODELS_DIR.exists():
        print(f"Models directory not found: {MODELS_DIR}")
        return
    results = []
    for entry in sorted(MODELS_DIR.iterdir()):
        if not entry.is_dir():
            continue
        info = audit_model(entry)
        if info:
            results.append(info)

    print("# Speech-tokenizer decoder weight audit\n")
    total_all = 0
    for info in results:
        print(f"## {info['model']}")
        print(f"- File: `{info['path']}`")
        print(f"- Total decoder weight size: **{info['total_bytes'] / 1e6:.2f} MB** ({info['total_bytes'] / 1e9:.3f} GB)")
        print("- Bytes by dtype:")
        for dtype, b in sorted(info["dtype_counts"].items(), key=lambda x: -x[1]):
            print(f"  - {dtype}: {b / 1e6:.2f} MB")
        print("- Tensor shapes:")
        for name, shape, dtype in info["tensors"]:
            print(f"  - `{name}`: {shape} {dtype}")
        print()
        total_all += info["total_bytes"]

    print(f"## Aggregate across {len(results)} models")
    print(f"Total decoder weight footprint: **{total_all / 1e9:.3f} GB**")
    print(f"If all decoder weights were cast to fp16: **{total_all / 2 / 1e9:.3f} GB** (≈ {total_all / 2 / 1e6:.2f} MB)")


if __name__ == "__main__":
    main()
