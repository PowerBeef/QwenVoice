#!/usr/bin/env python3
"""Estimate how much of the non-streaming peak is output-accumulator memory.

Reads engine telemetry rows (expects a `stream` or `bench_note` field) and reports:
- audio duration and PCM sample bytes
- generated codec-token frame/codebook counts and byte estimates
- observed peakGPU / physFoot deltas
- MLX memory-by-stage snapshots
"""

import argparse
import json
import pathlib
import re
import sys


def iter_rows(path: pathlib.Path):
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
        except json.JSONDecodeError:
            continue


def parse_tag(tag: str):
    m = re.match(r"^(custom|design)_(short|medium|long)_stream=(\d)$", tag)
    if not m:
        return None
    return m.group(1), m.group(2), int(m.group(3))


def analyze(rows):
    groups = {}
    for r in rows:
        tag = r.get("bench_note", "")
        parsed = parse_tag(tag)
        if not parsed:
            continue
        mode, length, stream = parsed
        groups.setdefault((mode, length), {})[stream] = r

    print("| mode | len | stream | audio s | PCM MB | codec frames | codec tokens | token MB | gpuPeak MB | physFoot MB |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for (mode, length), cells in sorted(groups.items()):
        for stream in [0, 1]:
            r = cells.get(stream)
            if not r:
                continue
            dur = r["audioQC"]["durationSeconds"]
            pcm_bytes = dur * 24_000 * 2  # 24 kHz, 16-bit mono
            frames = int(dur * 12.5)
            tokens = frames * 16  # 16 codebooks
            token_bytes = tokens * 4  # int32 per token
            gpu = r["summary"]["gpuAllocatedPeakMB"]
            phys = r["summary"]["physFootprintPeakMB"]
            print(f"| {mode} | {length} | {stream} | {dur:.2f} | {pcm_bytes/1e6:.3f} | {frames} | {tokens} | {token_bytes/1e6:.3f} | {gpu:.0f} | {phys:.0f} |")
    print()

    # Stage memory for long custom non-streaming vs streaming
    key = ("custom", "long")
    if key in groups and 0 in groups[key] and 1 in groups[key]:
        print("### MLX memory-by-stage snapshot — custom/long")
        for stream in [0, 1]:
            print(f"\nstream={stream}")
            r = groups[key][stream]
            for stage, vals in r.get("mlxMemoryByStage", {}).items():
                print(f"  {stage}: active={vals['activeMB']:.0f} MB, peak={vals['peakMB']:.0f} MB, cache={vals['cacheMB']:.0f} MB")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("diagnostics_dir", nargs="?", default=str(pathlib.Path.home() / "Library/Application Support/QwenVoice-Debug/diagnostics"))
    args = p.parse_args()
    diag = pathlib.Path(args.diagnostics_dir)
    engine_jsonl = diag / "engine" / "generations.jsonl"
    if not engine_jsonl.exists():
        print(f"No engine telemetry at {engine_jsonl}", file=sys.stderr)
        sys.exit(1)
    analyze(list(iter_rows(engine_jsonl)))


if __name__ == "__main__":
    main()
