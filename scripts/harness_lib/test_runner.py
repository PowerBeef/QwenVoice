"""Test runner — native-only test layers for the QwenVoice harness."""

from __future__ import annotations

import subprocess
import time
from typing import Any

from .contract import load_contract, speaker_list
from .output import build_suite_result, build_test_result, eprint
from .paths import CONTRACT_PATH, PROJECT_DIR
from .ui_test_support import discover_release_artifacts, resolve_xcodebuild_timeout_seconds


def run_tests(
    layer: str = "all",
    artifact_dir: str | None = None,
    artifacts_root: str | None = None,
) -> list[dict[str, Any]]:
    """Run selected test layers and return suite results."""
    suites: list[dict[str, Any]] = []

    if layer in ("all", "contract"):
        eprint("==> Running contract validation tests...")
        suites.append(_run_contract_tests())

    if layer in ("all", "swift"):
        eprint("==> Running Swift unit tests...")
        suites.append(_run_swift_tests())

    if layer in ("all", "native"):
        eprint("==> Running native runtime-focused tests...")
        suites.append(_run_native_tests())

    if layer in ("all", "audio"):
        eprint("==> Running audio pipeline tests...")
        from .audio_test_runner import run_audio_tests

        suites.append(run_audio_tests(artifact_dir=artifact_dir))

    if layer == "release":
        suites.extend(_run_release_tests(artifacts_root=artifacts_root))

    return suites


def _timed_test(name: str, fn: Any) -> dict[str, Any]:
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


def _run_contract_tests() -> dict[str, Any]:
    start = time.perf_counter()
    results = [
        _timed_test("contract_file_exists", _test_contract_file_exists),
        _timed_test("contract_schema_basics", _test_contract_schema_basics),
        _timed_test("contract_default_speaker_present", _test_default_speaker_present),
        _timed_test("contract_unique_model_ids", _test_unique_model_ids),
        _timed_test("contract_unique_model_modes", _test_unique_model_modes),
    ]
    return build_suite_result("contract_validation", results, int((time.perf_counter() - start) * 1000))


def _test_contract_file_exists() -> None:
    assert CONTRACT_PATH.exists(), f"Missing contract at {CONTRACT_PATH}"


def _test_contract_schema_basics() -> None:
    contract = load_contract()
    assert isinstance(contract.get("models"), list) and contract["models"], "models must be a non-empty list"
    assert isinstance(contract.get("speakers"), dict) and contract["speakers"], "speakers must be a non-empty mapping"
    assert contract.get("defaultSpeaker"), "defaultSpeaker must be set"

    for model in contract["models"]:
        assert model["id"], "each model must have an id"
        assert model["mode"], f"model {model['id']} must have a mode"
        assert model["folder"], f"model {model['id']} must have a folder"
        assert model["requiredRelativePaths"], f"model {model['id']} must declare requiredRelativePaths"


def _test_default_speaker_present() -> None:
    contract = load_contract()
    assert contract["defaultSpeaker"] in speaker_list(), "defaultSpeaker must appear in speakers"


def _test_unique_model_ids() -> None:
    ids = [model["id"] for model in load_contract()["models"]]
    assert len(ids) == len(set(ids)), f"duplicate model ids: {ids}"


def _test_unique_model_modes() -> None:
    modes = [model["mode"] for model in load_contract()["models"]]
    assert len(modes) == len(set(modes)), f"duplicate model modes: {modes}"


def _run_swift_tests() -> dict[str, Any]:
    return _run_xcodebuild_suite(
        suite_name="swift_unit_tests",
        command=[
            "xcodebuild",
            "-project",
            str(PROJECT_DIR / "QwenVoice.xcodeproj"),
            "-scheme",
            "QwenVoice",
            "-destination",
            "platform=macOS",
            "test",
        ],
    )


def _run_native_tests() -> dict[str, Any]:
    return _run_xcodebuild_suite(
        suite_name="native_runtime_tests",
        command=[
            "xcodebuild",
            "-project",
            str(PROJECT_DIR / "QwenVoice.xcodeproj"),
            "-scheme",
            "QwenVoice",
            "-destination",
            "platform=macOS",
            "-only-testing:QwenVoiceTests/EngineServiceCodecTests",
            "-only-testing:QwenVoiceTests/NativeAudioPreparationTests",
            "-only-testing:QwenVoiceTests/NativeCloneSupportTests",
            "-only-testing:QwenVoiceTests/NativeMLXMacEngineTests",
            "-only-testing:QwenVoiceTests/NativeModelLoadCoordinatorTests",
            "-only-testing:QwenVoiceTests/NativeModelRegistryTests",
            "-only-testing:QwenVoiceTests/TTSEngineStoreTests",
            "-only-testing:QwenVoiceTests/VoiceCloningReferenceAudioSupportTests",
            "-only-testing:QwenVoiceTests/XPCNativeEngineClientTests",
            "test",
        ],
    )


def _run_xcodebuild_suite(suite_name: str, command: list[str]) -> dict[str, Any]:
    start = time.perf_counter()
    timeout = resolve_xcodebuild_timeout_seconds()
    proc = subprocess.run(
        command,
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    details = {
        "command": command,
        "stdout_tail": proc.stdout.splitlines()[-20:],
        "stderr_tail": proc.stderr.splitlines()[-20:],
    }
    result = build_test_result(
        suite_name,
        passed=proc.returncode == 0,
        error=None if proc.returncode == 0 else f"xcodebuild exited with {proc.returncode}",
        duration_ms=int((time.perf_counter() - start) * 1000),
        details=details,
    )
    return build_suite_result(suite_name, [result], result["duration_ms"])


def _run_release_tests(artifacts_root: str | None = None) -> list[dict[str, Any]]:
    artifacts = discover_release_artifacts(artifacts_root)
    if not artifacts:
        return [
            build_suite_result(
                "release_artifacts",
                [
                    build_test_result(
                        "release_artifacts_available",
                        passed=True,
                        skip_reason="No downloaded release artifacts found.",
                    )
                ],
                0,
            )
        ]

    verify_script = PROJECT_DIR / "scripts" / "verify_packaged_dmg.sh"
    suites: list[dict[str, Any]] = []
    for artifact in artifacts:
        name = f"release_{artifact['variant_id']}"
        start = time.perf_counter()
        proc = subprocess.run(
            [str(verify_script), artifact["dmg_path"], artifact["metadata_path"]],
            cwd=str(PROJECT_DIR),
            capture_output=True,
            text=True,
        )
        result = build_test_result(
            name,
            passed=proc.returncode == 0,
            error=None if proc.returncode == 0 else f"verify_packaged_dmg.sh exited with {proc.returncode}",
            duration_ms=int((time.perf_counter() - start) * 1000),
            details={
                "dmg_path": artifact["dmg_path"],
                "metadata_path": artifact["metadata_path"],
                "stdout_tail": proc.stdout.splitlines()[-20:],
                "stderr_tail": proc.stderr.splitlines()[-20:],
            },
        )
        suites.append(build_suite_result(name, [result], result["duration_ms"]))
    return suites
