#!/usr/bin/env python3
"""Create a copy of a Qwen3-TTS model with speech-tokenizer decoder weights cast to fp16.

Only tensors whose key starts with `decoder.` are cast; encoder/quantizer tensors are
kept in their original dtype so any reference-audio encoder path stays unchanged.
"""

import argparse
import os
import shutil

import numpy as np
from safetensors import safe_open
from safetensors.numpy import save_file


def cast_dir(src: str, dst: str):
    src = os.path.expanduser(src)
    dst = os.path.expanduser(dst)
    if os.path.exists(dst):
        shutil.rmtree(dst)
    os.makedirs(dst, exist_ok=True)

    for root, dirs, files in os.walk(src):
        rel = os.path.relpath(root, src)
        out_root = os.path.join(dst, rel)
        os.makedirs(out_root, exist_ok=True)
        for d in dirs:
            os.makedirs(os.path.join(out_root, d), exist_ok=True)
        for f in files:
            src_path = os.path.join(root, f)
            dst_path = os.path.join(out_root, f)
            if f == "model.safetensors" and rel.endswith("speech_tokenizer"):
                tensors = {}
                with safe_open(src_path, framework="np") as fh:
                    for k in fh.keys():
                        arr = fh.get_tensor(k)
                        if k.startswith("decoder.") and arr.dtype == np.float32:
                            arr = arr.astype(np.float16)
                        tensors[k] = arr
                save_file(tensors, dst_path)
                cast_count = sum(1 for k in tensors if k.startswith("decoder."))
                print(f"Cast {src_path} -> {dst_path} ({cast_count} decoder tensors to fp16)")
            else:
                shutil.copy2(src_path, dst_path)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("src", help="source model directory")
    p.add_argument("dst", help="destination model directory")
    args = p.parse_args()
    cast_dir(args.src, args.dst)
