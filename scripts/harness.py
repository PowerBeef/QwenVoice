#!/usr/bin/env python3
"""QwenVoice unified testing, debugging & benchmarking harness.

Single entry point for autonomous test/bench/diagnose/validate workflows.
All structured output goes to stdout as JSON; progress messages to stderr.

Invocation:
  ~/Library/Application\\ Support/QwenVoice/python/bin/python3 scripts/harness.py <subcommand> [options]
"""

from __future__ import annotations

import argparse
import json
import sys
import time

# Ensure harness_lib is importable when run as a script
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from harness_lib.output import build_envelope, eprint


def _run_test(args: argparse.Namespace) -> None:
    from harness_lib.test_runner import run_tests

    start = time.perf_counter()
    suites = run_tests(
        layer=args.layer,
        python_path=args.python or None,
        artifact_dir=getattr(args, "artifact_dir", None),
        ui_backend_mode=getattr(args, "ui_backend_mode", "live"),
        ui_data_root=getattr(args, "ui_data_root", "fixture"),
    )
    duration_ms = int((time.perf_counter() - start) * 1000)
    envelope = build_envelope("test", suites, duration_ms)
    print(json.dumps(envelope, indent=2))
    if not envelope["overall_pass"]:
        sys.exit(1)


def _run_bench(args: argparse.Namespace) -> None:
    from harness_lib.bench_runner import run_benchmarks

    start = time.perf_counter()
    suites = run_benchmarks(
        category=args.category,
        runs=args.runs,
        python_path=args.python or None,
        output_dir=args.output_dir,
        tier=getattr(args, "tier", "all"),
    )
    duration_ms = int((time.perf_counter() - start) * 1000)
    envelope = build_envelope("bench", suites, duration_ms)
    print(json.dumps(envelope, indent=2))
    if not envelope["overall_pass"]:
        sys.exit(1)


def _run_diagnose(args: argparse.Namespace) -> None:
    from harness_lib.diagnose_runner import run_diagnose

    start = time.perf_counter()
    suites = run_diagnose(python_path=args.python or None)
    duration_ms = int((time.perf_counter() - start) * 1000)
    envelope = build_envelope("diagnose", suites, duration_ms)
    print(json.dumps(envelope, indent=2))


def _run_validate(args: argparse.Namespace) -> None:
    from harness_lib.validate_runner import run_validate

    start = time.perf_counter()
    suites = run_validate(python_path=args.python or None)
    duration_ms = int((time.perf_counter() - start) * 1000)
    envelope = build_envelope("validate", suites, duration_ms)
    print(json.dumps(envelope, indent=2))
    if not envelope["overall_pass"]:
        sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="QwenVoice unified testing, debugging & benchmarking harness.",
    )
    sub = parser.add_subparsers(dest="subcommand", required=True)

    # test
    p_test = sub.add_parser("test", help="Run test suites")
    p_test.add_argument(
        "--layer",
        choices=["pipeline", "rpc", "contract", "server", "swift", "audio", "ui", "design", "perf", "all"],
        default="all",
    )
    p_test.add_argument("--python", default="", help="Explicit Python interpreter path")
    p_test.add_argument("--artifact-dir", default=None,
        help="Directory with chunk_*.wav + final.wav for offline audio analysis")
    p_test.add_argument(
        "--ui-backend-mode",
        choices=["live", "stub"],
        default="live",
        help="Backend mode for UI/design/perf layers",
    )
    p_test.add_argument(
        "--ui-data-root",
        choices=["fixture", "real"],
        default="fixture",
        help="App data root for live UI/design/perf layers",
    )
    p_test.set_defaults(func=_run_test)

    # bench
    p_bench = sub.add_parser("bench", help="Run benchmarks")
    p_bench.add_argument(
        "--category",
        choices=["latency", "load", "quality", "release", "perf", "all"],
        default="all",
    )
    p_bench.add_argument("--runs", type=int, default=3, help="Runs per benchmark")
    p_bench.add_argument("--python", default="", help="Explicit Python interpreter path")
    p_bench.add_argument("--output-dir", default=None, help="Output directory for artifacts")
    p_bench.add_argument(
        "--tier",
        default="all",
        help="Perf profiler tiers to run (comma-separated: 1,2,3,4 or 'all')",
    )
    p_bench.set_defaults(func=_run_bench)

    # diagnose
    p_diag = sub.add_parser("diagnose", help="Run diagnostic checks")
    p_diag.add_argument("--python", default="", help="Explicit Python interpreter path")
    p_diag.set_defaults(func=_run_diagnose)

    # validate
    p_val = sub.add_parser("validate", help="Fast pre-commit validation")
    p_val.add_argument("--python", default="", help="Explicit Python interpreter path")
    p_val.set_defaults(func=_run_validate)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
