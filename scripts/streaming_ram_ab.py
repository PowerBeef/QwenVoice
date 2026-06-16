#!/usr/bin/env python3
"""Paired streaming vs non-streaming RAM/RTF A/B for 1.7B Qwen3-TTS.

Runs the fixed short/medium/long corpus for custom/design Speed once with
--stream and once without, reusing a single model load per pair by calling
vocello generate. Telemetry rows are collected into a single diagnostics
directory so the standard summarizer can compare the two paths.
"""

import json
import os
import pathlib
import shutil
import subprocess
import sys

PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent
VOCHELLO = PROJECT_ROOT / "build" / "vocello"
DATA_DIR = pathlib.Path("/tmp/streaming_ab")
ALL_DIAG = DATA_DIR / "all_diagnostics"
WAV_DIR = DATA_DIR / "outputs"

DEFAULT_MODELS = pathlib.Path.home() / "Library/Application Support/QwenVoice/models"

CORPUS = {
    "short": "The train left the station at dawn.",
    "medium": "The morning train slipped quietly out of the station, carrying a handful of sleepy travelers toward the coast.",
    "long": "The morning train slipped quietly out of the station, carrying a handful of sleepy travelers toward the coast. Outside the fogged windows, pale fields gave way to grey water, and the rhythm of the rails settled into a steady, hypnotic hum. By the time the sun finally broke through, most of the passengers had drifted into an unhurried silence.",
}


def setup():
    if DATA_DIR.exists():
        shutil.rmtree(DATA_DIR)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    ALL_DIAG.mkdir(parents=True, exist_ok=True)
    WAV_DIR.mkdir(parents=True, exist_ok=True)

    models_link = DATA_DIR / "models"
    if not models_link.exists():
        if DEFAULT_MODELS.exists():
            models_link.symlink_to(DEFAULT_MODELS, target_is_directory=True)
        else:
            raise RuntimeError(f"Default models dir not found: {DEFAULT_MODELS}")


def append_tagged(src_dir: pathlib.Path, stream: bool, tag: str):
    """Append rows from a fresh run into the cumulative diagnostics files."""
    flag = int(stream)
    for jsonl in src_dir.rglob("*.jsonl"):
        rel = jsonl.relative_to(src_dir)
        dst = ALL_DIAG / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        with open(jsonl, "r", encoding="utf-8") as fh:
            with open(dst, "a", encoding="utf-8") as out:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        row = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    row["stream"] = flag
                    row["bench_note"] = tag
                    out.write(json.dumps(row, sort_keys=True))
                    out.write("\n")


def run_generate(mode: str, length: str, stream: bool):
    tag = f"{mode}_{length}_stream={int(stream)}"
    wav = WAV_DIR / f"{tag}.wav"
    # Fresh per-run diagnostics so we can append only this run's rows.
    run_diag = DATA_DIR / "diagnostics"
    if run_diag.exists():
        shutil.rmtree(run_diag)

    cmd = [
        str(VOCHELLO),
        "generate",
        "--data-dir", str(DATA_DIR),
        "--mode", mode,
        "--variant", "speed",
        "--text", CORPUS[length],
        "--out", str(wav),
    ]
    if mode == "design":
        cmd += ["--voice-brief", "A warm, calm middle-aged male narrator with a clear, measured pace."]
    if stream:
        cmd.append("--stream")

    env = os.environ.copy()
    env["QWENVOICE_DEBUG"] = "1"
    env["QWENVOICE_NATIVE_TELEMETRY_MODE"] = "lightweight"
    print(f"Running {tag}", file=sys.stderr)
    subprocess.run(cmd, check=True, cwd=PROJECT_ROOT, env=env)
    append_tagged(run_diag, stream, tag)


def main():
    setup()
    for mode in ["custom", "design"]:
        for length in ["short", "medium", "long"]:
            for stream in [False, True]:
                run_generate(mode, length, stream)
    print(f"\nAll diagnostics: {ALL_DIAG}", file=sys.stderr)
    print(f"All WAVs:        {WAV_DIR}", file=sys.stderr)


if __name__ == "__main__":
    main()
