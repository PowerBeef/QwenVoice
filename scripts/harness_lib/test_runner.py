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


def run_tests(
    layer: str = "all",
    python_path: str | None = None,
    artifact_dir: str | None = None,
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
        suites.append(_run_ui_tests())

    if layer == "design":
        suites.append(_run_design_tests())

    if layer == "perf":
        suites.append(_run_perf_audit())

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

    tests = [
        ("env_flag_true", test_env_flag_true),
        ("env_flag_false", test_env_flag_false),
        ("env_flag_missing_default", test_env_flag_missing_default),
        ("env_float_valid", test_env_float_valid),
        ("env_float_invalid", test_env_float_invalid),
        ("env_float_missing", test_env_float_missing),
        ("early_abort_margin_positive", test_early_abort_margin_positive),
        ("meaningful_delivery_instruction", test_meaningful_delivery_various),
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
            with tempfile.TemporaryDirectory() as tmp:
                result = client.call("init", {"app_support_dir": tmp}, timeout=30)
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
                            params["voice_description"] = "A young female speaker"

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


def _run_ui_tests() -> dict[str, Any]:
    """Run UI tests via HTTP state server (no XCUI dependency)."""
    import signal
    from .ui_state_client import UIStateClient

    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    # 1. Build the app
    eprint("  Building app...")
    build_proc = subprocess.run(
        ["xcodebuild", "-project", str(PROJECT_DIR / "QwenVoice.xcodeproj"),
         "-scheme", "QwenVoice", "build", "-quiet"],
        capture_output=True, text=True, timeout=300,
    )
    if build_proc.returncode != 0:
        duration_ms = int((time.perf_counter() - start) * 1000)
        results.append(build_test_result("build", passed=False, details={"error": "build_failed"}))
        return build_suite_result("ui_http_tests", results, duration_ms)

    # 2. Find the built app binary
    settings = subprocess.run(
        ["xcodebuild", "-project", str(PROJECT_DIR / "QwenVoice.xcodeproj"),
         "-scheme", "QwenVoice", "-showBuildSettings"],
        capture_output=True, text=True, timeout=30,
    )
    app_dir = None
    for line in settings.stdout.splitlines():
        if "BUILT_PRODUCTS_DIR" in line:
            app_dir = line.split("=", 1)[1].strip()
            break
    if not app_dir:
        duration_ms = int((time.perf_counter() - start) * 1000)
        results.append(build_test_result("find_app", passed=False, details={"error": "no_build_dir"}))
        return build_suite_result("ui_http_tests", results, duration_ms)

    app_binary = os.path.join(app_dir, "QwenVoice.app", "Contents", "MacOS", "QwenVoice")

    # 3. Kill existing instances
    subprocess.run(["killall", "QwenVoice"], capture_output=True)
    time.sleep(0.5)

    # 4. Launch with test mode
    eprint("  Launching app with test state server...")
    env = dict(os.environ)
    env["QWENVOICE_UI_TEST"] = "1"
    env["QWENVOICE_UI_TEST_BACKEND_MODE"] = "stub"
    env["QWENVOICE_UI_TEST_SETUP_SCENARIO"] = "success"
    env["QWENVOICE_UI_TEST_SETUP_DELAY_MS"] = "1"
    app_proc = subprocess.Popen(
        [app_binary, "--uitest", "--uitest-disable-animations", "--uitest-fast-idle"],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )

    client = UIStateClient()

    try:
        # 5. Wait for ready
        t0 = time.perf_counter()
        ready = client.wait_for_ready(timeout=15)
        ready_ms = int((time.perf_counter() - t0) * 1000)
        results.append(build_test_result(
            "app_launch_to_ready",
            passed=ready,
            duration_ms=ready_ms,
            details={"ready_ms": ready_ms},
        ))
        if not ready:
            eprint(f"  App did not become ready within 15s")
            duration_ms = int((time.perf_counter() - start) * 1000)
            return build_suite_result("ui_http_tests", results, duration_ms)

        # 6. Check default screen
        state = client.query_state()
        default_ok = "customVoice" in state.get("activeScreen", "")
        results.append(build_test_result(
            "default_screen_is_customVoice",
            passed=default_ok,
            details={"activeScreen": state.get("activeScreen")},
        ))

        # 7. Test each screen by relaunching with --uitest-screen=X
        screens = [
            ("history", "screen_history"),
            ("voices", "screen_voices"),
            ("models", "screen_models"),
            ("voiceDesign", "screen_voiceDesign"),
            ("voiceCloning", "screen_voiceCloning"),
        ]
        for screen_arg, expected_id in screens:
            # Kill current instance
            app_proc.terminate()
            try:
                app_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                app_proc.kill()
            time.sleep(0.5)

            # Relaunch with target screen
            t0 = time.perf_counter()
            app_proc = subprocess.Popen(
                [app_binary, "--uitest", "--uitest-disable-animations",
                 "--uitest-fast-idle", f"--uitest-screen={screen_arg}"],
                env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            screen_ready = client.wait_for_ready(timeout=10)
            if screen_ready:
                state = client.query_state()
                actual = state.get("activeScreen", "")
            else:
                actual = "not_ready"
            launch_ms = int((time.perf_counter() - t0) * 1000)

            results.append(build_test_result(
                f"screen_{screen_arg}",
                passed=(actual == expected_id),
                duration_ms=launch_ms,
                details={"expected": expected_id, "actual": actual, "launch_ms": launch_ms},
            ))

    finally:
        # 8. Cleanup
        app_proc.terminate()
        try:
            app_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            app_proc.kill()

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("ui_http_tests", results, duration_ms)


def _run_design_tests() -> dict[str, Any]:
    """Compare captured screenshots against baselines."""
    start = time.perf_counter()

    baselines_dir = str(PROJECT_DIR / "tests" / "screenshots" / "baselines")
    captures_dir = str(PROJECT_DIR / "build" / "test" / "screenshots")
    diffs_dir = str(PROJECT_DIR / "tests" / "screenshots" / "diffs")
    os.makedirs(diffs_dir, exist_ok=True)

    results: list[dict[str, Any]] = []

    if not os.path.isdir(baselines_dir) or not os.listdir(baselines_dir):
        eprint("  No baselines found. Run --layer ui first to capture screenshots, then copy to tests/screenshots/baselines/")
        results.append(build_test_result("no_baselines", passed=True, details={"status": "skipped_no_baselines"}))
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("design_comparison", results, duration_ms)

    if not os.path.isdir(captures_dir):
        eprint("  No captured screenshots found. Run --layer ui first.")
        results.append(build_test_result("no_captures", passed=False, details={"error": "missing_captures_dir"}))
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("design_comparison", results, duration_ms)

    try:
        from .screenshot_diff import compare_screenshots
    except ImportError:
        eprint("  screenshot_diff module not available")
        results.append(build_test_result("import_error", passed=False, details={"error": "screenshot_diff_import_failed"}))
        duration_ms = int((time.perf_counter() - start) * 1000)
        return build_suite_result("design_comparison", results, duration_ms)

    for name in sorted(os.listdir(baselines_dir)):
        if not name.endswith(".png"):
            continue
        baseline_path = os.path.join(baselines_dir, name)
        capture_path = os.path.join(captures_dir, name)
        diff_path = os.path.join(diffs_dir, name.replace(".png", "_diff.png"))

        if not os.path.exists(capture_path):
            results.append(build_test_result(name, passed=False, details={"error": "capture_not_found"}))
            continue

        diff_result = compare_screenshots(baseline_path, capture_path, diff_path, max_diff_percent=1.0)
        results.append(build_test_result(name, passed=diff_result["passed"], details=diff_result))

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("design_comparison", results, duration_ms)


def _run_perf_audit() -> dict[str, Any]:
    """Run performance audit tests and check against thresholds."""
    import shutil

    start = time.perf_counter()

    # Run only PerformanceAuditTests
    result_bundle = str(PROJECT_DIR / "build" / "test" / "results" / "PerfAudit.xcresult")
    if os.path.exists(result_bundle):
        shutil.rmtree(result_bundle)

    cmd = [
        "xcodebuild", "test",
        "-project", str(PROJECT_DIR / "QwenVoice.xcodeproj"),
        "-scheme", "QwenVoice",
        "-destination", "platform=macOS,arch=arm64",
        "-only-testing:QwenVoiceUITests/PerformanceAuditTests",
        "CODE_SIGN_IDENTITY=-",
        "CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES",
        "-resultBundlePath", result_bundle,
    ]

    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        duration_ms = int((time.perf_counter() - start) * 1000)
        eprint("Performance audit timed out after 300s")
        results = [build_test_result("perf_audit_suite", passed=False, duration_ms=duration_ms, details={"error": "timeout_300s"})]
        return build_suite_result("perf_audit", results, duration_ms)
    duration_ms = int((time.perf_counter() - start) * 1000)

    results: list[dict[str, Any]] = []
    results.append(build_test_result(
        "perf_audit_suite",
        passed=(proc.returncode == 0),
        duration_ms=duration_ms,
        details={"return_code": proc.returncode},
    ))

    if proc.returncode != 0:
        eprint(f"Performance audit failed (exit {proc.returncode})")
        stderr_lines = proc.stderr.strip().split("\n")
        for line in stderr_lines[-20:]:
            eprint(f"  {line}")

    return build_suite_result("perf_audit", results, duration_ms)


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
