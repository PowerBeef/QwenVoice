#!/usr/bin/env python3
"""Matched seeded telemetry overhead/parity lane for vocello bench."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import statistics
import subprocess
import sys
import wave


ROOT = Path(__file__).resolve().parents[1]
DEBUG_ROOT = Path.home() / "Library" / "Application Support" / "QwenVoice-Debug"
TAKE_PATTERN = re.compile(
    r"custom/S/medium/warm#(?P<take>\d+)\s+"
    r"(?P<audio>[0-9.]+)s audio in (?P<wall>[0-9.]+)s\s+ttfc=(?P<ttfc>[0-9.]+)ms"
)
MODES = ("off", "lightweight", "verbose")


def pcm_digest(path: Path) -> str:
    with wave.open(str(path), "rb") as stream:
        payload = stream.readframes(stream.getnframes())
    return hashlib.sha256(payload).hexdigest()


def throughput_regression(candidate: float, baseline: float) -> float:
    """Positive when higher-is-better throughput regresses."""
    return 0.0 if baseline <= 0 else (1.0 - (candidate / baseline)) * 100.0


def latency_regression(candidate: float, baseline: float) -> float:
    """Positive when lower-is-better latency regresses."""
    return 0.0 if baseline <= 0 else ((candidate / baseline) - 1.0) * 100.0


def run_lane(args: argparse.Namespace) -> dict:
    run_id = "telemetry-overhead-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    run_dir = ROOT / "build" / "macos" / "telemetry-overhead" / run_id
    run_dir.mkdir(parents=True)
    source_models = DEBUG_ROOT / "models"
    if not source_models.exists():
        raise RuntimeError(f"debug model root is missing: {source_models}")

    results: dict[str, dict] = {}
    for mode in MODES:
        data_dir = run_dir / f"data-{mode}"
        data_dir.mkdir()
        (data_dir / "models").symlink_to(source_models.resolve(), target_is_directory=True)
        command = [
            str(ROOT / "build" / "vocello"), "bench",
            "--modes", "custom", "--variants", "speed", "--lengths", "medium",
            "--warm", str(args.measured + 1), "--seed", str(args.seed),
            "--telemetry", mode, "--data-dir", str(data_dir), "--no-summary",
        ]
        completed = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
        (run_dir / f"{mode}.stdout.log").write_text(completed.stdout)
        (run_dir / f"{mode}.stderr.log").write_text(completed.stderr)
        if completed.returncode:
            raise RuntimeError(f"{mode} bench failed with exit {completed.returncode}")

        samples = []
        for match in TAKE_PATTERN.finditer(completed.stderr):
            take = int(match.group("take"))
            if take == 0 or take > args.measured:
                continue
            audio = float(match.group("audio"))
            wall = float(match.group("wall"))
            samples.append({
                "take": take,
                "audioSeconds": audio,
                "wallSeconds": wall,
                "rtf": audio / wall,
                "ttfcMS": float(match.group("ttfc")),
            })
        if len(samples) != args.measured:
            raise RuntimeError(f"{mode} produced {len(samples)} measured warm takes, expected {args.measured}")

        output_dir = data_dir / "outputs" / "bench"
        pcm = {}
        for sample in samples:
            matches = list(output_dir.glob(f"custom_*_medium_warm_{sample['take']}.wav"))
            if len(matches) != 1:
                raise RuntimeError(f"{mode} take {sample['take']} has {len(matches)} WAV matches")
            pcm[str(sample["take"])] = pcm_digest(matches[0])
        results[mode] = {
            "samples": samples,
            "medianRTF": statistics.median(sample["rtf"] for sample in samples),
            "medianTTFCMS": statistics.median(sample["ttfcMS"] for sample in samples),
            "pcmSHA256": pcm,
        }

    baseline = results["off"]
    thresholds = {"lightweight": 5.0, "verbose": 10.0}
    failures = []
    parity = all(results[mode]["pcmSHA256"] == baseline["pcmSHA256"] for mode in MODES[1:])
    if not parity:
        failures.append("seeded PCM differs across telemetry modes")
    for mode, limit in thresholds.items():
        results[mode]["rtfRegressionPercent"] = throughput_regression(
            results[mode]["medianRTF"], baseline["medianRTF"]
        )
        results[mode]["ttfcRegressionPercent"] = latency_regression(
            results[mode]["medianTTFCMS"], baseline["medianTTFCMS"]
        )
        if results[mode]["rtfRegressionPercent"] > limit:
            failures.append(f"{mode} median RTF regression exceeds {limit:.0f}%")
        if results[mode]["ttfcRegressionPercent"] > limit:
            failures.append(f"{mode} median TTFC regression exceeds {limit:.0f}%")

    verdict = {
        "schemaVersion": 1,
        "runID": run_id,
        "completedAt": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "status": "pass" if not failures else "fail",
        "attestationSummary": {
            "seed": args.seed,
            "measuredWarmTakesPerMode": args.measured,
            "pcmParity": parity,
            "thresholdsPercent": thresholds,
            "modes": {
                mode: {
                    key: results[mode][key]
                    for key in (
                        "medianRTF", "medianTTFCMS", "rtfRegressionPercent",
                        "ttfcRegressionPercent",
                    )
                    if key in results[mode]
                }
                for mode in MODES
            },
        },
        "summary": {
            "seed": args.seed,
            "warmupTakesPerMode": 1,
            "measuredWarmTakesPerMode": args.measured,
            "pcmParity": parity,
            "thresholdsPercent": thresholds,
            "results": results,
            "failures": failures,
        },
    }
    verdict_path = run_dir / "verdict.json"
    verdict_path.write_text(json.dumps(verdict, indent=2, sort_keys=True) + "\n")
    print(verdict_path)
    if failures:
        raise RuntimeError("; ".join(failures))
    return verdict


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, default=1_264_849_675)
    parser.add_argument("--measured", type=int, default=5)
    args = parser.parse_args()
    if args.measured < 5:
        parser.error("--measured must be at least 5")
    try:
        run_lane(args)
        return 0
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
