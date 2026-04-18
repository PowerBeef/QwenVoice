"""Test runner — four layers of tests for the QwenVoice harness.

Layer (a): Pipeline pure-function tests — no model loading, no venv
Layer (b): Server pure-function tests — imports server.py via importlib
Layer (c): RPC integration tests — requires app venv + installed model
Layer (d): Contract cross-validation — cross-references across layers
"""

from __future__ import annotations

import contextlib
import importlib
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import types
from pathlib import Path
from typing import Any

from .contract import load_contract, model_ids, model_is_installed, speaker_list
from .output import build_suite_result, build_test_result, eprint
from .paths import (
    APP_MODELS_DIR,
    BACKEND_DIR,
    CONTRACT_PATH,
    PROJECT_DIR,
    SERVER_COMPAT_PATH,
    SERVER_PATH,
    resolve_backend_python,
)
from .ui_test_support import (
    UIAppTarget,
    build_ui_launch_environment,
    check_live_prerequisites,
    cleanup_ui_launch_context,
    cleanup_ui_app_target,
    discover_release_artifacts,
    describe_launch_context,
    kill_running_app_instances,
    launch_ui_app,
    prepare_ui_launch_context,
    resolve_xcodebuild_timeout_seconds,
    resolve_ui_app_target,
)


def run_tests(
    layer: str = "all",
    python_path: str | None = None,
    artifact_dir: str | None = None,
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

    if layer == "release":
        suites.extend(_run_release_tests(artifacts_root=artifacts_root))

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


@contextlib.contextmanager
def _temporary_sys_modules(replacements: dict[str, Any]):
    original: dict[str, Any] = {}
    missing: set[str] = set()

    for name, module in replacements.items():
        if name in sys.modules:
            original[name] = sys.modules[name]
        else:
            missing.add(name)
        sys.modules[name] = module

    try:
        yield
    finally:
        for name in replacements:
            if name in original:
                sys.modules[name] = original[name]
            elif name in missing:
                sys.modules.pop(name, None)


def _load_qwen_speed_patch_module():
    helper_path = PROJECT_DIR / "third_party_patches/mlx-audio/qwenvoice_speed_patch.py"

    class FakeTensor:
        def __init__(self, payload: str, shape: tuple[int, ...]):
            self.payload = payload
            self.shape = tuple(shape)

        @property
        def ndim(self) -> int:
            return len(self.shape)

        def reshape(self, *shape: int):
            return FakeTensor(f"reshape({self.payload},{shape})", tuple(shape))

        def __getitem__(self, key):
            if not isinstance(key, tuple):
                key = (key,)

            source_dims = list(self.shape)
            dim_index = 0
            result_shape: list[int] = []

            for item in key:
                if item is None:
                    result_shape.append(1)
                    continue

                size = source_dims[dim_index]
                dim_index += 1

                if isinstance(item, int):
                    continue

                if isinstance(item, slice):
                    start, stop, step = item.indices(size)
                    length = len(range(start, stop, step))
                    result_shape.append(length)
                    continue

                raise TypeError(f"Unsupported index type: {type(item)!r}")

            result_shape.extend(source_dims[dim_index:])
            return FakeTensor(f"{self.payload}[{key!r}]", tuple(result_shape))

        def __add__(self, other):
            other_tensor = other if isinstance(other, FakeTensor) else FakeTensor(repr(other), ())
            shape = self.shape if len(self.shape) >= len(other_tensor.shape) else other_tensor.shape
            return FakeTensor(f"add({self.payload},{other_tensor.payload})", shape)

        __radd__ = __add__

        def __eq__(self, other):
            return (
                isinstance(other, FakeTensor)
                and self.payload == other.payload
                and self.shape == other.shape
            )

        def __repr__(self) -> str:
            return f"FakeTensor(payload={self.payload!r}, shape={self.shape!r})"

    def _shape_for_data(value) -> tuple[int, ...]:
        if isinstance(value, FakeTensor):
            return value.shape
        if isinstance(value, list):
            if not value:
                return (0,)
            return (len(value),) + _shape_for_data(value[0])
        return ()

    def _mx_array(value):
        if isinstance(value, FakeTensor):
            return value
        return FakeTensor(repr(value), _shape_for_data(value))

    def _mx_concatenate(values, axis=0):
        tensors = [_mx_array(value) for value in values]
        base_shape = list(tensors[0].shape)
        base_shape[axis] = sum(tensor.shape[axis] for tensor in tensors)
        payload = "concat(" + ",".join(tensor.payload for tensor in tensors) + f";axis={axis})"
        return FakeTensor(payload, tuple(base_shape))

    def _mx_broadcast_to(value, shape):
        tensor = _mx_array(value)
        return FakeTensor(f"broadcast({tensor.payload}->{tuple(shape)!r})", tuple(shape))

    def _make_embedding(name: str):
        def embed(ids):
            tensor = _mx_array(ids)
            if len(tensor.shape) == 1:
                batch, seq = 1, tensor.shape[0]
            else:
                batch, seq = tensor.shape[0], tensor.shape[1]
            return FakeTensor(f"{name}({tensor.payload})", (batch, seq, 4))

        return embed

    class FakeTokenizer:
        def __init__(self) -> None:
            self.encoded_texts: list[str] = []

        def encode(self, text: str) -> list[int]:
            self.encoded_texts.append(text)
            base = [((ord(ch) % 17) + 1) for ch in text]
            while len(base) < 16:
                base.append(len(base) + 1)
            return base

    class FakeSpeechTokenizer:
        def __init__(self) -> None:
            self.has_encoder = True
            self.encode_calls = 0

        def encode(self, audio):
            self.encode_calls += 1
            return FakeTensor(f"ref_codes({getattr(audio, 'payload', audio)!r})", (1, 2, 3))

    class FakeTalker:
        def __init__(self) -> None:
            self._text_embeddings = _make_embedding("text_embeddings")
            self._input_embeddings = _make_embedding("input_embeddings")
            self.code_predictor = types.SimpleNamespace(
                codec_embedding=[_make_embedding("codec_embedding_0")]
            )

        def get_text_embeddings(self):
            return self._text_embeddings

        def text_projection(self, tensor):
            tensor = _mx_array(tensor)
            return FakeTensor(f"text_projection({tensor.payload})", tensor.shape)

        def get_input_embeddings(self):
            return self._input_embeddings

    class FakeModel(dict):
        def __init__(self) -> None:
            super().__init__()
            self.sample_rate = 24_000
            self.tokenizer = FakeTokenizer()
            self.talker = FakeTalker()
            self.speech_tokenizer = FakeSpeechTokenizer()
            self.speaker_encoder = object()
            self._sample_token = object()
            self.config = types.SimpleNamespace(
                tts_bos_token_id=101,
                tts_eos_token_id=102,
                tts_pad_token_id=0,
                talker_config=types.SimpleNamespace(
                    codec_pad_id=501,
                    codec_bos_id=502,
                    num_code_groups=2,
                    codec_nothink_id=601,
                    codec_think_bos_id=602,
                    codec_think_eos_id=603,
                    codec_think_id=604,
                    codec_eos_token_id=605,
                    vocab_size=10_000,
                    codec_language_id={"en": 701, "ja": 702},
                ),
            )

        def extract_speaker_embedding(self, audio):
            return FakeTensor(f"speaker_embed({getattr(audio, 'payload', audio)!r})", (4,))

    mx_core_module = types.ModuleType("mlx.core")
    mx_core_module.array = _mx_array
    mx_core_module.concatenate = _mx_concatenate
    mx_core_module.broadcast_to = _mx_broadcast_to
    mx_core_module.eval = lambda *args, **kwargs: None
    mx_core_module.load = lambda *args, **kwargs: {}
    mx_core_module.get_peak_memory = lambda: 0.0

    mlx_module = types.ModuleType("mlx")
    mlx_module.__path__ = []
    mlx_module.core = mx_core_module

    mlx_audio_module = types.ModuleType("mlx_audio")
    mlx_audio_module.__path__ = []
    mlx_audio_tts_module = types.ModuleType("mlx_audio.tts")
    mlx_audio_tts_module.__path__ = []
    mlx_audio_models_module = types.ModuleType("mlx_audio.tts.models")
    mlx_audio_models_module.__path__ = []
    mlx_audio_qwen_module = types.ModuleType("mlx_audio.tts.models.qwen3_tts")
    mlx_audio_qwen_module.__path__ = []

    base_module = types.ModuleType("mlx_audio.tts.models.base")
    base_module.GenerationResult = type("GenerationResult", (), {})
    base_module.BatchGenerationResult = type("BatchGenerationResult", (), {})

    qwen_module = types.ModuleType("mlx_audio.tts.models.qwen3_tts.qwen3_tts")
    qwen_module.format_duration = lambda duration_seconds: f"{duration_seconds:.2f}s"

    utils_module = types.ModuleType("mlx_audio.utils")
    utils_module.load_audio = lambda path, sample_rate=None: FakeTensor(f"audio({path})", (240,))

    replacements = {
        "mlx": mlx_module,
        "mlx.core": mx_core_module,
        "mlx_audio": mlx_audio_module,
        "mlx_audio.tts": mlx_audio_tts_module,
        "mlx_audio.tts.models": mlx_audio_models_module,
        "mlx_audio.tts.models.base": base_module,
        "mlx_audio.tts.models.qwen3_tts": mlx_audio_qwen_module,
        "mlx_audio.tts.models.qwen3_tts.qwen3_tts": qwen_module,
        "mlx_audio.utils": utils_module,
    }

    with _temporary_sys_modules(replacements):
        module_name = f"_qwen_speed_patch_harness_{id(object())}"
        module = _load_module_from_path(module_name, helper_path)

    return module, FakeTensor, FakeModel


# ---------------------------------------------------------------------------
# Layer (a): Pipeline pure-function tests
# ---------------------------------------------------------------------------

def _run_pipeline_tests() -> dict[str, Any]:
    start = time.perf_counter()
    results: list[dict[str, Any]] = []

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

    def test_click_detection_ignores_matching_boundary_with_small_final_alignment_drift():
        import numpy as np

        from .audio_analysis import check_click_detection

        chunk_a = np.linspace(0.0, 0.12, 64, dtype=np.float32)
        chunk_b = np.concatenate((
            np.array([0.95], dtype=np.float32),
            np.linspace(0.94, 0.2, 63, dtype=np.float32),
        ))
        final_audio = np.concatenate((
            chunk_a,
            chunk_b,
            np.array([0.19, 0.18], dtype=np.float32),
        ))
        result = check_click_detection(
            [(chunk_a, 24000), (chunk_b, 24000)],
            final_audio=final_audio,
        )
        assert result["passed"] is True

    def test_build_ui_launch_environment_uses_stub_fixture_root():
        context = prepare_ui_launch_context(backend_mode="stub", data_root="fixture")
        try:
            env = build_ui_launch_environment(context)
            assert env["QWENVOICE_UI_TEST_FIXTURE_ROOT"] == str(context.app_support_dir)
            assert "QWENVOICE_APP_SUPPORT_DIR" not in env
        finally:
            cleanup_ui_launch_context(context)

    def test_build_ui_launch_environment_uses_live_app_support_root():
        context = prepare_ui_launch_context(backend_mode="live", data_root="fixture")
        try:
            env = build_ui_launch_environment(context)
            assert env["QWENVOICE_APP_SUPPORT_DIR"] == str(context.app_support_dir)
            assert "QWENVOICE_UI_TEST_FIXTURE_ROOT" not in env
        finally:
            cleanup_ui_launch_context(context)

    def test_split_generation_pipeline_forwards_voice_kwarg():
        module = _load_module_from_path(
            f"_generation_pipeline_{id(object())}",
            BACKEND_DIR / "generation_pipeline.py",
        )
        pipeline = module.GenerationPipeline(
            state=None,
            transport=None,
            output_paths=None,
            audio_io=None,
            clone_context=None,
            default_speaker="vivian",
            cache_policy="always",
            default_streaming_interval=0.32,
            prewarm_profiles={},
        )

        kwargs = pipeline.build_generation_kwargs(
            "Hello",
            0.6,
            voice="vivian",
        )

        assert kwargs["voice"] == "vivian"
        assert "speaker" not in kwargs

    tests = [
        ("click_detection_ignores_matching_final_boundary_transient", test_click_detection_ignores_matching_final_boundary_transient),
        ("click_detection_detects_boundary_not_present_in_final_audio", test_click_detection_detects_boundary_not_present_in_final_audio),
        ("click_detection_ignores_matching_boundary_with_small_final_alignment_drift", test_click_detection_ignores_matching_boundary_with_small_final_alignment_drift),
        ("build_ui_launch_environment_uses_stub_fixture_root", test_build_ui_launch_environment_uses_stub_fixture_root),
        ("build_ui_launch_environment_uses_live_app_support_root", test_build_ui_launch_environment_uses_live_app_support_root),
        ("split_generation_pipeline_forwards_voice_kwarg", test_split_generation_pipeline_forwards_voice_kwarg),
        ("pipeline_tests_retired", lambda: {"skip_reason": "No pipeline-specific tests remain after clone delivery cleanup"}),
    ]

    for name, fn in tests:
        results.append(_timed_test(name, fn))

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("pipeline_pure_functions", results, duration_ms)


# ---------------------------------------------------------------------------
# Layer (b): Server pure-function tests
# ---------------------------------------------------------------------------

def _load_server_module() -> Any:
    """Load the backend pure-function harness surface in isolation."""
    # We need to load just the pure functions without triggering MLX imports.
    # The production backend now lives in server.py with helper modules, while
    # server_compat.py preserves the older pure-function surface the harness uses
    # for characterization tests.
    target_path = SERVER_COMPAT_PATH if SERVER_COMPAT_PATH.exists() else SERVER_PATH
    original_path = list(sys.path)
    if str(BACKEND_DIR) not in sys.path:
        sys.path.insert(0, str(BACKEND_DIR))
    try:
        # Use a unique name to get a fresh module each time
        spec = importlib.util.spec_from_file_location(
            f"_server_harness_{id(object())}",
            str(target_path),
        )
        if spec is None or spec.loader is None:
            raise ImportError(f"Cannot load server harness from {target_path}")
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

    def test_build_generation_kwargs_omits_auto_language():
        default_kwargs = server._build_generation_kwargs("Hello", 0.6)
        empty_kwargs = server._build_generation_kwargs("Hello", 0.6, language="")
        auto_kwargs = server._build_generation_kwargs("Hello", 0.6, language="auto")

        assert "lang_code" not in default_kwargs
        assert "lang_code" not in empty_kwargs
        assert "lang_code" not in auto_kwargs

    def test_build_generation_kwargs_includes_explicit_language():
        kwargs = server._build_generation_kwargs("Bonjour", 0.6, language="fr")

        assert kwargs["lang_code"] == "fr"

    def test_latency_first_chunk_uses_received_notification_timestamp():
        from harness_lib.bench_runner import _latency_first_chunk_ms

        notifications = [
            {"method": "progress", "_received_at_ms": 7.5},
            {"method": "generation_chunk", "_received_at_ms": 123.4},
            {"method": "generation_chunk", "_received_at_ms": 456.7},
        ]

        assert _latency_first_chunk_ms(notifications) == 123.4

    def test_latency_generate_params_use_streaming_and_design_instruct():
        from harness_lib.bench_runner import _latency_generate_params

        params = _latency_generate_params(
            mode="design",
            output_path="/tmp/latency.wav",
            clone_reference_path=None,
            clone_reference_text=None,
        )

        assert params["stream"] is True
        assert "streaming_interval" in params
        assert "instruct" in params
        assert "voice_description" not in params

    def test_clone_regression_reference_falls_back_to_committed_fixture():
        from harness_lib import clone_regression_runner

        original_reference_audio = clone_regression_runner.REFERENCE_AUDIO_PATH
        original_reference_text = clone_regression_runner.REFERENCE_TEXT_PATH
        original_committed_audio = clone_regression_runner.COMMITTED_REFERENCE_AUDIO_PATH
        original_committed_text = clone_regression_runner.COMMITTED_REFERENCE_TEXT_PATH

        with tempfile.TemporaryDirectory() as tmp:
            temp_root = Path(tmp)
            committed_audio = temp_root / "release_clone_reference.wav"
            committed_text = temp_root / "release_clone_reference.txt"
            committed_audio.write_bytes(b"wav")
            committed_text.write_text("fixture transcript", encoding="utf-8")

            try:
                clone_regression_runner.REFERENCE_AUDIO_PATH = temp_root / "missing_saved.wav"
                clone_regression_runner.REFERENCE_TEXT_PATH = temp_root / "missing_saved.txt"
                clone_regression_runner.COMMITTED_REFERENCE_AUDIO_PATH = committed_audio
                clone_regression_runner.COMMITTED_REFERENCE_TEXT_PATH = committed_text

                resolved = clone_regression_runner.resolve_clone_regression_reference()
                assert resolved == (committed_audio, committed_text)
            finally:
                clone_regression_runner.REFERENCE_AUDIO_PATH = original_reference_audio
                clone_regression_runner.REFERENCE_TEXT_PATH = original_reference_text
                clone_regression_runner.COMMITTED_REFERENCE_AUDIO_PATH = original_committed_audio
                clone_regression_runner.COMMITTED_REFERENCE_TEXT_PATH = original_committed_text

    def test_unload_model_clears_prewarm_and_clone_prime_state():
        original_prewarmed_keys = set(server._prewarmed_model_keys)
        original_primed_keys = set(server._primed_clone_reference_keys)

        try:
            server._prewarmed_model_keys.add("pro_custom|custom|vivian|Conversational")
            server._primed_clone_reference_keys.add("pro_clone|clone|fixture.wav|hello")

            result = server.handle_unload_model({})

            assert result["success"] is True
            assert server._prewarmed_model_keys == set()
            assert server._primed_clone_reference_keys == set()
        finally:
            server._prewarmed_model_keys = original_prewarmed_keys
            server._primed_clone_reference_keys = original_primed_keys

    def test_custom_prewarm_primes_streaming_generator():
        calls: list[dict[str, Any]] = []

        original_current_model = server._current_model
        original_build_standard_generator = server._build_standard_generator

        try:
            server._current_model = object()

            def fake_build_standard_generator(
                model,
                text,
                temperature,
                max_tokens=None,
                *,
                language="auto",
                voice=None,
                instruct=None,
                stream=False,
                streaming_interval=None,
            ):
                calls.append({
                    "text": text,
                    "max_tokens": max_tokens,
                    "voice": voice,
                    "instruct": instruct,
                    "stream": stream,
                    "streaming_interval": streaming_interval,
                })
                yield {"audio": "warmup"}

            server._build_standard_generator = fake_build_standard_generator

            result = server._run_model_prewarm(
                "custom",
                voice="vivian",
                instruct="Conversational",
            )

            assert calls
            assert calls[0]["stream"] is True
            assert calls[0]["streaming_interval"] == server.DEFAULT_STREAMING_INTERVAL
            assert "first_stream_chunk" in result
        finally:
            server._current_model = original_current_model
            server._build_standard_generator = original_build_standard_generator

    def test_clone_prewarm_prepared_generator_omits_instruct_kwarg():
        calls: list[dict[str, Any]] = []

        original_current_model = server._current_model
        original_normalize_clone_reference = server._normalize_clone_reference
        original_resolve_clone_transcript = server._resolve_clone_transcript
        original_get_or_prepare_clone_context = server._get_or_prepare_clone_context
        original_generate_prepared_icl_fn = server._generate_prepared_icl_fn

        try:
            server._current_model = object()
            server._normalize_clone_reference = lambda path: path
            server._resolve_clone_transcript = (
                lambda clean_ref_audio_path, original_ref_audio_path, requested_transcript: requested_transcript or "Prepared transcript"
            )
            server._get_or_prepare_clone_context = (
                lambda clean_ref_audio_path, ref_text: ("prepared-clone-context", True)
            )

            def fake_generate_prepared_icl(model, text, prepared_context, **kwargs):
                calls.append(dict(kwargs))
                yield {"audio": "warmup"}

            server._generate_prepared_icl_fn = fake_generate_prepared_icl

            result = server._run_model_prewarm(
                "clone",
                ref_audio="/tmp/reference.wav",
                ref_text="Reference transcript",
            )

            assert result["prepared_clone_used"] is True
            assert calls
            assert "instruct" not in calls[0]
            assert "language" not in calls[0]
            assert calls[0]["stream"] is True
            assert calls[0]["streaming_interval"] == server.DEFAULT_STREAMING_INTERVAL
            assert "first_stream_chunk" in result
            assert result["generation"] >= result["first_stream_chunk"]
            assert (
                result["prewarm_max_tokens"]
                == server.PREWARM_PROFILES["clone_prime"]["max_tokens"]
            )
        finally:
            server._current_model = original_current_model
            server._normalize_clone_reference = original_normalize_clone_reference
            server._resolve_clone_transcript = original_resolve_clone_transcript
            server._get_or_prepare_clone_context = original_get_or_prepare_clone_context
            server._generate_prepared_icl_fn = original_generate_prepared_icl_fn

    def test_clone_prewarm_prepared_generator_forwards_explicit_language():
        calls: list[dict[str, Any]] = []

        original_current_model = server._current_model
        original_normalize_clone_reference = server._normalize_clone_reference
        original_resolve_clone_transcript = server._resolve_clone_transcript
        original_get_or_prepare_clone_context = server._get_or_prepare_clone_context
        original_generate_prepared_icl_fn = server._generate_prepared_icl_fn

        try:
            server._current_model = object()
            server._normalize_clone_reference = lambda path: path
            server._resolve_clone_transcript = (
                lambda clean_ref_audio_path, original_ref_audio_path, requested_transcript: requested_transcript or "Prepared transcript"
            )
            server._get_or_prepare_clone_context = (
                lambda clean_ref_audio_path, ref_text: ("prepared-clone-context", True)
            )

            def fake_generate_prepared_icl(model, text, prepared_context, **kwargs):
                calls.append(dict(kwargs))
                yield {"audio": "warmup"}

            server._generate_prepared_icl_fn = fake_generate_prepared_icl

            result = server._run_model_prewarm(
                "clone",
                ref_audio="/tmp/reference.wav",
                ref_text="Reference transcript",
                language="fr",
            )

            assert result["prepared_clone_used"] is True
            assert calls[0]["stream"] is True
            assert calls[0]["language"] == "fr"
            assert (
                result["prewarm_max_tokens"]
                == server.PREWARM_PROFILES["clone_prime"]["max_tokens"]
            )
        finally:
            server._current_model = original_current_model
            server._normalize_clone_reference = original_normalize_clone_reference
            server._resolve_clone_transcript = original_resolve_clone_transcript
            server._get_or_prepare_clone_context = original_get_or_prepare_clone_context
            server._generate_prepared_icl_fn = original_generate_prepared_icl_fn

    def test_handle_generate_prepared_clone_omits_instruct_kwarg():
        calls: list[dict[str, Any]] = []
        final_path = "/tmp/qwenvoice-harness-clone.wav"

        original_current_model = server._current_model
        original_current_model_id = server._current_model_id
        original_ensure_mlx = server._ensure_mlx
        original_resolve_final_output_path = server._resolve_final_output_path
        original_derive_generation_paths = server._derive_generation_paths
        original_normalize_clone_reference = server._normalize_clone_reference
        original_resolve_clone_transcript = server._resolve_clone_transcript
        original_get_or_prepare_clone_context = server._get_or_prepare_clone_context
        original_generate_prepared_icl_fn = server._generate_prepared_icl_fn
        original_collect_generation_result_with_timings = server._collect_generation_result_with_timings
        original_finalize_generated_audio = server._finalize_generated_audio
        original_send_progress = server.send_progress

        try:
            server._current_model = object()
            server._current_model_id = None
            server._ensure_mlx = lambda: None
            server._resolve_final_output_path = lambda output_path, text, mode=None, voice=None, ref_audio=None: final_path
            server._derive_generation_paths = lambda path: (os.path.dirname(path), Path(path).stem, path)
            server._normalize_clone_reference = lambda path: path
            server._resolve_clone_transcript = (
                lambda clean_ref_audio_path, original_ref_audio_path, requested_transcript: requested_transcript or "Prepared transcript"
            )
            server._get_or_prepare_clone_context = (
                lambda clean_ref_audio_path, ref_text: ("prepared-clone-context", True)
            )

            def fake_generate_prepared_icl(model, text, prepared_context, **kwargs):
                calls.append(dict(kwargs))
                yield {"audio": "prepared-clone"}

            server._generate_prepared_icl_fn = fake_generate_prepared_icl
            server._collect_generation_result_with_timings = (
                lambda generator: (next(iter(generator)), server._timing_breakdown_template())
            )
            server._finalize_generated_audio = (
                lambda result, final_path, streaming_used: (
                    {"audio_path": final_path},
                    {},
                    {"duration_seconds": 0.1, "frames": 1},
                    0,
                    server._timing_breakdown_template(),
                )
            )
            server.send_progress = lambda *args, **kwargs: None

            result = server.handle_generate(
                {
                    "text": "Prepared clone release smoke line.",
                    "ref_audio": "/tmp/reference.wav",
                    "ref_text": "Reference transcript",
                }
            )

            assert result["metrics"]["prepared_clone_used"] is True
            assert calls
            assert "instruct" not in calls[0]
            assert "language" not in calls[0]
        finally:
            server._current_model = original_current_model
            server._current_model_id = original_current_model_id
            server._ensure_mlx = original_ensure_mlx
            server._resolve_final_output_path = original_resolve_final_output_path
            server._derive_generation_paths = original_derive_generation_paths
            server._normalize_clone_reference = original_normalize_clone_reference
            server._resolve_clone_transcript = original_resolve_clone_transcript
            server._get_or_prepare_clone_context = original_get_or_prepare_clone_context
            server._generate_prepared_icl_fn = original_generate_prepared_icl_fn
            server._collect_generation_result_with_timings = original_collect_generation_result_with_timings
            server._finalize_generated_audio = original_finalize_generated_audio
            server.send_progress = original_send_progress

    def test_handle_generate_prepared_clone_forwards_explicit_language():
        calls: list[dict[str, Any]] = []
        final_path = "/tmp/qwenvoice-harness-clone-language.wav"

        original_current_model = server._current_model
        original_current_model_id = server._current_model_id
        original_ensure_mlx = server._ensure_mlx
        original_resolve_final_output_path = server._resolve_final_output_path
        original_derive_generation_paths = server._derive_generation_paths
        original_normalize_clone_reference = server._normalize_clone_reference
        original_resolve_clone_transcript = server._resolve_clone_transcript
        original_get_or_prepare_clone_context = server._get_or_prepare_clone_context
        original_generate_prepared_icl_fn = server._generate_prepared_icl_fn
        original_collect_generation_result_with_timings = server._collect_generation_result_with_timings
        original_finalize_generated_audio = server._finalize_generated_audio
        original_send_progress = server.send_progress

        try:
            server._current_model = object()
            server._current_model_id = None
            server._ensure_mlx = lambda: None
            server._resolve_final_output_path = lambda output_path, text, mode=None, voice=None, ref_audio=None: final_path
            server._derive_generation_paths = lambda path: (os.path.dirname(path), Path(path).stem, path)
            server._normalize_clone_reference = lambda path: path
            server._resolve_clone_transcript = (
                lambda clean_ref_audio_path, original_ref_audio_path, requested_transcript: requested_transcript or "Prepared transcript"
            )
            server._get_or_prepare_clone_context = (
                lambda clean_ref_audio_path, ref_text: ("prepared-clone-context", True)
            )

            def fake_generate_prepared_icl(model, text, prepared_context, **kwargs):
                calls.append(dict(kwargs))
                yield {"audio": "prepared-clone"}

            server._generate_prepared_icl_fn = fake_generate_prepared_icl
            server._collect_generation_result_with_timings = (
                lambda generator: (next(iter(generator)), server._timing_breakdown_template())
            )
            server._finalize_generated_audio = (
                lambda result, final_path, streaming_used: (
                    {"audio_path": final_path},
                    {},
                    {"duration_seconds": 0.1, "frames": 1},
                    0,
                    server._timing_breakdown_template(),
                )
            )
            server.send_progress = lambda *args, **kwargs: None

            result = server.handle_generate(
                {
                    "text": "Prepared clone explicit language line.",
                    "ref_audio": "/tmp/reference.wav",
                    "ref_text": "Reference transcript",
                    "language": "fr",
                }
            )

            assert result["metrics"]["prepared_clone_used"] is True
            assert calls[0]["language"] == "fr"
        finally:
            server._current_model = original_current_model
            server._current_model_id = original_current_model_id
            server._ensure_mlx = original_ensure_mlx
            server._resolve_final_output_path = original_resolve_final_output_path
            server._derive_generation_paths = original_derive_generation_paths
            server._normalize_clone_reference = original_normalize_clone_reference
            server._resolve_clone_transcript = original_resolve_clone_transcript
            server._get_or_prepare_clone_context = original_get_or_prepare_clone_context
            server._generate_prepared_icl_fn = original_generate_prepared_icl_fn
            server._collect_generation_result_with_timings = original_collect_generation_result_with_timings
            server._finalize_generated_audio = original_finalize_generated_audio
            server.send_progress = original_send_progress

    def test_handle_prime_clone_reference_prepared_clone_streams_first_chunk():
        calls: list[dict[str, Any]] = []

        original_current_model = server._current_model
        original_current_model_path = server._current_model_path
        original_resolve_model_request = server._resolve_model_request
        original_load_model_request = server._load_model_request
        original_normalize_clone_reference = server._normalize_clone_reference
        original_resolve_clone_transcript = server._resolve_clone_transcript
        original_get_or_prepare_clone_context = server._get_or_prepare_clone_context
        original_generate_prepared_icl_fn = server._generate_prepared_icl_fn
        original_send_progress = server.send_progress
        original_primed_clone_reference_keys = set(server._primed_clone_reference_keys)

        with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
            reference_path = tmp.name
            tmp.write(b"RIFF")
            tmp.flush()

            try:
                server._current_model = object()
                server._current_model_path = "/tmp/pro_clone"
                server._resolve_model_request = lambda model_id=None, model_path=None: (
                    model_path or "/tmp/pro_clone",
                    model_id or "pro_clone",
                )
                server._load_model_request = lambda **kwargs: (
                    {
                        "benchmark": {
                            "timings_ms": {
                                "load_model_total": 0,
                            }
                        }
                    },
                    kwargs.get("model_id") or "pro_clone",
                    kwargs.get("model_path") or "/tmp/pro_clone",
                    False,
                )
                server._normalize_clone_reference = lambda path: path
                server._resolve_clone_transcript = (
                    lambda clean_ref_audio_path, original_ref_audio_path, requested_transcript: requested_transcript or "Prepared transcript"
                )
                server._get_or_prepare_clone_context = (
                    lambda clean_ref_audio_path, ref_text: ("prepared-clone-context", True)
                )

                def fake_generate_prepared_icl(model, text, prepared_context, **kwargs):
                    calls.append(dict(kwargs))
                    yield {"audio": "primed"}

                server._generate_prepared_icl_fn = fake_generate_prepared_icl
                server.send_progress = lambda *args, **kwargs: None
                server._primed_clone_reference_keys.clear()

                result = server.handle_prime_clone_reference(
                    {
                        "model_id": "pro_clone",
                        "ref_audio": reference_path,
                        "ref_text": "Reference transcript",
                        "streaming_interval": 0.32,
                    }
                )

                assert result["prime_applied"] is True
                assert result["prepared_clone_used"] is True
                assert calls
                assert calls[0]["stream"] is True
                assert calls[0]["streaming_interval"] == 0.32
                assert "instruct" not in calls[0]
                assert "language" not in calls[0]
            finally:
                server._current_model = original_current_model
                server._current_model_path = original_current_model_path
                server._resolve_model_request = original_resolve_model_request
                server._load_model_request = original_load_model_request
                server._normalize_clone_reference = original_normalize_clone_reference
                server._resolve_clone_transcript = original_resolve_clone_transcript
                server._get_or_prepare_clone_context = original_get_or_prepare_clone_context
                server._generate_prepared_icl_fn = original_generate_prepared_icl_fn
                server.send_progress = original_send_progress
                server._primed_clone_reference_keys = original_primed_clone_reference_keys

    def test_handle_prime_clone_reference_forwards_explicit_language():
        calls: list[dict[str, Any]] = []

        original_current_model = server._current_model
        original_current_model_path = server._current_model_path
        original_resolve_model_request = server._resolve_model_request
        original_load_model_request = server._load_model_request
        original_normalize_clone_reference = server._normalize_clone_reference
        original_resolve_clone_transcript = server._resolve_clone_transcript
        original_get_or_prepare_clone_context = server._get_or_prepare_clone_context
        original_generate_prepared_icl_fn = server._generate_prepared_icl_fn
        original_send_progress = server.send_progress
        original_primed_clone_reference_keys = set(server._primed_clone_reference_keys)

        with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
            reference_path = tmp.name
            tmp.write(b"RIFF")
            tmp.flush()

            try:
                server._current_model = object()
                server._current_model_path = "/tmp/pro_clone"
                server._resolve_model_request = lambda model_id=None, model_path=None: (
                    model_path or "/tmp/pro_clone",
                    model_id or "pro_clone",
                )
                server._load_model_request = lambda **kwargs: (
                    {
                        "benchmark": {
                            "timings_ms": {
                                "load_model_total": 0,
                            }
                        }
                    },
                    kwargs.get("model_id") or "pro_clone",
                    kwargs.get("model_path") or "/tmp/pro_clone",
                    False,
                )
                server._normalize_clone_reference = lambda path: path
                server._resolve_clone_transcript = (
                    lambda clean_ref_audio_path, original_ref_audio_path, requested_transcript: requested_transcript or "Prepared transcript"
                )
                server._get_or_prepare_clone_context = (
                    lambda clean_ref_audio_path, ref_text: ("prepared-clone-context", True)
                )

                def fake_generate_prepared_icl(model, text, prepared_context, **kwargs):
                    calls.append(dict(kwargs))
                    yield {"audio": "primed"}

                server._generate_prepared_icl_fn = fake_generate_prepared_icl
                server.send_progress = lambda *args, **kwargs: None
                server._primed_clone_reference_keys.clear()

                result = server.handle_prime_clone_reference(
                    {
                        "model_id": "pro_clone",
                        "ref_audio": reference_path,
                        "ref_text": "Reference transcript",
                        "streaming_interval": 0.32,
                        "language": "fr",
                    }
                )

                assert result["prime_applied"] is True
                assert calls[0]["language"] == "fr"
            finally:
                server._current_model = original_current_model
                server._current_model_path = original_current_model_path
                server._resolve_model_request = original_resolve_model_request
                server._load_model_request = original_load_model_request
                server._normalize_clone_reference = original_normalize_clone_reference
                server._resolve_clone_transcript = original_resolve_clone_transcript
                server._get_or_prepare_clone_context = original_get_or_prepare_clone_context
                server._generate_prepared_icl_fn = original_generate_prepared_icl_fn
                server.send_progress = original_send_progress
                server._primed_clone_reference_keys = original_primed_clone_reference_keys

    def test_handle_prepare_clone_reference_cold_and_warm_cache_paths():
        prepare_calls: list[tuple[Any, str, str]] = []
        progress_events: list[tuple[int, str, Any]] = []

        original_current_model = server._current_model
        original_current_model_path = server._current_model_path
        original_resolve_model_request = server._resolve_model_request
        original_load_model_request = server._load_model_request
        original_normalize_clone_reference = server._normalize_clone_reference
        original_resolve_clone_transcript = server._resolve_clone_transcript
        original_prepare_icl_context_fn = server._prepare_icl_context_fn
        original_can_prepare_icl_fn = server._can_prepare_icl_fn
        original_generate_prepared_icl_fn = server._generate_prepared_icl_fn
        original_clone_context_cache = type(server._clone_context_cache)(server._clone_context_cache)
        original_send_progress = server.send_progress

        with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
            reference_path = tmp.name
            tmp.write(b"RIFF")
            tmp.flush()

            try:
                server._current_model = object()
                server._current_model_path = "/tmp/pro_clone"
                server._resolve_model_request = lambda model_id=None, model_path=None: (
                    model_path or "/tmp/pro_clone",
                    model_id or "pro_clone",
                )
                server._load_model_request = lambda **kwargs: (
                    {
                        "benchmark": {
                            "timings_ms": {
                                "load_model_total": 0,
                            }
                        }
                    },
                    kwargs.get("model_id") or "pro_clone",
                    kwargs.get("model_path") or "/tmp/pro_clone",
                    False,
                )
                server._normalize_clone_reference = lambda path: path
                server._resolve_clone_transcript = (
                    lambda clean_ref_audio_path, original_ref_audio_path, requested_transcript: requested_transcript or "Prepared transcript"
                )
                server._can_prepare_icl_fn = lambda model: True

                def fake_prepare_context(model, ref_audio, ref_text, language="auto"):
                    prepare_calls.append((model, ref_audio, ref_text))
                    return {"prepared": ref_text}

                server._prepare_icl_context_fn = fake_prepare_context
                server._generate_prepared_icl_fn = lambda *args, **kwargs: iter(())
                server._clone_context_cache.clear()
                server.send_progress = lambda percent, message, request_id=None: (
                    progress_events.append((percent, message, request_id))
                )

                cold = server.handle_prepare_clone_reference(
                    {
                        "model_id": "pro_clone",
                        "ref_audio": reference_path,
                        "ref_text": "Reference transcript",
                        "benchmark": True,
                    },
                    request_id="req-cold",
                )
                warm = server.handle_prepare_clone_reference(
                    {
                        "model_id": "pro_clone",
                        "ref_audio": reference_path,
                        "ref_text": "Reference transcript",
                        "benchmark": True,
                    },
                    request_id="req-warm",
                )

                assert cold["success"] is True
                assert cold["reference_prepared"] is True
                assert cold["prepared_clone_used"] is True
                assert cold["clone_cache_hit"] is False
                assert "generation" not in cold["benchmark"]["timings_ms"]
                assert "first_stream_chunk" not in cold["benchmark"]["timings_ms"]

                assert warm["success"] is True
                assert warm["reference_prepared"] is True
                assert warm["prepared_clone_used"] is True
                assert warm["clone_cache_hit"] is True
                assert len(prepare_calls) == 1
                assert progress_events == [
                    (20, "Preparing voice context...", "req-cold"),
                    (20, "Preparing voice context...", "req-warm"),
                ]
            finally:
                server._current_model = original_current_model
                server._current_model_path = original_current_model_path
                server._resolve_model_request = original_resolve_model_request
                server._load_model_request = original_load_model_request
                server._normalize_clone_reference = original_normalize_clone_reference
                server._resolve_clone_transcript = original_resolve_clone_transcript
                server._prepare_icl_context_fn = original_prepare_icl_context_fn
                server._can_prepare_icl_fn = original_can_prepare_icl_fn
                server._generate_prepared_icl_fn = original_generate_prepared_icl_fn
                server._clone_context_cache = original_clone_context_cache
                server.send_progress = original_send_progress

    def test_clone_prewarm_reuses_prepared_reference_after_prepare_clone_reference():
        prepare_calls: list[tuple[Any, str, str]] = []
        generate_calls: list[dict[str, Any]] = []

        original_current_model = server._current_model
        original_current_model_path = server._current_model_path
        original_resolve_model_request = server._resolve_model_request
        original_load_model_request = server._load_model_request
        original_normalize_clone_reference = server._normalize_clone_reference
        original_resolve_clone_transcript = server._resolve_clone_transcript
        original_prepare_icl_context_fn = server._prepare_icl_context_fn
        original_can_prepare_icl_fn = server._can_prepare_icl_fn
        original_generate_prepared_icl_fn = server._generate_prepared_icl_fn
        original_clone_context_cache = type(server._clone_context_cache)(server._clone_context_cache)
        original_prewarmed_model_keys = set(server._prewarmed_model_keys)
        original_send_progress = server.send_progress

        with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
            reference_path = tmp.name
            tmp.write(b"RIFF")
            tmp.flush()

            try:
                server._current_model = object()
                server._current_model_path = "/tmp/pro_clone"
                server._resolve_model_request = lambda model_id=None, model_path=None: (
                    model_path or "/tmp/pro_clone",
                    model_id or "pro_clone",
                )
                server._load_model_request = lambda **kwargs: (
                    {
                        "benchmark": {
                            "timings_ms": {
                                "load_model_total": 0,
                            }
                        }
                    },
                    kwargs.get("model_id") or "pro_clone",
                    kwargs.get("model_path") or "/tmp/pro_clone",
                    False,
                )
                server._normalize_clone_reference = lambda path: path
                server._resolve_clone_transcript = (
                    lambda clean_ref_audio_path, original_ref_audio_path, requested_transcript: requested_transcript or "Prepared transcript"
                )
                server._can_prepare_icl_fn = lambda model: True

                def fake_prepare_context(model, ref_audio, ref_text, language="auto"):
                    prepare_calls.append((model, ref_audio, ref_text))
                    return {"prepared": ref_text}

                def fake_generate_prepared_icl(model, text, prepared_context, **kwargs):
                    generate_calls.append(dict(kwargs))
                    yield {"audio": "warm"}

                server._prepare_icl_context_fn = fake_prepare_context
                server._generate_prepared_icl_fn = fake_generate_prepared_icl
                server._clone_context_cache.clear()
                server._prewarmed_model_keys.clear()
                server.send_progress = lambda *args, **kwargs: None

                prepare_result = server.handle_prepare_clone_reference(
                    {
                        "model_id": "pro_clone",
                        "ref_audio": reference_path,
                        "ref_text": "Reference transcript",
                    }
                )
                prewarm_result = server.handle_prewarm_model(
                    {
                        "model_id": "pro_clone",
                        "mode": "clone",
                        "ref_audio": reference_path,
                        "ref_text": "Reference transcript",
                        "benchmark": True,
                    }
                )

                assert prepare_result["reference_prepared"] is True
                assert len(prepare_calls) == 1
                assert prewarm_result["prewarm_applied"] is True
                assert prewarm_result["benchmark"]["prepared_clone_used"] is True
                assert prewarm_result["benchmark"]["clone_cache_hit"] is True
                assert len(prepare_calls) == 1
                assert len(generate_calls) == 1
            finally:
                server._current_model = original_current_model
                server._current_model_path = original_current_model_path
                server._resolve_model_request = original_resolve_model_request
                server._load_model_request = original_load_model_request
                server._normalize_clone_reference = original_normalize_clone_reference
                server._resolve_clone_transcript = original_resolve_clone_transcript
                server._prepare_icl_context_fn = original_prepare_icl_context_fn
                server._can_prepare_icl_fn = original_can_prepare_icl_fn
                server._generate_prepared_icl_fn = original_generate_prepared_icl_fn
                server._clone_context_cache = original_clone_context_cache
                server._prewarmed_model_keys = original_prewarmed_model_keys
                server.send_progress = original_send_progress

    def test_build_mlx_audio_helper_sync_script_no_version_rewrite():
        script_text = (PROJECT_DIR / "scripts/build_mlx_audio_wheel.sh").read_text(encoding="utf-8")
        assert "0.4.1.post1" not in script_text
        assert "pip download" not in script_text
        assert "wheel pack" not in script_text
        assert "mlx_audio_qwen_speed_patch.py" in script_text
        assert not list((PROJECT_DIR / "Sources/Resources/vendor").glob("mlx_audio*.whl"))

    def test_prepare_icl_context_is_language_independent():
        helper, FakeTensor, FakeModel = _load_qwen_speed_patch_module()
        model = FakeModel()
        ref_audio = FakeTensor("reference_audio", (240,))

        prepared_en = helper.prepare_icl_context(
            model,
            ref_audio,
            "Reference transcript",
            language="en",
        )
        prepared_ja = helper.prepare_icl_context(
            model,
            ref_audio,
            "Reference transcript",
            language="ja",
        )

        assert prepared_en.clean_ref_text == "Reference transcript"
        assert prepared_en.clean_ref_text == prepared_ja.clean_ref_text
        assert prepared_en.ref_codes == prepared_ja.ref_codes
        assert prepared_en.ref_text_embed == prepared_ja.ref_text_embed
        assert prepared_en.codec_with_text_pad == prepared_ja.codec_with_text_pad
        assert prepared_en.speaker_embed == prepared_ja.speaker_embed
        assert not hasattr(prepared_en, "language")

    def test_request_time_language_changes_do_not_rebuild_reference_state():
        helper, FakeTensor, FakeModel = _load_qwen_speed_patch_module()
        model = FakeModel()
        prepared = helper.prepare_icl_context(
            model,
            FakeTensor("reference_audio", (240,)),
            "Reference transcript",
            language="auto",
        )
        ref_encode_calls = model.speech_tokenizer.encode_calls

        en_inputs, _, en_ref_codes = helper.prepare_icl_generation_inputs_from_context(
            model,
            "Target line",
            prepared,
            language="en",
        )
        ja_inputs, _, ja_ref_codes = helper.prepare_icl_generation_inputs_from_context(
            model,
            "Target line",
            prepared,
            language="ja",
        )

        assert model.speech_tokenizer.encode_calls == ref_encode_calls
        assert en_ref_codes == prepared.ref_codes
        assert ja_ref_codes == prepared.ref_codes
        assert en_inputs != ja_inputs

    def test_model_static_icl_cache_supports_unhashable_models():
        helper, _, FakeModel = _load_qwen_speed_patch_module()
        model = FakeModel()

        first_static = helper._get_model_static_icl(model)
        second_static = helper._get_model_static_icl(model)

        assert first_static is second_static
        assert len(helper._MODEL_STATIC_CACHE) == 1

    def test_model_static_icl_cache_isolated_per_model_instance():
        helper, _, FakeModel = _load_qwen_speed_patch_module()
        first_model = FakeModel()
        second_model = FakeModel()

        first_static = helper._get_model_static_icl(first_model)
        second_static = helper._get_model_static_icl(second_model)

        assert first_static is not second_static
        assert len(helper._MODEL_STATIC_CACHE) == 2

    def test_clone_packaged_regression_classifier_detects_packaged_app_regression():
        from harness_lib.clone_packaged_regression_runner import classify_packaged_clone_regression

        medians = {
            "legacy": {
                "clone_fast_ready_ms": 900.0,
                "first_preview_prepared_ms": 1100.0,
                "first_chunk_ms": 1700.0,
            },
            "current": {
                "clone_fast_ready_ms": 1350.0,
                "first_preview_prepared_ms": 1600.0,
                "first_chunk_ms": 2500.0,
            },
        }

        classification = classify_packaged_clone_regression(medians)

        assert classification["source"] == "packaged_app_regression"
        assert "clone_fast_ready_ms" in classification["slower_metrics"]
        assert "first_preview_prepared_ms" in classification["slower_metrics"]
        assert "first_chunk_ms" in classification["slower_metrics"]

    def test_clone_packaged_regression_classifier_handles_similar_medians():
        from harness_lib.clone_packaged_regression_runner import classify_packaged_clone_regression

        medians = {
            "legacy": {
                "clone_fast_ready_ms": 1000.0,
                "first_preview_prepared_ms": 1400.0,
                "first_chunk_ms": 2000.0,
            },
            "current": {
                "clone_fast_ready_ms": 1080.0,
                "first_preview_prepared_ms": 1490.0,
                "first_chunk_ms": 2100.0,
            },
        }

        classification = classify_packaged_clone_regression(medians)

        assert classification["source"] == "local_state_or_machine_environment"
        assert classification["slower_metrics"] == []

    def _bundled_qwen3_tts_source_path(name: str) -> Path | None:
        site_packages_roots = sorted(
            (PROJECT_DIR / "Sources/Resources/python/lib").glob("python*/site-packages")
        )
        if not site_packages_roots:
            return None
        source_path = site_packages_roots[-1] / "mlx_audio/tts/models/qwen3_tts" / name
        assert source_path.exists(), f"Expected bundled mlx-audio source at {source_path}"
        return source_path

    def test_overlay_source_marks_upstream_rebase_seams():
        overlay_text = (
            PROJECT_DIR / "third_party_patches/mlx-audio/qwenvoice_speed_patch.py"
        ).read_text(encoding="utf-8")

        assert "_prepare_icl_generation_inputs" in overlay_text
        assert "_generate_icl" in overlay_text
        assert "`batch_generate`" in overlay_text
        assert "Streaming clone requests must fall back to repeated single-item paths" in overlay_text

    def test_bundled_qwen3_tts_upstream_seams_are_present():
        qwen3_tts_path = _bundled_qwen3_tts_source_path("qwen3_tts.py")
        speech_tokenizer_path = _bundled_qwen3_tts_source_path("speech_tokenizer.py")
        if qwen3_tts_path is None or speech_tokenizer_path is None:
            return {
                "skip_reason": (
                    "Bundled Python site-packages are not present in this lightweight "
                    "test environment; packaged release verification covers bundled "
                    "upstream seam checks."
                )
            }

        qwen3_tts_text = qwen3_tts_path.read_text(encoding="utf-8")
        speech_tokenizer_text = speech_tokenizer_path.read_text(encoding="utf-8")

        assert "def _prepare_icl_generation_inputs(" in qwen3_tts_text
        assert "def _generate_icl(" in qwen3_tts_text
        assert "def batch_generate(" in qwen3_tts_text
        assert "def _sample_token(" in qwen3_tts_text
        assert "def _sample_token_batch(" in qwen3_tts_text
        assert "talker.make_cache()" in qwen3_tts_text
        assert "talker.code_predictor.make_cache()" in qwen3_tts_text
        assert "decoder.reset_streaming_state" in qwen3_tts_text
        assert "decoder.streaming_step" in qwen3_tts_text
        assert "def batch_decode(" in speech_tokenizer_text

    def test_ensure_mlx_prefers_standalone_overlay():
        standalone_can_prepare = lambda model: "standalone"
        standalone_prepare = lambda *args, **kwargs: "standalone-prepare"
        standalone_generate = lambda *args, **kwargs: "standalone-generate"
        standalone_batch = lambda *args, **kwargs: "standalone-batch"
        standalone_enable = lambda *args, **kwargs: True

        upstream_can_prepare = lambda model: "upstream"

        numpy_module = types.ModuleType("numpy")
        mx_core_module = types.ModuleType("mlx.core")
        mlx_module = types.ModuleType("mlx")
        mlx_module.__path__ = []
        mlx_module.core = mx_core_module

        mlx_audio_module = types.ModuleType("mlx_audio")
        mlx_audio_module.__path__ = []
        mlx_audio_tts_module = types.ModuleType("mlx_audio.tts")
        mlx_audio_tts_module.__path__ = []

        tts_utils_module = types.ModuleType("mlx_audio.tts.utils")
        tts_utils_module.load_model = lambda path: ("load_model", path)

        tts_generate_module = types.ModuleType("mlx_audio.tts.generate")
        tts_generate_module.generate_audio = lambda **kwargs: ("generate_audio", kwargs)

        audio_io_module = types.ModuleType("mlx_audio.audio_io")
        audio_io_module.write = lambda *args, **kwargs: None

        standalone_module = types.ModuleType("mlx_audio_qwen_speed_patch")
        standalone_module.can_prepare_icl = standalone_can_prepare
        standalone_module.prepare_icl_context = standalone_prepare
        standalone_module.generate_with_prepared_icl = standalone_generate
        standalone_module.batch_generate_with_prepared_icl = standalone_batch
        standalone_module.try_enable_speech_tokenizer_encoder = standalone_enable

        upstream_module = types.ModuleType("mlx_audio.qwenvoice_speed_patch")
        upstream_module.can_prepare_icl = upstream_can_prepare
        upstream_module.prepare_icl_context = lambda *args, **kwargs: "upstream-prepare"
        upstream_module.generate_with_prepared_icl = lambda *args, **kwargs: "upstream-generate"
        upstream_module.batch_generate_with_prepared_icl = lambda *args, **kwargs: "upstream-batch"
        upstream_module.try_enable_speech_tokenizer_encoder = lambda *args, **kwargs: False

        replacements = {
            "numpy": numpy_module,
            "mlx": mlx_module,
            "mlx.core": mx_core_module,
            "mlx_audio": mlx_audio_module,
            "mlx_audio.tts": mlx_audio_tts_module,
            "mlx_audio.tts.utils": tts_utils_module,
            "mlx_audio.tts.generate": tts_generate_module,
            "mlx_audio.audio_io": audio_io_module,
            "mlx_audio_qwen_speed_patch": standalone_module,
            "mlx_audio.qwenvoice_speed_patch": upstream_module,
        }

        original_state = (
            server._load_model_fn,
            server._generate_audio_fn,
            server._audio_write_fn,
            server._mx,
            server._np,
            server._can_prepare_icl_fn,
            server._prepare_icl_context_fn,
            server._generate_prepared_icl_fn,
            server._batch_generate_prepared_icl_fn,
            server._enable_speech_tokenizer_encoder_fn,
            server._mlx_audio_version,
        )

        try:
            server._load_model_fn = None
            server._generate_audio_fn = None
            server._audio_write_fn = None
            server._mx = None
            server._np = None
            server._can_prepare_icl_fn = None
            server._prepare_icl_context_fn = None
            server._generate_prepared_icl_fn = None
            server._batch_generate_prepared_icl_fn = None
            server._enable_speech_tokenizer_encoder_fn = None
            server._mlx_audio_version = None

            with _temporary_sys_modules(replacements):
                server._ensure_mlx()

            assert server._can_prepare_icl_fn is standalone_can_prepare
            assert server._prepare_icl_context_fn is standalone_prepare
            assert server._generate_prepared_icl_fn is standalone_generate
            assert server._batch_generate_prepared_icl_fn is standalone_batch
            assert server._enable_speech_tokenizer_encoder_fn is standalone_enable
        finally:
            (
                server._load_model_fn,
                server._generate_audio_fn,
                server._audio_write_fn,
                server._mx,
                server._np,
                server._can_prepare_icl_fn,
                server._prepare_icl_context_fn,
                server._generate_prepared_icl_fn,
                server._batch_generate_prepared_icl_fn,
                server._enable_speech_tokenizer_encoder_fn,
                server._mlx_audio_version,
            ) = original_state

    def test_handle_generate_clone_batch_uses_shared_prepared_reference_once():
        prepare_calls = 0
        normalize_calls = 0
        transcript_calls = 0
        batch_calls: list[dict[str, Any]] = []

        original_current_model = server._current_model
        original_current_model_id = server._current_model_id
        original_ensure_mlx = server._ensure_mlx
        original_resolve_final_output_path = server._resolve_final_output_path
        original_normalize_clone_reference = server._normalize_clone_reference
        original_resolve_clone_transcript = server._resolve_clone_transcript
        original_get_or_prepare_clone_context = server._get_or_prepare_clone_context
        original_generate_prepared_icl_fn = server._generate_prepared_icl_fn
        original_batch_generate_prepared_icl_fn = server._batch_generate_prepared_icl_fn
        original_build_clone_fallback_generator = server._build_clone_fallback_generator
        original_finalize_generated_audio = server._finalize_generated_audio
        original_send_progress = server.send_progress

        class FakeBatchResult:
            def __init__(self, sequence_idx: int) -> None:
                self.sequence_idx = sequence_idx

        class FakeBatchModel:
            def __init__(self) -> None:
                self.config = types.SimpleNamespace(tts_model_type="base")
                self._sample_token_batch = object()
                self.speech_tokenizer = types.SimpleNamespace(batch_decode=lambda *args, **kwargs: None)

        try:
            clone_model_id = server.MODELS_BY_MODE["clone"]["id"]
            server._current_model = FakeBatchModel()
            server._current_model_id = clone_model_id
            server._ensure_mlx = lambda: None
            server._resolve_final_output_path = (
                lambda output_path, text, mode=None, voice=None, ref_audio=None: output_path
            )

            def fake_normalize(path: str) -> str:
                nonlocal normalize_calls
                normalize_calls += 1
                return "/tmp/normalized-reference.wav"

            def fake_resolve(
                clean_ref_audio_path: str,
                original_ref_audio_path: str | None,
                requested_transcript: str | None,
            ) -> str:
                nonlocal transcript_calls
                transcript_calls += 1
                return requested_transcript or "Resolved transcript"

            def fake_prepare(clean_ref_audio_path: str, ref_text: str):
                nonlocal prepare_calls
                prepare_calls += 1
                return "prepared-context", False

            def fake_batch_generate(model, texts, prepared_context, **kwargs):
                batch_calls.append(dict(kwargs))
                assert prepared_context == "prepared-context"
                for index, _ in enumerate(texts):
                    yield FakeBatchResult(index)

            server._normalize_clone_reference = fake_normalize
            server._resolve_clone_transcript = fake_resolve
            server._get_or_prepare_clone_context = fake_prepare
            server._generate_prepared_icl_fn = lambda *args, **kwargs: iter(())
            server._batch_generate_prepared_icl_fn = fake_batch_generate
            server._build_clone_fallback_generator = lambda *args, **kwargs: (_ for _ in ()).throw(
                AssertionError("Clone batch fast path should not use single-item fallback")
            )
            server._finalize_generated_audio = (
                lambda result, final_path, streaming_used: (
                    {"audio_path": final_path, "duration_seconds": 0.2},
                    {"token_count": 1},
                    {"duration_seconds": 0.2},
                    0,
                    server._timing_breakdown_template(),
                )
            )
            server.send_progress = lambda *args, **kwargs: None

            result = server.handle_generate_clone_batch(
                {
                    "texts": ["One", "Two", "Three"],
                    "ref_audio": "/tmp/reference.wav",
                    "ref_text": "Reference transcript",
                    "output_paths": ["/tmp/one.wav", "/tmp/two.wav", "/tmp/three.wav"],
                }
            )

            assert prepare_calls == 1
            assert normalize_calls == 1
            assert transcript_calls == 1
            assert len(batch_calls) == 1
            assert "language" not in batch_calls[0]
            assert len(result) == 3
            assert all(item["metrics"]["prepared_clone_used"] is True for item in result)
            assert all(item["metrics"]["batch_generation_used"] is True for item in result)
            assert all(item["metrics"]["clone_cache_hit"] is False for item in result)
        finally:
            server._current_model = original_current_model
            server._current_model_id = original_current_model_id
            server._ensure_mlx = original_ensure_mlx
            server._resolve_final_output_path = original_resolve_final_output_path
            server._normalize_clone_reference = original_normalize_clone_reference
            server._resolve_clone_transcript = original_resolve_clone_transcript
            server._get_or_prepare_clone_context = original_get_or_prepare_clone_context
            server._generate_prepared_icl_fn = original_generate_prepared_icl_fn
            server._batch_generate_prepared_icl_fn = original_batch_generate_prepared_icl_fn
            server._build_clone_fallback_generator = original_build_clone_fallback_generator
            server._finalize_generated_audio = original_finalize_generated_audio
            server.send_progress = original_send_progress

    def test_handle_generate_clone_batch_forwards_explicit_language_to_batch_fast_path():
        batch_calls: list[dict[str, Any]] = []

        original_current_model = server._current_model
        original_current_model_id = server._current_model_id
        original_ensure_mlx = server._ensure_mlx
        original_resolve_final_output_path = server._resolve_final_output_path
        original_normalize_clone_reference = server._normalize_clone_reference
        original_resolve_clone_transcript = server._resolve_clone_transcript
        original_get_or_prepare_clone_context = server._get_or_prepare_clone_context
        original_generate_prepared_icl_fn = server._generate_prepared_icl_fn
        original_batch_generate_prepared_icl_fn = server._batch_generate_prepared_icl_fn
        original_build_clone_fallback_generator = server._build_clone_fallback_generator
        original_finalize_generated_audio = server._finalize_generated_audio
        original_send_progress = server.send_progress

        class FakeBatchResult:
            def __init__(self, sequence_idx: int) -> None:
                self.sequence_idx = sequence_idx

        class FakeBatchModel:
            def __init__(self) -> None:
                self.config = types.SimpleNamespace(tts_model_type="base")
                self._sample_token_batch = object()
                self.speech_tokenizer = types.SimpleNamespace(batch_decode=lambda *args, **kwargs: None)

        try:
            clone_model_id = server.MODELS_BY_MODE["clone"]["id"]
            server._current_model = FakeBatchModel()
            server._current_model_id = clone_model_id
            server._ensure_mlx = lambda: None
            server._resolve_final_output_path = (
                lambda output_path, text, mode=None, voice=None, ref_audio=None: output_path
            )
            server._normalize_clone_reference = lambda path: "/tmp/normalized-reference.wav"
            server._resolve_clone_transcript = (
                lambda clean_ref_audio_path, original_ref_audio_path, requested_transcript: requested_transcript or "Resolved transcript"
            )
            server._get_or_prepare_clone_context = (
                lambda clean_ref_audio_path, ref_text: ("prepared-context", False)
            )
            server._generate_prepared_icl_fn = lambda *args, **kwargs: iter(())

            def fake_batch_generate(model, texts, prepared_context, **kwargs):
                batch_calls.append(dict(kwargs))
                for index, _ in enumerate(texts):
                    yield FakeBatchResult(index)

            server._batch_generate_prepared_icl_fn = fake_batch_generate
            server._build_clone_fallback_generator = lambda *args, **kwargs: (_ for _ in ()).throw(
                AssertionError("Explicit-language batch fast path should not use fallback")
            )
            server._finalize_generated_audio = (
                lambda result, final_path, streaming_used: (
                    {"audio_path": final_path, "duration_seconds": 0.2},
                    {"token_count": 1},
                    {"duration_seconds": 0.2},
                    0,
                    server._timing_breakdown_template(),
                )
            )
            server.send_progress = lambda *args, **kwargs: None

            result = server.handle_generate_clone_batch(
                {
                    "texts": ["One", "Two"],
                    "ref_audio": "/tmp/reference.wav",
                    "ref_text": "Reference transcript",
                    "output_paths": ["/tmp/one.wav", "/tmp/two.wav"],
                    "language": "fr",
                }
            )

            assert len(batch_calls) == 1
            assert batch_calls[0]["language"] == "fr"
            assert len(result) == 2
        finally:
            server._current_model = original_current_model
            server._current_model_id = original_current_model_id
            server._ensure_mlx = original_ensure_mlx
            server._resolve_final_output_path = original_resolve_final_output_path
            server._normalize_clone_reference = original_normalize_clone_reference
            server._resolve_clone_transcript = original_resolve_clone_transcript
            server._get_or_prepare_clone_context = original_get_or_prepare_clone_context
            server._generate_prepared_icl_fn = original_generate_prepared_icl_fn
            server._batch_generate_prepared_icl_fn = original_batch_generate_prepared_icl_fn
            server._build_clone_fallback_generator = original_build_clone_fallback_generator
            server._finalize_generated_audio = original_finalize_generated_audio
            server.send_progress = original_send_progress

    def test_handle_generate_clone_batch_stream_request_falls_back_to_prepared_single_item_generation():
        prepare_calls = 0
        normalize_calls = 0
        transcript_calls = 0
        batch_calls = 0
        prepared_calls: list[dict[str, Any]] = []

        original_current_model = server._current_model
        original_current_model_id = server._current_model_id
        original_ensure_mlx = server._ensure_mlx
        original_resolve_final_output_path = server._resolve_final_output_path
        original_normalize_clone_reference = server._normalize_clone_reference
        original_resolve_clone_transcript = server._resolve_clone_transcript
        original_get_or_prepare_clone_context = server._get_or_prepare_clone_context
        original_generate_prepared_icl_fn = server._generate_prepared_icl_fn
        original_batch_generate_prepared_icl_fn = server._batch_generate_prepared_icl_fn
        original_build_clone_fallback_generator = server._build_clone_fallback_generator
        original_collect_generation_result_with_timings = server._collect_generation_result_with_timings
        original_finalize_generated_audio = server._finalize_generated_audio
        original_send_progress = server.send_progress

        class FakePreparedBatchModel:
            def __init__(self) -> None:
                self.config = types.SimpleNamespace(tts_model_type="base")
                self._sample_token_batch = object()
                self.speech_tokenizer = types.SimpleNamespace(
                    batch_decode=lambda *args, **kwargs: None
                )

        try:
            clone_model_id = server.MODELS_BY_MODE["clone"]["id"]
            server._current_model = FakePreparedBatchModel()
            server._current_model_id = clone_model_id
            server._ensure_mlx = lambda: None
            server._resolve_final_output_path = (
                lambda output_path, text, mode=None, voice=None, ref_audio=None: output_path
            )

            def fake_normalize(path: str) -> str:
                nonlocal normalize_calls
                normalize_calls += 1
                return "/tmp/normalized-reference.wav"

            def fake_resolve(
                clean_ref_audio_path: str,
                original_ref_audio_path: str | None,
                requested_transcript: str | None,
            ) -> str:
                nonlocal transcript_calls
                transcript_calls += 1
                return requested_transcript or "Resolved transcript"

            def fake_prepare(clean_ref_audio_path: str, ref_text: str):
                nonlocal prepare_calls
                prepare_calls += 1
                return "prepared-context", False

            def fake_generate_prepared(model, text, prepared_context, **kwargs):
                prepared_calls.append(
                    {
                        "text": text,
                        "prepared_context": prepared_context,
                        **kwargs,
                    }
                )
                yield types.SimpleNamespace(audio="audio", sample_rate=24_000)

            def fake_batch_generate(*args, **kwargs):
                nonlocal batch_calls
                batch_calls += 1
                raise AssertionError("Streaming clone batch requests should not use the batch fast path")

            server._normalize_clone_reference = fake_normalize
            server._resolve_clone_transcript = fake_resolve
            server._get_or_prepare_clone_context = fake_prepare
            server._generate_prepared_icl_fn = fake_generate_prepared
            server._batch_generate_prepared_icl_fn = fake_batch_generate
            server._build_clone_fallback_generator = lambda *args, **kwargs: (_ for _ in ()).throw(
                AssertionError("Prepared single-item fallback should stay available")
            )
            server._collect_generation_result_with_timings = (
                lambda generator: (next(iter(generator)), server._timing_breakdown_template())
            )
            server._finalize_generated_audio = (
                lambda result, final_path, streaming_used: (
                    {"audio_path": final_path, "duration_seconds": 0.2},
                    {"token_count": 1},
                    {"duration_seconds": 0.2},
                    0,
                    server._timing_breakdown_template(),
                )
            )
            server.send_progress = lambda *args, **kwargs: None

            result = server.handle_generate_clone_batch(
                {
                    "texts": ["One", "Two"],
                    "ref_audio": "/tmp/reference.wav",
                    "ref_text": "Reference transcript",
                    "output_paths": ["/tmp/one.wav", "/tmp/two.wav"],
                    "stream": True,
                }
            )

            assert prepare_calls == 1
            assert normalize_calls == 1
            assert transcript_calls == 1
            assert batch_calls == 0
            assert len(prepared_calls) == 2
            assert all(call["prepared_context"] == "prepared-context" for call in prepared_calls)
            assert all(call["stream"] is False for call in prepared_calls)
            assert all("language" not in call for call in prepared_calls)
            assert all(item["metrics"]["prepared_clone_used"] is True for item in result)
            assert all(item["metrics"]["batch_generation_used"] is False for item in result)
        finally:
            server._current_model = original_current_model
            server._current_model_id = original_current_model_id
            server._ensure_mlx = original_ensure_mlx
            server._resolve_final_output_path = original_resolve_final_output_path
            server._normalize_clone_reference = original_normalize_clone_reference
            server._resolve_clone_transcript = original_resolve_clone_transcript
            server._get_or_prepare_clone_context = original_get_or_prepare_clone_context
            server._generate_prepared_icl_fn = original_generate_prepared_icl_fn
            server._batch_generate_prepared_icl_fn = original_batch_generate_prepared_icl_fn
            server._build_clone_fallback_generator = original_build_clone_fallback_generator
            server._collect_generation_result_with_timings = original_collect_generation_result_with_timings
            server._finalize_generated_audio = original_finalize_generated_audio
            server.send_progress = original_send_progress

    def test_handle_generate_clone_batch_falls_back_when_batch_capabilities_are_missing():
        prepare_calls = 0
        normalize_calls = 0
        transcript_calls = 0
        prepared_calls: list[dict[str, Any]] = []

        original_current_model = server._current_model
        original_current_model_id = server._current_model_id
        original_ensure_mlx = server._ensure_mlx
        original_resolve_final_output_path = server._resolve_final_output_path
        original_normalize_clone_reference = server._normalize_clone_reference
        original_resolve_clone_transcript = server._resolve_clone_transcript
        original_get_or_prepare_clone_context = server._get_or_prepare_clone_context
        original_generate_prepared_icl_fn = server._generate_prepared_icl_fn
        original_batch_generate_prepared_icl_fn = server._batch_generate_prepared_icl_fn
        original_build_clone_fallback_generator = server._build_clone_fallback_generator
        original_collect_generation_result_with_timings = server._collect_generation_result_with_timings
        original_finalize_generated_audio = server._finalize_generated_audio
        original_send_progress = server.send_progress

        class MissingBatchCapabilityModel:
            def __init__(self) -> None:
                self.config = types.SimpleNamespace(tts_model_type="base")
                self.speech_tokenizer = types.SimpleNamespace(
                    batch_decode=lambda *args, **kwargs: None
                )

        try:
            clone_model_id = server.MODELS_BY_MODE["clone"]["id"]
            server._current_model = MissingBatchCapabilityModel()
            server._current_model_id = clone_model_id
            server._ensure_mlx = lambda: None
            server._resolve_final_output_path = (
                lambda output_path, text, mode=None, voice=None, ref_audio=None: output_path
            )

            def fake_normalize(path: str) -> str:
                nonlocal normalize_calls
                normalize_calls += 1
                return "/tmp/normalized-reference.wav"

            def fake_resolve(
                clean_ref_audio_path: str,
                original_ref_audio_path: str | None,
                requested_transcript: str | None,
            ) -> str:
                nonlocal transcript_calls
                transcript_calls += 1
                return requested_transcript or "Resolved transcript"

            def fake_prepare(clean_ref_audio_path: str, ref_text: str):
                nonlocal prepare_calls
                prepare_calls += 1
                return "prepared-context", False

            def fake_generate_prepared(model, text, prepared_context, **kwargs):
                prepared_calls.append(
                    {
                        "text": text,
                        "prepared_context": prepared_context,
                        **kwargs,
                    }
                )
                yield types.SimpleNamespace(audio="audio", sample_rate=24_000)

            server._normalize_clone_reference = fake_normalize
            server._resolve_clone_transcript = fake_resolve
            server._get_or_prepare_clone_context = fake_prepare
            server._generate_prepared_icl_fn = fake_generate_prepared
            server._batch_generate_prepared_icl_fn = lambda *args, **kwargs: (_ for _ in ()).throw(
                AssertionError("Missing batch capabilities should bypass the fast path")
            )
            server._build_clone_fallback_generator = lambda *args, **kwargs: (_ for _ in ()).throw(
                AssertionError("Prepared single-item fallback should handle missing batch capabilities")
            )
            server._collect_generation_result_with_timings = (
                lambda generator: (next(iter(generator)), server._timing_breakdown_template())
            )
            server._finalize_generated_audio = (
                lambda result, final_path, streaming_used: (
                    {"audio_path": final_path, "duration_seconds": 0.2},
                    {"token_count": 1},
                    {"duration_seconds": 0.2},
                    0,
                    server._timing_breakdown_template(),
                )
            )
            server.send_progress = lambda *args, **kwargs: None

            result = server.handle_generate_clone_batch(
                {
                    "texts": ["One", "Two"],
                    "ref_audio": "/tmp/reference.wav",
                    "ref_text": "Reference transcript",
                    "output_paths": ["/tmp/one.wav", "/tmp/two.wav"],
                }
            )

            assert prepare_calls == 1
            assert normalize_calls == 1
            assert transcript_calls == 1
            assert len(prepared_calls) == 2
            assert all(call["prepared_context"] == "prepared-context" for call in prepared_calls)
            assert all(call["stream"] is False for call in prepared_calls)
            assert all("language" not in call for call in prepared_calls)
            assert all(item["metrics"]["prepared_clone_used"] is True for item in result)
            assert all(item["metrics"]["batch_generation_used"] is False for item in result)
        finally:
            server._current_model = original_current_model
            server._current_model_id = original_current_model_id
            server._ensure_mlx = original_ensure_mlx
            server._resolve_final_output_path = original_resolve_final_output_path
            server._normalize_clone_reference = original_normalize_clone_reference
            server._resolve_clone_transcript = original_resolve_clone_transcript
            server._get_or_prepare_clone_context = original_get_or_prepare_clone_context
            server._generate_prepared_icl_fn = original_generate_prepared_icl_fn
            server._batch_generate_prepared_icl_fn = original_batch_generate_prepared_icl_fn
            server._build_clone_fallback_generator = original_build_clone_fallback_generator
            server._collect_generation_result_with_timings = original_collect_generation_result_with_timings
            server._finalize_generated_audio = original_finalize_generated_audio
            server.send_progress = original_send_progress

    def test_handle_generate_clone_batch_falls_back_without_prepared_or_batch_helpers():
        normalize_calls = 0
        transcript_calls = 0
        prepare_calls = 0
        fallback_calls: list[dict[str, Any]] = []

        original_current_model = server._current_model
        original_current_model_id = server._current_model_id
        original_ensure_mlx = server._ensure_mlx
        original_resolve_final_output_path = server._resolve_final_output_path
        original_normalize_clone_reference = server._normalize_clone_reference
        original_resolve_clone_transcript = server._resolve_clone_transcript
        original_get_or_prepare_clone_context = server._get_or_prepare_clone_context
        original_batch_generate_prepared_icl_fn = server._batch_generate_prepared_icl_fn
        original_build_clone_fallback_generator = server._build_clone_fallback_generator
        original_collect_generation_result_with_timings = server._collect_generation_result_with_timings
        original_finalize_generated_audio = server._finalize_generated_audio
        original_send_progress = server.send_progress

        try:
            clone_model_id = server.MODELS_BY_MODE["clone"]["id"]
            server._current_model = object()
            server._current_model_id = clone_model_id
            server._ensure_mlx = lambda: None
            server._resolve_final_output_path = (
                lambda output_path, text, mode=None, voice=None, ref_audio=None: output_path
            )

            def fake_normalize(path: str) -> str:
                nonlocal normalize_calls
                normalize_calls += 1
                return "/tmp/normalized-reference.wav"

            def fake_resolve(
                clean_ref_audio_path: str,
                original_ref_audio_path: str | None,
                requested_transcript: str | None,
            ) -> str:
                nonlocal transcript_calls
                transcript_calls += 1
                return requested_transcript or "Resolved transcript"

            def fake_prepare(clean_ref_audio_path: str, ref_text: str):
                nonlocal prepare_calls
                prepare_calls += 1
                return None, None

            def fake_fallback_generator(model, text, temperature, clean_ref_audio, resolved_ref_text, **kwargs):
                fallback_calls.append(
                    {
                        "text": text,
                        "clean_ref_audio": clean_ref_audio,
                        "resolved_ref_text": resolved_ref_text,
                        **kwargs,
                    }
                )
                yield types.SimpleNamespace(audio="audio", sample_rate=24_000)

            server._normalize_clone_reference = fake_normalize
            server._resolve_clone_transcript = fake_resolve
            server._get_or_prepare_clone_context = fake_prepare
            server._batch_generate_prepared_icl_fn = None
            server._build_clone_fallback_generator = fake_fallback_generator
            server._collect_generation_result_with_timings = (
                lambda generator: (next(iter(generator)), server._timing_breakdown_template())
            )
            server._finalize_generated_audio = (
                lambda result, final_path, streaming_used: (
                    {"audio_path": final_path, "duration_seconds": 0.2},
                    {"token_count": 1},
                    {"duration_seconds": 0.2},
                    0,
                    server._timing_breakdown_template(),
                )
            )
            server.send_progress = lambda *args, **kwargs: None

            result = server.handle_generate_clone_batch(
                {
                    "texts": ["One", "Two"],
                    "ref_audio": "/tmp/reference.wav",
                    "ref_text": "Reference transcript",
                    "output_paths": ["/tmp/one.wav", "/tmp/two.wav"],
                }
            )

            assert prepare_calls == 1
            assert normalize_calls == 1
            assert transcript_calls == 1
            assert len(fallback_calls) == 2
            assert all("language" not in call for call in fallback_calls)
            assert all(item["metrics"]["prepared_clone_used"] is False for item in result)
            assert all(item["metrics"]["batch_generation_used"] is False for item in result)
        finally:
            server._current_model = original_current_model
            server._current_model_id = original_current_model_id
            server._ensure_mlx = original_ensure_mlx
            server._resolve_final_output_path = original_resolve_final_output_path
            server._normalize_clone_reference = original_normalize_clone_reference
            server._resolve_clone_transcript = original_resolve_clone_transcript
            server._get_or_prepare_clone_context = original_get_or_prepare_clone_context
            server._batch_generate_prepared_icl_fn = original_batch_generate_prepared_icl_fn
            server._build_clone_fallback_generator = original_build_clone_fallback_generator
            server._collect_generation_result_with_timings = original_collect_generation_result_with_timings
            server._finalize_generated_audio = original_finalize_generated_audio
            server.send_progress = original_send_progress

    def test_handle_generate_clone_single_falls_back_without_prepared_helper():
        fallback_calls: list[dict[str, Any]] = []
        final_path = "/tmp/qwenvoice-harness-clone-fallback.wav"

        original_current_model = server._current_model
        original_current_model_id = server._current_model_id
        original_ensure_mlx = server._ensure_mlx
        original_resolve_final_output_path = server._resolve_final_output_path
        original_derive_generation_paths = server._derive_generation_paths
        original_normalize_clone_reference = server._normalize_clone_reference
        original_resolve_clone_transcript = server._resolve_clone_transcript
        original_get_or_prepare_clone_context = server._get_or_prepare_clone_context
        original_build_clone_fallback_generator = server._build_clone_fallback_generator
        original_collect_generation_result_with_timings = server._collect_generation_result_with_timings
        original_finalize_generated_audio = server._finalize_generated_audio
        original_send_progress = server.send_progress

        try:
            clone_model_id = server.MODELS_BY_MODE["clone"]["id"]
            server._current_model = object()
            server._current_model_id = clone_model_id
            server._ensure_mlx = lambda: None
            server._resolve_final_output_path = lambda output_path, text, mode=None, voice=None, ref_audio=None: final_path
            server._derive_generation_paths = lambda path: (os.path.dirname(path), Path(path).stem, path)
            server._normalize_clone_reference = lambda path: path
            server._resolve_clone_transcript = (
                lambda clean_ref_audio_path, original_ref_audio_path, requested_transcript: requested_transcript or "Resolved transcript"
            )
            server._get_or_prepare_clone_context = lambda clean_ref_audio_path, ref_text: (None, None)

            def fake_fallback_generator(model, text, temperature, clean_ref_audio, resolved_ref_text, **kwargs):
                fallback_calls.append(
                    {
                        "text": text,
                        "clean_ref_audio": clean_ref_audio,
                        "resolved_ref_text": resolved_ref_text,
                        **kwargs,
                    }
                )
                yield types.SimpleNamespace(audio="audio", sample_rate=24_000)

            server._build_clone_fallback_generator = fake_fallback_generator
            server._collect_generation_result_with_timings = (
                lambda generator: (next(iter(generator)), server._timing_breakdown_template())
            )
            server._finalize_generated_audio = (
                lambda result, final_path, streaming_used: (
                    {"audio_path": final_path},
                    {},
                    {"duration_seconds": 0.1, "frames": 1},
                    0,
                    server._timing_breakdown_template(),
                )
            )
            server.send_progress = lambda *args, **kwargs: None

            result = server.handle_generate(
                {
                    "text": "Clone fallback line.",
                    "ref_audio": "/tmp/reference.wav",
                    "ref_text": "Reference transcript",
                }
            )

            assert len(fallback_calls) == 1
            assert "language" not in fallback_calls[0]
            assert result["metrics"]["prepared_clone_used"] is False
            assert result["metrics"]["clone_cache_hit"] is None
        finally:
            server._current_model = original_current_model
            server._current_model_id = original_current_model_id
            server._ensure_mlx = original_ensure_mlx
            server._resolve_final_output_path = original_resolve_final_output_path
            server._derive_generation_paths = original_derive_generation_paths
            server._normalize_clone_reference = original_normalize_clone_reference
            server._resolve_clone_transcript = original_resolve_clone_transcript
            server._get_or_prepare_clone_context = original_get_or_prepare_clone_context
            server._build_clone_fallback_generator = original_build_clone_fallback_generator
            server._collect_generation_result_with_timings = original_collect_generation_result_with_timings
            server._finalize_generated_audio = original_finalize_generated_audio
            server.send_progress = original_send_progress

    def test_handle_generate_clone_single_fallback_forwards_explicit_language():
        fallback_calls: list[dict[str, Any]] = []
        final_path = "/tmp/qwenvoice-harness-clone-fallback-language.wav"

        original_current_model = server._current_model
        original_current_model_id = server._current_model_id
        original_ensure_mlx = server._ensure_mlx
        original_resolve_final_output_path = server._resolve_final_output_path
        original_derive_generation_paths = server._derive_generation_paths
        original_normalize_clone_reference = server._normalize_clone_reference
        original_resolve_clone_transcript = server._resolve_clone_transcript
        original_get_or_prepare_clone_context = server._get_or_prepare_clone_context
        original_build_clone_fallback_generator = server._build_clone_fallback_generator
        original_collect_generation_result_with_timings = server._collect_generation_result_with_timings
        original_finalize_generated_audio = server._finalize_generated_audio
        original_send_progress = server.send_progress

        try:
            clone_model_id = server.MODELS_BY_MODE["clone"]["id"]
            server._current_model = object()
            server._current_model_id = clone_model_id
            server._ensure_mlx = lambda: None
            server._resolve_final_output_path = lambda output_path, text, mode=None, voice=None, ref_audio=None: final_path
            server._derive_generation_paths = lambda path: (os.path.dirname(path), Path(path).stem, path)
            server._normalize_clone_reference = lambda path: path
            server._resolve_clone_transcript = (
                lambda clean_ref_audio_path, original_ref_audio_path, requested_transcript: requested_transcript or "Resolved transcript"
            )
            server._get_or_prepare_clone_context = lambda clean_ref_audio_path, ref_text: (None, None)

            def fake_fallback_generator(model, text, temperature, clean_ref_audio, resolved_ref_text, **kwargs):
                fallback_calls.append(
                    {
                        "text": text,
                        "clean_ref_audio": clean_ref_audio,
                        "resolved_ref_text": resolved_ref_text,
                        **kwargs,
                    }
                )
                yield types.SimpleNamespace(audio="audio", sample_rate=24_000)

            server._build_clone_fallback_generator = fake_fallback_generator
            server._collect_generation_result_with_timings = (
                lambda generator: (next(iter(generator)), server._timing_breakdown_template())
            )
            server._finalize_generated_audio = (
                lambda result, final_path, streaming_used: (
                    {"audio_path": final_path},
                    {},
                    {"duration_seconds": 0.1, "frames": 1},
                    0,
                    server._timing_breakdown_template(),
                )
            )
            server.send_progress = lambda *args, **kwargs: None

            result = server.handle_generate(
                {
                    "text": "Clone fallback explicit language line.",
                    "ref_audio": "/tmp/reference.wav",
                    "ref_text": "Reference transcript",
                    "language": "fr",
                }
            )

            assert len(fallback_calls) == 1
            assert fallback_calls[0]["language"] == "fr"
            assert result["metrics"]["prepared_clone_used"] is False
        finally:
            server._current_model = original_current_model
            server._current_model_id = original_current_model_id
            server._ensure_mlx = original_ensure_mlx
            server._resolve_final_output_path = original_resolve_final_output_path
            server._derive_generation_paths = original_derive_generation_paths
            server._normalize_clone_reference = original_normalize_clone_reference
            server._resolve_clone_transcript = original_resolve_clone_transcript
            server._get_or_prepare_clone_context = original_get_or_prepare_clone_context
            server._build_clone_fallback_generator = original_build_clone_fallback_generator
            server._collect_generation_result_with_timings = original_collect_generation_result_with_timings
            server._finalize_generated_audio = original_finalize_generated_audio
            server.send_progress = original_send_progress

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

    def test_convert_audio_if_needed_falls_back_to_ffmpeg_for_webm():
        with tempfile.NamedTemporaryFile(suffix=".webm", delete=False) as tmp:
            input_path = tmp.name

        original_audio_write_fn = server._audio_write_fn
        original_convert_audio_with_mlx = server._convert_audio_with_mlx
        original_convert_audio_to_wav = server._convert_audio_to_wav
        fallback_calls: list[tuple[str, str]] = []

        try:
            server._audio_write_fn = object()

            def fake_convert_audio_with_mlx(input_path, output_path):
                raise ValueError("webm is not supported by the mlx conversion path")

            def fake_convert_audio_to_wav(input_path, output_path):
                fallback_calls.append((input_path, output_path))
                return output_path

            server._convert_audio_with_mlx = fake_convert_audio_with_mlx
            server._convert_audio_to_wav = fake_convert_audio_to_wav

            wav_path = server.convert_audio_if_needed(input_path)

            assert len(fallback_calls) == 1
            assert fallback_calls[0][0] == input_path
            assert fallback_calls[0][1].endswith(".wav")
            assert wav_path == fallback_calls[0][1]
        finally:
            server._audio_write_fn = original_audio_write_fn
            server._convert_audio_with_mlx = original_convert_audio_with_mlx
            server._convert_audio_to_wav = original_convert_audio_to_wav
            os.unlink(input_path)

    def test_resolve_clone_transcript_prefers_original_reference_sidecar():
        with tempfile.TemporaryDirectory(prefix="qwenvoice_clone_transcript_") as tmp_dir:
            original_path = os.path.join(tmp_dir, "reference.wav")
            normalized_path = os.path.join(tmp_dir, "normalized.wav")
            original_sidecar = os.path.splitext(original_path)[0] + ".txt"
            normalized_sidecar = os.path.splitext(normalized_path)[0] + ".txt"

            Path(original_path).write_bytes(b"RIFF")
            Path(normalized_path).write_bytes(b"RIFF")
            Path(original_sidecar).write_text("Original sidecar transcript", encoding="utf-8")
            Path(normalized_sidecar).write_text("Normalized sidecar transcript", encoding="utf-8")

            resolved = server._resolve_clone_transcript(
                normalized_path,
                original_path,
                None,
            )

            assert resolved == "Original sidecar transcript"

    def test_normalize_clone_reference_trim_falls_back_when_trimmed_audio_is_too_short():
        import struct
        import wave

        original_trim_enabled = server.EXPERIMENTAL_CLONE_REF_TRIM
        original_trim_helper = server._trim_clone_reference_silence
        original_metrics = dict(getattr(server, "_last_clone_reference_metrics", {}))

        with tempfile.TemporaryDirectory(prefix="qwenvoice_clone_trim_") as tmp_dir:
            input_path = os.path.join(tmp_dir, "reference.wav")

            with wave.open(input_path, "wb") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)
                wf.setframerate(24000)
                wf.writeframes(struct.pack("<" + "h" * 24000, *([0] * 24000)))

            def fake_trim(input_path, output_path):
                with wave.open(output_path, "wb") as wf:
                    wf.setnchannels(1)
                    wf.setsampwidth(2)
                    wf.setframerate(24000)
                    wf.writeframes(struct.pack("<" + "h" * 1200, *([0] * 1200)))
                return output_path

            try:
                server.EXPERIMENTAL_CLONE_REF_TRIM = True
                server._trim_clone_reference_silence = fake_trim

                normalized = server._normalize_clone_reference(input_path)

                assert normalized == input_path
                assert server._last_clone_reference_metrics["trim_applied"] is False
                assert server._last_clone_reference_metrics["trim_status"] == "trim_rejected_too_short"
            finally:
                server.EXPERIMENTAL_CLONE_REF_TRIM = original_trim_enabled
                server._trim_clone_reference_silence = original_trim_helper
                server._last_clone_reference_metrics = original_metrics

    def test_tts_roundtrip_word_error_rate_normalizes_punctuation():
        from harness_lib.tts_roundtrip_runner import normalize_wer_text, word_error_rate

        assert normalize_wer_text("Hello, QwenVoice!") == ["hello", "qwenvoice"]
        assert word_error_rate(
            "The package is ready.",
            "the package is ready",
        ) == 0.0

    def test_tts_roundtrip_runtime_variant_labels_known_paths():
        from harness_lib.paths import APP_VENV_PYTHON, BUNDLED_PYTHON_BIN
        from harness_lib.tts_roundtrip_runner import _runtime_variant_label

        assert _runtime_variant_label(str(APP_VENV_PYTHON)) == "app_support_venv"
        assert _runtime_variant_label(str(BUNDLED_PYTHON_BIN)) == "bundled_runtime"
        assert _runtime_variant_label("/tmp/custom/python3") == "custom_python"

    def test_tts_roundtrip_helper_variant_defaults_to_current_overlay():
        from harness_lib.tts_roundtrip_runner import _helper_variant_label

        original = os.environ.pop("QWENVOICE_MLX_AUDIO_HELPER_VARIANT", None)
        try:
            assert _helper_variant_label() == "current_overlay"
            os.environ["QWENVOICE_MLX_AUDIO_HELPER_VARIANT"] = "audit_candidate_a"
            assert _helper_variant_label() == "audit_candidate_a"
        finally:
            if original is None:
                os.environ.pop("QWENVOICE_MLX_AUDIO_HELPER_VARIANT", None)
            else:
                os.environ["QWENVOICE_MLX_AUDIO_HELPER_VARIANT"] = original

    def test_stream_selected_audio_emits_chunks_before_final_write():
        try:
            import numpy as np
        except ImportError:
            return {"skip_reason": "numpy not installed in the active python3 environment"}

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
        ("meaningful_delivery_instruction", test_meaningful_delivery_various),
        ("design_prewarm_identity_ignores_instruction", test_design_prewarm_identity_ignores_instruction),
        ("custom_prewarm_identity_tracks_shape", test_custom_prewarm_identity_tracks_voice_and_instruction),
        ("build_generation_kwargs_omits_auto_language", test_build_generation_kwargs_omits_auto_language),
        ("build_generation_kwargs_includes_explicit_language", test_build_generation_kwargs_includes_explicit_language),
        ("latency_first_chunk_uses_received_notification_timestamp", test_latency_first_chunk_uses_received_notification_timestamp),
        ("latency_generate_params_use_streaming_and_design_instruct", test_latency_generate_params_use_streaming_and_design_instruct),
        ("clone_regression_reference_falls_back_to_committed_fixture", test_clone_regression_reference_falls_back_to_committed_fixture),
        ("unload_model_clears_prewarm_and_clone_prime_state", test_unload_model_clears_prewarm_and_clone_prime_state),
        ("custom_prewarm_primes_streaming_generator", test_custom_prewarm_primes_streaming_generator),
        ("clone_prewarm_prepared_generator_omits_instruct_kwarg", test_clone_prewarm_prepared_generator_omits_instruct_kwarg),
        ("clone_prewarm_prepared_generator_forwards_explicit_language", test_clone_prewarm_prepared_generator_forwards_explicit_language),
        ("handle_generate_prepared_clone_omits_instruct_kwarg", test_handle_generate_prepared_clone_omits_instruct_kwarg),
        ("handle_generate_prepared_clone_forwards_explicit_language", test_handle_generate_prepared_clone_forwards_explicit_language),
        ("handle_prime_clone_reference_prepared_clone_streams_first_chunk", test_handle_prime_clone_reference_prepared_clone_streams_first_chunk),
        ("handle_prime_clone_reference_forwards_explicit_language", test_handle_prime_clone_reference_forwards_explicit_language),
        ("handle_prepare_clone_reference_cold_and_warm_cache_paths", test_handle_prepare_clone_reference_cold_and_warm_cache_paths),
        ("clone_prewarm_reuses_prepared_reference_after_prepare_clone_reference", test_clone_prewarm_reuses_prepared_reference_after_prepare_clone_reference),
        ("build_mlx_audio_helper_sync_script_no_version_rewrite", test_build_mlx_audio_helper_sync_script_no_version_rewrite),
        ("prepare_icl_context_is_language_independent", test_prepare_icl_context_is_language_independent),
        ("request_time_language_changes_do_not_rebuild_reference_state", test_request_time_language_changes_do_not_rebuild_reference_state),
        ("model_static_icl_cache_supports_unhashable_models", test_model_static_icl_cache_supports_unhashable_models),
        ("model_static_icl_cache_isolated_per_model_instance", test_model_static_icl_cache_isolated_per_model_instance),
        ("clone_packaged_regression_classifier_detects_packaged_app_regression", test_clone_packaged_regression_classifier_detects_packaged_app_regression),
        ("clone_packaged_regression_classifier_handles_similar_medians", test_clone_packaged_regression_classifier_handles_similar_medians),
        ("overlay_source_marks_upstream_rebase_seams", test_overlay_source_marks_upstream_rebase_seams),
        ("bundled_qwen3_tts_upstream_seams_are_present", test_bundled_qwen3_tts_upstream_seams_are_present),
        ("ensure_mlx_prefers_standalone_overlay", test_ensure_mlx_prefers_standalone_overlay),
        ("handle_generate_clone_batch_uses_shared_prepared_reference_once", test_handle_generate_clone_batch_uses_shared_prepared_reference_once),
        ("handle_generate_clone_batch_forwards_explicit_language_to_batch_fast_path", test_handle_generate_clone_batch_forwards_explicit_language_to_batch_fast_path),
        ("handle_generate_clone_batch_stream_request_falls_back_to_prepared_single_item_generation", test_handle_generate_clone_batch_stream_request_falls_back_to_prepared_single_item_generation),
        ("handle_generate_clone_batch_falls_back_when_batch_capabilities_are_missing", test_handle_generate_clone_batch_falls_back_when_batch_capabilities_are_missing),
        ("handle_generate_clone_batch_falls_back_without_prepared_or_batch_helpers", test_handle_generate_clone_batch_falls_back_without_prepared_or_batch_helpers),
        ("handle_generate_clone_single_falls_back_without_prepared_helper", test_handle_generate_clone_single_falls_back_without_prepared_helper),
        ("handle_generate_clone_single_fallback_forwards_explicit_language", test_handle_generate_clone_single_fallback_forwards_explicit_language),
        ("collect_generation_result_with_timings", test_collect_generation_result_with_timings_captures_first_yield),
        ("stream_selected_audio_emits_chunks_before_final_write", test_stream_selected_audio_emits_chunks_before_final_write),
        ("infer_legacy_mode", test_infer_legacy_mode),
        ("make_output_path", test_make_output_path),
        ("get_audio_metadata_missing", test_get_audio_metadata_missing),
        ("get_audio_metadata_valid", test_get_audio_metadata_valid),
        ("convert_audio_if_needed_falls_back_to_ffmpeg_for_webm", test_convert_audio_if_needed_falls_back_to_ffmpeg_for_webm),
        ("resolve_clone_transcript_prefers_original_reference_sidecar", test_resolve_clone_transcript_prefers_original_reference_sidecar),
        ("normalize_clone_reference_trim_falls_back_when_trimmed_audio_is_too_short", test_normalize_clone_reference_trim_falls_back_when_trimmed_audio_is_too_short),
        ("tts_roundtrip_word_error_rate_normalizes_punctuation", test_tts_roundtrip_word_error_rate_normalizes_punctuation),
        ("tts_roundtrip_runtime_variant_labels_known_paths", test_tts_roundtrip_runtime_variant_labels_known_paths),
        ("tts_roundtrip_helper_variant_defaults_to_current_overlay", test_tts_roundtrip_helper_variant_defaults_to_current_overlay),
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
                backend_models = [m for m in result if isinstance(m, dict)]
            elif isinstance(result, dict) and "models" in result:
                backend_models = [m for m in result["models"] if isinstance(m, dict)]
            else:
                backend_models = []
            backend_ids = {m.get("id") or m.get("model_id") for m in backend_models}
            assert backend_ids == contract_ids, (
                f"Model ID mismatch: backend={backend_ids}, contract={contract_ids}"
            )
            required_fields = {
                "resolved_path",
                "downloaded",
                "complete",
                "repairable",
                "missing_required_paths",
                "size_bytes",
            }
            for model_info in backend_models:
                missing_fields = required_fields - set(model_info.keys())
                assert not missing_fields, (
                    f"Model info missing fields for {model_info.get('id')}: {sorted(missing_fields)}"
                )
                assert isinstance(model_info["downloaded"], bool), (
                    f"downloaded must be bool for {model_info.get('id')}"
                )
                assert isinstance(model_info["complete"], bool), (
                    f"complete must be bool for {model_info.get('id')}"
                )
                assert isinstance(model_info["repairable"], bool), (
                    f"repairable must be bool for {model_info.get('id')}"
                )
                assert isinstance(model_info["missing_required_paths"], list), (
                    f"missing_required_paths must be list for {model_info.get('id')}"
                )
                assert isinstance(model_info["size_bytes"], int), (
                    f"size_bytes must be int for {model_info.get('id')}"
                )
                if model_info["complete"]:
                    assert model_info["downloaded"], (
                        f"complete model must also be downloaded for {model_info.get('id')}"
                    )
                    assert not model_info["repairable"], (
                        f"complete model must not be repairable for {model_info.get('id')}"
                    )
                    assert not model_info["missing_required_paths"], (
                        f"complete model must not report missing files for {model_info.get('id')}"
                    )
                if model_info["repairable"]:
                    assert model_info["downloaded"], (
                        f"repairable model must report downloaded for {model_info.get('id')}"
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


def _ui_test_appearance() -> str:
    raw = os.environ.get("QWENVOICE_UI_TEST_APPEARANCE", "").strip().lower()
    if raw in {"light", "dark"}:
        return raw
    return "system"


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
        requires_app_support_python=False,
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
    models_ok = bool(prerequisites["installed_models"])
    results.append(build_test_result(
        "live_native_models_available",
        passed=models_ok or not requires_models,
        skip_reason=None if requires_models or models_ok else "Installed models are only required for live generation checks",
        details={
            "models_dir": prerequisites["models_dir"],
            "installed_models": prerequisites["installed_models"],
            "required_for_target": requires_models,
        },
    ))

    python_ok = True
    if backend_mode == "live" and requires_app_support_python:
        python_ok = bool(prerequisites.get("python_exists"))
        results.append(build_test_result(
            "live_python_compat_available",
            passed=python_ok,
            details={
                "python_path": prerequisites.get("python_path"),
                "required_for_target": True,
            },
        ))
    if backend_mode == "live" and python_ok and requires_app_support_python:
        runtime_ok, runtime_details = _validate_python_runtime_imports(prerequisites["python_path"])
        results.append(build_test_result(
            "live_python_compat_runtime_validation",
            passed=runtime_ok,
            details=runtime_details,
        ))
        python_ok = python_ok and runtime_ok

    return (models_ok or not requires_models) and (python_ok or not requires_app_support_python)


def _validate_python_runtime_imports(python_path: str, timeout: int = 30) -> tuple[bool, dict[str, Any]]:
    import_script = (
        "import mlx; import mlx.core as mx; import mlx_audio; import transformers; "
        "import numpy; import soundfile; import huggingface_hub; "
        "x = mx.array([1.0], dtype=mx.float32); mx.eval(x)"
    )
    try:
        proc = subprocess.run(
            [python_path, "-c", import_script],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return False, {
            "python_path": python_path,
            "timeout_s": timeout,
            "error": "runtime_validation_timeout",
        }

    return proc.returncode == 0, {
        "python_path": python_path,
        "returncode": proc.returncode,
        "stdout_tail": proc.stdout.splitlines()[-20:],
        "stderr_tail": proc.stderr.splitlines()[-20:],
    }


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

    runtime_source = state.get("runtimeSource")
    active_python_path = state.get("activePythonPath", "")
    active_ffmpeg_path = state.get("activeFFmpegPath", "")
    normalized_active_python_path = _normalize_runtime_path(active_python_path)
    normalized_active_ffmpeg_path = _normalize_runtime_path(active_ffmpeg_path)

    results.append(build_test_result(
        "native_runtime_source",
        passed=runtime_source == "native",
        details={
            "runtimeSource": runtime_source,
            "expected": "native",
        },
    ))
    results.append(build_test_result(
        "native_runtime_python_absent",
        passed=normalized_active_python_path == "",
        details={
            "activePythonPath": active_python_path,
            "normalizedActivePythonPath": normalized_active_python_path,
            "expected": "",
        },
    ))
    results.append(build_test_result(
        "native_runtime_ffmpeg_absent",
        passed=normalized_active_ffmpeg_path == "",
        details={
            "activeFFmpegPath": active_ffmpeg_path,
            "normalizedActiveFFmpegPath": normalized_active_ffmpeg_path,
            "expected": "",
        },
    ))

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

def _is_process_running(process_name: str) -> bool:
    proc = subprocess.run(
        ["pgrep", "-x", process_name],
        capture_output=True,
        text=True,
    )
    return proc.returncode == 0


def _wait_for_process_running(process_name: str, timeout_s: float) -> bool:
    deadline = time.perf_counter() + timeout_s
    while time.perf_counter() < deadline:
        if _is_process_running(process_name):
            return True
        time.sleep(0.1)
    return _is_process_running(process_name)


def _run_packaged_startup_smoke(
    app_target: UIAppTarget,
    *,
    backend_mode: str,
    data_root: str,
    variant_label: str,
) -> dict[str, Any]:
    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    if not _append_live_preflight_results_for_target(
        results,
        backend_mode,
        requires_app_support_python=False,
        requires_models=False,
    ):
        duration_ms = int((time.perf_counter() - start) * 1000)
        return _prefix_suite(build_suite_result("packaged_startup_smoke", results, duration_ms), variant_label)

    context = prepare_ui_launch_context(backend_mode=backend_mode, data_root=data_root)
    results.append(build_test_result(
        "packaged_launch_context",
        passed=True,
        details=describe_launch_context(context),
    ))

    app_proc: subprocess.Popen[Any] | None = None
    try:
        kill_running_app_instances()
        env = build_ui_launch_environment(context)
        app_proc = launch_ui_app(str(app_target.app_binary), env)
        started = _wait_for_process_running("QwenVoice", timeout_s=20.0)
        stable = False
        if started:
            time.sleep(2.0)
            stable = _is_process_running("QwenVoice")
        results.append(build_test_result(
            "packaged_app_launches",
            passed=started and stable,
            details={
                "app_bundle": str(app_target.app_bundle),
                "variant_id": app_target.variant_id,
                "ui_profile": app_target.ui_profile,
                "backend_mode": backend_mode,
                "data_root": data_root,
            },
            error=None if started and stable else "Packaged app did not stay running long enough to pass startup smoke",
        ))
    finally:
        _terminate_ui_process(app_proc)
        cleanup_ui_launch_context(context)

    duration_ms = int((time.perf_counter() - start) * 1000)
    return _prefix_suite(build_suite_result("packaged_startup_smoke", results, duration_ms), variant_label)


def _run_release_generation_smoke(
    backend_mode: str = "live",
    data_root: str = "fixture",
    *,
    app_bundle: str | None = None,
    dmg: str | None = None,
    app_target: UIAppTarget | None = None,
) -> dict[str, Any]:
    """Retire the old packaged generation smoke that depended on localhost UI control."""
    details = {
        "backend_mode": backend_mode,
        "data_root": data_root,
        "app_bundle": app_bundle,
        "dmg": dmg,
        "app_target_source": app_target.source if app_target is not None else None,
    }
    return build_suite_result(
        "release_generation_smoke",
        [
            build_test_result(
                "release_generation_smoke_retired",
                passed=True,
                skip_reason="Packaged generation smoke depended on the retired localhost UI control plane. Use release bundle verification plus source-native generation checks instead.",
                details=details,
            )
        ],
        0,
    )


def _run_release_tests(
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
            suites.append(_run_packaged_startup_smoke(
                target,
                backend_mode="live",
                data_root="fixture",
                variant_label=variant_label,
            ))
            suites.append(_prefix_suite(_run_release_generation_smoke(
                backend_mode="live",
                data_root="fixture",
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
                "-enableCodeCoverage", "NO",
                "-quiet",
            ],
            capture_output=True,
            text=True,
            timeout=resolve_xcodebuild_timeout_seconds(),
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
