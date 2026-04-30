#!/usr/bin/env python3
"""Run autonomous generated-audio quality review workflows.

This is the orchestration layer above ``audit_generated_audio.py``. It can
analyze existing latest outputs, run the analyzer self-test, or opt into a live
macOS XPC generation pass that creates fresh clips and audits both final WAVs
and retained live-preview chunk sessions.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from harness_lib.contract import load_contract  # noqa: E402
from harness_lib.paths import APP_MODELS_DIR, BUILD_ROOT, PROJECT_DIR, ensure_directory  # noqa: E402
from harness_lib.ui_test_support import resolve_xcodebuild_timeout_seconds  # noqa: E402

MODE_MODEL_IDS = {
    "CustomVoice": "pro_custom",
    "VoiceDesign": "pro_design",
    "Clones": "pro_clone",
}
DEFAULT_MODES = ["CustomVoice", "VoiceDesign"]


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Run autonomous QwenVoice/Vocello generated-audio quality review.",
    )
    parser.add_argument(
        "--source",
        choices=["self-test", "latest", "live-xpc"],
        default="self-test",
        help="Audit source. live-xpc generates fresh clips through the macOS XPC engine.",
    )
    parser.add_argument(
        "--modes",
        default=",".join(DEFAULT_MODES),
        help="Comma-separated modes: CustomVoice, VoiceDesign, Clones.",
    )
    parser.add_argument(
        "--allow-model-load",
        action="store_true",
        help="Required for --source live-xpc because it may load MLX models.",
    )
    parser.add_argument("--clone-reference", help="Reference WAV/audio path required for Clones live generation.")
    parser.add_argument("--clone-transcript", help="Optional transcript for Clones live generation.")
    parser.add_argument(
        "--models-root",
        default=str(APP_MODELS_DIR),
        help="Installed model root used by --source live-xpc.",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="Audit artifact directory. Defaults to build/audio-qc/<timestamp>.",
    )
    parser.add_argument(
        "--repeat-count",
        type=int,
        default=1,
        help="Repeat live-xpc generation this many times per requested mode. Defaults to 1; maximum 10.",
    )
    parser.add_argument(
        "--benchmark-profile",
        choices=["repeat", "cold-warm", "warm-focus", "custom-ui-cold", "exhaustive"],
        default="repeat",
        help=(
            "Live XPC benchmark profile. cold-warm measures all modes; "
            "warm-focus measures repeated Voice Design warm runs; custom-ui-cold "
            "measures selected Custom Voice warmup plus generation; exhaustive adds "
            "endurance, direct long-text, and product long-form batch coverage."
        ),
    )
    parser.add_argument(
        "--cold-runs",
        type=int,
        default=2,
        help="Measured cold runs per mode for --benchmark-profile cold-warm. Defaults to 2.",
    )
    parser.add_argument(
        "--warm-runs",
        type=int,
        default=3,
        help="Measured warm runs per mode for --benchmark-profile cold-warm or warm-focus. Defaults to 3.",
    )
    parser.add_argument(
        "--compare-baseline",
        default=None,
        help="Optional previous summary.json to compare timing medians against this run.",
    )
    parser.add_argument(
        "--streaming-interval",
        type=float,
        default=None,
        help="Optional live benchmark streaming interval override in seconds.",
    )
    parser.add_argument(
        "--custom-prewarm-depth",
        choices=["full", "skip-decoder-bucket", "skip-stream-step"],
        default=None,
        help=(
            "Benchmark-only Custom Voice prewarm depth override. Defaults to the product "
            "full prewarm path."
        ),
    )

    args = parser.parse_args()
    output_dir = (Path(args.output_dir) if args.output_dir else default_output_dir(args.source)).resolve()
    ensure_directory(output_dir)

    try:
        modes = parse_modes(args.modes)
        repeat_count = parse_repeat_count(args.repeat_count)
        cold_runs = parse_benchmark_run_count(args.cold_runs, "--cold-runs")
        warm_runs = parse_benchmark_run_count(args.warm_runs, "--warm-runs")
        if args.benchmark_profile != "repeat" and args.source != "live-xpc":
            raise UsageError("--benchmark-profile cold-warm/warm-focus/custom-ui-cold/exhaustive is only supported with --source live-xpc.")
        if args.benchmark_profile == "warm-focus" and modes != ["VoiceDesign"]:
            raise UsageError("--benchmark-profile warm-focus requires --modes VoiceDesign.")
        if args.benchmark_profile == "custom-ui-cold" and modes != ["CustomVoice"]:
            raise UsageError("--benchmark-profile custom-ui-cold requires --modes CustomVoice.")
        if args.streaming_interval is not None and not (0.1 <= args.streaming_interval <= 1.5):
            raise UsageError("--streaming-interval must be between 0.1 and 1.5 seconds.")
        if args.custom_prewarm_depth is not None and args.source != "live-xpc":
            raise UsageError("--custom-prewarm-depth is only supported with --source live-xpc.")
        if args.source == "self-test":
            summary = run_self_test(output_dir, repeat_count)
        elif args.source == "latest":
            summary = run_latest_analysis(output_dir, modes, repeat_count)
        else:
            summary = run_live_xpc_analysis(
                output_dir,
                modes,
                repeat_count,
                cold_runs,
                warm_runs,
                args,
            )
        if args.compare_baseline:
            summary["comparison_baseline"] = str(Path(args.compare_baseline))
            summary["timing_comparison"] = compare_timing_summaries(
                current_summary=summary,
                baseline_path=Path(args.compare_baseline),
            )
    except UsageError as exc:
        summary = build_base_summary(
            output_dir,
            args.source,
            parse_modes_lenient(args.modes),
            repeat_count=getattr(args, "repeat_count", 1),
            benchmark_profile=getattr(args, "benchmark_profile", "repeat"),
            cold_runs=getattr(args, "cold_runs", None),
            warm_runs=getattr(args, "warm_runs", None),
        )
        summary["overall_pass"] = False
        summary["error"] = str(exc)
        write_summary(output_dir, summary)
        print(render_summary_markdown(summary))
        raise SystemExit(2)

    write_summary(output_dir, summary)
    print(render_summary_markdown(summary))
    raise SystemExit(summary.get("exit_code", 0 if summary["overall_pass"] else 1))


class UsageError(Exception):
    """Invalid invocation or unavailable source artifact."""


def default_output_dir(source: str) -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return BUILD_ROOT / "audio-qc" / f"{source}-{stamp}"


def parse_modes(raw_modes: str) -> list[str]:
    modes = [part.strip() for part in raw_modes.split(",") if part.strip()]
    if not modes:
        modes = list(DEFAULT_MODES)
    unsupported = [mode for mode in modes if mode not in MODE_MODEL_IDS]
    if unsupported:
        raise UsageError(f"Unsupported mode(s): {', '.join(unsupported)}")
    deduped: list[str] = []
    for mode in modes:
        if mode not in deduped:
            deduped.append(mode)
    return deduped


def parse_modes_lenient(raw_modes: str) -> list[str]:
    try:
        return parse_modes(raw_modes)
    except UsageError:
        return [part.strip() for part in raw_modes.split(",") if part.strip()]


def parse_repeat_count(value: int) -> int:
    if not 1 <= value <= 10:
        raise UsageError("--repeat-count must be between 1 and 10.")
    return value


def parse_benchmark_run_count(value: int, flag_name: str) -> int:
    if not 1 <= value <= 10:
        raise UsageError(f"{flag_name} must be between 1 and 10.")
    return value


def run_self_test(output_dir: Path, repeat_count: int) -> dict[str, Any]:
    summary = build_base_summary(output_dir, "self-test", [], repeat_count=repeat_count)
    report = run_audio_audit(
        output_dir=output_dir,
        name="self-test",
        args=["--self-test"],
    )
    summary["reports"].append(report)
    summary["overall_pass"] = report["exit_code"] == 0
    return summary


def run_latest_analysis(output_dir: Path, modes: list[str], repeat_count: int) -> dict[str, Any]:
    summary = build_base_summary(output_dir, "latest", modes, repeat_count=repeat_count)
    for mode in modes:
        report = run_audio_audit(
            output_dir=output_dir,
            name=f"latest-{mode}",
            args=["--latest", mode],
        )
        summary["reports"].append(report)
        if report["exit_code"] == 2:
            summary["error"] = f"Missing latest output for {mode}."
            summary["overall_pass"] = False
            summary["exit_code"] = 2
            return summary
    summary["overall_pass"] = all(report["exit_code"] == 0 for report in summary["reports"])
    return summary


def run_live_xpc_analysis(
    output_dir: Path,
    modes: list[str],
    repeat_count: int,
    cold_runs: int,
    warm_runs: int,
    args: argparse.Namespace,
) -> dict[str, Any]:
    if not args.allow_model_load:
        raise UsageError("--source live-xpc requires --allow-model-load.")
    if "Clones" in modes and not args.clone_reference:
        raise UsageError("--modes including Clones requires --clone-reference for live-xpc.")
    if args.clone_reference and not Path(args.clone_reference).is_file():
        raise UsageError(f"Clone reference does not exist: {args.clone_reference}")

    models_root = Path(args.models_root).expanduser().resolve()
    validate_required_models(modes, models_root)

    summary = build_base_summary(
        output_dir,
        "live-xpc",
        modes,
        repeat_count=repeat_count,
        benchmark_profile=args.benchmark_profile,
        cold_runs=cold_runs if args.benchmark_profile in {"cold-warm", "custom-ui-cold", "exhaustive"} else None,
        warm_runs=warm_runs if args.benchmark_profile in {"cold-warm", "warm-focus", "custom-ui-cold", "exhaustive"} else None,
    )
    summary["models_root"] = str(models_root)
    if args.streaming_interval is not None:
        summary["streaming_interval_override"] = args.streaming_interval
    if args.custom_prewarm_depth is not None:
        summary["custom_prewarm_depth"] = args.custom_prewarm_depth
    xcode_result = run_live_xcode_test(output_dir, modes, repeat_count, cold_runs, warm_runs, models_root, args)
    summary["xcodebuild"] = xcode_result
    if xcode_result["exit_code"] != 0:
        summary["overall_pass"] = False
        summary["error"] = "Live XPC generation test failed."
        return summary

    manifest_path = output_dir / "generation-manifest.json"
    if not manifest_path.exists():
        summary["overall_pass"] = False
        summary["error"] = f"Live XPC generation did not write {manifest_path}."
        return summary

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    summary["generation_manifest"] = str(manifest_path)
    long_text_manifest_path = output_dir / "long-text-manifest.json"
    if long_text_manifest_path.exists():
        summary["long_text_manifest"] = str(long_text_manifest_path)
    if manifest.get("longText"):
        summary["long_text"] = manifest.get("longText")
    summary["generated_artifacts"] = manifest.get("artifacts", [])
    for artifact in manifest.get("artifacts", []):
        mode = artifact.get("mode", "unknown")
        output_path = artifact.get("outputPath")
        measured = bool(artifact.get("measured", True))
        qc_eligible = bool(artifact.get("qcEligible", measured))
        mode_summary = {
            "iteration": artifact_int(artifact, "iteration", default=1),
            "phase": artifact.get("phase", "repeat"),
            "run_index": artifact_run_index(artifact),
            "measured": measured,
            "qc_eligible": qc_eligible,
            "mode": mode,
            "duration_seconds": artifact.get("durationSeconds"),
            "wall_clock_ms": artifact.get("wallClockMS"),
            "real_time_factor": artifact.get("realTimeFactor"),
            "text_character_count": artifact.get("textCharacterCount"),
            "text_word_count": artifact.get("textWordCount"),
            "segment_count": artifact.get("segmentCount"),
            "segment_index": artifact.get("segmentIndex"),
            "batch_total": artifact.get("batchTotal"),
            "output_path": output_path,
            "stream_session_directory": artifact.get("streamSessionDirectory"),
            "streaming_used": artifact.get("streamingUsed"),
            "timings_ms": artifact.get("timingsMS") or {},
            "qwen3_timings_ms": qwen3_timing_subset(artifact.get("timingsMS") or {}),
            "qwen3_cache_flags": qwen3_cache_flag_subset(artifact.get("booleanFlags") or {}),
            "reports": [],
        }
        report_prefix = live_report_prefix(artifact, repeat_count)
        if output_path and qc_eligible:
            report = run_audio_audit(
                output_dir=output_dir,
                name=f"{report_prefix}-final",
                args=["--file", output_path],
            )
            summary["reports"].append(report)
            mode_summary["reports"].append(summarize_qc_report(report))
        session_dir = artifact.get("streamSessionDirectory")
        if session_dir and Path(session_dir).is_dir() and qc_eligible:
            ensure_session_final(session_dir, output_path)
            report = run_audio_audit(
                output_dir=output_dir,
                name=f"{report_prefix}-session",
                args=["--session-dir", session_dir],
            )
            summary["reports"].append(report)
            mode_summary["reports"].append(summarize_qc_report(report))
        summary.setdefault("mode_summaries", []).append(mode_summary)
        if mode_summary["reports"]:
            artifact["qcPassed"] = all(report.get("exit_code") == 0 for report in mode_summary["reports"])
        elif qc_eligible:
            artifact["qcPassed"] = False
        else:
            artifact["qcPassed"] = None

    attach_long_text_qc_summary(summary)

    measured_artifacts = [
        artifact
        for artifact in manifest.get("artifacts", [])
        if artifact.get("measured", True)
    ]
    if measured_artifacts:
        timing_csv = output_dir / "timing-runs.csv"
        write_timing_csv(timing_csv, measured_artifacts, summary)
        summary["timing_csv"] = str(timing_csv)
        summary["timing_summary"] = summarize_timings(measured_artifacts)

    summary["overall_pass"] = bool(summary["reports"]) and all(
        report["exit_code"] == 0 for report in summary["reports"]
    )
    return summary


def attach_long_text_qc_summary(summary: dict[str, Any]) -> None:
    long_text = summary.get("long_text")
    if not isinstance(long_text, dict):
        return

    grouped: dict[str, list[dict[str, Any]]] = {}
    for item in summary.get("mode_summaries") or []:
        if item.get("phase") != "batch-long-form":
            continue
        mode = str(item.get("mode") or "")
        grouped.setdefault(mode, []).append(item)

    batch_cases = long_text.get("batchCases") or []
    for case in batch_cases:
        mode = str(case.get("mode") or "")
        segments = sorted(
            grouped.get(mode, []),
            key=lambda item: artifact_int(item, "segment_index", default=artifact_int(item, "run_index", default=0)),
        )
        qc_failures: list[dict[str, Any]] = []
        qc_passed_segments = 0
        for segment in segments:
            reports = segment.get("reports") or []
            failed_checks = [
                failure
                for report in reports
                for failure in report.get("failed_required_checks", [])
            ]
            if failed_checks:
                qc_failures.append(
                    {
                        "segmentIndex": segment.get("segment_index"),
                        "outputPath": segment.get("output_path"),
                        "failedRequiredChecks": failed_checks,
                    }
                )
            elif segment.get("qc_eligible", True) and reports:
                qc_passed_segments += 1

        case["qcPassedSegments"] = qc_passed_segments
        case["qcFailedSegments"] = len(qc_failures)
        case["qcFailures"] = qc_failures
        case["failed"] = max(artifact_int(case, "failed", default=0), len(qc_failures))


def live_report_prefix(artifact: dict[str, Any], repeat_count: int) -> str:
    mode = artifact.get("mode", "unknown")
    phase = artifact.get("phase", "repeat")
    run_index = artifact_run_index(artifact)
    if phase != "repeat":
        return f"{phase}-run-{run_index:03d}-live-{mode}"
    iteration = artifact_int(artifact, "iteration", default=1)
    if repeat_count <= 1:
        return f"live-{mode}"
    return f"run-{iteration:03d}-live-{mode}"


def artifact_run_index(artifact: dict[str, Any]) -> int:
    value = artifact.get("runIndex")
    if value is None:
        value = artifact.get("iteration")
    return int(value if value is not None else 1)


def artifact_int(artifact: dict[str, Any], key: str, *, default: int) -> int:
    value = artifact.get(key)
    return int(value if value is not None else default)


def validate_required_models(modes: list[str], models_root: Path) -> None:
    contract = load_contract()
    by_id = {model["id"]: model for model in contract.get("models", [])}
    for mode in modes:
        model_id = MODE_MODEL_IDS[mode]
        model = by_id.get(model_id)
        if not model:
            raise UsageError(f"Contract is missing model {model_id} for {mode}.")
        model_dir = models_root / model["folder"]
        missing = [
            str(model_dir / relative)
            for relative in model.get("requiredRelativePaths", [])
            if not (model_dir / relative).exists()
        ]
        if not model_dir.is_dir() or missing:
            missing_text = "\n  - ".join(missing or [str(model_dir)])
            raise UsageError(
                f"Installed model for {mode} is incomplete under {models_root}:\n  - {missing_text}"
            )


def run_live_xcode_test(
    output_dir: Path,
    modes: list[str],
    repeat_count: int,
    cold_runs: int,
    warm_runs: int,
    models_root: Path,
    args: argparse.Namespace,
) -> dict[str, Any]:
    log_path = output_dir / "xcodebuild.log"
    result_bundle = output_dir / "GenerationQualityAuditLiveTests.xcresult"
    derived_data = output_dir / "derived-data"
    source_packages = output_dir / "source-packages"
    request_file = BUILD_ROOT / "audio-qc" / "live-request.json"
    if result_bundle.exists():
        shutil.rmtree(result_bundle)
    ensure_directory(request_file.parent)

    command = [
        "xcodebuild",
        "-project",
        str(PROJECT_DIR / "QwenVoice.xcodeproj"),
        "-scheme",
        "QwenVoice Foundation",
        "-destination",
        "platform=macOS",
        "-derivedDataPath",
        str(derived_data),
        "-clonedSourcePackagesDirPath",
        str(source_packages),
        "-resultBundlePath",
        str(result_bundle),
        "test",
        "-only-testing:QwenVoiceTests/GenerationQualityAuditLiveTests",
    ]
    environment = dict(os.environ)
    environment.update(
        {
            "QWENVOICE_AUDIO_QC_LIVE": "1",
            "QWENVOICE_AUDIO_QC_ALLOW_MODEL_LOAD": "1",
            "QWENVOICE_AUDIO_QC_OUTPUT_DIR": str(output_dir.resolve()),
            "QWENVOICE_AUDIO_QC_MODES": ",".join(modes),
            "QWENVOICE_AUDIO_QC_MODELS_ROOT": str(models_root.resolve()),
            "QWENVOICE_AUDIO_QC_REPEAT_COUNT": str(repeat_count),
            "QWENVOICE_AUDIO_QC_BENCHMARK_PROFILE": args.benchmark_profile,
            "QWENVOICE_AUDIO_QC_COLD_RUNS": str(cold_runs),
            "QWENVOICE_AUDIO_QC_WARM_RUNS": str(warm_runs),
        }
    )
    if args.streaming_interval is not None:
        environment["QWENVOICE_AUDIO_QC_STREAMING_INTERVAL"] = str(args.streaming_interval)
    if args.custom_prewarm_depth is not None:
        environment["QWENVOICE_AUDIO_QC_CUSTOM_PREWARM_DEPTH"] = args.custom_prewarm_depth
    if args.clone_reference:
        environment["QWENVOICE_AUDIO_QC_CLONE_REFERENCE"] = str(Path(args.clone_reference).resolve())
    if args.clone_transcript:
        environment["QWENVOICE_AUDIO_QC_CLONE_TRANSCRIPT"] = args.clone_transcript

    started = time.perf_counter()
    timeout_floor = 7200 if args.benchmark_profile == "exhaustive" else 1800
    expires_at = datetime.fromtimestamp(time.time() + timeout_floor, timezone.utc)
    request_payload = {
        "live": True,
        "allowModelLoad": True,
        "outputDirectory": str(output_dir.resolve()),
        "modes": modes,
        "modelsRoot": str(models_root.resolve()),
        "repeatCount": repeat_count,
        "benchmarkProfile": args.benchmark_profile,
        "coldRuns": cold_runs,
        "warmRuns": warm_runs,
        "streamingIntervalOverride": args.streaming_interval,
        "customPrewarmDepth": args.custom_prewarm_depth,
        "cloneReference": str(Path(args.clone_reference).resolve()) if args.clone_reference else None,
        "cloneTranscript": args.clone_transcript,
        "expiresAt": expires_at.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    }
    request_file.write_text(
        json.dumps(request_payload, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    try:
        with log_path.open("w", encoding="utf-8") as log_file:
            timeout_seconds = max(resolve_xcodebuild_timeout_seconds(), timeout_floor)
            proc = subprocess.Popen(
                command,
                cwd=str(PROJECT_DIR),
                env=environment,
                stdout=log_file,
                stderr=subprocess.STDOUT,
                text=True,
            )
            snapshots, timed_out = monitor_process(proc, started, timeout_seconds)
    finally:
        try:
            request_file.unlink()
        except FileNotFoundError:
            pass
    exit_code = 124 if timed_out else int(proc.returncode or 0)
    return {
        "exit_code": exit_code,
        "duration_ms": int((time.perf_counter() - started) * 1000),
        "timed_out": timed_out,
        "command": command,
        "request_file": str(request_file),
        "log_path": str(log_path),
        "result_bundle": str(result_bundle),
        "runtime_log_summary": summarize_runtime_log(log_path),
        "process_snapshots": snapshots,
        "process_memory_summary": summarize_process_memory(snapshots),
    }


WATCHED_PROCESS_TOKENS = (
    "Vocello",
    "QwenVoiceEngineService",
    "xcodebuild",
    "xctest",
    "swift-frontend",
)


def monitor_process(
    proc: subprocess.Popen[str],
    started: float,
    timeout_seconds: int,
) -> tuple[list[dict[str, Any]], bool]:
    snapshots: list[dict[str, Any]] = []
    deadline = started + timeout_seconds
    next_snapshot_at = started
    timed_out = False

    while True:
        return_code = proc.poll()
        now = time.perf_counter()
        if now >= next_snapshot_at or return_code is not None:
            snapshots.append(capture_process_snapshot(started))
            next_snapshot_at = now + 5.0
        if return_code is not None:
            break
        if now >= deadline:
            timed_out = True
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=10)
            snapshots.append(capture_process_snapshot(started))
            break
        time.sleep(0.5)

    return snapshots, timed_out


def capture_process_snapshot(started: float) -> dict[str, Any]:
    proc = subprocess.run(
        ["ps", "-axo", "pid=,rss=,comm=,command="],
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
        timeout=5,
    )
    processes: list[dict[str, Any]] = []
    if proc.returncode == 0:
        for line in proc.stdout.splitlines():
            parts = line.strip().split(None, 3)
            if len(parts) < 3:
                continue
            pid_raw, rss_raw, comm = parts[:3]
            command = parts[3] if len(parts) > 3 else comm
            label = classify_process(comm, command)
            if label is None:
                continue
            try:
                rss_kb = int(rss_raw)
                pid = int(pid_raw)
            except ValueError:
                continue
            processes.append(
                {
                    "pid": pid,
                    "label": label,
                    "rss_kb": rss_kb,
                    "rss_mb": round(rss_kb / 1024, 1),
                    "command": command[:220],
                }
            )
    return {
        "elapsed_ms": int((time.perf_counter() - started) * 1000),
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "processes": processes,
    }


def classify_process(comm: str, command: str) -> str | None:
    haystack = f"{comm} {command}"
    for token in WATCHED_PROCESS_TOKENS:
        if token in haystack:
            return token
    return None


def summarize_process_memory(snapshots: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_label: dict[str, dict[str, Any]] = {}
    for snapshot in snapshots:
        for process in snapshot.get("processes", []):
            label = process.get("label")
            if not label:
                continue
            current = by_label.setdefault(
                label,
                {
                    "label": label,
                    "max_rss_kb": 0,
                    "max_rss_mb": 0.0,
                    "sample_count": 0,
                },
            )
            current["sample_count"] += 1
            rss_kb = int(process.get("rss_kb") or 0)
            if rss_kb > current["max_rss_kb"]:
                current["max_rss_kb"] = rss_kb
                current["max_rss_mb"] = round(rss_kb / 1024, 1)
                current["pid_at_max"] = process.get("pid")
                current["elapsed_ms_at_max"] = snapshot.get("elapsed_ms")
    return sorted(by_label.values(), key=lambda item: item["label"])


def summarize_runtime_log(log_path: Path) -> dict[str, Any]:
    if not log_path.is_file():
        return {}
    patterns = {
        "connection_interrupted": ("interrupted", "XPC_ERROR_CONNECTION_INTERRUPTED"),
        "connection_invalidated": ("invalidated", "invalidation", "XPC_ERROR_CONNECTION_INVALID"),
        "reconnect": ("reconnect", "reconnecting"),
        "request_timeout": ("timed out", "timeout"),
    }
    counts = {key: 0 for key in patterns}
    matching_lines: list[str] = []
    for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        lowered = line.lower()
        matched = False
        for key, needles in patterns.items():
            if any(needle.lower() in lowered for needle in needles):
                counts[key] += 1
                matched = True
        if matched:
            matching_lines.append(line[-300:])
    return {
        "counts": counts,
        "matching_line_tail": matching_lines[-20:],
    }


def ensure_session_final(session_dir: str, output_path: str | None) -> None:
    if not output_path:
        return
    session_path = Path(session_dir)
    final_path = session_path / "final.wav"
    source = Path(output_path)
    if final_path.exists() or not source.exists():
        return
    shutil.copy2(source, final_path)


def run_audio_audit(
    *,
    output_dir: Path,
    name: str,
    args: list[str],
) -> dict[str, Any]:
    json_report = output_dir / f"{name}.json"
    markdown_report = output_dir / f"{name}.md"
    command = [
        sys.executable,
        str(PROJECT_DIR / "scripts" / "audit_generated_audio.py"),
        *args,
        "--json-out",
        str(json_report),
        "--report-out",
        str(markdown_report),
    ]
    started = time.perf_counter()
    proc = subprocess.run(
        command,
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
        timeout=180,
    )
    return {
        "name": name,
        "exit_code": proc.returncode,
        "duration_ms": int((time.perf_counter() - started) * 1000),
        "command": command,
        "json_report": str(json_report),
        "markdown_report": str(markdown_report),
        "stdout_tail": proc.stdout.splitlines()[-20:],
        "stderr_tail": proc.stderr.splitlines()[-20:],
    }


def summarize_qc_report(report: dict[str, Any]) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "name": report.get("name"),
        "exit_code": report.get("exit_code"),
        "json_report": report.get("json_report"),
        "markdown_report": report.get("markdown_report"),
    }
    report_path = Path(str(report.get("json_report", "")))
    if not report_path.is_file():
        return summary
    try:
        data = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return summary
    summary.update(
        {
            "overall_pass": data.get("overall_pass"),
            "failed_required_checks": data.get("failed_required_checks") or [],
            "warning_checks": data.get("warning_checks") or [],
            "selected_metrics": selected_qc_metrics(data.get("checks") or {}),
            "audio_issue_details": audio_issue_details(data.get("checks") or {}),
        }
    )
    return summary


def audio_issue_details(checks: dict[str, Any]) -> list[dict[str, Any]]:
    details: list[dict[str, Any]] = []
    for name, check in sorted(checks.items()):
        if not isinstance(check, dict):
            continue
        if check.get("passed") is True:
            continue
        lowered = name.lower()
        is_dropout = "dropout" in lowered
        is_silence_gap = lowered == "silence_gap_detection" or "silence_gap" in lowered
        if not is_dropout and not is_silence_gap:
            continue

        metric = check.get("metric") if isinstance(check.get("metric"), dict) else {}
        dropouts = check.get("dropouts") if isinstance(check.get("dropouts"), list) else []
        gaps = check.get("gaps") if isinstance(check.get("gaps"), list) else None
        if gaps is None:
            gaps = metric.get("gaps") if isinstance(metric.get("gaps"), list) else []

        detail: dict[str, Any] = {
            "check": name,
            "error": check.get("error") or check.get("warning"),
        }
        if dropouts:
            detail["dropouts"] = [
                {
                    "start_seconds": dropout.get("start_seconds"),
                    "duration_seconds": dropout.get("duration_seconds"),
                }
                for dropout in dropouts
                if isinstance(dropout, dict)
            ][:5]
        if gaps:
            detail["gaps"] = [
                {
                    "start_sample": gap.get("start_sample"),
                    "duration_samples": gap.get("duration_samples"),
                    "duration_seconds": gap.get("duration_seconds"),
                }
                for gap in gaps
                if isinstance(gap, dict)
            ][:5]
        if metric.get("longest_dropout_seconds") is not None:
            detail["longest_dropout_seconds"] = metric.get("longest_dropout_seconds")
        if check.get("threshold") is not None:
            detail["threshold"] = check.get("threshold")
        details.append(detail)
    return details


def selected_qc_metrics(checks: dict[str, Any]) -> dict[str, Any]:
    selected_names = (
        "final_duration",
        "final_file_container",
        "final_non_silence",
        "final_abrupt_discontinuities",
        "final_dropouts",
        "final_cutoff_ending",
        "silence_gap_detection",
        "clipping_detection",
        "chunk_sample_fidelity",
        "chunk_duration_consistency",
        "chunk_loudness_consistency",
    )
    selected: dict[str, Any] = {}
    for name in selected_names:
        check = checks.get(name)
        if not isinstance(check, dict):
            continue
        selected[name] = {
            "passed": check.get("passed"),
            "severity": check.get("severity"),
            "metric": check.get("metric"),
            "threshold": check.get("threshold"),
        }
    return selected


CORE_TIMING_KEYS = (
    "model_mirror_ms",
    "client_initialize_ms",
    "custom_ui_selected_prewarm_ms",
    "custom_ui_ready_ms",
    "custom_ui_selected_prewarm_attempts",
    "request_wall_ms",
    "cache_prepare",
    "mlx_model_load",
    "load_model",
    "conditioning_prepare",
    "interactive_prefetch_total_ms",
    "interactive_prefetch_load_model_ms",
    "interactive_prefetch_conditioning_prepare_ms",
    "generation",
    "first_audio_ready",
    "first_stream_chunk",
    "final_write",
    "chunk_write_total",
    "chunk_write_max",
    "batch_wall_ms",
    "event_dispatch_ms",
    "stream_chunk_count",
    "avg_chunk_frames",
    "max_chunk_frames",
    "streaming_interval_ms",
    "reference_normalize",
    "reference_decode",
    "clone_prompt_artifact_load",
    "clone_prompt_build",
    "clone_prompt_resolve",
    "prime_clone_reference",
)

QWEN3_TIMING_KEYS = (
    "tokenizer_load",
    "speech_tokenizer_load",
    "talker_safetensors_io",
    "talker_weight_sanitize",
    "talker_quantize_prepare",
    "talker_parameter_update",
    "talker_parameter_eval",
    "talker_core_eval",
    "talker_decoder_layers_eval",
    "talker_code_predictor_core_eval",
    "talker_code_predictor_layers_eval",
    "speech_tokenizer_eval",
    "speaker_encoder_update",
    "speaker_encoder_eval",
    "custom_prefix_prepare",
    "custom_prefix_tokenize_ms",
    "custom_prefix_embed_build_ms",
    "custom_text_prepare_ms",
    "custom_prewarm_eval_ms",
    "custom_stream_step_warm_ms",
    "custom_stream_step_eval_total_ms",
    "custom_audio_chunk_eval_total_ms",
    "design_prefix_prepare",
    "design_prefix_tokenize_ms",
    "design_prefix_embed_build_ms",
    "design_text_prepare_ms",
    "design_prewarm_eval_ms",
    "design_stream_step_warm_ms",
    "design_stream_step_eval_total_ms",
    "design_audio_chunk_eval_total_ms",
    "design_final_decode_eval_ms",
    "first_decoder_step",
    "qwen_talker_forward_total",
    "qwen_code_predictor_total",
    "qwen_stream_decoder_total",
    "qwen_stream_decoder_calls",
    "qwen_generated_code_count",
    "custom_generation_steps_before_first_chunk",
    "custom_first_chunk_decoder_tokens",
    "design_generation_steps_before_first_chunk",
    "design_first_chunk_decoder_tokens",
)

TIMING_KEYS = CORE_TIMING_KEYS + QWEN3_TIMING_KEYS

QWEN3_FLAG_KEYS = (
    "prepared_model_cache_hit",
    "prepared_overlay_cache_hit",
    "prepared_overlay_rebuilt",
    "prepared_directory_already_validated",
    "trusted_prepared_checkpoint",
    "tokenizer_cache_hit",
    "tokenizer_direct_config_load",
    "tokenizer_direct_config_fallback",
    "speech_tokenizer_cache_hit",
    "speech_tokenizer_encoder_loaded",
    "speech_tokenizer_eval_skipped",
    "prefix_cache_hit",
    "custom_prefix_cache_hit",
    "design_prefix_cache_hit",
    "decoder_bucket_cache_hit",
    "decoder_bucket_precompile_skipped",
    "custom_stream_step_prewarmed",
    "custom_prewarm_depth_full",
    "custom_prewarm_depth_skip_decoder_bucket",
    "custom_prewarm_depth_skip_stream_step",
    "design_conditioning_reused",
    "design_conditioning_prefetch_hit",
    "interactive_design_prefetch_hit",
    "design_conditioning_prewarmed",
    "design_stream_step_prewarmed",
    "design_stream_step_prefetch_hit",
    "design_warm_bucket_short",
    "design_warm_bucket_long",
    "prepared_clone_cache_hit",
    "clone_prompt_cache_hit",
    "clone_prompt_used",
    "clone_conditioning_reused",
    "reused_normalized_reference",
    "reused_decoded_reference",
)


def qwen3_timing_subset(timings: dict[str, Any]) -> dict[str, Any]:
    return {
        key: timings[key]
        for key in QWEN3_TIMING_KEYS
        if key in timings
    }


def qwen3_cache_flag_subset(flags: dict[str, Any]) -> dict[str, Any]:
    return {
        key: value
        for key, value in sorted(flags.items())
        if key.startswith(("tokenizer_", "speech_tokenizer_", "prefix_", "custom_", "design_", "decoder_bucket_", "clone_"))
        or key in {
            "prepared_model_cache_hit",
            "prepared_overlay_cache_hit",
            "prepared_overlay_rebuilt",
            "prepared_directory_already_validated",
            "prepared_clone_cache_hit",
            "reused_normalized_reference",
            "reused_decoded_reference",
            "trusted_prepared_checkpoint",
        }
    }


def write_timing_csv(path: Path, artifacts: list[dict[str, Any]], summary: dict[str, Any] | None = None) -> None:
    runtime_counts = (((summary or {}).get("xcodebuild") or {}).get("runtime_log_summary") or {}).get("counts") or {}
    peak_rss_mb = peak_process_rss_mb((summary or {}).get("xcodebuild") or {})
    fieldnames = [
        "mode",
        "phase",
        "run_index",
        "iteration",
        "text_character_count",
        "text_word_count",
        "segment_count",
        "segment_index",
        "batch_total",
        "wall_clock_ms",
        "duration_seconds",
        "real_time_factor",
        "first_audio_ready",
        "streaming_used",
        "stream_chunk_count",
        "chunk_write_total",
        "chunk_write_max",
        "final_write",
        "rss_peak_mb",
        "xpc_interruption_count",
        "timeout_count",
        "qc_passed",
        "model_id",
        "output_path",
        "stream_session_directory",
        *[f"timing_{key}" for key in TIMING_KEYS],
        *[f"flag_{key}" for key in QWEN3_FLAG_KEYS],
    ]
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for artifact in artifacts:
            timings = artifact.get("timingsMS") or {}
            row = {
                "mode": artifact.get("mode"),
                "phase": artifact.get("phase", "repeat"),
                "run_index": artifact.get("runIndex") or artifact.get("iteration"),
                "iteration": artifact.get("iteration"),
                "text_character_count": artifact.get("textCharacterCount"),
                "text_word_count": artifact.get("textWordCount"),
                "segment_count": artifact.get("segmentCount"),
                "segment_index": artifact.get("segmentIndex"),
                "batch_total": artifact.get("batchTotal"),
                "wall_clock_ms": artifact.get("wallClockMS"),
                "duration_seconds": artifact.get("durationSeconds"),
                "real_time_factor": artifact.get("realTimeFactor"),
                "first_audio_ready": timings.get("first_audio_ready"),
                "streaming_used": artifact.get("streamingUsed"),
                "stream_chunk_count": timings.get("stream_chunk_count"),
                "chunk_write_total": timings.get("chunk_write_total"),
                "chunk_write_max": timings.get("chunk_write_max"),
                "final_write": timings.get("final_write"),
                "rss_peak_mb": peak_rss_mb,
                "xpc_interruption_count": runtime_counts.get("connection_interrupted", 0),
                "timeout_count": runtime_counts.get("request_timeout", 0),
                "qc_passed": artifact.get("qcPassed"),
                "model_id": artifact.get("modelID"),
                "output_path": artifact.get("outputPath"),
                "stream_session_directory": artifact.get("streamSessionDirectory"),
            }
            for key in TIMING_KEYS:
                row[f"timing_{key}"] = timings.get(key)
            flags = artifact.get("booleanFlags") or {}
            for key in QWEN3_FLAG_KEYS:
                row[f"flag_{key}"] = flags.get(key)
            writer.writerow(row)


def peak_process_rss_mb(xcode_summary: dict[str, Any]) -> float | None:
    values = [
        numeric(item.get("max_rss_mb"))
        for item in xcode_summary.get("process_memory_summary") or []
    ]
    values = [value for value in values if value is not None]
    return max(values) if values else None


def summarize_timings(artifacts: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for artifact in artifacts:
        mode = str(artifact.get("mode") or "unknown")
        phase = str(artifact.get("phase") or "repeat")
        grouped.setdefault((mode, phase), []).append(artifact)

    summaries: list[dict[str, Any]] = []
    for (mode, phase), items in sorted(grouped.items(), key=lambda pair: (pair[0][0], pair[0][1])):
        timings_by_key: dict[str, list[float]] = {}
        flags_by_key: dict[str, list[bool]] = {}
        for item in items:
            timings = item.get("timingsMS") or {}
            for key in TIMING_KEYS:
                value = numeric(timings.get(key))
                if value is not None:
                    timings_by_key.setdefault(key, []).append(value)
            flags = item.get("booleanFlags") or {}
            for key in QWEN3_FLAG_KEYS:
                value = flags.get(key)
                if isinstance(value, bool):
                    flags_by_key.setdefault(key, []).append(value)

        summaries.append(
            {
                "mode": mode,
                "phase": phase,
                "sample_count": len(items),
                "wall_clock_ms": describe_values(
                    [value for item in items if (value := numeric(item.get("wallClockMS"))) is not None]
                ),
                "duration_seconds": describe_values(
                    [value for item in items if (value := numeric(item.get("durationSeconds"))) is not None]
                ),
                "real_time_factor": describe_values(
                    [value for item in items if (value := numeric(item.get("realTimeFactor"))) is not None]
                ),
                "timings_ms": {
                    key: describe_values(values)
                    for key, values in sorted(timings_by_key.items())
                },
                "flags": {
                    key: {
                        "true": sum(1 for value in values if value),
                        "false": sum(1 for value in values if not value),
                    }
                    for key, values in sorted(flags_by_key.items())
                },
            }
        )
    return summaries


def compare_timing_summaries(
    *,
    current_summary: dict[str, Any],
    baseline_path: Path,
) -> list[dict[str, Any]]:
    if not baseline_path.is_file():
        raise UsageError(f"Comparison baseline does not exist: {baseline_path}")
    try:
        baseline_summary = json.loads(baseline_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise UsageError(f"Could not read comparison baseline {baseline_path}: {exc}") from exc

    baseline_by_key = {
        (str(item.get("mode")), str(item.get("phase"))): item
        for item in baseline_summary.get("timing_summary") or []
    }
    current_by_key = {
        (str(item.get("mode")), str(item.get("phase"))): item
        for item in current_summary.get("timing_summary") or []
    }

    comparisons: list[dict[str, Any]] = []
    metric_specs = [
        ("wall_clock_ms", ("wall_clock_ms",)),
        ("real_time_factor", ("real_time_factor",)),
        ("generation_ms", ("timings_ms", "generation")),
        ("first_audio_ready_ms", ("timings_ms", "first_audio_ready")),
        ("first_stream_chunk_ms", ("timings_ms", "first_stream_chunk")),
    ]
    for key in sorted(current_by_key):
        current = current_by_key[key]
        baseline = baseline_by_key.get(key)
        if not baseline:
            continue
        metrics: dict[str, Any] = {}
        for metric_name, path in metric_specs:
            before = nested_median(baseline, path)
            after = nested_median(current, path)
            metrics[metric_name] = compare_metric(before, after)
        comparisons.append(
            {
                "mode": key[0],
                "phase": key[1],
                "baseline_sample_count": baseline.get("sample_count"),
                "current_sample_count": current.get("sample_count"),
                "metrics": metrics,
            }
        )
    return comparisons


def nested_median(item: dict[str, Any], path: tuple[str, ...]) -> float | None:
    cursor: Any = item
    for key in path:
        if not isinstance(cursor, dict):
            return None
        cursor = cursor.get(key)
    if not isinstance(cursor, dict):
        return None
    return numeric(cursor.get("median"))


def compare_metric(before: float | None, after: float | None) -> dict[str, Any]:
    result: dict[str, Any] = {
        "baseline_median": before,
        "current_median": after,
    }
    if before is None or after is None or before == 0:
        return result
    delta = after - before
    result["delta"] = round(delta, 3)
    result["delta_percent"] = round((delta / before) * 100.0, 2)
    return result


def numeric(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def describe_values(values: list[float]) -> dict[str, Any]:
    if not values:
        return {}
    sorted_values = sorted(values)
    return {
        "count": len(values),
        "min": round(sorted_values[0], 3),
        "median": round(statistics.median(sorted_values), 3),
        "mean": round(statistics.fmean(sorted_values), 3),
        "max": round(sorted_values[-1], 3),
        "stdev": round(statistics.stdev(sorted_values), 3) if len(sorted_values) > 1 else 0.0,
    }


def build_base_summary(
    output_dir: Path,
    source: str,
    modes: list[str],
    *,
    repeat_count: int,
    benchmark_profile: str = "repeat",
    cold_runs: int | None = None,
    warm_runs: int | None = None,
) -> dict[str, Any]:
    return {
        "tool": "run_generation_quality_audit",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "source": source,
        "modes": modes,
        "repeat_count": repeat_count,
        "benchmark_profile": benchmark_profile,
        "cold_runs": cold_runs,
        "warm_runs": warm_runs,
        "output_dir": str(output_dir),
        "overall_pass": False,
        "reports": [],
        "mode_summaries": [],
    }


def write_summary(output_dir: Path, summary: dict[str, Any]) -> None:
    ensure_directory(output_dir)
    (output_dir / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    (output_dir / "summary.md").write_text(render_summary_markdown(summary), encoding="utf-8")


def render_summary_markdown(summary: dict[str, Any]) -> str:
    status = "PASS" if summary.get("overall_pass") else "FAIL"
    lines = [
        f"# Generation Audio Quality Audit: {status}",
        "",
        f"- Source: `{summary.get('source')}`",
        f"- Modes: `{', '.join(summary.get('modes') or [])}`",
        f"- Repeat count: `{summary.get('repeat_count', 1)}`",
        f"- Benchmark profile: `{summary.get('benchmark_profile', 'repeat')}`",
        f"- Output: `{summary.get('output_dir')}`",
        f"- Created: `{summary.get('created_at')}`",
        "",
    ]
    benchmark_profile = summary.get("benchmark_profile")
    if benchmark_profile in {"cold-warm", "warm-focus", "custom-ui-cold", "exhaustive"}:
        benchmark_lines = []
        if benchmark_profile in {"cold-warm", "custom-ui-cold", "exhaustive"}:
            benchmark_lines.append(f"- Cold runs per mode: `{summary.get('cold_runs')}`")
        benchmark_lines.append(f"- Warm runs per mode: `{summary.get('warm_runs')}`")
        if benchmark_profile == "custom-ui-cold":
            benchmark_lines.append("- Selected-mode prewarm: `Custom Voice interactive readiness before measured generate`")
        if summary.get("custom_prewarm_depth"):
            benchmark_lines.append(f"- Custom Voice prewarm depth: `{summary.get('custom_prewarm_depth')}`")
        if benchmark_profile == "exhaustive":
            benchmark_lines.append("- Endurance warm samples per mode: `10`")
            benchmark_lines.append("- Direct long-text samples: `900` and `2700` characters per mode")
            benchmark_lines.append("- Product long-form batch sample: `9000` characters per mode")
        benchmark_lines.append("")
        lines.extend(
            benchmark_lines
        )
    if summary.get("error"):
        lines.extend(["## Error", "", str(summary["error"]), ""])
    if summary.get("xcodebuild"):
        xcode = summary["xcodebuild"]
        lines.extend(
            [
                "## Live Generation",
                "",
                f"- Exit code: `{xcode.get('exit_code')}`",
                f"- Duration: `{xcode.get('duration_ms')} ms`",
                f"- Log: `{xcode.get('log_path')}`",
                f"- Result bundle: `{xcode.get('result_bundle')}`",
                "",
            ]
        )
        if xcode.get("process_memory_summary"):
            lines.extend(["### Process Memory", ""])
            for item in xcode["process_memory_summary"]:
                lines.append(
                    f"- `{item.get('label')}` max RSS: `{item.get('max_rss_mb')} MB` "
                    f"at `{item.get('elapsed_ms_at_max')} ms`"
                )
            lines.append("")
        if xcode.get("runtime_log_summary"):
            counts = xcode["runtime_log_summary"].get("counts") or {}
            lines.extend(
                [
                    "### Runtime Log Signals",
                    "",
                    f"- XPC interruptions: `{counts.get('connection_interrupted', 0)}`",
                    f"- XPC invalidations: `{counts.get('connection_invalidated', 0)}`",
                    f"- Reconnect mentions: `{counts.get('reconnect', 0)}`",
                    f"- Request timeouts: `{counts.get('request_timeout', 0)}`",
                    "",
                ]
            )
    if summary.get("generated_artifacts"):
        lines.extend(["## Generated Artifacts", ""])
        for artifact in summary["generated_artifacts"]:
            phase = artifact.get("phase", "repeat")
            run_index = artifact.get("runIndex", artifact.get("iteration", 1))
            measured = "measured" if artifact.get("measured", True) else "primer"
            lines.append(
                f"- `{phase}` run `{run_index}` `{artifact.get('mode')}` ({measured}): "
                f"`{artifact.get('outputPath')}` ({artifact.get('durationSeconds')}s, "
                f"{artifact.get('wallClockMS')} ms)"
            )
        lines.append("")
    if summary.get("timing_summary"):
        lines.extend(["## Timing Summary", ""])
        for item in summary["timing_summary"]:
            wall = item.get("wall_clock_ms") or {}
            rtf = item.get("real_time_factor") or {}
            generation = (item.get("timings_ms") or {}).get("generation") or {}
            timings = item.get("timings_ms") or {}
            lines.append(
                f"- `{item.get('mode')}` `{item.get('phase')}` n=`{item.get('sample_count')}`: "
                f"wall median `{wall.get('median')} ms`, mean `{wall.get('mean')} ms`, "
                f"RTF median `{rtf.get('median')}`, generation median `{generation.get('median')} ms`"
            )
            setup_highlights = []
            for label, key in (
                ("mirror", "model_mirror_ms"),
                ("client init", "client_initialize_ms"),
                ("selected prewarm", "custom_ui_selected_prewarm_ms"),
                ("prefetch total", "interactive_prefetch_total_ms"),
                ("prefetch load", "interactive_prefetch_load_model_ms"),
                ("cache prepare", "cache_prepare"),
                ("MLX load", "mlx_model_load"),
                ("load model", "load_model"),
            ):
                metric = timings.get(key) or {}
                if metric.get("median") is not None:
                    setup_highlights.append(f"{label} `{metric.get('median')} ms`")
            if setup_highlights:
                lines.append(f"  - Setup/cache: {', '.join(setup_highlights)}")
            qwen_highlights = []
            for label, key in (
                ("tokenizer", "tokenizer_load"),
                ("speech tokenizer", "speech_tokenizer_load"),
                ("custom prewarm", "custom_prewarm_eval_ms"),
                ("stream-step warm", "custom_stream_step_warm_ms"),
                ("custom step eval", "custom_stream_step_eval_total_ms"),
                ("custom chunk eval", "custom_audio_chunk_eval_total_ms"),
                ("first decoder", "first_decoder_step"),
                ("stream decode", "qwen_stream_decoder_total"),
                ("generated codes", "qwen_generated_code_count"),
                ("first chunk steps", "custom_generation_steps_before_first_chunk"),
            ):
                metric = timings.get(key) or {}
                if metric.get("median") is not None:
                    suffix = "" if key in ("qwen_generated_code_count", "custom_generation_steps_before_first_chunk") else " ms"
                    qwen_highlights.append(f"{label} `{metric.get('median')}{suffix}`")
            if qwen_highlights:
                lines.append(f"  - Qwen3: {', '.join(qwen_highlights)}")
            flag_highlights = []
            for label, key in (
                ("prepared overlay hit", "prepared_overlay_cache_hit"),
                ("prepared overlay rebuilt", "prepared_overlay_rebuilt"),
                ("validated prepared dir", "prepared_directory_already_validated"),
                ("trusted prepared checkpoint", "trusted_prepared_checkpoint"),
                ("tokenizer hit", "tokenizer_cache_hit"),
                ("speech tokenizer hit", "speech_tokenizer_cache_hit"),
                ("prefix hit", "custom_prefix_cache_hit"),
                ("decoder bucket hit", "decoder_bucket_cache_hit"),
                ("stream-step prewarmed", "custom_stream_step_prewarmed"),
            ):
                counts = (item.get("flags") or {}).get(key) or {}
                total = (counts.get("true") or 0) + (counts.get("false") or 0)
                if total:
                    flag_highlights.append(f"{label} `{counts.get('true', 0)}/{total}`")
            if flag_highlights:
                lines.append(f"  - Cache flags: {', '.join(flag_highlights)}")
        if summary.get("timing_csv"):
            lines.append(f"- CSV: `{summary.get('timing_csv')}`")
        lines.append("")
    if summary.get("long_text"):
        long_text = summary["long_text"]
        lines.extend(["## Long Text", ""])
        lines.append(f"- Manifest: `{summary.get('long_text_manifest')}`")
        lines.append(f"- Segment max characters: `{long_text.get('segmentMaxCharacters')}`")
        bounded = long_text.get("boundedFailures") or []
        lines.append(f"- Bounded direct failures: `{len(bounded)}`")
        if bounded:
            for failure in bounded:
                lines.append(
                    f"  - `{failure.get('phase')}` `{failure.get('mode')}` "
                    f"{failure.get('characterCount')} chars: `{failure.get('error')}`"
                )
        batch_cases = long_text.get("batchCases") or []
        if batch_cases:
            lines.append("")
            lines.append("### Product Batch")
            for item in batch_cases:
                lines.append(
                    f"- `{item.get('mode')}` chars `{item.get('characterCount')}`, "
                    f"segments `{item.get('segmentCount')}`, generated `{item.get('generated')}`, "
                    f"failed `{item.get('failed')}`, QC passed `{item.get('qcPassedSegments')}`, "
                    f"QC failed `{item.get('qcFailedSegments')}`, "
                    f"audio `{round(float(item.get('totalAudioDurationSeconds') or 0), 3)}s`"
                )
                for failure in item.get("qcFailures") or []:
                    lines.append(
                        f"  - Segment `{failure.get('segmentIndex')}` failed "
                        f"`{', '.join(failure.get('failedRequiredChecks') or [])}`"
                    )
        lines.append("")
    if summary.get("timing_comparison"):
        lines.extend(["## Timing Comparison", ""])
        if summary.get("comparison_baseline"):
            lines.append(f"- Baseline: `{summary.get('comparison_baseline')}`")
            lines.append("")
        for item in summary["timing_comparison"]:
            metrics = item.get("metrics") or {}
            wall = metrics.get("wall_clock_ms") or {}
            first_audio = metrics.get("first_audio_ready_ms") or {}
            generation = metrics.get("generation_ms") or {}
            lines.append(
                f"- `{item.get('mode')}` `{item.get('phase')}`: "
                f"wall `{wall.get('baseline_median')}` -> `{wall.get('current_median')}` ms "
                f"({format_delta_percent(wall)}), "
                f"first audio `{first_audio.get('baseline_median')}` -> `{first_audio.get('current_median')}` ms "
                f"({format_delta_percent(first_audio)}), "
                f"generation `{generation.get('baseline_median')}` -> `{generation.get('current_median')}` ms "
                f"({format_delta_percent(generation)})"
            )
        lines.append("")
    if summary.get("mode_summaries"):
        lines.extend(["## Per-Mode Results", ""])
        for item in summary["mode_summaries"]:
            failed = [
                failure
                for report in item.get("reports", [])
                for failure in report.get("failed_required_checks", [])
            ]
            if not item.get("qc_eligible", True):
                result = "SKIP"
            else:
                result = "PASS" if not failed and item.get("reports") else "FAIL"
            lines.append(
                f"- {result} `{item.get('phase')}` run `{item.get('run_index')}` `{item.get('mode')}` "
                f"wall `{item.get('wall_clock_ms')} ms`, duration `{item.get('duration_seconds')}s`, "
                f"reports `{len(item.get('reports', []))}`"
            )
            if failed:
                lines.append(f"  Failed checks: `{', '.join(failed)}`")
                for report in item.get("reports", []):
                    for detail in report.get("audio_issue_details") or []:
                        lines.append(f"  - {format_audio_issue_detail(report, detail)}")
        lines.append("")
    lines.extend(["## QC Reports", ""])
    if not summary.get("reports"):
        lines.append("- No reports were produced.")
    for report in summary.get("reports", []):
        report_status = "PASS" if report.get("exit_code") == 0 else "FAIL"
        lines.append(
            f"- {report_status} `{report.get('name')}`: "
            f"[markdown]({report.get('markdown_report')}) "
            f"[json]({report.get('json_report')})"
        )
    lines.append("")
    return "\n".join(lines)


def format_audio_issue_detail(report: dict[str, Any], detail: dict[str, Any]) -> str:
    check_name = detail.get("check") or "audio issue"
    source_name = report.get("name") or "report"
    pieces = [f"`{source_name}` `{check_name}`"]
    error = detail.get("error")
    if error:
        pieces.append(str(error))

    dropouts = detail.get("dropouts") or []
    if dropouts:
        formatted = []
        for dropout in dropouts[:3]:
            start = numeric(dropout.get("start_seconds"))
            duration = numeric(dropout.get("duration_seconds"))
            if start is None or duration is None:
                continue
            formatted.append(f"start {start:.3f}s for {duration:.3f}s")
        if formatted:
            pieces.append("; ".join(formatted))

    gaps = detail.get("gaps") or []
    if gaps:
        formatted = []
        for gap in gaps[:3]:
            start_sample = gap.get("start_sample")
            duration_samples = gap.get("duration_samples")
            duration_seconds = numeric(gap.get("duration_seconds"))
            if duration_seconds is not None:
                formatted.append(
                    f"sample {start_sample} for {duration_samples} samples ({duration_seconds:.3f}s)"
                )
            else:
                formatted.append(f"sample {start_sample} for {duration_samples} samples")
        if formatted:
            pieces.append("; ".join(formatted))

    return " - ".join(pieces)


def format_delta_percent(metric: dict[str, Any]) -> str:
    value = metric.get("delta_percent")
    if value is None:
        return "n/a"
    prefix = "+" if value > 0 else ""
    return f"{prefix}{value}%"


if __name__ == "__main__":
    main()
