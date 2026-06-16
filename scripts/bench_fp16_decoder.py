#!/usr/bin/env python3
"""A/B the original F32 speech-tokenizer decoder against an fp16-decoder copy."""

import json
import os
import pathlib
import shutil
import subprocess
import sys

PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent
VOCHELLO = PROJECT_ROOT / "build" / "vocello"
DATA_DIR = pathlib.Path("/tmp/fp16dec_ab")
ALL_DIAG = DATA_DIR / "all_diagnostics"
WAV_DIR = DATA_DIR / "outputs"
DEFAULT_MODELS = pathlib.Path.home() / "Library/Application Support/QwenVoice/models"
MANIFEST_ORIGINAL = None
MANIFEST_FP16 = PROJECT_ROOT / "scripts" / "manifest_fp16_decoder_research.json"

CORPUS = {
    "short": "The train left the station at dawn.",
    "medium": "The morning train slipped quietly out of the station, carrying a handful of sleepy travelers toward the coast.",
}


def setup():
    if DATA_DIR.exists():
        shutil.rmtree(DATA_DIR)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    ALL_DIAG.mkdir(parents=True, exist_ok=True)
    WAV_DIR.mkdir(parents=True, exist_ok=True)
    models_link = DATA_DIR / "models"
    if DEFAULT_MODELS.exists():
        models_link.symlink_to(DEFAULT_MODELS, target_is_directory=True)
    else:
        raise RuntimeError(f"Default models dir not found: {DEFAULT_MODELS}")


def append_tagged(src_dir: pathlib.Path, tag: str):
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
                    row["decoder"] = tag
                    out.write(json.dumps(row, sort_keys=True))
                    out.write("\n")


def run_generate(length: str, manifest: pathlib.Path | None, tag: str):
    wav = WAV_DIR / f"custom_{length}_{tag}.wav"
    run_diag = DATA_DIR / "diagnostics"
    if run_diag.exists():
        shutil.rmtree(run_diag)

    cmd = [
        str(VOCHELLO),
        "generate",
        "--data-dir", str(DATA_DIR),
        "--mode", "custom",
        "--variant", "speed",
        "--text", CORPUS[length],
        "--out", str(wav),
    ]
    if manifest is not None:
        cmd += ["--manifest", str(manifest)]

    env = os.environ.copy()
    env["QWENVOICE_DEBUG"] = "1"
    env["QWENVOICE_NATIVE_TELEMETRY_MODE"] = "lightweight"
    print(f"Running custom/{length} with {tag} decoder", file=sys.stderr)
    subprocess.run(cmd, check=True, cwd=PROJECT_ROOT, env=env)
    append_tagged(run_diag, tag)


def main():
    setup()
    for length in ["short", "medium"]:
        run_generate(length, MANIFEST_ORIGINAL, "f32")
        run_generate(length, MANIFEST_FP16, "fp16")
    print(f"\nAll diagnostics: {ALL_DIAG}", file=sys.stderr)
    print(f"All WAVs:        {WAV_DIR}", file=sys.stderr)


if __name__ == "__main__":
    main()
