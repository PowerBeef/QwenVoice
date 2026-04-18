"""Bench subcommand — benchmarking categories for the QwenVoice harness."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Any

from .contract import load_contract, model_ids, model_is_installed
from .output import build_suite_result, build_test_result, eprint
from .paths import APP_MODELS_DIR, PROJECT_DIR, resolve_backend_python, ensure_directory
from .stats import summarize_numeric

LATENCY_CLONE_REFERENCE_PATH = PROJECT_DIR / "tests" / "fixtures" / "release_clone_reference.wav"
LATENCY_CLONE_REFERENCE_TEXT_PATH = PROJECT_DIR / "tests" / "fixtures" / "release_clone_reference.txt"
LATENCY_STREAMING_INTERVAL = 0.32


def run_benchmarks(
    category: str = "all",
    runs: int = 3,
    python_path: str | None = None,
    output_dir: str | None = None,
    tier: str = "all",
    legacy_app_bundle: str | None = None,
    legacy_dmg: str | None = None,
    current_app_bundle: str | None = None,
    current_dmg: str | None = None,
) -> list[dict[str, Any]]:
    """Run selected benchmark categories."""
    suites: list[dict[str, Any]] = []

    if category in ("all", "latency"):
        eprint("==> Running generation latency benchmarks...")
        suites.append(_run_latency_bench(runs, python_path, output_dir))

    if category in ("all", "load"):
        eprint("==> Running model load benchmarks...")
        suites.append(_run_load_bench(python_path))

    if category in ("all", "quality"):
        eprint("==> Running clone quality benchmarks...")
        suites.append(_run_quality_bench(python_path, output_dir))

    if category in ("all", "release"):
        eprint("==> Running release bundle validation...")
        suites.append(_run_release_bench())

    if category == "clone_regression":
        eprint("==> Running serialized clone helper regression isolation...")
        from .clone_regression_runner import run_clone_regression_bench

        suites.append(
            run_clone_regression_bench(
                python_path=python_path,
                output_dir=output_dir,
            )
        )

    if category == "clone_packaged_regression":
        eprint("==> Packaged clone regression isolation is retired...")
        suites.append(
            build_suite_result(
                "clone_packaged_regression",
                [
                    build_test_result(
                        "clone_packaged_regression_retired",
                        passed=True,
                        skip_reason="Packaged clone regression automation depended on the retired localhost UI control plane.",
                        details={
                            "legacy_app_bundle": legacy_app_bundle,
                            "legacy_dmg": legacy_dmg,
                            "current_app_bundle": current_app_bundle,
                            "current_dmg": current_dmg,
                        },
                    )
                ],
                0,
            )
        )

    if category == "tts_roundtrip":
        eprint("==> Running TTS round-trip intelligibility benchmark...")
        from .tts_roundtrip_runner import run_tts_roundtrip_bench

        suites.append(
            run_tts_roundtrip_bench(
                python_path=python_path,
                output_dir=output_dir,
            )
        )

    if category == "perf":
        eprint("==> Running exhaustive performance profiler...")
        suites.extend(_run_perf_benchmarks(
            python_path=python_path,
            output_dir=output_dir,
            tier=tier,
            runs=runs,
        ))

    return suites


# ---------------------------------------------------------------------------
# Generation latency
# ---------------------------------------------------------------------------

def _run_latency_bench(
    runs: int,
    python_path: str | None,
    output_dir: str | None,
) -> dict[str, Any]:
    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    try:
        resolved_python = resolve_backend_python(python_path)
    except RuntimeError as exc:
        results.append(build_test_result(
            "python_available", passed=False, skip_reason=str(exc),
        ))
        return build_suite_result("generation_latency", results, 0)

    installed = [mid for mid in model_ids() if model_is_installed(mid)]
    if not installed:
        results.append(build_test_result(
            "models_available", passed=True,
            skip_reason="No models installed — skipping latency bench",
        ))
        return build_suite_result("generation_latency", results, 0)

    from .backend_client import BackendClient

    # Set up output directory
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    bench_dir = Path(output_dir) if output_dir else PROJECT_DIR / "build" / "benchmarks" / timestamp
    ensure_directory(bench_dir)

    client = BackendClient(resolved_python)
    try:
        client.start()
        client.call("init", timeout=30)

        contract = load_contract()
        clone_reference_path = (
            str(LATENCY_CLONE_REFERENCE_PATH)
            if LATENCY_CLONE_REFERENCE_PATH.exists()
            else None
        )
        clone_reference_text = (
            LATENCY_CLONE_REFERENCE_TEXT_PATH.read_text(encoding="utf-8").strip()
            if LATENCY_CLONE_REFERENCE_TEXT_PATH.exists()
            else None
        )

        for mid in installed:
            model_def = next((m for m in contract["models"] if m["id"] == mid), None)
            if not model_def:
                continue
            mode = model_def["mode"]
            if mode == "clone" and not clone_reference_path:
                for scenario in ("cold", "warm", "prewarmed"):
                    results.append(build_test_result(
                        f"latency_{mid}_{scenario}",
                        passed=True,
                        skip_reason="Committed clone reference fixture is unavailable",
                    ))
                continue

            for scenario in ("cold", "warm", "prewarmed"):
                run_records: list[dict[str, Any]] = []
                scenario_prewarm_timings: list[dict[str, Any]] = []
                try:
                    try:
                        _ = client.call("unload_model", timeout=30)
                    except Exception:
                        pass

                    scenario_load_result = None
                    scenario_prewarm_result = None
                    if scenario in ("warm", "prewarmed"):
                        scenario_load_result = client.call(
                            "load_model",
                            {"model_id": mid, "benchmark": True},
                            timeout=120,
                        )

                        if scenario == "prewarmed":
                            prewarm_params: dict[str, Any] = {
                                "model_id": mid,
                                "mode": mode,
                                "benchmark": True,
                            }
                            if mode == "custom":
                                prewarm_params["voice"] = "vivian"
                                prewarm_params["instruct"] = "Normal tone"
                            elif mode == "clone":
                                prewarm_params["ref_audio"] = clone_reference_path
                                if clone_reference_text:
                                    prewarm_params["ref_text"] = clone_reference_text
                            scenario_prewarm_result = client.call(
                                "prewarm_model",
                                prewarm_params,
                                timeout=120,
                            )
                            scenario_prewarm_timings.append(
                                dict(
                                    scenario_prewarm_result.get("benchmark", {}).get(
                                        "timings_ms", {}
                                    )
                                )
                            )

                    for i in range(runs):
                        eprint(f"  {mid} {scenario} run {i + 1}/{runs}...")

                        load_result = None
                        prewarm_result = None
                        if scenario == "cold":
                            try:
                                _ = client.call("unload_model", timeout=30)
                            except Exception:
                                pass
                            load_result = client.call(
                                "load_model",
                                {"model_id": mid, "benchmark": True},
                                timeout=120,
                            )
                        elif i == 0:
                            load_result = scenario_load_result
                            prewarm_result = scenario_prewarm_result

                        with tempfile.TemporaryDirectory() as tmp:
                            output_path = os.path.join(tmp, f"{scenario}_{i}.wav")
                            params = _latency_generate_params(
                                mode=mode,
                                output_path=output_path,
                                clone_reference_path=clone_reference_path,
                                clone_reference_text=clone_reference_text,
                            )
                            params["benchmark"] = True
                            params["benchmark_label"] = f"latency_{mid}_{scenario}_run{i + 1}"

                            try:
                                result, notifications = client.call_collecting_notifications_timed(
                                    "generate",
                                    params,
                                    timeout=300,
                                )
                            except Exception as exc:
                                results.append(
                                    build_test_result(
                                        f"latency_{mid}_{scenario}_run{i + 1}",
                                        passed=False,
                                        error=str(exc),
                                    )
                                )
                                break

                            run_records.append(
                                _latency_run_record(
                                    scenario=scenario,
                                    run_index=i + 1,
                                    result=result,
                                    notifications=notifications,
                                    load_result=load_result,
                                    prewarm_result=prewarm_result,
                                )
                            )
                    else:
                        summary = _latency_summary(run_records, scenario_prewarm_timings)
                        results.append(
                            build_test_result(
                                f"latency_{mid}_{scenario}",
                                passed=True,
                                details=summary,
                            )
                        )
                        samples_path = bench_dir / f"{mid}_{scenario}_samples.json"
                        samples_path.write_text(
                            json.dumps(summary, indent=2), encoding="utf-8"
                        )
                finally:
                    try:
                        _ = client.call("unload_model", timeout=30)
                    except Exception:
                        pass

            client.call("unload_model", timeout=30)

    except Exception as exc:
        results.append(build_test_result(
            "latency_bench_error", passed=False, error=str(exc),
        ))
    finally:
        client.stop()

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("generation_latency", results, duration_ms)


def _latency_generate_params(
    *,
    mode: str,
    output_path: str,
    clone_reference_path: str | None,
    clone_reference_text: str | None,
) -> dict[str, Any]:
    params: dict[str, Any] = {
        "text": "The package is ready at the front desk for pickup.",
        "output_path": output_path,
        "stream": True,
        "streaming_interval": LATENCY_STREAMING_INTERVAL,
    }
    if mode == "custom":
        params["voice"] = "vivian"
        params["instruct"] = "Normal tone"
    elif mode == "design":
        params["instruct"] = "A young female speaker with a clear voice"
    elif mode == "clone":
        if clone_reference_path is None:
            raise RuntimeError("Clone latency params require a committed reference fixture")
        params["ref_audio"] = clone_reference_path
        if clone_reference_text:
            params["ref_text"] = clone_reference_text
    return params


def _latency_first_chunk_ms(notifications: list[dict[str, Any]]) -> float | None:
    for notification in notifications:
        if notification.get("method") == "generation_chunk":
            received_at_ms = notification.get("_received_at_ms")
            if isinstance(received_at_ms, (int, float)):
                return round(float(received_at_ms), 2)
    return None


def _latency_run_record(
    *,
    scenario: str,
    run_index: int,
    result: dict[str, Any],
    notifications: list[dict[str, Any]],
    load_result: dict[str, Any] | None,
    prewarm_result: dict[str, Any] | None,
) -> dict[str, Any]:
    return {
        "scenario": scenario,
        "run_index": run_index,
        "wall_ms": float(result.get("_wall_ms", 0.0) or 0.0),
        "first_chunk_ms": _latency_first_chunk_ms(notifications),
        "notification_count": len(notifications),
        "load_model_total_ms": (
            load_result.get("benchmark", {}).get("timings_ms", {}).get("load_model_total")
            if load_result is not None
            else None
        ),
        "prewarm_timings_ms": (
            dict(prewarm_result.get("benchmark", {}).get("timings_ms", {}))
            if prewarm_result is not None
            else None
        ),
        "server_timings_ms": dict(result.get("benchmark", {}).get("timings_ms", {})),
    }


def _latency_summary(
    run_records: list[dict[str, Any]],
    prewarm_timings: list[dict[str, Any]],
) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "scenario": run_records[0]["scenario"] if run_records else "unknown",
        "run_count": len(run_records),
        "raw_records": run_records,
    }
    wall_times = [float(record["wall_ms"]) for record in run_records]
    if wall_times:
        summary["wall_ms"] = summarize_numeric(wall_times)

    first_chunks = [
        float(record["first_chunk_ms"])
        for record in run_records
        if isinstance(record.get("first_chunk_ms"), (int, float))
    ]
    if first_chunks:
        summary["first_chunk_ms"] = summarize_numeric(first_chunks)

    load_totals = [
        float(record["load_model_total_ms"])
        for record in run_records
        if isinstance(record.get("load_model_total_ms"), (int, float))
    ]
    if load_totals:
        summary["load_model_total_ms"] = summarize_numeric(load_totals)

    server_timing_keys = {
        key
        for record in run_records
        for key in record.get("server_timings_ms", {}).keys()
    }
    for key in sorted(server_timing_keys):
        values = [
            float(record["server_timings_ms"][key])
            for record in run_records
            if isinstance(record.get("server_timings_ms", {}).get(key), (int, float))
        ]
        if values:
            summary[f"server_{key}_ms"] = summarize_numeric(values)

    if prewarm_timings:
        prewarm_timing_keys = {key for timing in prewarm_timings for key in timing.keys()}
        for key in sorted(prewarm_timing_keys):
            values = [
                float(timing[key])
                for timing in prewarm_timings
                if isinstance(timing.get(key), (int, float))
            ]
            if values:
                summary[f"prewarm_{key}_ms"] = summarize_numeric(values)

    return summary


# ---------------------------------------------------------------------------
# Model load time
# ---------------------------------------------------------------------------

def _run_load_bench(python_path: str | None) -> dict[str, Any]:
    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    try:
        resolved_python = resolve_backend_python(python_path)
    except RuntimeError as exc:
        results.append(build_test_result(
            "python_available", passed=False, skip_reason=str(exc),
        ))
        return build_suite_result("model_load_time", results, 0)

    installed = [mid for mid in model_ids() if model_is_installed(mid)]
    if not installed:
        results.append(build_test_result(
            "models_available", passed=True,
            skip_reason="No models installed — skipping load bench",
        ))
        return build_suite_result("model_load_time", results, 0)

    from .backend_client import BackendClient

    client = BackendClient(resolved_python)
    try:
        client.start()
        client.call("init", timeout=30)

        for mid in installed:
            eprint(f"  Cold-loading {mid}...")
            t0 = time.perf_counter()
            try:
                client.call("load_model", {"model_id": mid}, timeout=120)
                load_ms = (time.perf_counter() - t0) * 1000
                results.append(build_test_result(
                    f"cold_load_{mid}",
                    passed=True,
                    details={"load_ms": round(load_ms, 1)},
                ))
            except Exception as exc:
                results.append(build_test_result(
                    f"cold_load_{mid}", passed=False, error=str(exc),
                ))

            try:
                client.call("unload_model", timeout=30)
            except Exception:
                pass

    except Exception as exc:
        results.append(build_test_result(
            "load_bench_error", passed=False, error=str(exc),
        ))
    finally:
        client.stop()

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("model_load_time", results, duration_ms)


# ---------------------------------------------------------------------------
# Clone quality (acoustic)
# ---------------------------------------------------------------------------

def _run_quality_bench(
    python_path: str | None,
    output_dir: str | None,
) -> dict[str, Any]:
    start = time.perf_counter()
    _ = python_path, output_dir
    results = [
        build_test_result(
            "clone_quality_retired",
            passed=True,
            skip_reason="Clone tone acoustic evaluator removed during clone-delivery cleanup",
        )
    ]

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("clone_quality", results, duration_ms)


# ---------------------------------------------------------------------------
# Release bundle validation
# ---------------------------------------------------------------------------

def _run_release_bench() -> dict[str, Any]:
    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    verify_script = PROJECT_DIR / "scripts" / "verify_release_bundle.sh"
    if not verify_script.exists():
        results.append(build_test_result(
            "verify_script_exists", passed=True,
            skip_reason="verify_release_bundle.sh not found",
        ))
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("release_validation", results, duration_ms)

    # Look for built .app bundles
    app_candidates = list((PROJECT_DIR / "build").glob("**/QwenVoice.app"))
    if not app_candidates:
        results.append(build_test_result(
            "app_bundle_exists", passed=True,
            skip_reason="No .app bundle found in build/ — run release.sh first",
        ))
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("release_validation", results, duration_ms)

    app_path = app_candidates[0]
    eprint(f"  Verifying {app_path.name}...")

    try:
        proc = subprocess.run(
            ["bash", str(verify_script), str(app_path)],
            capture_output=True,
            text=True,
            timeout=120,
            cwd=str(PROJECT_DIR),
        )
        # Parse step results from output
        steps: list[dict[str, Any]] = []
        for line in proc.stdout.splitlines():
            if line.startswith("[") and "]" in line:
                step_label = line.split("]", 1)[1].strip()
                passed = "OK" in line or "runs" in line or "present" in line or "passed" in line.lower()
                steps.append({"step": line.split("]")[0] + "]", "detail": step_label, "passed": passed})

        results.append(build_test_result(
            "release_bundle_verify",
            passed=proc.returncode == 0,
            error=proc.stderr.strip() if proc.returncode != 0 else None,
            details={"steps": steps, "app_path": str(app_path)},
        ))
    except subprocess.TimeoutExpired:
        results.append(build_test_result(
            "release_bundle_verify", passed=False, error="Timed out (120s)",
        ))
    except Exception as exc:
        results.append(build_test_result(
            "release_bundle_verify", passed=False, error=str(exc),
        ))

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("release_validation", results, duration_ms)


# ---------------------------------------------------------------------------
# Exhaustive performance profiler
# ---------------------------------------------------------------------------

def _run_perf_benchmarks(
    python_path: str | None,
    output_dir: str | None,
    tier: str = "all",
    runs: int = 3,
) -> list[dict[str, Any]]:
    """Launch the perf profiler and wrap results as harness suites."""
    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    try:
        resolved_python = resolve_backend_python(python_path)
    except RuntimeError as exc:
        results.append(build_test_result(
            "python_available", passed=False, skip_reason=str(exc),
        ))
        return [build_suite_result("perf_profiler", results, 0)]

    installed = [mid for mid in model_ids() if model_is_installed(mid)]
    if not installed:
        results.append(build_test_result(
            "models_available", passed=True,
            skip_reason="No models installed — skipping perf profiler",
        ))
        return [build_suite_result("perf_profiler", results, 0)]

    from .backend_client import BackendClient
    from .perf_profiler import run_all_tiers

    client = BackendClient(resolved_python)
    try:
        client.start()
        full_result = run_all_tiers(
            client,
            runs=runs,
            tiers=tier,
            output_dir=output_dir,
        )

        # Convert tier suites into harness suite format
        tier_suites: list[dict[str, Any]] = []
        for _tier_name, tier_data in full_result.get("tiers", {}).items():
            tier_suites.append(tier_data)

        # Add a summary suite with the bottleneck analysis
        bottleneck = full_result.get("bottleneck_analysis", {})
        summary_results = [
            build_test_result(
                "bottleneck_analysis",
                passed=True,
                details=bottleneck,
            ),
        ]
        summary_duration = int((time.perf_counter() - start) * 1000)
        tier_suites.append(build_suite_result("perf_summary", summary_results, summary_duration))
        return tier_suites

    except Exception as exc:
        results.append(build_test_result(
            "perf_profiler_error", passed=False, error=str(exc),
        ))
        return [build_suite_result("perf_profiler", results, 0)]
    finally:
        client.stop()
