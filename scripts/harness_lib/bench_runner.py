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


def run_benchmarks(
    category: str = "all",
    runs: int = 3,
    python_path: str | None = None,
    output_dir: str | None = None,
    tier: str = "all",
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

        for mid in installed:
            model_def = next((m for m in contract["models"] if m["id"] == mid), None)
            if not model_def:
                continue
            mode = model_def["mode"]

            # Load model
            eprint(f"  Loading {mid}...")
            client.call("load_model", {"model_id": mid}, timeout=120)

            # Cold and warm runs
            for warmth in ("cold", "warm"):
                wall_times: list[float] = []
                first_chunk_times: list[float] = []
                actual_runs = runs

                for i in range(actual_runs):
                    eprint(f"  {mid} {warmth} run {i + 1}/{actual_runs}...")
                    with tempfile.TemporaryDirectory() as tmp:
                        output_path = os.path.join(tmp, f"bench_{i}.wav")
                        params: dict[str, Any] = {
                            "text": "The package is ready at the front desk for pickup.",
                            "output_path": output_path,
                        }
                        if mode == "custom":
                            params["voice"] = "vivian"
                        elif mode == "design":
                            params["voice_description"] = "A young female speaker"
                        elif mode == "clone":
                            # Skip clone latency if no reference available
                            results.append(build_test_result(
                                f"latency_{mid}_{warmth}",
                                passed=True,
                                skip_reason="No reference audio for clone benchmark",
                            ))
                            break

                        t0 = time.perf_counter()
                        try:
                            result, notifications = client.call_collecting_notifications(
                                "generate", params, timeout=300,
                            )
                            wall_ms = (time.perf_counter() - t0) * 1000
                            wall_times.append(wall_ms)

                            # Find first chunk notification
                            first_chunk_ms = wall_ms
                            for notif in notifications:
                                if notif.get("method") == "generation_chunk":
                                    first_chunk_ms = (time.perf_counter() - t0) * 1000
                                    break
                            first_chunk_times.append(first_chunk_ms)
                        except Exception as exc:
                            results.append(build_test_result(
                                f"latency_{mid}_{warmth}_run{i}",
                                passed=False,
                                error=str(exc),
                            ))
                            break
                else:
                    if wall_times:
                        summary = {
                            "wall_ms": summarize_numeric(wall_times),
                            "first_chunk_ms": summarize_numeric(first_chunk_times),
                            "raw_wall_ms": [round(t, 1) for t in wall_times],
                        }
                        results.append(build_test_result(
                            f"latency_{mid}_{warmth}",
                            passed=True,
                            details=summary,
                        ))
                        # Save raw samples
                        samples_path = bench_dir / f"{mid}_{warmth}_samples.json"
                        samples_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")

            client.call("unload_model", timeout=30)

    except Exception as exc:
        results.append(build_test_result(
            "latency_bench_error", passed=False, error=str(exc),
        ))
    finally:
        client.stop()

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("generation_latency", results, duration_ms)


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
    results: list[dict[str, Any]] = []

    # Try to import evaluate_pair from the acoustic evaluator
    try:
        scripts_dir = PROJECT_DIR / "scripts"
        sys.path.insert(0, str(scripts_dir))
        from evaluate_clone_tone_acoustic import evaluate_pair, evaluate_directory
    except ImportError as exc:
        results.append(build_test_result(
            "acoustic_evaluator_available", passed=True,
            skip_reason=f"Cannot import acoustic evaluator: {exc}",
        ))
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("clone_quality", results, duration_ms)

    # Check for existing evaluation artifacts
    eval_dirs = sorted(
        (PROJECT_DIR / "build" / "tone-evals").glob("acoustic-run-*")
    ) if (PROJECT_DIR / "build" / "tone-evals").is_dir() else []

    if eval_dirs:
        latest = eval_dirs[-1]
        eprint(f"  Evaluating existing artifacts in {latest.name}...")
        try:
            eval_result = evaluate_directory(latest)
            results.append(build_test_result(
                "acoustic_eval_existing",
                passed=eval_result.get("overall_pass", False),
                details={
                    "source": str(latest),
                    "scenario_count": eval_result.get("scenario_count", 0),
                    "pass_count": eval_result.get("pass_count", 0),
                    "fail_count": eval_result.get("fail_count", 0),
                },
            ))
        except Exception as exc:
            results.append(build_test_result(
                "acoustic_eval_existing", passed=False, error=str(exc),
            ))
    else:
        results.append(build_test_result(
            "acoustic_eval_existing", passed=True,
            skip_reason="No existing tone-eval artifacts found",
        ))

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
