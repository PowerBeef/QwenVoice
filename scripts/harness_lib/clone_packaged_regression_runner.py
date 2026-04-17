"""Serialized packaged-app clone regression comparison for QwenVoice."""

from __future__ import annotations

import json
import os
import plistlib
import statistics
import subprocess
import time
from datetime import datetime
from pathlib import Path
from typing import Any, TYPE_CHECKING

from .output import build_suite_result, build_test_result
from .paths import PROJECT_DIR, ensure_directory
from .ui_test_support import (
    UIAppTarget,
    build_ui_launch_environment,
    check_live_prerequisites,
    cleanup_ui_app_target,
    cleanup_ui_launch_context,
    describe_launch_context,
    kill_running_app_instances,
    launch_ui_app,
    prepare_ui_launch_context,
    resolve_ui_app_target,
)

if TYPE_CHECKING:
    from .ui_state_client import UIStateClientError

FIXTURE_AUDIO_PATH = PROJECT_DIR / "tests" / "fixtures" / "release_clone_reference.wav"
FIXTURE_TEXT_PATH = PROJECT_DIR / "tests" / "fixtures" / "release_clone_reference.txt"
BENCH_TEXT = "Packaged clone release smoke line."
EXPECTED_LEGACY_VERSION = "1.2.2"
SIMILAR_RATIO_THRESHOLD = 1.15
SIMILAR_DELTA_THRESHOLD_MS = 150
READY_TIMEOUT_S = 60.0
CLONE_FAST_READY_TIMEOUT_S = 25.0
PREVIEW_PREPARED_TIMEOUT_S = 20.0
FIRST_CHUNK_TIMEOUT_S = 30.0
FINALIZED_TIMEOUT_S = 40.0
IDLE_TIMEOUT_S = 45.0
PASS_ORDER = [
    ("current", 1),
    ("legacy", 1),
    ("legacy", 2),
    ("current", 2),
]
KEY_MEDIAN_METRICS = (
    "clone_fast_ready_ms",
    "first_preview_prepared_ms",
    "first_chunk_ms",
)
REQUIRED_CLONE_STATE_KEYS = (
    "cloneFastReady",
    "clonePrimingPhase",
    "previewPreparedAtMS",
    "previewChunkAtMS",
    "previewFinalizedAtMS",
)


def run_clone_packaged_regression_bench(
    *,
    output_dir: str | None = None,
    legacy_app_bundle: str | None = None,
    legacy_dmg: str | None = None,
    current_app_bundle: str | None = None,
    current_dmg: str | None = None,
) -> dict[str, Any]:
    """Compare packaged clone behavior between a legacy and current app artifact."""
    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    argument_error = _validate_target_arguments(
        legacy_app_bundle=legacy_app_bundle,
        legacy_dmg=legacy_dmg,
        current_app_bundle=current_app_bundle,
        current_dmg=current_dmg,
    )
    if argument_error:
        results.append(
            build_test_result(
                "clone_packaged_regression_target_arguments",
                passed=False,
                error=argument_error,
                details={
                    "legacy_app_bundle": legacy_app_bundle,
                    "legacy_dmg": legacy_dmg,
                    "current_app_bundle": current_app_bundle,
                    "current_dmg": current_dmg,
                },
            )
        )
        return build_suite_result(
            "clone_packaged_regression",
            results,
            int((time.perf_counter() - start) * 1000),
        )

    if not FIXTURE_AUDIO_PATH.exists() or not FIXTURE_TEXT_PATH.exists():
        results.append(
            build_test_result(
                "clone_packaged_regression_fixture_available",
                passed=True,
                skip_reason=(
                    "Missing packaged clone fixture at "
                    f"{FIXTURE_AUDIO_PATH} / {FIXTURE_TEXT_PATH}"
                ),
            )
        )
        return build_suite_result(
            "clone_packaged_regression",
            results,
            int((time.perf_counter() - start) * 1000),
        )

    preflight_snapshot = _collect_qwenvoice_processes()
    if preflight_snapshot:
        results.append(
            build_test_result(
                "clone_packaged_regression_preflight_idle",
                passed=False,
                error=(
                    "Close any running QwenVoice app before starting the packaged clone "
                    "regression benchmark."
                ),
                details={"processes": preflight_snapshot},
            )
        )
        return build_suite_result(
            "clone_packaged_regression",
            results,
            int((time.perf_counter() - start) * 1000),
        )

    prerequisites = check_live_prerequisites()
    models_ok = bool(prerequisites["installed_models"])
    results.append(
        build_test_result(
            "clone_packaged_regression_live_models_available",
            passed=models_ok,
            skip_reason=None if models_ok else "Installed models are required for live packaged clone comparison",
            details={
                "models_dir": prerequisites["models_dir"],
                "installed_models": prerequisites["installed_models"],
            },
        )
    )
    if not models_ok:
        return build_suite_result(
            "clone_packaged_regression",
            results,
            int((time.perf_counter() - start) * 1000),
        )

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    bench_dir = Path(output_dir) if output_dir else PROJECT_DIR / "build" / "benchmarks" / timestamp
    ensure_directory(bench_dir)

    fixture_transcript = FIXTURE_TEXT_PATH.read_text(encoding="utf-8").strip()
    configuration = {
        "legacy_app_bundle": legacy_app_bundle,
        "legacy_dmg": legacy_dmg,
        "current_app_bundle": current_app_bundle,
        "current_dmg": current_dmg,
        "reference_audio": str(FIXTURE_AUDIO_PATH),
        "reference_text_path": str(FIXTURE_TEXT_PATH),
        "text": BENCH_TEXT,
        "pass_order": [f"{side}:{index}" for side, index in PASS_ORDER],
    }
    results.append(
        build_test_result(
            "clone_packaged_regression_configuration",
            passed=True,
            details=configuration,
        )
    )

    targets: dict[str, UIAppTarget] = {}
    target_details: dict[str, dict[str, Any]] = {}
    try:
        for side, app_bundle, dmg in (
            ("legacy", legacy_app_bundle, legacy_dmg),
            ("current", current_app_bundle, current_dmg),
        ):
            resolved, target, details = resolve_ui_app_target(app_bundle=app_bundle, dmg=dmg)
            details = dict(details)
            if target is not None:
                version_info = _read_app_version(target.app_bundle)
                details.update(version_info)
                target_details[side] = details
            results.append(
                build_test_result(
                    f"clone_packaged_regression_{side}_target_resolved",
                    passed=resolved,
                    details=details,
                )
            )
            if not resolved or target is None:
                return build_suite_result(
                    "clone_packaged_regression",
                    results,
                    int((time.perf_counter() - start) * 1000),
                )
            targets[side] = target

        legacy_version = target_details["legacy"].get("version")
        results.append(
            build_test_result(
                "clone_packaged_regression_legacy_version",
                passed=legacy_version == EXPECTED_LEGACY_VERSION,
                error=(
                    None
                    if legacy_version == EXPECTED_LEGACY_VERSION
                    else f"Legacy packaged target must be {EXPECTED_LEGACY_VERSION}, found {legacy_version!r}"
                ),
                details=target_details["legacy"],
            )
        )
        if legacy_version != EXPECTED_LEGACY_VERSION:
            return build_suite_result(
                "clone_packaged_regression",
                results,
                int((time.perf_counter() - start) * 1000),
            )

        if os.path.realpath(str(targets["legacy"].app_bundle)) == os.path.realpath(str(targets["current"].app_bundle)):
            results.append(
                build_test_result(
                    "clone_packaged_regression_distinct_targets",
                    passed=False,
                    error="Legacy and current packaged targets resolve to the same app bundle path",
                    details={
                        "legacy_app_bundle": str(targets["legacy"].app_bundle),
                        "current_app_bundle": str(targets["current"].app_bundle),
                    },
                )
            )
            return build_suite_result(
                "clone_packaged_regression",
                results,
                int((time.perf_counter() - start) * 1000),
            )

        pass_details: list[dict[str, Any]] = []
        for side, pass_index in PASS_ORDER:
            target = targets[side]
            pass_result = _run_clone_pass(
                side=side,
                pass_index=pass_index,
                target=target,
                fixture_transcript=fixture_transcript,
            )
            results.append(
                build_test_result(
                    f"clone_packaged_regression_{side}_pass_{pass_index}",
                    passed=pass_result.get("passed", False),
                    error=pass_result.get("error"),
                    details=pass_result.get("details"),
                )
            )
            if not pass_result.get("passed", False):
                return build_suite_result(
                    "clone_packaged_regression",
                    results,
                    int((time.perf_counter() - start) * 1000),
                )

            idle_snapshot = _collect_qwenvoice_processes()
            idle_passed = not idle_snapshot
            results.append(
                build_test_result(
                    f"clone_packaged_regression_{side}_pass_{pass_index}_post_run_idle",
                    passed=idle_passed,
                    error=None if idle_passed else "Lingering QwenVoice process detected after serialized packaged pass",
                    details={"processes": idle_snapshot},
                )
            )
            if not idle_passed:
                return build_suite_result(
                    "clone_packaged_regression",
                    results,
                    int((time.perf_counter() - start) * 1000),
                )

            pass_details.append(pass_result["details"])

        medians = _compute_packaged_medians(pass_details)
        results.append(
            build_test_result(
                "clone_packaged_regression_medians",
                passed=True,
                details=medians,
            )
        )
        classification = classify_packaged_clone_regression(medians)
        results.append(
            build_test_result(
                "clone_packaged_regression_source",
                passed=True,
                details=classification,
            )
        )

        artifact_path = bench_dir / "clone_packaged_regression.json"
        artifact_path.write_text(
            json.dumps(
                {
                    "configuration": configuration,
                    "targets": {
                        "legacy": target_details["legacy"],
                        "current": target_details["current"],
                    },
                    "passes": pass_details,
                    "medians": medians,
                    "classification": classification,
                },
                indent=2,
            ),
            encoding="utf-8",
        )
        results.append(
            build_test_result(
                "clone_packaged_regression_artifact",
                passed=True,
                details={"path": str(artifact_path)},
            )
        )
    finally:
        kill_running_app_instances()
        for target in targets.values():
            cleanup_ui_app_target(target)

    return build_suite_result(
        "clone_packaged_regression",
        results,
        int((time.perf_counter() - start) * 1000),
    )


def classify_packaged_clone_regression(medians: dict[str, dict[str, Any]]) -> dict[str, Any]:
    slower_metrics = [
        metric
        for metric in KEY_MEDIAN_METRICS
        if _is_materially_slower(
            medians.get("legacy", {}).get(metric),
            medians.get("current", {}).get(metric),
        )
    ]

    if slower_metrics:
        source = "packaged_app_regression"
        reason = (
            "The current packaged app is materially slower than the legacy 1.2.2 packaged app "
            "on one or more clone user-experience medians."
        )
    else:
        source = "local_state_or_machine_environment"
        reason = (
            "The current and legacy packaged apps are within the configured similarity threshold "
            "on clone priming and preview medians, which points away from a packaged app regression."
        )

    return {
        "source": source,
        "reason": reason,
        "slower_metrics": slower_metrics,
        "similar_ratio_threshold": SIMILAR_RATIO_THRESHOLD,
        "similar_delta_threshold_ms": SIMILAR_DELTA_THRESHOLD_MS,
        "legacy": medians.get("legacy", {}),
        "current": medians.get("current", {}),
    }


def _run_clone_pass(
    *,
    side: str,
    pass_index: int,
    target: UIAppTarget,
    fixture_transcript: str,
) -> dict[str, Any]:
    from .ui_state_client import UIStateClient, UIStateClientError

    context = prepare_ui_launch_context(backend_mode="live", data_root="fixture")
    client = UIStateClient()
    app_proc: subprocess.Popen[Any] | None = None

    try:
        kill_running_app_instances()
        env = build_ui_launch_environment(context)
        launch_start = time.perf_counter()
        app_proc = launch_ui_app(str(target.app_binary), env)
        ready, state, failure_reason = client.wait_for_ready(
            timeout=READY_TIMEOUT_S,
            ready_field="interactiveReady",
        )
        launch_to_ready_ms = int((time.perf_counter() - launch_start) * 1000)
        if not ready:
            return {
                "passed": False,
                "error": f"Packaged app did not become ready: {failure_reason}",
                "details": {
                    "side": side,
                    "pass_index": pass_index,
                    "app_bundle": str(target.app_bundle),
                    "launch_to_ready_ms": launch_to_ready_ms,
                    "failure_reason": failure_reason,
                    "state": state,
                    "launch_context": describe_launch_context(context),
                },
            }

        runtime_diagnostics = _runtime_diagnostics(target, state)
        if not runtime_diagnostics["native_runtime_ok"]:
            return {
                "passed": False,
                "error": "Packaged clone comparison requires native runtime diagnostics to pass",
                "details": {
                    "side": side,
                    "pass_index": pass_index,
                    "app_bundle": str(target.app_bundle),
                    "launch_to_ready_ms": launch_to_ready_ms,
                    "runtime_diagnostics": runtime_diagnostics,
                    "state": state,
                    "launch_context": describe_launch_context(context),
                },
            }

        missing_state_keys = [
            key for key in REQUIRED_CLONE_STATE_KEYS if key not in state
        ]
        if missing_state_keys:
            return {
                "passed": False,
                "error": (
                    "Packaged app does not expose the required clone regression "
                    "test-state fields; rebuild or supply a current packaged artifact."
                ),
                "details": {
                    "side": side,
                    "pass_index": pass_index,
                    "app_bundle": str(target.app_bundle),
                    "launch_to_ready_ms": launch_to_ready_ms,
                    "missing_state_keys": missing_state_keys,
                    "runtime_diagnostics": runtime_diagnostics,
                    "state": state,
                    "launch_context": describe_launch_context(context),
                },
            }

        clone_ready_start = time.perf_counter()
        if state.get("activeScreen") != "screen_voiceCloning":
            try:
                nav_state = client.navigate("voiceCloning")
            except UIStateClientError as exc:
                return _transport_failure(
                    side=side,
                    pass_index=pass_index,
                    stage="navigate",
                    exc=exc,
                    last_state=state,
                )
            navigated, ready_state = client.wait_for_navigation("screen_voiceCloning", timeout=15)
            state = ready_state or nav_state
            if not navigated:
                return {
                    "passed": False,
                    "error": "Voice Cloning screen did not become active",
                    "details": {
                        "side": side,
                        "pass_index": pass_index,
                        "state": state,
                    },
                }

        try:
            state = client.seed_screen(
                "voiceCloning",
                text=BENCH_TEXT,
                reference_audio_path=str(FIXTURE_AUDIO_PATH),
                reference_transcript=fixture_transcript,
            )
        except UIStateClientError as exc:
            return _transport_failure(
                side=side,
                pass_index=pass_index,
                stage="seed_screen",
                exc=exc,
                last_state=state,
            )

        clone_fast_ready = (
            state.get("activeScreen") == "screen_voiceCloning"
            and state.get("cloneFastReady") is True
        )
        clone_state = state
        if not clone_fast_ready:
            clone_fast_ready, clone_state = client.wait_for_state(
                lambda snapshot: (
                    snapshot.get("activeScreen") == "screen_voiceCloning"
                    and snapshot.get("cloneFastReady") is True
                ),
                timeout=CLONE_FAST_READY_TIMEOUT_S,
                interval=0.1,
            )
        clone_fast_ready_ms = int((time.perf_counter() - clone_ready_start) * 1000)
        if clone_state:
            state = clone_state
        if not clone_fast_ready:
            return {
                "passed": False,
                "error": "Clone reference did not reach cloneFastReady",
                "details": {
                    "side": side,
                    "pass_index": pass_index,
                    "clone_fast_ready_ms": clone_fast_ready_ms,
                    "state": state,
                    "runtime_diagnostics": runtime_diagnostics,
                },
            }
        clone_priming_phase = state.get("clonePrimingPhase")

        baseline_prepared_count = int(state.get("previewPreparedCount", 0))
        baseline_chunk_count = int(state.get("previewChunkCount", 0))
        baseline_finalized_count = int(state.get("previewFinalizedCount", 0))

        trigger_start = time.perf_counter()
        try:
            state = client.start_generation("voiceCloning", BENCH_TEXT)
        except UIStateClientError as exc:
            return _transport_failure(
                side=side,
                pass_index=pass_index,
                stage="start_generation",
                exc=exc,
                last_state=state,
            )

        prepared_visible = int(state.get("previewPreparedCount", 0)) > baseline_prepared_count
        prepared_state = state
        if not prepared_visible:
            prepared_visible, prepared_state = client.wait_for_state(
                lambda snapshot: int(snapshot.get("previewPreparedCount", 0)) > baseline_prepared_count,
                timeout=PREVIEW_PREPARED_TIMEOUT_S,
                interval=0.05,
            )
        first_preview_prepared_ms = int((time.perf_counter() - trigger_start) * 1000)
        if prepared_state:
            state = prepared_state
        if not prepared_visible:
            return {
                "passed": False,
                "error": "Preview never reached prepared state",
                "details": {
                    "side": side,
                    "pass_index": pass_index,
                    "first_preview_prepared_ms": first_preview_prepared_ms,
                    "state": state,
                    "runtime_diagnostics": runtime_diagnostics,
                },
            }

        prepared_at_ms = state.get("previewPreparedAtMS")

        chunk_visible = int(state.get("previewChunkCount", 0)) > baseline_chunk_count
        chunk_state = state
        if not chunk_visible:
            chunk_visible, chunk_state = client.wait_for_state(
                lambda snapshot: int(snapshot.get("previewChunkCount", 0)) > baseline_chunk_count,
                timeout=FIRST_CHUNK_TIMEOUT_S,
                interval=0.05,
            )
        first_chunk_ms = int((time.perf_counter() - trigger_start) * 1000)
        if chunk_state:
            state = chunk_state
        if not chunk_visible:
            return {
                "passed": False,
                "error": "Preview never emitted a first chunk",
                "details": {
                    "side": side,
                    "pass_index": pass_index,
                    "first_chunk_ms": first_chunk_ms,
                    "state": state,
                    "runtime_diagnostics": runtime_diagnostics,
                },
            }

        chunk_at_ms = state.get("previewChunkAtMS")

        finalized = int(state.get("previewFinalizedCount", 0)) > baseline_finalized_count
        finalized_state = state
        if not finalized:
            finalized, finalized_state = client.wait_for_state(
                lambda snapshot: int(snapshot.get("previewFinalizedCount", 0)) > baseline_finalized_count,
                timeout=FINALIZED_TIMEOUT_S,
                interval=0.05,
            )
        preview_finalized_ms = int((time.perf_counter() - trigger_start) * 1000)
        if finalized_state:
            state = finalized_state
        if not finalized:
            return {
                "passed": False,
                "error": "Preview never finalized",
                "details": {
                    "side": side,
                    "pass_index": pass_index,
                    "preview_finalized_ms": preview_finalized_ms,
                    "state": state,
                    "runtime_diagnostics": runtime_diagnostics,
                },
            }

        finalized_at_ms = state.get("previewFinalizedAtMS")

        idle_ready = (
            state.get("sidebarStatusKind") == "idle"
            and state.get("sidebarInlineStatusVisible") is False
            and state.get("sidebarStandaloneStatusVisible") is True
        )
        idle_state = state
        if not idle_ready:
            idle_ready, idle_state = client.wait_for_state(
                lambda snapshot: (
                    snapshot.get("sidebarStatusKind") == "idle"
                    and snapshot.get("sidebarInlineStatusVisible") is False
                    and snapshot.get("sidebarStandaloneStatusVisible") is True
                ),
                timeout=IDLE_TIMEOUT_S,
                interval=0.05,
            )
        returns_to_idle_ms = int((time.perf_counter() - trigger_start) * 1000)
        if idle_state:
            state = idle_state
        if not idle_ready:
            return {
                "passed": False,
                "error": "Packaged app did not return to idle after clone generation",
                "details": {
                    "side": side,
                    "pass_index": pass_index,
                    "returns_to_idle_ms": returns_to_idle_ms,
                    "state": state,
                    "runtime_diagnostics": runtime_diagnostics,
                },
            }

        details = {
            "side": side,
            "pass_index": pass_index,
            "app_bundle": str(target.app_bundle),
            "app_version": _read_app_version(target.app_bundle),
            "source": target.source,
            "variant_id": target.variant_id,
            "ui_profile": target.ui_profile,
            "launch_context": describe_launch_context(context),
            "runtime_diagnostics": runtime_diagnostics,
            "launch_to_ready_ms": launch_to_ready_ms,
            "clone_fast_ready_ms": clone_fast_ready_ms,
            "clone_priming_phase": clone_priming_phase,
            "first_preview_prepared_ms": first_preview_prepared_ms,
            "preview_prepared_at_ms": prepared_at_ms,
            "first_chunk_ms": first_chunk_ms,
            "preview_chunk_at_ms": chunk_at_ms,
            "preview_finalized_ms": preview_finalized_ms,
            "preview_finalized_at_ms": finalized_at_ms,
            "returns_to_idle_ms": returns_to_idle_ms,
            "previewPreparedCount": state.get("previewPreparedCount"),
            "previewChunkCount": state.get("previewChunkCount"),
            "previewFinalizedCount": state.get("previewFinalizedCount"),
            "final_state": state,
        }
        return {"passed": True, "details": details}
    finally:
        _terminate_ui_process(app_proc)
        cleanup_ui_launch_context(context)


def _runtime_diagnostics(target: UIAppTarget, state: dict[str, Any]) -> dict[str, Any]:
    runtime_source = state.get("runtimeSource")
    active_python_path = state.get("activePythonPath", "")
    active_ffmpeg_path = state.get("activeFFmpegPath", "")
    normalized_active_python_path = _normalize_path(active_python_path)
    normalized_active_ffmpeg_path = _normalize_path(active_ffmpeg_path)

    native_runtime_ok = (
        runtime_source == "native"
        and normalized_active_python_path == ""
        and normalized_active_ffmpeg_path == ""
    )

    return {
        "runtimeSource": runtime_source,
        "activePythonPath": active_python_path,
        "activeFFmpegPath": active_ffmpeg_path,
        "expectedPythonPrefix": "",
        "expectedFFmpegPath": "",
        "normalizedActivePythonPath": normalized_active_python_path,
        "normalizedActiveFFmpegPath": normalized_active_ffmpeg_path,
        "native_runtime_ok": native_runtime_ok,
    }


def _normalize_path(path: str) -> str:
    if not path:
        return ""
    return os.path.realpath(path)


def _compute_packaged_medians(pass_details: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    medians: dict[str, dict[str, Any]] = {}
    for side in ("legacy", "current"):
        side_passes = [item for item in pass_details if item.get("side") == side]
        medians[side] = {
            "sample_count": len(side_passes),
            "pass_order": [item.get("pass_index") for item in side_passes],
            "app_version": side_passes[0].get("app_version") if side_passes else None,
            "runtime_sources": [item.get("runtime_diagnostics", {}).get("runtimeSource") for item in side_passes],
        }
        for metric in (
            "launch_to_ready_ms",
            "clone_fast_ready_ms",
            "first_preview_prepared_ms",
            "first_chunk_ms",
            "preview_finalized_ms",
            "returns_to_idle_ms",
        ):
            medians[side][metric] = _median_or_none(
                item.get(metric) for item in side_passes
            )
    return medians


def _median_or_none(values: Any) -> float | None:
    numeric = []
    for value in values:
        try:
            numeric.append(float(value))
        except (TypeError, ValueError):
            continue
    if not numeric:
        return None
    return round(float(statistics.median(numeric)), 2)


def _is_materially_slower(legacy_value: Any, current_value: Any) -> bool:
    try:
        legacy_f = float(legacy_value)
        current_f = float(current_value)
    except (TypeError, ValueError):
        return False

    if current_f - legacy_f <= SIMILAR_DELTA_THRESHOLD_MS:
        return False
    if legacy_f <= 0:
        return current_f > SIMILAR_DELTA_THRESHOLD_MS
    return current_f > legacy_f * SIMILAR_RATIO_THRESHOLD


def _validate_target_arguments(
    *,
    legacy_app_bundle: str | None,
    legacy_dmg: str | None,
    current_app_bundle: str | None,
    current_dmg: str | None,
) -> str | None:
    if bool(legacy_app_bundle) == bool(legacy_dmg):
        return "Provide exactly one of --legacy-app-bundle or --legacy-dmg"
    if bool(current_app_bundle) == bool(current_dmg):
        return "Provide exactly one of --current-app-bundle or --current-dmg"
    return None


def _read_app_version(app_bundle: Path) -> dict[str, Any]:
    info_path = app_bundle / "Contents" / "Info.plist"
    info: dict[str, Any] = {}
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except Exception:
        return {
            "version": None,
            "build": None,
            "info_plist": str(info_path),
        }

    return {
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
        "info_plist": str(info_path),
    }


def _transport_failure(
    *,
    side: str,
    pass_index: int,
    stage: str,
    exc: Any,
    last_state: dict[str, Any],
) -> dict[str, Any]:
    return {
        "passed": False,
        "error": str(exc),
        "details": {
            "side": side,
            "pass_index": pass_index,
            "stage": stage,
            "operation": exc.operation,
            "error_kind": exc.kind,
            "error_detail": exc.detail,
            "url": exc.url,
            "state": last_state,
        },
    }


def _terminate_ui_process(app_proc: subprocess.Popen[Any] | None) -> None:
    if app_proc is None:
        kill_running_app_instances()
        return
    app_proc.terminate()
    try:
        app_proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        app_proc.kill()
    kill_running_app_instances()


def _collect_qwenvoice_processes() -> list[dict[str, Any]]:
    proc = subprocess.run(
        ["ps", "-axo", "pid=,command="],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    matches: list[dict[str, Any]] = []
    current_pid = os.getpid()
    for raw_line in proc.stdout.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        parts = line.split(maxsplit=1)
        if len(parts) != 2:
            continue
        pid = int(parts[0])
        command = parts[1]
        if pid == current_pid:
            continue
        if "/QwenVoice.app/Contents/MacOS/QwenVoice" in command:
            matches.append({"pid": pid, "command": command})
    return matches
