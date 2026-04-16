"""Serialized clone helper/runtime regression isolation for QwenVoice."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import textwrap
import time
import zipfile
from datetime import datetime
from pathlib import Path
from typing import Any

from .output import build_suite_result, build_test_result, eprint
from .paths import (
    APP_MODELS_DIR,
    APP_SUPPORT_DIR,
    CONTRACT_PATH,
    PROJECT_DIR,
    ensure_directory,
    resolve_backend_python,
)

OLD_HELPER_REF = "7f0da86"
OLD_WHEEL_REF = "7f0da86:Sources/Resources/vendor/mlx_audio-0.4.1.post1-py3-none-any.whl"
REFERENCE_AUDIO_PATH = APP_SUPPORT_DIR / "voices" / "Un_homme_Francais.wav"
REFERENCE_TEXT_PATH = APP_SUPPORT_DIR / "voices" / "Un_homme_Francais.txt"
COMMITTED_REFERENCE_AUDIO_PATH = PROJECT_DIR / "tests" / "fixtures" / "release_clone_reference.wav"
COMMITTED_REFERENCE_TEXT_PATH = PROJECT_DIR / "tests" / "fixtures" / "release_clone_reference.txt"
CLONE_MODEL_ID = "pro_clone"
BENCH_TEXT = "Bonjour toi."
BENCH_LANGUAGE = "fr"
BENCH_TEMPERATURE = 0.6
BENCH_MAX_TOKENS = 48
SIMILAR_RATIO_THRESHOLD = 1.15
SIMILAR_DELTA_THRESHOLD_SECONDS = 0.15
RUNTIME_LEGACY = "legacy_mlx_audio_041_post1"
RUNTIME_CURRENT = "current_mlx_audio_042"


def resolve_clone_regression_reference() -> tuple[Path, Path] | None:
    candidates = (
        (REFERENCE_AUDIO_PATH, REFERENCE_TEXT_PATH),
        (COMMITTED_REFERENCE_AUDIO_PATH, COMMITTED_REFERENCE_TEXT_PATH),
    )
    for audio_path, text_path in candidates:
        if audio_path.exists() and text_path.exists():
            return audio_path, text_path
    return None


def run_clone_regression_bench(
    python_path: str | None = None,
    output_dir: str | None = None,
) -> dict[str, Any]:
    """Compare legacy/current helper and runtime combinations in serialized child processes."""
    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    try:
        resolved_python = resolve_backend_python(python_path)
    except RuntimeError as exc:
        results.append(
            build_test_result(
                "clone_regression_python_available",
                passed=False,
                skip_reason=str(exc),
            )
        )
        return build_suite_result("clone_regression", results, 0)

    reference_fixture = resolve_clone_regression_reference()
    if reference_fixture is None:
        results.append(
            build_test_result(
                "clone_regression_reference_available",
                passed=True,
                skip_reason=(
                    "Missing clone regression reference at either "
                    f"{REFERENCE_AUDIO_PATH} / {REFERENCE_TEXT_PATH} or "
                    f"{COMMITTED_REFERENCE_AUDIO_PATH} / {COMMITTED_REFERENCE_TEXT_PATH}"
                ),
            )
        )
        return build_suite_result(
            "clone_regression",
            results,
            int((time.perf_counter() - start) * 1000),
        )
    reference_audio_path, reference_text_path = reference_fixture

    try:
        clone_model_path = _resolve_clone_model_path(CLONE_MODEL_ID)
    except RuntimeError as exc:
        results.append(
            build_test_result(
                "clone_regression_model_available",
                passed=True,
                skip_reason=str(exc),
            )
        )
        return build_suite_result(
            "clone_regression",
            results,
            int((time.perf_counter() - start) * 1000),
        )

    preflight_snapshot = _active_heavy_processes(resolved_python)
    if preflight_snapshot["backend_python"] or preflight_snapshot["qwenvoice_app"]:
        results.append(
            build_test_result(
                "clone_regression_preflight_idle",
                passed=False,
                error=(
                    "Close QwenVoice and any backend Python/model process before running "
                    "clone regression benchmarks."
                ),
                details=preflight_snapshot,
            )
        )
        return build_suite_result(
            "clone_regression",
            results,
            int((time.perf_counter() - start) * 1000),
        )

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    bench_dir = Path(output_dir) if output_dir else PROJECT_DIR / "build" / "benchmarks" / timestamp
    ensure_directory(bench_dir)

    ref_text = reference_text_path.read_text(encoding="utf-8").strip()
    benchmark_details = {
        "reference_audio": str(reference_audio_path),
        "reference_text_path": str(reference_text_path),
        "text": BENCH_TEXT,
        "language": BENCH_LANGUAGE,
        "temperature": BENCH_TEMPERATURE,
        "max_tokens": BENCH_MAX_TOKENS,
        "model_id": CLONE_MODEL_ID,
        "model_path": str(clone_model_path),
        "old_helper_ref": OLD_HELPER_REF,
        "legacy_runtime_ref": OLD_WHEEL_REF,
    }
    results.append(
        build_test_result(
            "clone_regression_configuration",
            passed=True,
            details=benchmark_details,
        )
    )

    with tempfile.TemporaryDirectory(prefix="qwenvoice-clone-regression-") as temp_dir:
        temp_root = Path(temp_dir)
        try:
            legacy_runtime_root = _extract_legacy_runtime(temp_root)
        except Exception as exc:
            results.append(
                build_test_result(
                    "clone_regression_extract_legacy_runtime",
                    passed=False,
                    error=str(exc),
                )
            )
            return build_suite_result(
                "clone_regression",
                results,
                int((time.perf_counter() - start) * 1000),
            )

        legacy_old_result = _run_serialized_arm(
            results=results,
            arm_name="clone_regression_legacy_runtime_old_helper",
            idle_check_name="clone_regression_after_legacy_runtime_old_helper_idle",
            resolved_python=resolved_python,
            runtime_mode=RUNTIME_LEGACY,
            helper_mode="old",
            legacy_runtime_root=legacy_runtime_root,
            model_path=str(clone_model_path),
            ref_audio=str(reference_audio_path),
            ref_text=ref_text,
        )
        if legacy_old_result is None:
            return build_suite_result(
                "clone_regression",
                results,
                int((time.perf_counter() - start) * 1000),
            )

        current_old_result = _run_serialized_arm(
            results=results,
            arm_name="clone_regression_current_runtime_old_helper",
            idle_check_name="clone_regression_after_current_runtime_old_helper_idle",
            resolved_python=resolved_python,
            runtime_mode=RUNTIME_CURRENT,
            helper_mode="old",
            legacy_runtime_root=None,
            model_path=str(clone_model_path),
            ref_audio=str(reference_audio_path),
            ref_text=ref_text,
        )
        if current_old_result is None:
            return build_suite_result(
                "clone_regression",
                results,
                int((time.perf_counter() - start) * 1000),
            )

        current_current_result = _run_serialized_arm(
            results=results,
            arm_name="clone_regression_current_runtime_current_helper",
            idle_check_name="clone_regression_after_current_runtime_current_helper_idle",
            resolved_python=resolved_python,
            runtime_mode=RUNTIME_CURRENT,
            helper_mode="current",
            legacy_runtime_root=None,
            model_path=str(clone_model_path),
            ref_audio=str(reference_audio_path),
            ref_text=ref_text,
        )
        if current_current_result is None:
            return build_suite_result(
                "clone_regression",
                results,
                int((time.perf_counter() - start) * 1000),
            )

    classification = _classify_regression_source(
        legacy_old_result=legacy_old_result,
        current_old_result=current_old_result,
        current_current_result=current_current_result,
    )
    results.append(
        build_test_result(
            "clone_regression_source",
            passed=True,
            details=classification,
        )
    )

    artifact_path = bench_dir / "clone_regression.json"
    artifact_path.write_text(
        json.dumps(
            {
                "configuration": benchmark_details,
                "legacy_runtime_old_helper": legacy_old_result,
                "current_runtime_old_helper": current_old_result,
                "current_runtime_current_helper": current_current_result,
                "classification": classification,
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    results.append(
        build_test_result(
            "clone_regression_artifact",
            passed=True,
            details={"path": str(artifact_path)},
        )
    )

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("clone_regression", results, duration_ms)


def _run_serialized_arm(
    *,
    results: list[dict[str, Any]],
    arm_name: str,
    idle_check_name: str,
    resolved_python: str,
    runtime_mode: str,
    helper_mode: str,
    legacy_runtime_root: str | None,
    model_path: str,
    ref_audio: str,
    ref_text: str,
) -> dict[str, Any] | None:
    try:
        arm_result = _run_helper_process(
            resolved_python=resolved_python,
            runtime_mode=runtime_mode,
            helper_mode=helper_mode,
            legacy_runtime_root=legacy_runtime_root,
            model_path=model_path,
            ref_audio=ref_audio,
            ref_text=ref_text,
        )
        results.append(
            build_test_result(
                arm_name,
                passed=True,
                details=arm_result,
            )
        )
    except Exception as exc:
        results.append(
            build_test_result(
                arm_name,
                passed=False,
                error=str(exc),
            )
        )
        return None

    post_snapshot = _active_heavy_processes(resolved_python)
    if post_snapshot["backend_python"] or post_snapshot["qwenvoice_app"]:
        results.append(
            build_test_result(
                idle_check_name,
                passed=False,
                error=f"Lingering heavy process detected after {arm_name}.",
                details=post_snapshot,
            )
        )
        return None

    return arm_result


def _run_helper_process(
    *,
    resolved_python: str,
    runtime_mode: str,
    helper_mode: str,
    legacy_runtime_root: str | None,
    model_path: str,
    ref_audio: str,
    ref_text: str,
) -> dict[str, Any]:
    child_script = textwrap.dedent(
        """
        import gc
        import inspect
        import importlib.metadata as importlib_metadata
        import importlib.util
        import json
        import os
        import subprocess
        import sys
        import time
        import types
        from pathlib import Path

        project_dir = Path(sys.argv[1])
        runtime_mode = sys.argv[2]
        helper_mode = sys.argv[3]
        legacy_runtime_root = sys.argv[4]
        model_path = sys.argv[5]
        ref_audio = sys.argv[6]
        ref_text = sys.argv[7]
        text = sys.argv[8]
        language = sys.argv[9]
        temperature = float(sys.argv[10])
        max_tokens = int(sys.argv[11])
        helper_ref = sys.argv[12]

        if legacy_runtime_root:
            sys.path.insert(0, legacy_runtime_root)

        def load_old_helper():
            source = subprocess.check_output(
                ["git", "show", f"{helper_ref}:third_party_patches/mlx-audio/qwenvoice_speed_patch.py"],
                cwd=project_dir,
                text=True,
            )
            module_name = "qwenvoice_speed_patch_122"
            module = types.ModuleType(module_name)
            module.__file__ = str(project_dir / "third_party_patches" / "mlx-audio" / "qwenvoice_speed_patch.py")
            sys.modules[module_name] = module
            exec(compile(source, module.__file__, "exec"), module.__dict__)
            return module

        def load_current_helper():
            helper_path = project_dir / "third_party_patches" / "mlx-audio" / "qwenvoice_speed_patch.py"
            module_name = "qwenvoice_speed_patch_current"
            spec = importlib.util.spec_from_file_location(module_name, helper_path)
            module = importlib.util.module_from_spec(spec)
            sys.modules[module_name] = module
            assert spec.loader is not None
            spec.loader.exec_module(module)
            return module

        helper = load_old_helper() if helper_mode == "old" else load_current_helper()
        import mlx_audio
        import mlx.core as mx
        from mlx_audio.tts.utils import load_model

        try:
            mlx_audio_version = getattr(mlx_audio, "__version__", None) or importlib_metadata.version("mlx-audio")
        except importlib_metadata.PackageNotFoundError:
            mlx_audio_version = "unknown"

        model = load_model(model_path)
        enable_encoder = getattr(helper, "try_enable_speech_tokenizer_encoder", None)
        if enable_encoder is not None:
            try:
                signature = inspect.signature(enable_encoder)
                if len(signature.parameters) >= 2:
                    enable_encoder(model, model_path)
                else:
                    enable_encoder(model)
            except TypeError:
                enable_encoder(model, model_path)

        try:
            prep_start = time.perf_counter()
            prepared = helper.prepare_icl_context(model, ref_audio, ref_text, language=language)
            prepare_s = time.perf_counter() - prep_start

            generate_fn = helper.generate_with_prepared_icl
            generate_kwargs = {
                "model": model,
                "text": text,
                "prepared": prepared,
                "temperature": temperature,
                "max_tokens": max_tokens,
                "stream": False,
            }
            if "language" in inspect.signature(generate_fn).parameters:
                generate_kwargs["language"] = language

            generate_start = time.perf_counter()
            outputs = list(generate_fn(**generate_kwargs))
            generate_s = time.perf_counter() - generate_start
            if not outputs:
                raise RuntimeError("Prepared helper produced no output")
            result = outputs[-1]

            print(
                json.dumps(
                    {
                        "runtime_mode": runtime_mode,
                        "helper_mode": helper_mode,
                        "mlx_audio_version": mlx_audio_version,
                        "mlx_audio_file": getattr(mlx_audio, "__file__", None),
                        "model_path": model_path,
                        "prepare_s": round(prepare_s, 4),
                        "generate_s": round(generate_s, 4),
                        "total_s": round(prepare_s + generate_s, 4),
                        "token_count": getattr(result, "token_count", None),
                        "processing_time_seconds": getattr(result, "processing_time_seconds", None),
                        "samples": getattr(result, "samples", None),
                    }
                )
            )
        finally:
            try:
                del model
            except NameError:
                pass
            gc.collect()
            mx.clear_cache()
        """
    )

    command = [
        resolved_python,
        "-c",
        child_script,
        str(PROJECT_DIR),
        runtime_mode,
        helper_mode,
        legacy_runtime_root or "",
        model_path,
        ref_audio,
        ref_text,
        BENCH_TEXT,
        BENCH_LANGUAGE,
        str(BENCH_TEMPERATURE),
        str(BENCH_MAX_TOKENS),
        OLD_HELPER_REF,
    ]
    env = os.environ.copy()
    existing_pythonpath = env.get("PYTHONPATH", "")
    if legacy_runtime_root:
        env["PYTHONPATH"] = (
            legacy_runtime_root
            if not existing_pythonpath
            else f"{legacy_runtime_root}{os.pathsep}{existing_pythonpath}"
        )
    start = time.perf_counter()
    proc = subprocess.run(
        command,
        cwd=PROJECT_DIR,
        capture_output=True,
        text=True,
        timeout=600,
        check=False,
        env=env,
    )
    duration_ms = int((time.perf_counter() - start) * 1000)

    if proc.returncode != 0:
        stderr_tail = "\n".join(proc.stderr.strip().splitlines()[-20:])
        stdout_tail = "\n".join(proc.stdout.strip().splitlines()[-20:])
        raise RuntimeError(
            f"Serialized {helper_mode} helper run failed with exit code {proc.returncode}.\n"
            f"stdout:\n{stdout_tail}\n\nstderr:\n{stderr_tail}"
        )

    json_line = None
    for line in reversed(proc.stdout.splitlines()):
        candidate = line.strip()
        if candidate.startswith("{") and candidate.endswith("}"):
            json_line = candidate
            break

    if json_line is None:
        raise RuntimeError(
            f"Serialized {helper_mode} helper run did not emit a JSON result.\nstdout:\n{proc.stdout}\n\nstderr:\n{proc.stderr}"
        )

    try:
        result = json.loads(json_line)
    except json.JSONDecodeError as exc:
        raise RuntimeError(
            f"Could not parse serialized {helper_mode} helper result.\nstdout:\n{proc.stdout}\n\nstderr:\n{proc.stderr}"
        ) from exc

    result["subprocess_wall_ms"] = duration_ms
    return result


def _resolve_clone_model_path(model_id: str) -> Path:
    contract = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
    model_def = next((model for model in contract["models"] if model["id"] == model_id), None)
    if model_def is None:
        raise RuntimeError(f"Model '{model_id}' is not present in qwenvoice_contract.json")

    full_path = APP_MODELS_DIR / model_def["folder"]
    if not full_path.exists():
        raise RuntimeError(f"Clone regression benchmark requires installed model at {full_path}")

    snapshots_dir = full_path / "snapshots"
    if snapshots_dir.exists():
        subfolders = sorted(path for path in snapshots_dir.iterdir() if not path.name.startswith("."))
        if subfolders:
            return subfolders[0]

    return full_path


def _extract_legacy_runtime(temp_root: Path) -> str:
    wheel_path = temp_root / "mlx_audio-0.4.1.post1-py3-none-any.whl"
    extract_root = temp_root / "legacy_runtime"

    proc = subprocess.run(
        ["git", "show", OLD_WHEEL_REF],
        cwd=PROJECT_DIR,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        stderr_tail = "\n".join(proc.stderr.decode("utf-8", errors="replace").splitlines()[-20:])
        raise RuntimeError(
            f"Could not read legacy mlx-audio wheel from {OLD_WHEEL_REF}.\n{stderr_tail}"
        )

    wheel_path.write_bytes(proc.stdout)
    ensure_directory(extract_root)
    with zipfile.ZipFile(wheel_path) as archive:
        archive.extractall(extract_root)
    return str(extract_root)


def _active_heavy_processes(resolved_python: str) -> dict[str, list[dict[str, Any]]]:
    resolved_python_real = os.path.realpath(resolved_python)
    current_pid = os.getpid()
    proc = subprocess.run(
        ["ps", "-axo", "pid=,command="],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )

    backend_python: list[dict[str, Any]] = []
    qwenvoice_app: list[dict[str, Any]] = []
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

        normalized_command = os.path.realpath(command.split()[0])
        if normalized_command == resolved_python_real:
            backend_python.append({"pid": pid, "command": command})

        if "/QwenVoice.app/Contents/MacOS/QwenVoice" in command:
            qwenvoice_app.append({"pid": pid, "command": command})

    return {
        "backend_python": backend_python,
        "qwenvoice_app": qwenvoice_app,
    }


def _classify_regression_source(
    *,
    legacy_old_result: dict[str, Any],
    current_old_result: dict[str, Any],
    current_current_result: dict[str, Any],
) -> dict[str, Any]:
    runtime_prepare_slower = _is_significantly_slower(
        legacy_old_result.get("prepare_s"),
        current_old_result.get("prepare_s"),
    )
    runtime_generate_slower = _is_significantly_slower(
        legacy_old_result.get("generate_s"),
        current_old_result.get("generate_s"),
    )
    runtime_total_slower = _is_significantly_slower(
        legacy_old_result.get("total_s"),
        current_old_result.get("total_s"),
    )

    overlay_prepare_slower = _is_significantly_slower(
        current_old_result.get("prepare_s"),
        current_current_result.get("prepare_s"),
    )
    overlay_generate_slower = _is_significantly_slower(
        current_old_result.get("generate_s"),
        current_current_result.get("generate_s"),
    )
    overlay_total_slower = _is_significantly_slower(
        current_old_result.get("total_s"),
        current_current_result.get("total_s"),
    )

    if runtime_prepare_slower or runtime_generate_slower or runtime_total_slower:
        source = "mlx_audio_runtime_move"
        reason = (
            "The old helper is materially slower on the current installed mlx-audio runtime "
            "than it is on the legacy 0.4.1.post1 runtime, which points to the runtime move "
            "rather than the overlay refactor."
        )
    elif overlay_prepare_slower or overlay_generate_slower or overlay_total_slower:
        source = "overlay_refactor"
        reason = (
            "The current helper is materially slower than the old helper on the same current "
            "mlx-audio runtime, which points to the overlay refactor rather than the runtime move."
        )
    else:
        source = "other_environment_or_model_path"
        reason = (
            "The legacy-runtime old helper, current-runtime old helper, and current-runtime "
            "current helper are all within the configured similarity threshold, which points "
            "away from both the overlay refactor and the mlx-audio runtime move."
        )

    return {
        "source": source,
        "reason": reason,
        "similar_ratio_threshold": SIMILAR_RATIO_THRESHOLD,
        "similar_delta_threshold_seconds": SIMILAR_DELTA_THRESHOLD_SECONDS,
        "legacy_runtime_old_helper_total_s": legacy_old_result.get("total_s"),
        "current_runtime_old_helper_total_s": current_old_result.get("total_s"),
        "current_runtime_current_helper_total_s": current_current_result.get("total_s"),
        "legacy_runtime_old_helper_prepare_s": legacy_old_result.get("prepare_s"),
        "current_runtime_old_helper_prepare_s": current_old_result.get("prepare_s"),
        "current_runtime_current_helper_prepare_s": current_current_result.get("prepare_s"),
        "legacy_runtime_old_helper_generate_s": legacy_old_result.get("generate_s"),
        "current_runtime_old_helper_generate_s": current_old_result.get("generate_s"),
        "current_runtime_current_helper_generate_s": current_current_result.get("generate_s"),
    }


def _is_significantly_slower(
    old_value: Any,
    current_value: Any,
) -> bool:
    try:
        old_f = float(old_value)
        current_f = float(current_value)
    except (TypeError, ValueError):
        return False

    if current_f - old_f <= SIMILAR_DELTA_THRESHOLD_SECONDS:
        return False
    if old_f <= 0:
        return current_f > SIMILAR_DELTA_THRESHOLD_SECONDS
    return current_f > old_f * SIMILAR_RATIO_THRESHOLD
