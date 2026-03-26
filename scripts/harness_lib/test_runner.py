"""Test runner — four layers of tests for the QwenVoice harness.

Layer (a): Pipeline pure-function tests — no model loading, no venv
Layer (b): Server pure-function tests — imports server.py via importlib
Layer (c): RPC integration tests — requires app venv + installed model
Layer (d): Contract cross-validation — cross-references across layers
"""

from __future__ import annotations

import importlib
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

from .contract import load_contract, model_ids, model_is_installed, speaker_list
from .output import build_suite_result, build_test_result, eprint
from .paths import (
    APP_MODELS_DIR,
    BACKEND_DIR,
    CONTRACT_PATH,
    PIPELINE_PATH,
    PROJECT_DIR,
    SERVER_PATH,
    resolve_backend_python,
)
from .ui_test_support import (
    UIAppTarget,
    build_app_binary,
    build_ui_launch_environment,
    check_live_prerequisites,
    cleanup_ui_launch_context,
    cleanup_ui_app_target,
    discover_release_artifacts,
    describe_launch_context,
    kill_running_app_instances,
    launch_ui_app,
    prepare_ui_launch_context,
    resolve_ui_app_target,
)


def run_tests(
    layer: str = "all",
    python_path: str | None = None,
    artifact_dir: str | None = None,
    ui_backend_mode: str = "live",
    ui_data_root: str = "fixture",
    app_bundle: str | None = None,
    dmg: str | None = None,
    artifacts_root: str | None = None,
) -> list[dict[str, Any]]:
    """Run selected test layers and return suite results."""
    suites: list[dict[str, Any]] = []

    if layer in ("all", "pipeline"):
        eprint("==> Running pipeline pure-function tests...")
        suites.append(_run_pipeline_tests())

    if layer in ("all", "server"):
        eprint("==> Running server pure-function tests...")
        suites.append(_run_server_tests())

    if layer in ("all", "contract"):
        eprint("==> Running contract validation tests...")
        suites.append(_run_contract_tests(python_path))

    if layer in ("all", "rpc"):
        eprint("==> Running RPC integration tests...")
        suites.append(_run_rpc_tests(python_path))

    if layer in ("all", "swift"):
        eprint("==> Running Swift unit tests...")
        suites.append(_run_swift_tests())

    if layer in ("all", "audio"):
        eprint("==> Running audio pipeline tests...")
        from .audio_test_runner import run_audio_tests
        suites.append(run_audio_tests(python_path=python_path, artifact_dir=artifact_dir))

    if layer == "ui":
        suites.append(_run_ui_tests(
            backend_mode=ui_backend_mode,
            data_root=ui_data_root,
            app_bundle=app_bundle,
            dmg=dmg,
        ))

    if layer == "design":
        suites.append(_run_design_tests(
            backend_mode=ui_backend_mode,
            data_root=ui_data_root,
            app_bundle=app_bundle,
            dmg=dmg,
        ))

    if layer == "perf":
        suites.append(_run_perf_audit(
            backend_mode=ui_backend_mode,
            data_root=ui_data_root,
            app_bundle=app_bundle,
            dmg=dmg,
        ))

    if layer == "release":
        suites.extend(_run_release_tests(
            backend_mode=ui_backend_mode,
            data_root=ui_data_root,
            artifacts_root=artifacts_root,
        ))

    return suites


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _timed_test(name: str, fn: Any) -> dict[str, Any]:
    """Run a test function, capturing pass/fail/skip and timing."""
    start = time.perf_counter()
    try:
        result = fn()
        duration_ms = int((time.perf_counter() - start) * 1000)
        if isinstance(result, dict) and result.get("skip_reason"):
            return build_test_result(name, passed=True, skip_reason=result["skip_reason"], duration_ms=duration_ms)
        if isinstance(result, dict) and "details" in result:
            return build_test_result(name, passed=True, duration_ms=duration_ms, details=result["details"])
        return build_test_result(name, passed=True, duration_ms=duration_ms)
    except Exception as exc:
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_test_result(name, passed=False, error=str(exc), duration_ms=duration_ms)


def _ui_transport_failure_reason(operation: str) -> str:
    return {
        "navigate": "navigation_transport_error",
        "start_preview": "preview_transport_error",
        "start_generation": "preview_transport_error",
        "activate_window": "window_activation_transport_error",
        "capture_screenshot": "screenshot_transport_error",
        "query_state": "state_server_transport_error",
    }.get(operation, "state_server_transport_error")


def _wait_for_stub_event(app_support_dir: str, name: str, timeout: float = 10.0) -> bool:
    event_file = Path(app_support_dir) / ".stub-events" / f"{name.replace('/', '-')}.txt"
    deadline = time.perf_counter() + timeout
    while time.perf_counter() < deadline:
        if event_file.exists():
            return True
        time.sleep(0.05)
    return False


def _build_ui_transport_failure_result(
    name: str,
    exc: Any,
    *,
    last_state: dict[str, Any] | None = None,
) -> dict[str, Any]:
    details = {
        "failure_reason": _ui_transport_failure_reason(getattr(exc, "operation", "")),
        "operation": getattr(exc, "operation", "unknown"),
        "error_kind": getattr(exc, "kind", "transport"),
        "error_detail": getattr(exc, "detail", str(exc)),
        "url": getattr(exc, "url", ""),
        "state": last_state or {},
    }
    return build_test_result(
        name,
        passed=False,
        error=getattr(exc, "detail", str(exc)),
        details=details,
    )


def _load_module_from_path(name: str, path: Path) -> Any:
    """Load a Python module from a file path using importlib."""
    spec = importlib.util.spec_from_file_location(name, str(path))
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot load module from {path}")
    module = importlib.util.module_from_spec(spec)
    # Register in sys.modules so dataclass/typing introspection works
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except Exception:
        sys.modules.pop(name, None)
        raise
    return module


# ---------------------------------------------------------------------------
# Layer (a): Pipeline pure-function tests
# ---------------------------------------------------------------------------

def _run_pipeline_tests() -> dict[str, Any]:
    start = time.perf_counter()
    pipeline = _load_module_from_path("clone_delivery_pipeline", PIPELINE_PATH)
    results: list[dict[str, Any]] = []

    # parse_clone_delivery_profile tests
    def test_parse_profile_preset():
        for emotion in ["happy", "sad", "angry", "fearful", "whisper", "dramatic", "calm", "excited"]:
            profile = pipeline.parse_clone_delivery_profile(
                {"preset_id": emotion, "intensity": "normal", "final_instruction": f"{emotion} tone"}
            )
            assert profile is not None, f"Expected profile for {emotion}"
            assert profile.preset_id == emotion

    def test_parse_profile_custom_text():
        profile = pipeline.parse_clone_delivery_profile(
            {"custom_text": "Speak like a pirate", "final_instruction": "Speak like a pirate"}
        )
        assert profile is not None
        assert profile.is_custom

    def test_parse_profile_neutral_returns_none():
        profile = pipeline.parse_clone_delivery_profile(
            {"preset_id": "neutral", "final_instruction": "Normal tone"}
        )
        assert profile is None, "Neutral profile should return None"

    def test_parse_profile_empty_returns_none():
        profile = pipeline.parse_clone_delivery_profile({})
        assert profile is None

    def test_parse_profile_already_parsed():
        original = pipeline.CloneDeliveryProfile(
            preset_id="happy", intensity="normal", custom_text=None, final_instruction="Happy tone"
        )
        result = pipeline.parse_clone_delivery_profile(original)
        assert result is original

    # build_clone_delivery_plan tests
    def test_build_plan_all_emotions():
        text = "Hello world"
        for emotion in ["happy", "sad", "angry", "fearful", "whisper", "dramatic", "calm", "excited"]:
            for intensity in ["subtle", "normal", "strong"]:
                plan = pipeline.build_clone_delivery_plan(
                    {"preset_id": emotion, "intensity": intensity, "final_instruction": f"{emotion} tone"},
                    text=text,
                )
                assert plan is not None, f"Expected plan for {emotion}/{intensity}"
                assert plan.strength_level in ("light", "medium", "strong")
                assert plan.sampling_profile is not None

    def test_build_plan_custom_profile():
        plan = pipeline.build_clone_delivery_plan(
            {"custom_text": "Speak warmly", "final_instruction": "Speak warmly"},
            text="Test text",
        )
        assert plan is not None
        assert plan.profile.is_custom

    def test_build_plan_strength_override():
        plan = pipeline.build_clone_delivery_plan(
            {"preset_id": "happy", "intensity": "subtle", "final_instruction": "Happy tone"},
            text="Test",
            strength_override="strong",
        )
        assert plan is not None
        assert plan.strength_level == "strong"

    # CloneDeliveryPlan.clone_instruct tests
    def test_plan_clone_instruct_preset():
        for preset, expected in pipeline.CLONE_EMOTION_INSTRUCT.items():
            if preset == "neutral":
                continue
            plan = pipeline.build_clone_delivery_plan(
                {"preset_id": preset, "intensity": "normal", "final_instruction": f"{preset} tone"},
                text="Test",
            )
            assert plan is not None
            assert plan.clone_instruct == expected, f"Expected {expected} for {preset}, got {plan.clone_instruct}"

    # delivery_profile_fingerprint tests
    def test_fingerprint_stable():
        profile = {"preset_id": "happy", "intensity": "normal", "final_instruction": "Happy tone"}
        fp1 = pipeline.delivery_profile_fingerprint(profile)
        fp2 = pipeline.delivery_profile_fingerprint(profile)
        assert fp1 == fp2, "Fingerprint should be stable"
        assert fp1, "Fingerprint should be non-empty for meaningful profile"

    def test_fingerprint_empty_for_neutral():
        fp = pipeline.delivery_profile_fingerprint(
            {"preset_id": "neutral", "final_instruction": "Normal tone"}
        )
        assert fp == "", "Fingerprint should be empty for neutral"

    # CloneDeliveryProfile property tests
    def test_profile_is_meaningful():
        meaningful = pipeline.CloneDeliveryProfile(
            preset_id="happy", intensity="normal", custom_text=None, final_instruction="Happy tone"
        )
        assert meaningful.is_meaningful
        not_meaningful = pipeline.CloneDeliveryProfile(
            preset_id="neutral", intensity=None, custom_text=None, final_instruction="Normal tone"
        )
        assert not not_meaningful.is_meaningful

    def test_profile_is_custom():
        custom = pipeline.CloneDeliveryProfile(
            preset_id=None, intensity=None, custom_text="Custom instruction", final_instruction="Custom"
        )
        assert custom.is_custom
        preset = pipeline.CloneDeliveryProfile(
            preset_id="happy", intensity="normal", custom_text=None, final_instruction="Happy"
        )
        assert not preset.is_custom

    def test_profile_canonical_intensity():
        for raw, expected in [("subtle", "subtle"), ("normal", "normal"), ("strong", "strong")]:
            p = pipeline.CloneDeliveryProfile(preset_id="happy", intensity=raw, custom_text=None, final_instruction="X")
            assert p.canonical_intensity == expected
        p = pipeline.CloneDeliveryProfile(preset_id="happy", intensity="invalid", custom_text=None, final_instruction="X")
        assert p.canonical_intensity is None

    def test_profile_starting_strength():
        p = pipeline.CloneDeliveryProfile(preset_id="happy", intensity="subtle", custom_text=None, final_instruction="X")
        assert p.starting_strength == "light"
        p = pipeline.CloneDeliveryProfile(preset_id="happy", intensity="normal", custom_text=None, final_instruction="X")
        assert p.starting_strength == "medium"
        p = pipeline.CloneDeliveryProfile(preset_id="happy", intensity="strong", custom_text=None, final_instruction="X")
        assert p.starting_strength == "strong"

    def test_profile_fallback_ladder():
        p = pipeline.CloneDeliveryProfile(preset_id="happy", intensity="strong", custom_text=None, final_instruction="X")
        assert p.fallback_ladder == ["strong", "medium", "light"]
        p = pipeline.CloneDeliveryProfile(preset_id="happy", intensity="subtle", custom_text=None, final_instruction="X")
        assert p.fallback_ladder == ["light"]

    # Text styling tests
    def test_energetic_text():
        text = "Hello, world"
        styled_strong = pipeline._energetic_text(text, "strong")
        assert "!" in styled_strong
        styled_light = pipeline._energetic_text(text, "light")
        assert styled_light.endswith(".")

    def test_fragile_text():
        text = "Hello, world"
        styled_strong = pipeline._fragile_text(text, "strong")
        assert "..." in styled_strong
        styled_light = pipeline._fragile_text(text, "light")
        assert styled_light.endswith(".")

    def test_dramatic_text():
        text = "Hello, world"
        styled_strong = pipeline._dramatic_text(text, "strong")
        assert "--" in styled_strong
        styled_medium = pipeline._dramatic_text(text, "medium")
        assert "..." in styled_medium

    def test_calm_text():
        text = "Hello world"
        styled_light = pipeline._calm_text(text, "light")
        assert styled_light == text  # light calm returns text as-is

    # Structural integrity tests
    def test_sampling_profiles_keys():
        assert set(pipeline.SAMPLING_PROFILES.keys()) == {"light", "medium", "strong"}

    def test_strength_fallbacks_keys():
        assert set(pipeline.STRENGTH_FALLBACKS.keys()) == {"light", "medium", "strong"}

    def test_clone_emotion_instruct_entries():
        expected_emotions = {"happy", "sad", "angry", "fearful", "whisper", "dramatic", "calm", "excited", "neutral"}
        assert set(pipeline.CLONE_EMOTION_INSTRUCT.keys()) == expected_emotions
        assert pipeline.CLONE_EMOTION_INSTRUCT["neutral"] is None

    def test_ui_state_client_wraps_transport_errors():
        from .ui_state_client import UIStateClient, UIStateClientError

        client = UIStateClient(base_url="http://127.0.0.1:1")
        try:
            client.navigate("history")
        except UIStateClientError as exc:
            assert exc.operation == "navigate"
            assert exc.kind == "transport"
            assert exc.url.endswith("/navigate?screen=history")
        else:
            raise AssertionError("Expected UIStateClientError for refused connection")

    def test_build_ui_transport_failure_result():
        from .ui_state_client import UIStateClientError

        exc = UIStateClientError(
            "navigate",
            "http://localhost:19876/navigate?screen=history",
            "transport",
            "[Errno 61] Connection refused",
        )
        result = _build_ui_transport_failure_result(
            "sidebar_history_run_1",
            exc,
            last_state={"activeScreen": "screen_customVoice"},
        )
        assert result["passed"] is False
        assert result["details"]["failure_reason"] == "navigation_transport_error"
        assert result["details"]["state"]["activeScreen"] == "screen_customVoice"

    def test_click_detection_ignores_matching_final_boundary_transient():
        import numpy as np

        from .audio_analysis import check_click_detection

        chunk_a = np.linspace(0.0, 0.12, 64, dtype=np.float32)
        chunk_b = np.concatenate((
            np.array([0.95], dtype=np.float32),
            np.linspace(0.94, 0.2, 63, dtype=np.float32),
        ))
        final_audio = np.concatenate((chunk_a, chunk_b))
        result = check_click_detection(
            [(chunk_a, 24000), (chunk_b, 24000)],
            final_audio=final_audio,
        )
        assert result["passed"] is True

    def test_click_detection_detects_boundary_not_present_in_final_audio():
        import numpy as np

        from .audio_analysis import check_click_detection

        chunk_a = np.linspace(0.0, 0.12, 64, dtype=np.float32)
        chunk_b = np.concatenate((
            np.array([0.95], dtype=np.float32),
            np.linspace(0.94, 0.2, 63, dtype=np.float32),
        ))
        final_audio = np.concatenate((
            chunk_a[:-1],
            np.array([0.13, 0.14], dtype=np.float32),
            np.linspace(0.15, 0.2, 63, dtype=np.float32),
        ))
        result = check_click_detection(
            [(chunk_a, 24000), (chunk_b, 24000)],
            final_audio=final_audio,
        )
        assert result["passed"] is False
        assert result["clicks"]

    def test_build_ui_launch_environment_defaults_screenshot_capture_mode():
        context = prepare_ui_launch_context(backend_mode="stub", data_root="fixture")
        try:
            env = build_ui_launch_environment(
                context,
                screenshot_dir="/tmp/qwenvoice-screenshots",
            )
            assert env["QWENVOICE_UITEST_CAPTURE_MODE"] == "content"
        finally:
            cleanup_ui_launch_context(context)

    def test_build_ui_launch_environment_preserves_explicit_capture_mode():
        previous_value = os.environ.get("QWENVOICE_UITEST_CAPTURE_MODE")
        os.environ["QWENVOICE_UITEST_CAPTURE_MODE"] = "system"
        context = prepare_ui_launch_context(backend_mode="stub", data_root="fixture")
        try:
            env = build_ui_launch_environment(
                context,
                screenshot_dir="/tmp/qwenvoice-screenshots",
            )
            assert env["QWENVOICE_UITEST_CAPTURE_MODE"] == "system"
        finally:
            cleanup_ui_launch_context(context)
            if previous_value is None:
                os.environ.pop("QWENVOICE_UITEST_CAPTURE_MODE", None)
            else:
                os.environ["QWENVOICE_UITEST_CAPTURE_MODE"] = previous_value

    tests = [
        ("parse_profile_preset", test_parse_profile_preset),
        ("parse_profile_custom_text", test_parse_profile_custom_text),
        ("parse_profile_neutral_returns_none", test_parse_profile_neutral_returns_none),
        ("parse_profile_empty_returns_none", test_parse_profile_empty_returns_none),
        ("parse_profile_already_parsed", test_parse_profile_already_parsed),
        ("build_plan_all_emotions", test_build_plan_all_emotions),
        ("build_plan_custom_profile", test_build_plan_custom_profile),
        ("build_plan_strength_override", test_build_plan_strength_override),
        ("plan_clone_instruct_preset", test_plan_clone_instruct_preset),
        ("fingerprint_stable", test_fingerprint_stable),
        ("fingerprint_empty_for_neutral", test_fingerprint_empty_for_neutral),
        ("profile_is_meaningful", test_profile_is_meaningful),
        ("profile_is_custom", test_profile_is_custom),
        ("profile_canonical_intensity", test_profile_canonical_intensity),
        ("profile_starting_strength", test_profile_starting_strength),
        ("profile_fallback_ladder", test_profile_fallback_ladder),
        ("energetic_text", test_energetic_text),
        ("fragile_text", test_fragile_text),
        ("dramatic_text", test_dramatic_text),
        ("calm_text", test_calm_text),
        ("sampling_profiles_keys", test_sampling_profiles_keys),
        ("strength_fallbacks_keys", test_strength_fallbacks_keys),
        ("clone_emotion_instruct_entries", test_clone_emotion_instruct_entries),
        ("ui_state_client_wraps_transport_errors", test_ui_state_client_wraps_transport_errors),
        ("build_ui_transport_failure_result", test_build_ui_transport_failure_result),
        ("click_detection_ignores_matching_final_boundary_transient", test_click_detection_ignores_matching_final_boundary_transient),
        ("click_detection_detects_boundary_not_present_in_final_audio", test_click_detection_detects_boundary_not_present_in_final_audio),
        ("build_ui_launch_environment_defaults_screenshot_capture_mode", test_build_ui_launch_environment_defaults_screenshot_capture_mode),
        ("build_ui_launch_environment_preserves_explicit_capture_mode", test_build_ui_launch_environment_preserves_explicit_capture_mode),
    ]

    for name, fn in tests:
        results.append(_timed_test(name, fn))

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("pipeline_pure_functions", results, duration_ms)


# ---------------------------------------------------------------------------
# Layer (b): Server pure-function tests
# ---------------------------------------------------------------------------

def _load_server_module() -> Any:
    """Load server.py in isolation, patching out heavy imports."""
    # We need to load just the pure functions without triggering MLX imports.
    # server.py executes _resolve_cache_policy() and _load_contract() at module
    # level, which is fine.  The heavy parts (_ensure_mlx) are gated behind
    # function calls.  We can safely import the module as long as the contract
    # JSON is reachable.
    original_path = list(sys.path)
    if str(BACKEND_DIR) not in sys.path:
        sys.path.insert(0, str(BACKEND_DIR))
    try:
        # Use a unique name to get a fresh module each time
        spec = importlib.util.spec_from_file_location(
            f"_server_harness_{id(object())}",
            str(SERVER_PATH),
        )
        if spec is None or spec.loader is None:
            raise ImportError(f"Cannot load server from {SERVER_PATH}")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        sys.path = original_path


def _run_server_tests() -> dict[str, Any]:
    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    try:
        server = _load_server_module()
    except Exception as exc:
        results.append(build_test_result(
            "server_import", passed=False, error=f"Failed to import server.py: {exc}"
        ))
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("server_pure_functions", results, duration_ms)

    # _env_flag tests
    def test_env_flag_true():
        os.environ["_HARNESS_TEST_FLAG"] = "1"
        try:
            assert server._env_flag("_HARNESS_TEST_FLAG") is True
        finally:
            del os.environ["_HARNESS_TEST_FLAG"]

    def test_env_flag_false():
        os.environ["_HARNESS_TEST_FLAG"] = "0"
        try:
            assert server._env_flag("_HARNESS_TEST_FLAG") is False
        finally:
            del os.environ["_HARNESS_TEST_FLAG"]

    def test_env_flag_missing_default():
        key = "_HARNESS_TEST_MISSING"
        os.environ.pop(key, None)
        assert server._env_flag(key, default=True) is True
        assert server._env_flag(key, default=False) is False

    # _has_meaningful_delivery_instruction tests
    def test_meaningful_delivery_various():
        assert server._has_meaningful_delivery_instruction("Speak angrily") is True
        assert server._has_meaningful_delivery_instruction("normal tone") is False
        assert server._has_meaningful_delivery_instruction("Normal tone") is False
        assert server._has_meaningful_delivery_instruction("") is False
        assert server._has_meaningful_delivery_instruction(None) is False
        assert server._has_meaningful_delivery_instruction("  ") is False

    def test_design_prewarm_identity_ignores_instruction():
        calm_key = server._prewarm_identity_key(
            "pro_design",
            "design",
            instruct="Calm narration",
        )
        energetic_key = server._prewarm_identity_key(
            "pro_design",
            "design",
            instruct="Energetic narration",
        )
        assert calm_key == energetic_key

    def test_custom_prewarm_identity_tracks_voice_and_instruction():
        base_key = server._prewarm_identity_key(
            "pro_custom",
            "custom",
            voice="vivian",
            instruct="Conversational",
        )
        changed_voice_key = server._prewarm_identity_key(
            "pro_custom",
            "custom",
            voice="ethan",
            instruct="Conversational",
        )
        changed_instruction_key = server._prewarm_identity_key(
            "pro_custom",
            "custom",
            voice="vivian",
            instruct="Dramatic",
        )
        assert base_key != changed_voice_key
        assert base_key != changed_instruction_key

    def test_collect_generation_result_with_timings_captures_first_yield():
        class FakeResult:
            def __init__(self, value: int) -> None:
                self.value = value

        def fake_generator():
            yield FakeResult(1)
            yield FakeResult(2)

        result, timings = server._collect_generation_result_with_timings(fake_generator())
        assert result.value == 2
        assert timings["first_generator_yield"] >= 0
        assert timings["collect_generation"] >= timings["first_generator_yield"]

    # _infer_legacy_mode tests
    def test_infer_legacy_mode():
        assert server._infer_legacy_mode(voice="ryan") == "custom"
        assert server._infer_legacy_mode(ref_audio="/path/to/audio.wav") == "clone"
        assert server._infer_legacy_mode(voice="ryan", ref_audio="/path") == "clone"
        assert server._infer_legacy_mode() == "design"

    # make_output_path tests
    def test_make_output_path():
        path = server.make_output_path("TestFolder", "Hello world test text")
        assert "TestFolder" in path
        assert path.endswith(".wav")
        # Verify directory was created
        assert os.path.isdir(os.path.dirname(path))

    # get_audio_metadata tests
    def test_get_audio_metadata_missing():
        meta = server.get_audio_metadata("/nonexistent/path.wav")
        assert meta["frames"] is None
        assert meta["duration_seconds"] == 0.0

    def test_get_audio_metadata_valid():
        import struct
        import wave
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp_path = tmp.name
        try:
            with wave.open(tmp_path, "wb") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)
                wf.setframerate(24000)
                wf.writeframes(struct.pack("<" + "h" * 24000, *([0] * 24000)))
            meta = server.get_audio_metadata(tmp_path)
            assert meta["frames"] == 24000
            assert abs(meta["duration_seconds"] - 1.0) < 0.01
        finally:
            os.unlink(tmp_path)

    # _env_float tests
    def test_env_float_valid():
        os.environ["_HARNESS_TEST_FLOAT"] = "0.75"
        try:
            assert server._env_float("_HARNESS_TEST_FLOAT", 0.5) == 0.75
        finally:
            del os.environ["_HARNESS_TEST_FLOAT"]

    def test_env_float_invalid():
        os.environ["_HARNESS_TEST_FLOAT"] = "not_a_number"
        try:
            assert server._env_float("_HARNESS_TEST_FLOAT", 0.5) == 0.5
        finally:
            del os.environ["_HARNESS_TEST_FLOAT"]

    def test_env_float_missing():
        os.environ.pop("_HARNESS_TEST_FLOAT_MISSING", None)
        assert server._env_float("_HARNESS_TEST_FLOAT_MISSING", 0.78) == 0.78

    # Early-abort constant validation
    def test_early_abort_margin_positive():
        assert server.GUIDED_CLONE_EARLY_ABORT_MARGIN > 0
        assert server.GUIDED_CLONE_EARLY_ABORT_MARGIN < server.GUIDED_CLONE_HARD_SIMILARITY

    def test_stream_selected_audio_emits_chunks_before_final_write():
        import numpy as np

        events: list[str] = []
        original_np = server._np
        original_make_session_dir = server._make_stream_session_dir
        original_audio_write_fn = server._audio_write_fn
        original_write_audio_file = server._write_audio_file
        original_get_audio_metadata = server.get_audio_metadata
        original_send_generation_chunk = server.send_generation_chunk

        class FakeResult:
            def __init__(self) -> None:
                self.audio = np.linspace(-0.25, 0.25, 2400, dtype=np.float32)
                self.sample_rate = 24000
                self.token_count = 4
                self.processing_time_seconds = 0.2
                self.peak_memory_usage = 0.1

        with tempfile.TemporaryDirectory(prefix="qwenvoice_stream_selected_audio_") as tmp_dir:
            final_path = os.path.join(tmp_dir, "final.wav")
            session_dir = os.path.join(tmp_dir, "stream")
            os.makedirs(session_dir, exist_ok=True)

            try:
                server._np = np
                server._make_stream_session_dir = lambda request_id: session_dir

                def fake_chunk_write(path, audio, sample_rate, format="wav"):
                    events.append(f"chunk_write:{os.path.basename(path)}")

                def fake_final_write(path, audio, sample_rate):
                    events.append("final_write")
                    with open(path, "wb") as handle:
                        handle.write(b"RIFF")

                def fake_get_audio_metadata(path):
                    events.append("metadata_lookup")
                    return {"duration_seconds": 0.1}

                def fake_send_generation_chunk(**kwargs):
                    events.append(f"notify:{kwargs['chunk_index']}")

                server._audio_write_fn = fake_chunk_write
                server._write_audio_file = fake_final_write
                server.get_audio_metadata = fake_get_audio_metadata
                server.send_generation_chunk = fake_send_generation_chunk

                response, _, _, breakdown = server._stream_selected_audio(
                    FakeResult(),
                    request_id="req-1",
                    final_path=final_path,
                    streaming_interval=0.05,
                )
            finally:
                server._np = original_np
                server._make_stream_session_dir = original_make_session_dir
                server._audio_write_fn = original_audio_write_fn
                server._write_audio_file = original_write_audio_file
                server.get_audio_metadata = original_get_audio_metadata
                server.send_generation_chunk = original_send_generation_chunk

        assert events[0].startswith("chunk_write:")
        assert "final_write" in events
        assert events.index("notify:0") < events.index("final_write")
        assert response["stream_session_dir"] == session_dir
        assert breakdown["first_stream_chunk"] >= 0

    tests = [
        ("env_flag_true", test_env_flag_true),
        ("env_flag_false", test_env_flag_false),
        ("env_flag_missing_default", test_env_flag_missing_default),
        ("env_float_valid", test_env_float_valid),
        ("env_float_invalid", test_env_float_invalid),
        ("env_float_missing", test_env_float_missing),
        ("early_abort_margin_positive", test_early_abort_margin_positive),
        ("meaningful_delivery_instruction", test_meaningful_delivery_various),
        ("design_prewarm_identity_ignores_instruction", test_design_prewarm_identity_ignores_instruction),
        ("custom_prewarm_identity_tracks_shape", test_custom_prewarm_identity_tracks_voice_and_instruction),
        ("collect_generation_result_with_timings", test_collect_generation_result_with_timings_captures_first_yield),
        ("stream_selected_audio_emits_chunks_before_final_write", test_stream_selected_audio_emits_chunks_before_final_write),
        ("infer_legacy_mode", test_infer_legacy_mode),
        ("make_output_path", test_make_output_path),
        ("get_audio_metadata_missing", test_get_audio_metadata_missing),
        ("get_audio_metadata_valid", test_get_audio_metadata_valid),
    ]

    for name, fn in tests:
        results.append(_timed_test(name, fn))

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("server_pure_functions", results, duration_ms)


# ---------------------------------------------------------------------------
# Layer (c): RPC integration tests
# ---------------------------------------------------------------------------

def _run_rpc_tests(python_path: str | None) -> dict[str, Any]:
    start = time.perf_counter()
    results: list[dict[str, Any]] = []
    app_support_tmp: tempfile.TemporaryDirectory[str] | None = None

    try:
        resolved_python = resolve_backend_python(python_path)
    except RuntimeError as exc:
        results.append(build_test_result(
            "backend_python_available", passed=False,
            skip_reason=str(exc),
        ))
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("rpc_integration", results, duration_ms)

    installed_models = [mid for mid in model_ids() if model_is_installed(mid)]
    if not installed_models:
        results.append(build_test_result(
            "model_available", passed=True,
            skip_reason="No models installed — skipping RPC tests",
        ))
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("rpc_integration", results, duration_ms)

    from .backend_client import BackendClient

    client: BackendClient | None = None
    try:
        app_support_tmp = tempfile.TemporaryDirectory(prefix="qwenvoice_rpc_test_")
        app_support_dir = Path(app_support_tmp.name)
        models_dir = app_support_dir / "models"
        try:
            models_dir.symlink_to(APP_MODELS_DIR, target_is_directory=True)
        except OSError:
            shutil.copytree(APP_MODELS_DIR, models_dir)

        # Test: backend starts
        def test_backend_starts():
            nonlocal client
            client = BackendClient(resolved_python)
            client.start()

        results.append(_timed_test("backend_starts", test_backend_starts))
        if not results[-1]["passed"]:
            duration_ms = int((time.perf_counter() - start) * 1000)
            return build_suite_result("rpc_integration", results, duration_ms)

        assert client is not None

        # Test: ping
        def test_ping():
            result = client.call("ping", timeout=10)
            assert result.get("status") == "ok", f"Expected status ok, got {result}"

        results.append(_timed_test("ping", test_ping))

        # Test: init
        def test_init():
            result = client.call("init", {"app_support_dir": str(app_support_dir)}, timeout=30)
            assert "status" in result or result == {}, f"Unexpected init result: {result}"

        results.append(_timed_test("init", test_init))

        # Test: get_speakers
        def test_get_speakers():
            result = client.call("get_speakers", timeout=10)
            backend_speakers = []
            if isinstance(result, dict):
                for group_name in sorted(result.keys()):
                    group = result[group_name]
                    if isinstance(group, list):
                        backend_speakers.extend(group)
            contract_speakers = speaker_list()
            assert set(backend_speakers) == set(contract_speakers), (
                f"Speaker mismatch: backend={backend_speakers}, contract={contract_speakers}"
            )

        results.append(_timed_test("get_speakers_matches_contract", test_get_speakers))

        # Test: get_model_info
        def test_get_model_info():
            result = client.call("get_model_info", timeout=10)
            contract_ids = set(model_ids())
            if isinstance(result, list):
                backend_ids = {m.get("id") or m.get("model_id") for m in result if isinstance(m, dict)}
            elif isinstance(result, dict) and "models" in result:
                backend_ids = {m.get("id") or m.get("model_id") for m in result["models"] if isinstance(m, dict)}
            else:
                backend_ids = set()
            assert backend_ids == contract_ids, (
                f"Model ID mismatch: backend={backend_ids}, contract={contract_ids}"
            )

        results.append(_timed_test("get_model_info_matches_contract", test_get_model_info))

        # Test: load_model for each installed model
        for mid in installed_models:
            def test_load(model_id: str = mid):
                result = client.call("load_model", {"model_id": model_id}, timeout=120)
                assert result is not None

            results.append(_timed_test(f"load_model_{mid}", test_load))

            # Test: generate smoke test per mode
            contract = load_contract()
            model_def = next((m for m in contract["models"] if m["id"] == mid), None)
            if model_def:
                mode = model_def["mode"]

                def test_generate(m: str = mode, model_id: str = mid):
                    with tempfile.TemporaryDirectory() as tmp:
                        output_path = os.path.join(tmp, "test_output.wav")
                        params: dict[str, Any] = {
                            "text": "Hello.",
                            "output_path": output_path,
                        }
                        if m == "custom":
                            params["voice"] = "vivian"
                        elif m == "clone":
                            # Skip if no reference audio available
                            return {"skip_reason": "No reference audio for clone smoke test"}
                        elif m == "design":
                            params["instruct"] = "A young female speaker"

                        result = client.call("generate", params, timeout=300)
                        actual_path = result.get("audio_path", output_path)
                        assert Path(actual_path).exists(), f"Output file not found: {actual_path}"
                        assert Path(actual_path).stat().st_size > 1024, "Output too small"

                results.append(_timed_test(f"generate_smoke_{mode}", test_generate))

            # Unload after testing
            def test_unload():
                result = client.call("unload_model", timeout=30)
                assert result is not None

            results.append(_timed_test(f"unload_model_{mid}", test_unload))

        # Test: unknown method returns error
        def test_unknown_method():
            try:
                client.call("nonexistent_method_xyz", timeout=10)
                raise AssertionError("Expected error for unknown method")
            except RuntimeError:
                pass  # Expected

        results.append(_timed_test("unknown_method_error", test_unknown_method))

        # Test: list_voices
        def test_list_voices():
            result = client.call("list_voices", timeout=10)
            assert isinstance(result, (list, dict)), f"Expected list or dict, got {type(result)}"

        results.append(_timed_test("list_voices", test_list_voices))

    finally:
        if client is not None:
            client.stop()
        if app_support_tmp is not None:
            app_support_tmp.cleanup()

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("rpc_integration", results, duration_ms)


# ---------------------------------------------------------------------------
# Layer (d): Contract cross-validation + Swift tests
# ---------------------------------------------------------------------------

def _run_contract_tests(python_path: str | None = None) -> dict[str, Any]:
    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    # Contract JSON structure
    def test_contract_structure():
        contract = load_contract()
        assert "models" in contract and len(contract["models"]) > 0
        assert "speakers" in contract and len(contract["speakers"]) > 0
        assert "defaultSpeaker" in contract

    def test_default_speaker_in_list():
        contract = load_contract()
        all_speakers = speaker_list()
        assert contract["defaultSpeaker"] in all_speakers

    def test_no_duplicate_model_ids():
        contract = load_contract()
        ids = [m["id"] for m in contract["models"]]
        assert len(ids) == len(set(ids)), f"Duplicate model IDs: {ids}"

    def test_no_duplicate_modes():
        contract = load_contract()
        modes = [m["mode"] for m in contract["models"]]
        assert len(modes) == len(set(modes)), f"Duplicate modes: {modes}"

    def test_installed_models_have_required_files():
        contract = load_contract()
        for model in contract["models"]:
            mid = model["id"]
            if not model_is_installed(mid):
                continue
            model_dir = APP_MODELS_DIR / model["folder"]
            for rp in model["requiredRelativePaths"]:
                assert (model_dir / rp).exists(), f"Missing required file: {model_dir / rp}"

    def test_swift_references_model_ids():
        # Grep TTSContract.swift for model IDs to verify Swift-side references
        contract = load_contract()
        tts_contract_path = PROJECT_DIR / "Sources" / "Models" / "TTSContract.swift"
        tts_model_path = PROJECT_DIR / "Sources" / "Models" / "TTSModel.swift"
        # Just verify these files exist and reference the generation modes
        assert tts_contract_path.exists(), "TTSContract.swift not found"
        assert tts_model_path.exists(), "TTSModel.swift not found"
        model_content = tts_model_path.read_text(encoding="utf-8")
        for model in contract["models"]:
            mode = model["mode"]
            assert mode in model_content, f"Mode '{mode}' not referenced in TTSModel.swift"

    tests = [
        ("contract_structure_valid", test_contract_structure),
        ("default_speaker_in_list", test_default_speaker_in_list),
        ("no_duplicate_model_ids", test_no_duplicate_model_ids),
        ("no_duplicate_modes", test_no_duplicate_modes),
        ("installed_models_required_files", test_installed_models_have_required_files),
        ("swift_references_model_ids", test_swift_references_model_ids),
    ]

    for name, fn in tests:
        results.append(_timed_test(name, fn))

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("contract_validation", results, duration_ms)


def _ui_ready_field(backend_mode: str) -> str:
    return "interactiveReady" if backend_mode == "live" else "isReady"


def _ui_ready_timeout(backend_mode: str) -> float:
    return 60.0 if backend_mode == "live" else 15.0


def _wait_for_ui_launch_ready(
    client: Any,
    backend_mode: str,
) -> tuple[bool, dict[str, Any], str]:
    ready_field = _ui_ready_field(backend_mode)
    return client.wait_for_ready(
        timeout=_ui_ready_timeout(backend_mode),
        ready_field=ready_field,
    )


def _append_live_preflight_results(results: list[dict[str, Any]], backend_mode: str) -> bool:
    return _append_live_preflight_results_for_target(
        results,
        backend_mode,
        requires_app_support_python=True,
        requires_models=True,
    )


def _append_live_preflight_results_for_target(
    results: list[dict[str, Any]],
    backend_mode: str,
    *,
    requires_app_support_python: bool,
    requires_models: bool,
) -> bool:
    if backend_mode != "live":
        results.append(build_test_result(
            "ui_launch_mode",
            passed=True,
            details={"backend_mode": backend_mode},
        ))
        return True

    prerequisites = check_live_prerequisites()
    python_ok = prerequisites["python_exists"]
    models_ok = bool(prerequisites["installed_models"])
    results.append(build_test_result(
        "live_backend_python_available",
        passed=python_ok or not requires_app_support_python,
        skip_reason=None if requires_app_support_python or python_ok else "Packaged release targets use bundled Python instead of the app-support venv",
        details={
            "python_path": prerequisites["python_path"],
            "required_for_target": requires_app_support_python,
        },
    ))
    results.append(build_test_result(
        "live_models_available",
        passed=models_ok or not requires_models,
        skip_reason=None if requires_models or models_ok else "Installed models are only required for live generation checks",
        details={
            "models_dir": prerequisites["models_dir"],
            "installed_models": prerequisites["installed_models"],
            "required_for_target": requires_models,
        },
    ))
    return (models_ok or not requires_models) and (python_ok or not requires_app_support_python)


def _release_thresholds_for(mode: str) -> dict[str, int]:
    if mode == "clone":
        return {
            "running_ms": 1_000,
            "first_chunk_ms": 15_000,
            "finalized_ms": 30_000,
            "idle_ms": 35_000,
        }
    return {
        "running_ms": 1_000,
        "first_chunk_ms": 10_000,
        "finalized_ms": 20_000,
        "idle_ms": 25_000,
    }


def _format_runtime_expectation(target: UIAppTarget) -> tuple[str, str]:
    resources_dir = target.app_bundle / "Contents" / "Resources"
    return (
        str(resources_dir / "python") + "/",
        str(resources_dir / "ffmpeg"),
    )


def _normalize_runtime_path(path: str) -> str:
    if not path:
        return ""
    return os.path.realpath(path)


def _append_runtime_dependency_results(
    results: list[dict[str, Any]],
    state: dict[str, Any],
    app_target: UIAppTarget | None,
) -> None:
    if app_target is None or app_target.source == "build":
        return

    expected_python_prefix, expected_ffmpeg_path = _format_runtime_expectation(app_target)
    normalized_python_prefix = _normalize_runtime_path(expected_python_prefix.rstrip("/")) + "/"
    normalized_ffmpeg_path = _normalize_runtime_path(expected_ffmpeg_path)
    runtime_source = state.get("runtimeSource")
    active_python_path = state.get("activePythonPath", "")
    active_ffmpeg_path = state.get("activeFFmpegPath", "")
    normalized_active_python_path = _normalize_runtime_path(active_python_path)
    normalized_active_ffmpeg_path = _normalize_runtime_path(active_ffmpeg_path)

    results.append(build_test_result(
        "bundled_runtime_source",
        passed=runtime_source == "bundled",
        details={
            "runtimeSource": runtime_source,
            "expected": "bundled",
        },
    ))
    results.append(build_test_result(
        "bundled_python_path",
        passed=normalized_active_python_path.startswith(normalized_python_prefix),
        details={
            "activePythonPath": active_python_path,
            "expectedPrefix": expected_python_prefix,
            "normalizedActivePythonPath": normalized_active_python_path,
            "normalizedExpectedPrefix": normalized_python_prefix,
        },
    ))
    results.append(build_test_result(
        "bundled_ffmpeg_path",
        passed=normalized_active_ffmpeg_path == normalized_ffmpeg_path,
        details={
            "activeFFmpegPath": active_ffmpeg_path,
            "expected": expected_ffmpeg_path,
            "normalizedActiveFFmpegPath": normalized_active_ffmpeg_path,
            "normalizedExpected": normalized_ffmpeg_path,
        },
    ))


def _resolve_test_app_target(
    *,
    app_bundle: str | None = None,
    dmg: str | None = None,
    app_target: UIAppTarget | None = None,
) -> tuple[bool, UIAppTarget | None, dict[str, Any]]:
    if app_target is not None:
        return True, app_target, {
            "source": app_target.source,
            "app_bundle": str(app_target.app_bundle),
            "app_binary": str(app_target.app_binary),
            "variant_id": app_target.variant_id,
            "ui_profile": app_target.ui_profile,
        }
    return resolve_ui_app_target(app_bundle=app_bundle, dmg=dmg)


def _prefix_suite(suite: dict[str, Any], prefix: str) -> dict[str, Any]:
    prefixed = dict(suite)
    prefixed["name"] = f"{prefix}_{suite['name']}"
    prefixed["results"] = [
        {
            **result,
            "name": f"{prefix}_{result['name']}",
        }
        for result in suite.get("results", [])
    ]
    return prefixed


def _run_release_bundle_verification(
    app_target: UIAppTarget,
    *,
    variant_label: str,
) -> dict[str, Any]:
    start = time.perf_counter()
    results: list[dict[str, Any]] = []
    verify_script = PROJECT_DIR / "scripts" / "verify_release_bundle.sh"
    proc = subprocess.run(
        ["bash", str(verify_script), str(app_target.app_bundle)],
        capture_output=True,
        text=True,
        cwd=str(PROJECT_DIR),
        timeout=180,
    )
    details = {
        "app_bundle": str(app_target.app_bundle),
        "variant_id": app_target.variant_id,
        "ui_profile": app_target.ui_profile,
    }
    if proc.stdout:
        details["stdout_tail"] = proc.stdout.splitlines()[-20:]
    if proc.stderr:
        details["stderr_tail"] = proc.stderr.splitlines()[-20:]
    results.append(build_test_result(
        "verify_release_bundle",
        passed=proc.returncode == 0,
        error=None if proc.returncode == 0 else f"verify_release_bundle.sh exited with {proc.returncode}",
        details=details,
    ))
    duration_ms = int((time.perf_counter() - start) * 1000)
    return _prefix_suite(build_suite_result("release_bundle_verification", results, duration_ms), variant_label)


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


def _run_ui_tests(
    backend_mode: str = "live",
    data_root: str = "fixture",
    *,
    app_bundle: str | None = None,
    dmg: str | None = None,
    app_target: UIAppTarget | None = None,
) -> dict[str, Any]:
    """Run UI smoke coverage via the test-state server."""
    from .ui_state_client import UIStateClient, UIStateClientError

    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    resolved, target, target_details = _resolve_test_app_target(
        app_bundle=app_bundle,
        dmg=dmg,
        app_target=app_target,
    )
    results.append(build_test_result("resolve_app_target", passed=resolved, details=target_details))
    if not resolved or target is None:
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("ui_http_tests", results, duration_ms)

    if not _append_live_preflight_results_for_target(
        results,
        backend_mode,
        requires_app_support_python=target.source == "build",
        requires_models=False,
    ):
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("ui_http_tests", results, duration_ms)

    context = prepare_ui_launch_context(backend_mode=backend_mode, data_root=data_root)
    results.append(build_test_result(
        "ui_launch_context",
        passed=True,
        details=describe_launch_context(context),
    ))

    app_proc: subprocess.Popen[Any] | None = None
    client = UIStateClient()
    try:
        kill_running_app_instances()
        results.append(build_test_result("terminate_existing_instances", passed=True))

        eprint("  Launching app with test state server...")
        env = build_ui_launch_environment(context)
        launch_start = time.perf_counter()
        app_proc = launch_ui_app(str(target.app_binary), env)
        ready, state, failure_reason = _wait_for_ui_launch_ready(client, backend_mode)
        ready_ms = int((time.perf_counter() - launch_start) * 1000)
        results.append(build_test_result(
            "app_launch_to_ready",
            passed=ready,
            duration_ms=ready_ms,
            details={
                "ready_ms": ready_ms,
                "ready_field": _ui_ready_field(backend_mode),
                "failure_reason": failure_reason,
                "state": state,
            },
        ))
        if not ready:
            duration_ms = int((time.perf_counter() - start) * 1000)
            return build_suite_result("ui_http_tests", results, duration_ms)

        _append_runtime_dependency_results(results, state, target)

        disabled_sidebar_items = {
            item for item in state.get("disabledSidebarItems", "").split(",")
            if item and item != "none"
        }
        expected_default_screen = (
            "screen_models"
            if "sidebar_customVoice" in disabled_sidebar_items
            else "screen_customVoice"
        )
        default_ok = state.get("activeScreen") == expected_default_screen
        results.append(build_test_result(
            "default_screen_is_customVoice",
            passed=default_ok,
            details={
                "activeScreen": state.get("activeScreen"),
                "expected": expected_default_screen,
                "disabledSidebarItems": sorted(disabled_sidebar_items),
            },
        ))

        screens = [
            ("history", "screen_history", "sidebar_history"),
            ("voices", "screen_voices", "sidebar_voices"),
            ("models", "screen_models", "sidebar_models"),
            ("voiceDesign", "screen_voiceDesign", "sidebar_voiceDesign"),
            ("voiceCloning", "screen_voiceCloning", "sidebar_voiceCloning"),
            ("customVoice", "screen_customVoice", "sidebar_customVoice"),
        ]
        for screen_arg, expected_id, sidebar_id in screens:
            if sidebar_id in disabled_sidebar_items:
                results.append(build_test_result(
                    f"screen_{screen_arg}",
                    passed=True,
                    skip_reason=f"{sidebar_id} is disabled in the current launch context",
                    details={"disabledSidebarItems": sorted(disabled_sidebar_items)},
                ))
                continue
            nav_start = time.perf_counter()
            try:
                state = client.navigate(screen_arg)
            except UIStateClientError as exc:
                results.append(_build_ui_transport_failure_result(
                    f"screen_{screen_arg}",
                    exc,
                    last_state=state,
                ))
                continue
            navigated, nav_state = client.wait_for_navigation(
                expected_id,
                timeout=15 if backend_mode == "live" else 5,
            )
            if nav_state:
                state = nav_state
            nav_ms = int((time.perf_counter() - nav_start) * 1000)
            results.append(build_test_result(
                f"screen_{screen_arg}",
                passed=navigated and nav_state.get("activeScreen") == expected_id,
                duration_ms=nav_ms,
                details={
                    "expected": expected_id,
                    "actual": nav_state.get("activeScreen"),
                    "navigation_wall_ms": nav_ms,
                    "app_navigation_duration_ms": nav_state.get("lastNavigationDurationMS"),
                    "backend_mode": backend_mode,
                    "data_root": data_root,
                },
            ))

        if "sidebar_customVoice" not in disabled_sidebar_items:
            try:
                state = client.navigate("customVoice")
                preview_started = client.start_preview("customVoice", "Hello there buddy")
                state = preview_started
            except UIStateClientError as exc:
                preview_started = None
                results.append(_build_ui_transport_failure_result(
                    "custom_voice_preview_start",
                    exc,
                    last_state=state,
                ))
            if preview_started is not None:
                results.append(build_test_result(
                    "custom_voice_preview_start",
                    passed=preview_started.get("activeScreen") == "screen_customVoice",
                    details={
                        "activeScreen": preview_started.get("activeScreen"),
                        "text": preview_started.get("text"),
                        "selectedSpeaker": preview_started.get("selectedSpeaker"),
                    },
                ))

                if backend_mode == "stub":
                    preview_completed = _wait_for_stub_event(
                        str(context.app_support_dir),
                        "custom-generate-success",
                    )
                    preview_finalized = _wait_for_stub_event(
                        str(context.app_support_dir),
                        "sidebar-preview-finalized",
                    )
                    events_dir = str(Path(context.app_support_dir) / ".stub-events")
                    results.append(build_test_result(
                        "custom_voice_preview_inline_status",
                        passed=preview_completed,
                        details={
                            "stub_event": "custom-generate-success",
                            "events_dir": events_dir,
                        },
                    ))
                    results.append(build_test_result(
                        "custom_voice_preview_status_resets",
                        passed=preview_finalized,
                        details={
                            "stub_event": "sidebar-preview-finalized",
                            "events_dir": events_dir,
                        },
                    ))
                else:
                    inline_visible, inline_state = client.wait_for_state(
                        lambda state: (
                            state.get("sidebarInlineStatusVisible") is True
                            and state.get("sidebarStatusKind") == "running"
                            and state.get("sidebarStatusPresentation") == "inlinePlayer"
                        ),
                        timeout=45 if backend_mode == "live" else 15,
                    )
                    results.append(build_test_result(
                        "custom_voice_preview_inline_status",
                        passed=inline_visible,
                        details={
                            "sidebarStatusKind": inline_state.get("sidebarStatusKind"),
                            "sidebarStatusLabel": inline_state.get("sidebarStatusLabel"),
                            "sidebarStatusPresentation": inline_state.get("sidebarStatusPresentation"),
                            "sidebarInlineStatusVisible": inline_state.get("sidebarInlineStatusVisible"),
                            "sidebarStandaloneStatusVisible": inline_state.get("sidebarStandaloneStatusVisible"),
                            "isGenerating": inline_state.get("isGenerating"),
                        },
                    ))

                    reset_to_idle, idle_state = client.wait_for_state(
                        lambda state: (
                            state.get("sidebarStatusKind") == "idle"
                            and state.get("sidebarInlineStatusVisible") is False
                            and state.get("sidebarStandaloneStatusVisible") is True
                        ),
                        timeout=120 if backend_mode == "live" else 30,
                    )
                    results.append(build_test_result(
                        "custom_voice_preview_status_resets",
                        passed=reset_to_idle,
                        details={
                            "sidebarStatusKind": idle_state.get("sidebarStatusKind"),
                            "sidebarStatusLabel": idle_state.get("sidebarStatusLabel"),
                            "sidebarStatusPresentation": idle_state.get("sidebarStatusPresentation"),
                            "sidebarInlineStatusVisible": idle_state.get("sidebarInlineStatusVisible"),
                            "sidebarStandaloneStatusVisible": idle_state.get("sidebarStandaloneStatusVisible"),
                            "isGenerating": idle_state.get("isGenerating"),
                        },
                    ))
    finally:
        _terminate_ui_process(app_proc)
        cleanup_ui_launch_context(context)
        if app_target is None:
            cleanup_ui_app_target(target)

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("ui_http_tests", results, duration_ms)


def _run_design_tests(
    backend_mode: str = "live",
    data_root: str = "fixture",
    *,
    app_bundle: str | None = None,
    dmg: str | None = None,
    app_target: UIAppTarget | None = None,
    force_capture_only: bool | None = None,
) -> dict[str, Any]:
    """Launch through the UI path and compare captures when baselines exist."""
    from .ui_state_client import UIStateClient, UIStateClientError

    start = time.perf_counter()
    results: list[dict[str, Any]] = []
    capture_only = os.environ.get("QWENVOICE_UI_DESIGN_CAPTURE_ONLY", "").strip().lower() in {
        "1", "true", "yes", "on",
    }
    baselines_dir = PROJECT_DIR / "tests" / "screenshots" / "baselines"
    captures_dir = PROJECT_DIR / "build" / "test" / "screenshots"
    diffs_dir = PROJECT_DIR / "tests" / "screenshots" / "diffs"
    capture_targets = [
        ("customVoice", "screen_customVoice", "screenshot_customVoice_default", "sidebar_customVoice"),
        ("voiceDesign", "screen_voiceDesign", "screenshot_voiceDesign_default", "sidebar_voiceDesign"),
        ("voiceCloning", "screen_voiceCloning", "screenshot_voiceCloning_default", "sidebar_voiceCloning"),
        ("history", "screen_history", "screenshot_history_empty", "sidebar_history"),
        ("voices", "screen_voices", "screenshot_voices_empty", "sidebar_voices"),
        ("models", "screen_models", "screenshot_models_default", "sidebar_models"),
    ]
    shutil.rmtree(captures_dir, ignore_errors=True)
    os.makedirs(captures_dir, exist_ok=True)
    os.makedirs(diffs_dir, exist_ok=True)

    resolved, target, target_details = _resolve_test_app_target(
        app_bundle=app_bundle,
        dmg=dmg,
        app_target=app_target,
    )
    results.append(build_test_result("resolve_app_target", passed=resolved, details=target_details))
    if not resolved or target is None:
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("design_comparison", results, duration_ms)

    if not _append_live_preflight_results_for_target(
        results,
        backend_mode,
        requires_app_support_python=target.source == "build",
        requires_models=False,
    ):
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("design_comparison", results, duration_ms)

    context = prepare_ui_launch_context(backend_mode=backend_mode, data_root=data_root)
    results.append(build_test_result(
        "design_launch_context",
        passed=True,
        details=describe_launch_context(context),
    ))

    app_proc: subprocess.Popen[Any] | None = None
    client = UIStateClient()
    try:
        kill_running_app_instances()
        env = build_ui_launch_environment(context, screenshot_dir=str(captures_dir))
        launch_start = time.perf_counter()
        app_proc = launch_ui_app(str(target.app_binary), env)
        ready, state, failure_reason = _wait_for_ui_launch_ready(client, backend_mode)
        ready_ms = int((time.perf_counter() - launch_start) * 1000)
        results.append(build_test_result(
            "design_launch_to_ready",
            passed=ready,
            duration_ms=ready_ms,
            details={
                "ready_ms": ready_ms,
                "ready_field": _ui_ready_field(backend_mode),
                "failure_reason": failure_reason,
                "state": state,
            },
        ))
        if not ready:
            duration_ms = int((time.perf_counter() - start) * 1000)
            return build_suite_result("design_comparison", results, duration_ms)

        _append_runtime_dependency_results(results, state, target)
        disabled_sidebar_items = {
            item for item in state.get("disabledSidebarItems", "").split(",")
            if item and item != "none"
        }

        for screen_arg, expected_id, screenshot_name, sidebar_id in capture_targets:
            if sidebar_id in disabled_sidebar_items:
                results.append(build_test_result(
                    f"capture_prepare_{screenshot_name}",
                    passed=True,
                    skip_reason=f"{sidebar_id} is disabled in the current launch context",
                    details={"disabledSidebarItems": sorted(disabled_sidebar_items)},
                ))
                continue
            try:
                state = client.navigate(screen_arg)
            except UIStateClientError as exc:
                results.append(_build_ui_transport_failure_result(
                    f"capture_prepare_{screenshot_name}",
                    exc,
                    last_state=state,
                ))
                continue

            if state.get("activeScreen") == expected_id:
                navigated = True
            else:
                navigated, nav_state = client.wait_for_navigation(
                    expected_id,
                    timeout=10 if backend_mode == "live" else 5,
                )
                if nav_state:
                    state = nav_state
            results.append(build_test_result(
                f"capture_prepare_{screenshot_name}",
                passed=navigated and state.get("activeScreen") == expected_id,
                details={
                    "expected": expected_id,
                    "actual": state.get("activeScreen"),
                },
            ))
            if not navigated or state.get("activeScreen") != expected_id:
                continue

            time.sleep(0.5)
            try:
                capture_state = client.capture_screenshot(screenshot_name)
            except UIStateClientError as exc:
                results.append(_build_ui_transport_failure_result(
                    f"capture_{screenshot_name}",
                    exc,
                    last_state=state,
                ))
                continue

            results.append(build_test_result(
                f"capture_{screenshot_name}",
                passed=bool(capture_state.get("screenshotCaptured")),
                details={
                    "screenshotCaptured": capture_state.get("screenshotCaptured"),
                    "screenshotName": capture_state.get("screenshotName"),
                    "screenshotCaptureMode": capture_state.get("screenshotCaptureMode"),
                    "screenshotFailureReason": capture_state.get("screenshotFailureReason"),
                    "captures_dir": str(captures_dir),
                },
            ))

        variant_baselines_dir = baselines_dir / target.variant_id if target.variant_id else None
        has_variant_baselines = bool(
            variant_baselines_dir is not None
            and variant_baselines_dir.is_dir()
            and any(variant_baselines_dir.glob("*.png"))
        )
        packaged_capture_only = (
            target.source != "build"
            and not has_variant_baselines
        )
        capture_only = force_capture_only if force_capture_only is not None else (capture_only or packaged_capture_only)

        if capture_only:
            results.append(build_test_result(
                "design_capture_only",
                passed=True,
                skip_reason="Baseline comparison disabled for this environment",
                details={
                    "captures_dir": str(captures_dir),
                    "variant_id": target.variant_id,
                    "variant_baselines_dir": str(variant_baselines_dir) if variant_baselines_dir else None,
                },
            ))
            duration_ms = int((time.perf_counter() - start) * 1000)
            return build_suite_result("design_comparison", results, duration_ms)

        active_baselines_dir = variant_baselines_dir if has_variant_baselines and variant_baselines_dir is not None else baselines_dir
        baseline_names = sorted(
            name for name in os.listdir(active_baselines_dir)
            if name.endswith(".png")
        ) if active_baselines_dir.is_dir() else []
        if not baseline_names:
            results.append(build_test_result(
                "missing_baselines",
                passed=False,
                details={
                    "error": "missing_baselines",
                    "captures_dir": str(captures_dir),
                    "baselines_dir": str(active_baselines_dir),
                },
            ))
            duration_ms = int((time.perf_counter() - start) * 1000)
            return build_suite_result("design_comparison", results, duration_ms)

        try:
            from .screenshot_diff import compare_screenshots
        except ImportError:
            results.append(build_test_result(
                "import_error",
                passed=False,
                details={"error": "screenshot_diff_import_failed"},
            ))
            duration_ms = int((time.perf_counter() - start) * 1000)
            return build_suite_result("design_comparison", results, duration_ms)

        for name in baseline_names:
            baseline_path = active_baselines_dir / name
            capture_path = captures_dir / name
            diff_path = diffs_dir / name.replace(".png", "_diff.png")

            if not capture_path.exists():
                results.append(build_test_result(name, passed=False, details={"error": "capture_not_found"}))
                continue

            diff_result = compare_screenshots(
                str(baseline_path),
                str(capture_path),
                str(diff_path),
                max_diff_percent=1.0,
            )
            results.append(build_test_result(name, passed=diff_result["passed"], details=diff_result))
    finally:
        _terminate_ui_process(app_proc)
        cleanup_ui_launch_context(context)
        if app_target is None:
            cleanup_ui_app_target(target)

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("design_comparison", results, duration_ms)


def _run_perf_audit(
    backend_mode: str = "live",
    data_root: str = "fixture",
    *,
    app_bundle: str | None = None,
    dmg: str | None = None,
    app_target: UIAppTarget | None = None,
    enforce_thresholds: bool | None = None,
) -> dict[str, Any]:
    """Run live-backed launch and sidebar navigation measurements."""
    from .ui_state_client import UIStateClient, UIStateClientError

    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    resolved, target, target_details = _resolve_test_app_target(
        app_bundle=app_bundle,
        dmg=dmg,
        app_target=app_target,
    )
    results.append(build_test_result("resolve_app_target", passed=resolved, details=target_details))
    if not resolved or target is None:
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("perf_audit", results, duration_ms)

    if not _append_live_preflight_results_for_target(
        results,
        backend_mode,
        requires_app_support_python=target.source == "build",
        requires_models=False,
    ):
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("perf_audit", results, duration_ms)

    context = prepare_ui_launch_context(backend_mode=backend_mode, data_root=data_root)
    results.append(build_test_result(
        "perf_launch_context",
        passed=True,
        details=describe_launch_context(context),
    ))

    app_proc: subprocess.Popen[Any] | None = None
    client = UIStateClient()
    try:
        kill_running_app_instances()
        env = build_ui_launch_environment(context)
        launch_start = time.perf_counter()
        app_proc = launch_ui_app(str(target.app_binary), env)
        ready, ready_state, failure_reason = _wait_for_ui_launch_ready(client, backend_mode)
        ready_ms = int((time.perf_counter() - launch_start) * 1000)
        launch_threshold_ms = 20_000
        should_enforce = enforce_thresholds if enforce_thresholds is not None else target.source != "build"
        results.append(build_test_result(
            "launch_to_interactive_ready",
            passed=ready and (not should_enforce or ready_ms <= launch_threshold_ms),
            duration_ms=ready_ms,
            details={
                "ready_ms": ready_ms,
                "ready_field": _ui_ready_field(backend_mode),
                "failure_reason": failure_reason,
                "state": ready_state,
                "threshold_ms": launch_threshold_ms if should_enforce else None,
            },
        ))
        if not ready:
            duration_ms = int((time.perf_counter() - start) * 1000)
            return build_suite_result("perf_audit", results, duration_ms)

        _append_runtime_dependency_results(results, ready_state, target)
        disabled_sidebar_items = {
            item for item in ready_state.get("disabledSidebarItems", "").split(",")
            if item and item != "none"
        }

        navigation_loop = [
            ("voiceDesign", "screen_voiceDesign", "sidebar_voiceDesign"),
            ("voiceCloning", "screen_voiceCloning", "sidebar_voiceCloning"),
            ("history", "screen_history", "sidebar_history"),
            ("models", "screen_models", "sidebar_models"),
            ("customVoice", "screen_customVoice", "sidebar_customVoice"),
        ]
        aggregate_wall: dict[str, list[int]] = {screen: [] for _, screen, _ in navigation_loop}
        aggregate_app: dict[str, list[int]] = {screen: [] for _, screen, _ in navigation_loop}
        last_state = ready_state

        for run_index in range(2):
            for screen_arg, expected_id, sidebar_id in navigation_loop:
                if sidebar_id in disabled_sidebar_items:
                    results.append(build_test_result(
                        f"sidebar_{screen_arg}_run_{run_index + 1}",
                        passed=True,
                        skip_reason=f"{sidebar_id} is disabled in the current launch context",
                        details={"disabledSidebarItems": sorted(disabled_sidebar_items)},
                    ))
                    continue
                nav_start = time.perf_counter()
                try:
                    last_state = client.navigate(screen_arg)
                except UIStateClientError as exc:
                    results.append(_build_ui_transport_failure_result(
                        f"sidebar_{screen_arg}_run_{run_index + 1}",
                        exc,
                        last_state=last_state,
                    ))
                    continue
                navigated, nav_state = client.wait_for_navigation(expected_id, timeout=15)
                wall_ms = int((time.perf_counter() - nav_start) * 1000)
                if nav_state:
                    last_state = nav_state
                app_duration = nav_state.get("lastNavigationDurationMS")
                if isinstance(app_duration, int):
                    aggregate_app[expected_id].append(app_duration)
                aggregate_wall[expected_id].append(wall_ms)
                within_threshold = wall_ms <= 1_500
                results.append(build_test_result(
                    f"sidebar_{screen_arg}_run_{run_index + 1}",
                    passed=navigated and nav_state.get("activeScreen") == expected_id and (not should_enforce or within_threshold),
                    duration_ms=wall_ms,
                    details={
                        "expected": expected_id,
                        "actual": nav_state.get("activeScreen"),
                        "wall_ms": wall_ms,
                        "app_navigation_duration_ms": app_duration,
                        "lastNavigationTargetScreen": nav_state.get("lastNavigationTargetScreen"),
                        "lastNavigationCompletedScreen": nav_state.get("lastNavigationCompletedScreen"),
                        "threshold_ms": 1_500 if should_enforce else None,
                    },
                ))

        median_threshold_failures = {}
        for screen_id, samples in aggregate_wall.items():
            if not samples:
                continue
            sorted_samples = sorted(samples)
            median = sorted_samples[len(sorted_samples) // 2]
            if median > 800:
                median_threshold_failures[screen_id] = median
        results.append(build_test_result(
            "sidebar_navigation_summary",
            passed=not should_enforce or not median_threshold_failures,
            details={
                "wall_ms_by_screen": aggregate_wall,
                "app_navigation_duration_ms_by_screen": aggregate_app,
                "runs_per_screen": 2,
                "median_wall_threshold_ms": 800 if should_enforce else None,
                "median_wall_failures": median_threshold_failures,
            },
        ))
    finally:
        _terminate_ui_process(app_proc)
        cleanup_ui_launch_context(context)
        if app_target is None:
            cleanup_ui_app_target(target)

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("perf_audit", results, duration_ms)


def _run_release_generation_smoke(
    backend_mode: str = "live",
    data_root: str = "fixture",
    *,
    app_bundle: str | None = None,
    dmg: str | None = None,
    app_target: UIAppTarget | None = None,
) -> dict[str, Any]:
    """Run packaged-app generation smoke for custom, design, and clone."""
    from .ui_state_client import UIStateClient, UIStateClientError

    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    resolved, target, target_details = _resolve_test_app_target(
        app_bundle=app_bundle,
        dmg=dmg,
        app_target=app_target,
    )
    results.append(build_test_result("resolve_app_target", passed=resolved, details=target_details))
    if not resolved or target is None:
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("release_generation_smoke", results, duration_ms)

    if not _append_live_preflight_results_for_target(
        results,
        backend_mode,
        requires_app_support_python=target.source == "build",
        requires_models=True,
    ):
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("release_generation_smoke", results, duration_ms)

    clone_fixture_path = PROJECT_DIR / "tests" / "fixtures" / "release_clone_reference.wav"
    clone_fixture_transcript_path = PROJECT_DIR / "tests" / "fixtures" / "release_clone_reference.txt"
    clone_fixture_exists = clone_fixture_path.exists() and clone_fixture_transcript_path.exists()
    results.append(build_test_result(
        "clone_reference_fixture_present",
        passed=clone_fixture_exists,
        details={
            "audio_path": str(clone_fixture_path),
            "transcript_path": str(clone_fixture_transcript_path),
        },
    ))
    if not clone_fixture_exists:
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("release_generation_smoke", results, duration_ms)
    clone_fixture_transcript = clone_fixture_transcript_path.read_text(encoding="utf-8").strip()

    scenarios = [
        {
            "screen": "customVoice",
            "screen_id": "screen_customVoice",
            "mode": "custom",
            "text": "Packaged custom release smoke line.",
            "trigger_kwargs": {},
        },
        {
            "screen": "voiceDesign",
            "screen_id": "screen_voiceDesign",
            "mode": "design",
            "text": "Packaged design release smoke line.",
            "trigger_kwargs": {
                "voice_description": "Warm cinematic narrator with calm, confident pacing.",
                "emotion": "Calm tone",
            },
        },
        {
            "screen": "voiceCloning",
            "screen_id": "screen_voiceCloning",
            "mode": "clone",
            "text": "Packaged clone release smoke line.",
            "trigger_kwargs": {
                "reference_audio_path": str(clone_fixture_path),
                "reference_transcript": clone_fixture_transcript,
            },
        },
    ]

    context = prepare_ui_launch_context(backend_mode=backend_mode, data_root=data_root)
    results.append(build_test_result(
        "release_generation_launch_context",
        passed=True,
        details=describe_launch_context(context),
    ))

    app_proc: subprocess.Popen[Any] | None = None
    client = UIStateClient()
    try:
        kill_running_app_instances()
        env = build_ui_launch_environment(context)
        launch_start = time.perf_counter()
        app_proc = launch_ui_app(str(target.app_binary), env)
        ready, state, failure_reason = _wait_for_ui_launch_ready(client, backend_mode)
        ready_ms = int((time.perf_counter() - launch_start) * 1000)
        results.append(build_test_result(
            "release_generation_launch_to_ready",
            passed=ready and ready_ms <= 20_000,
            duration_ms=ready_ms,
            details={
                "ready_ms": ready_ms,
                "failure_reason": failure_reason,
                "state": state,
                "threshold_ms": 20_000,
            },
        ))
        if not ready:
            duration_ms = int((time.perf_counter() - start) * 1000)
            return build_suite_result("release_generation_smoke", results, duration_ms)

        _append_runtime_dependency_results(results, state, target)

        settled, settled_state = client.wait_for_state(
            lambda snapshot: (
                snapshot.get("sidebarStatusKind") == "idle"
                and snapshot.get("sidebarInlineStatusVisible") is False
                and snapshot.get("sidebarStandaloneStatusVisible") is True
            ),
            timeout=5,
            interval=0.05,
        )
        if settled_state:
            state = settled_state
        results.append(build_test_result(
            "release_generation_launch_settled",
            passed=settled,
            details={
                "state": state,
                "threshold_ms": 5000,
            },
        ))

        for scenario in scenarios:
            thresholds = _release_thresholds_for(scenario["mode"])
            if state.get("activeScreen") == scenario["screen_id"]:
                navigated = True
            else:
                try:
                    nav_state = client.navigate(scenario["screen"])
                except UIStateClientError as exc:
                    results.append(_build_ui_transport_failure_result(
                        f"{scenario['mode']}_navigate",
                        exc,
                        last_state=state,
                    ))
                    continue
                navigated, ready_state = client.wait_for_navigation(scenario["screen_id"], timeout=15)
                state = ready_state or nav_state
            results.append(build_test_result(
                f"{scenario['mode']}_screen_ready",
                passed=state.get("activeScreen") == scenario["screen_id"],
                details={
                    "navigated": navigated,
                    "expected": scenario["screen_id"],
                    "actual": state.get("activeScreen"),
                },
            ))
            if state.get("activeScreen") != scenario["screen_id"]:
                continue

            baseline_chunk_count = int(state.get("previewChunkCount", 0))
            baseline_finalized_count = int(state.get("previewFinalizedCount", 0))
            trigger_start = time.perf_counter()
            try:
                state = client.start_generation(
                    scenario["screen"],
                    scenario["text"],
                    **scenario["trigger_kwargs"],
                )
            except UIStateClientError as exc:
                results.append(_build_ui_transport_failure_result(
                    f"{scenario['mode']}_start_generation",
                    exc,
                    last_state=state,
                ))
                continue

            results.append(build_test_result(
                f"{scenario['mode']}_generation_triggered",
                passed=state.get("activeScreen") == scenario["screen_id"],
                details={
                    "activeScreen": state.get("activeScreen"),
                    "text": scenario["text"],
                    **scenario["trigger_kwargs"],
                },
            ))

            running_visible = (
                state.get("sidebarStatusKind") == "running"
                and state.get("sidebarStatusPresentation") == "inlinePlayer"
                and state.get("sidebarInlineStatusVisible") is True
            )
            running_state = state
            if not running_visible:
                running_visible, running_state = client.wait_for_state(
                    lambda snapshot: (
                        snapshot.get("sidebarStatusKind") == "running"
                        and snapshot.get("sidebarStatusPresentation") == "inlinePlayer"
                        and snapshot.get("sidebarInlineStatusVisible") is True
                    ),
                    timeout=thresholds["running_ms"] / 1000,
                )
            running_ms = int((time.perf_counter() - trigger_start) * 1000)
            if running_state:
                state = running_state
            results.append(build_test_result(
                f"{scenario['mode']}_running_visible",
                passed=running_visible and running_ms <= thresholds["running_ms"],
                duration_ms=running_ms,
                details={
                    "running_ms": running_ms,
                    "threshold_ms": thresholds["running_ms"],
                    "state": state,
                },
            ))

            chunk_visible = int(state.get("previewChunkCount", 0)) > baseline_chunk_count
            chunk_state = state
            if not chunk_visible:
                chunk_visible, chunk_state = client.wait_for_state(
                    lambda snapshot: int(snapshot.get("previewChunkCount", 0)) > baseline_chunk_count,
                    timeout=thresholds["first_chunk_ms"] / 1000,
                )
            first_chunk_ms = int((time.perf_counter() - trigger_start) * 1000)
            if chunk_state:
                state = chunk_state
            results.append(build_test_result(
                f"{scenario['mode']}_first_chunk",
                passed=chunk_visible and first_chunk_ms <= thresholds["first_chunk_ms"],
                duration_ms=first_chunk_ms,
                details={
                    "first_chunk_ms": first_chunk_ms,
                    "threshold_ms": thresholds["first_chunk_ms"],
                    "previewChunkCount": state.get("previewChunkCount"),
                },
            ))

            finalized = int(state.get("previewFinalizedCount", 0)) > baseline_finalized_count
            finalized_state = state
            if not finalized:
                finalized, finalized_state = client.wait_for_state(
                    lambda snapshot: int(snapshot.get("previewFinalizedCount", 0)) > baseline_finalized_count,
                    timeout=thresholds["finalized_ms"] / 1000,
                )
            finalized_ms = int((time.perf_counter() - trigger_start) * 1000)
            if finalized_state:
                state = finalized_state
            results.append(build_test_result(
                f"{scenario['mode']}_preview_finalized",
                passed=finalized and finalized_ms <= thresholds["finalized_ms"],
                duration_ms=finalized_ms,
                details={
                    "preview_finalized_ms": finalized_ms,
                    "threshold_ms": thresholds["finalized_ms"],
                    "previewFinalizedCount": state.get("previewFinalizedCount"),
                },
            ))

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
                    timeout=thresholds["idle_ms"] / 1000,
                )
            idle_ms = int((time.perf_counter() - trigger_start) * 1000)
            if idle_state:
                state = idle_state
            results.append(build_test_result(
                f"{scenario['mode']}_returns_to_idle",
                passed=idle_ready and idle_ms <= thresholds["idle_ms"],
                duration_ms=idle_ms,
                details={
                    "idle_ms": idle_ms,
                    "threshold_ms": thresholds["idle_ms"],
                    "state": state,
                },
            ))
    finally:
        _terminate_ui_process(app_proc)
        cleanup_ui_launch_context(context)
        if app_target is None:
            cleanup_ui_app_target(target)

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("release_generation_smoke", results, duration_ms)


def _run_release_tests(
    backend_mode: str = "live",
    data_root: str = "fixture",
    *,
    artifacts_root: str | None = None,
) -> list[dict[str, Any]]:
    """Run packaged release validation against downloaded artifacts."""
    artifacts = discover_release_artifacts(artifacts_root)
    if not artifacts:
        result = build_suite_result(
            "release_artifact_discovery",
            [
                build_test_result(
                    "discover_release_artifacts",
                    passed=False,
                    error="No release artifacts found",
                    details={"artifacts_root": artifacts_root},
                )
            ],
            0,
        )
        return [result]

    suites: list[dict[str, Any]] = []
    for artifact in artifacts:
        variant_label = artifact.get("variant_id") or Path(artifact["dmg_path"]).stem
        resolved, target, details = resolve_ui_app_target(dmg=artifact["dmg_path"])
        discovery_suite = _prefix_suite(
            build_suite_result(
                "release_artifact_target",
                [build_test_result("resolve_artifact_target", passed=resolved, details=details)],
                0,
            ),
            variant_label,
        )
        suites.append(discovery_suite)
        if not resolved or target is None:
            continue

        target.variant_id = target.variant_id or artifact.get("variant_id")
        target.ui_profile = target.ui_profile or artifact.get("ui_profile")
        target.metadata = target.metadata or artifact.get("metadata")

        try:
            suites.append(_run_release_bundle_verification(target, variant_label=variant_label))
            suites.append(_prefix_suite(_run_ui_tests(
                backend_mode=backend_mode,
                data_root=data_root,
                app_target=target,
            ), variant_label))
            suites.append(_prefix_suite(_run_design_tests(
                backend_mode=backend_mode,
                data_root=data_root,
                app_target=target,
                force_capture_only=True,
            ), variant_label))
            suites.append(_prefix_suite(_run_perf_audit(
                backend_mode=backend_mode,
                data_root=data_root,
                app_target=target,
                enforce_thresholds=True,
            ), variant_label))
            suites.append(_prefix_suite(_run_release_generation_smoke(
                backend_mode=backend_mode,
                data_root=data_root,
                app_target=target,
            ), variant_label))
        finally:
            cleanup_ui_app_target(target)

    return suites


def _run_swift_tests() -> dict[str, Any]:
    """Run Swift unit tests via xcodebuild."""
    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    xcodeproj = PROJECT_DIR / "QwenVoice.xcodeproj"
    if not xcodeproj.exists():
        results.append(build_test_result(
            "xcode_project_exists", passed=False,
            error="QwenVoice.xcodeproj not found",
        ))
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("swift_unit_tests", results, duration_ms)

    def test_xcodebuild():
        proc = subprocess.run(
            [
                "xcodebuild", "test",
                "-project", str(xcodeproj),
                "-scheme", "QwenVoice",
                "-only-testing:QwenVoiceTests",
                "-destination", "platform=macOS,arch=arm64",
                "-quiet",
            ],
            capture_output=True,
            text=True,
            timeout=300,
            cwd=str(PROJECT_DIR),
        )
        if proc.returncode != 0:
            # Extract test failures from output
            output = proc.stdout + "\n" + proc.stderr
            failure_lines = [l for l in output.splitlines() if "failed" in l.lower() or "error:" in l.lower()]
            raise AssertionError(
                f"xcodebuild test failed (exit {proc.returncode}): "
                + "\n".join(failure_lines[-10:])
            )

    results.append(_timed_test("xcodebuild_test", test_xcodebuild))

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("swift_unit_tests", results, duration_ms)
