#!/usr/bin/env python3
"""QwenVoice unified testing, debugging, and benchmarking harness."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import sys
import time
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from harness_lib.output import build_envelope

# Tier 4.4: AGENTS.md forbids overlapping heavy harness/xcodebuild runs on
# this machine. `swift`, `native`, `ios`, `audio`, and the whole `bench`
# subcommand are considered heavy — we take an advisory flock so two
# concurrent invocations fail fast instead of thrashing shared derived-data.
_HEAVY_TEST_LAYERS = {"swift", "native", "ios", "audio", "all"}
_HARNESS_LOCK_PATH = SCRIPTS_DIR.parent / "build" / "harness" / ".harness.lock"


@contextlib.contextmanager
def _heavy_run_lock(label: str):
    """Acquire an advisory file lock for heavy runs; fail fast if contended."""
    _HARNESS_LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    lock_file = open(_HARNESS_LOCK_PATH, "w")
    try:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.stderr.write(
                f"harness.py: another heavy run holds {_HARNESS_LOCK_PATH} — "
                f"refusing to overlap with current request ({label}).\n"
                "Wait for the other run or remove the lock file if stale.\n"
            )
            sys.exit(75)  # EX_TEMPFAIL — clear "retry later" signal
        lock_file.write(f"pid={os.getpid()} label={label}\n")
        lock_file.flush()
        yield
    finally:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
        lock_file.close()


def _run_test(args: argparse.Namespace) -> None:
    from harness_lib.test_runner import run_tests

    layer = args.layer
    lock_cm = _heavy_run_lock(f"test --layer {layer}") if layer in _HEAVY_TEST_LAYERS \
        else contextlib.nullcontext()

    with lock_cm:
        start = time.perf_counter()
        suites = run_tests(
            layer=layer,
            artifact_dir=getattr(args, "artifact_dir", None),
        )
        duration_ms = int((time.perf_counter() - start) * 1000)
    envelope = build_envelope("test", suites, duration_ms)
    print(json.dumps(envelope, indent=2))
    if not envelope["overall_pass"]:
        sys.exit(1)


def _run_bench(args: argparse.Namespace) -> None:
    from harness_lib.bench_runner import run_benchmarks

    with _heavy_run_lock(f"bench --category {args.category}"):
        start = time.perf_counter()
        suites = run_benchmarks(
            category=args.category,
            runs=args.runs,
            output_dir=args.output_dir,
            tier=getattr(args, "tier", "all"),
        )
        duration_ms = int((time.perf_counter() - start) * 1000)
    envelope = build_envelope("bench", suites, duration_ms)
    print(json.dumps(envelope, indent=2))
    if not envelope["overall_pass"]:
        sys.exit(1)


def _run_diagnose(_: argparse.Namespace) -> None:
    from harness_lib.diagnose_runner import run_diagnose

    start = time.perf_counter()
    suites = run_diagnose()
    duration_ms = int((time.perf_counter() - start) * 1000)
    envelope = build_envelope("diagnose", suites, duration_ms)
    print(json.dumps(envelope, indent=2))


def _run_validate(_: argparse.Namespace) -> None:
    from harness_lib.validate_runner import run_validate

    start = time.perf_counter()
    suites = run_validate()
    duration_ms = int((time.perf_counter() - start) * 1000)
    envelope = build_envelope("validate", suites, duration_ms)
    print(json.dumps(envelope, indent=2))
    if not envelope["overall_pass"]:
        sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="QwenVoice unified testing, debugging, and benchmarking harness.",
    )
    sub = parser.add_subparsers(dest="subcommand", required=True)

    p_test = sub.add_parser("test", help="Run test suites")
    p_test.add_argument(
        "--layer",
        choices=["contract", "swift", "native", "ios", "audio", "all"],
        default="all",
    )
    p_test.add_argument(
        "--artifact-dir",
        default=None,
        help="Directory with chunk_*.wav plus final.wav for offline audio analysis",
    )
    p_test.set_defaults(func=_run_test)

    p_bench = sub.add_parser("bench", help="Run benchmark suites")
    p_bench.add_argument(
        "--category",
        choices=["latency", "load", "quality", "tts_roundtrip", "perf", "all"],
        default="all",
    )
    p_bench.add_argument("--runs", type=int, default=3, help="Runs per benchmark")
    p_bench.add_argument("--output-dir", default=None, help="Output directory for artifacts")
    p_bench.add_argument(
        "--tier",
        default="all",
        help="Perf profiler tiers to run (comma-separated: 1,2,3,4 or 'all')",
    )
    p_bench.set_defaults(func=_run_bench)

    p_diag = sub.add_parser("diagnose", help="Run diagnostic checks")
    p_diag.set_defaults(func=_run_diagnose)

    p_val = sub.add_parser("validate", help="Fast pre-commit validation")
    p_val.set_defaults(func=_run_validate)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
