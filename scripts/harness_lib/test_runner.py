"""Deterministic test runner for QwenVoice source and runtime suites."""

from __future__ import annotations

import json
import subprocess
import time
from pathlib import Path
from typing import Any

from .contract import load_contract, speaker_list
from .output import build_suite_result, build_test_result, eprint
from .paths import (
    CONTRACT_PATH,
    HARNESS_DERIVED_DATA_ROOT,
    HARNESS_RESULT_BUNDLES_ROOT,
    HARNESS_SOURCE_PACKAGES_ROOT,
    PROJECT_DIR,
    ensure_directory,
    reset_directory,
)
from .ui_test_support import resolve_xcodebuild_timeout_seconds


def run_tests(
    layer: str = "all",
    artifact_dir: str | None = None,
) -> list[dict[str, Any]]:
    """Run selected test layers and return suite results."""
    suites: list[dict[str, Any]] = []

    if layer in ("all", "contract"):
        eprint("==> Running contract validation tests...")
        suites.append(_run_contract_tests())

    if layer in ("all", "swift"):
        eprint("==> Running Swift source tests...")
        suites.append(
            _run_xcodebuild_test_suite(
                suite_name="swift_source_tests",
                scheme="QwenVoice Foundation",
                destination="platform=macOS",
            )
        )

    if layer in ("all", "native"):
        eprint("==> Running native runtime-focused tests...")
        suites.append(
            _run_xcodebuild_test_suite(
                suite_name="native_runtime_tests",
                scheme="QwenVoice Foundation",
                destination="platform=macOS",
                test_plan="QwenVoiceRuntime",
                test_arguments=[
                    "-only-testing:QwenVoiceTests/EngineServiceCodecTests",
                    "-only-testing:QwenVoiceTests/NativeAudioPreparationTests",
                    "-only-testing:QwenVoiceTests/NativeCloneSupportTests",
                    "-only-testing:QwenVoiceTests/NativeMLXMacEngineTests",
                    "-only-testing:QwenVoiceTests/NativeModelLoadCoordinatorTests",
                    "-only-testing:QwenVoiceTests/NativeModelRegistryTests",
                    "-only-testing:QwenVoiceTests/TTSEngineStoreTests",
                    "-only-testing:QwenVoiceTests/VoiceCloningReferenceAudioSupportTests",
                    "-only-testing:QwenVoiceTests/XPCNativeEngineClientTests",
                ],
            )
        )

    if layer in ("all", "ios"):
        eprint("==> Running iPhone foundation tests...")
        suites.append(_run_ios_tests())

    if layer in ("all", "audio"):
        eprint("==> Running audio pipeline tests...")
        from .audio_test_runner import run_audio_tests

        suites.append(run_audio_tests(artifact_dir=artifact_dir))

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


def _run_ios_tests() -> dict[str, Any]:
    destination = _resolve_ios_simulator_destination()
    if destination is None:
        return build_suite_result(
            "ios_foundation_tests",
            [
                build_test_result(
                    "ios_foundation_tests",
                    passed=True,
                    skip_reason="No available iPhone simulator destination was found for VocelloiOS Foundation.",
                )
            ],
            0,
        )

    return _run_xcodebuild_test_suite(
        suite_name="ios_foundation_tests",
        scheme="VocelloiOS Foundation",
        destination=destination,
    )


def _resolve_ios_simulator_destination() -> str | None:
    proc = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return None

    try:
        devices_by_runtime = json.loads(proc.stdout).get("devices", {})
    except json.JSONDecodeError:
        return None

    candidates: list[dict[str, Any]] = []
    for runtime, devices in devices_by_runtime.items():
        if "iOS" not in runtime:
            continue
        for device in devices:
            name = device.get("name", "")
            if not name.startswith("iPhone"):
                continue
            if not device.get("isAvailable", True):
                continue
            candidates.append(device)

    if not candidates:
        return None

    preferred_names = ("iPhone 17 Pro", "iPhone 17 Pro Max", "iPhone 17", "iPhone 16 Pro")
    candidates.sort(
        key=lambda device: (
            0 if device.get("state") == "Booted" else 1,
            next(
                (
                    index
                    for index, preferred_name in enumerate(preferred_names)
                    if device.get("name") == preferred_name
                ),
                len(preferred_names),
            ),
            device.get("name", ""),
        )
    )
    return f"platform=iOS Simulator,id={candidates[0]['udid']}"


def _run_xcodebuild_test_suite(
    suite_name: str,
    scheme: str,
    destination: str,
    *,
    test_plan: str | None = None,
    build_arguments: list[str] | None = None,
    test_arguments: list[str] | None = None,
) -> dict[str, Any]:
    start = time.perf_counter()
    timeout = resolve_xcodebuild_timeout_seconds()
    derived_data_path = reset_directory(HARNESS_DERIVED_DATA_ROOT / suite_name)
    result_bundle_root = reset_directory(HARNESS_RESULT_BUNDLES_ROOT / suite_name)
    source_packages_path = ensure_directory(HARNESS_SOURCE_PACKAGES_ROOT / suite_name)
    build_result_bundle = result_bundle_root / "build.xcresult"
    test_result_bundle = result_bundle_root / "test.xcresult"

    build_arguments = build_arguments or []
    test_arguments = test_arguments or []
    test_plan_arguments = ["-testPlan", test_plan] if test_plan else []

    resolve_command = [
        "xcodebuild",
        "-project",
        str(PROJECT_DIR / "QwenVoice.xcodeproj"),
        "-scheme",
        scheme,
        "-destination",
        destination,
        "-clonedSourcePackagesDirPath",
        str(source_packages_path),
        "-resolvePackageDependencies",
    ]
    resolve_proc = subprocess.run(
        resolve_command,
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if resolve_proc.returncode != 0:
        details = {
            "stage": "resolve-package-dependencies",
            "scheme": scheme,
            "destination": destination,
            "source_packages_path": str(source_packages_path),
            "command": resolve_command,
            "stdout_tail": resolve_proc.stdout.splitlines()[-20:],
            "stderr_tail": resolve_proc.stderr.splitlines()[-20:],
        }
        result = build_test_result(
            suite_name,
            passed=False,
            duration_ms=int((time.perf_counter() - start) * 1000),
            error="xcodebuild -resolvePackageDependencies failed",
            details=details,
        )
        return build_suite_result(suite_name, [result], result["duration_ms"])

    build_command = [
        "xcodebuild",
        "-project",
        str(PROJECT_DIR / "QwenVoice.xcodeproj"),
        "-scheme",
        scheme,
        "-destination",
        destination,
        "-clonedSourcePackagesDirPath",
        str(source_packages_path),
        "-disableAutomaticPackageResolution",
        "-derivedDataPath",
        str(derived_data_path),
        "-resultBundlePath",
        str(build_result_bundle),
        "-resultBundleVersion",
        "3",
        *test_plan_arguments,
        *build_arguments,
        "build-for-testing",
    ]
    build_proc = subprocess.run(
        build_command,
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if build_proc.returncode != 0:
        details = {
            "stage": "build-for-testing",
            "scheme": scheme,
            "destination": destination,
            "source_packages_path": str(source_packages_path),
            "derived_data_path": str(derived_data_path),
            "result_bundle_path": str(build_result_bundle),
            "resolve_command": resolve_command,
            "command": build_command,
            "resolve_stdout_tail": resolve_proc.stdout.splitlines()[-20:],
            "resolve_stderr_tail": resolve_proc.stderr.splitlines()[-20:],
            "stdout_tail": build_proc.stdout.splitlines()[-20:],
            "stderr_tail": build_proc.stderr.splitlines()[-20:],
            "xcresult_summary": _xcresult_summary(build_result_bundle, stage="build"),
        }
        result = build_test_result(
            suite_name,
            passed=False,
            error=f"xcodebuild build-for-testing exited with {build_proc.returncode}",
            duration_ms=int((time.perf_counter() - start) * 1000),
            details=details,
        )
        return build_suite_result(suite_name, [result], result["duration_ms"])

    test_command = [
        "xcodebuild",
        "-project",
        str(PROJECT_DIR / "QwenVoice.xcodeproj"),
        "-scheme",
        scheme,
        "-destination",
        destination,
        "-clonedSourcePackagesDirPath",
        str(source_packages_path),
        "-disableAutomaticPackageResolution",
        "-derivedDataPath",
        str(derived_data_path),
        "-resultBundlePath",
        str(test_result_bundle),
        "-resultBundleVersion",
        "3",
        *test_plan_arguments,
        *test_arguments,
        "test-without-building",
    ]
    test_proc = subprocess.run(
        test_command,
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    details = {
            "stage": "test-without-building",
            "scheme": scheme,
            "destination": destination,
            "test_plan": test_plan,
            "source_packages_path": str(source_packages_path),
            "derived_data_path": str(derived_data_path),
            "build_result_bundle_path": str(build_result_bundle),
            "test_result_bundle_path": str(test_result_bundle),
            "resolve_command": resolve_command,
            "build_command": build_command,
            "test_command": test_command,
            "resolve_stdout_tail": resolve_proc.stdout.splitlines()[-20:],
            "resolve_stderr_tail": resolve_proc.stderr.splitlines()[-20:],
            "build_stdout_tail": build_proc.stdout.splitlines()[-20:],
            "build_stderr_tail": build_proc.stderr.splitlines()[-20:],
            "test_stdout_tail": test_proc.stdout.splitlines()[-20:],
        "test_stderr_tail": test_proc.stderr.splitlines()[-20:],
        "build_xcresult_summary": _xcresult_summary(build_result_bundle, stage="build"),
        "test_xcresult_summary": _xcresult_summary(test_result_bundle, stage="test"),
    }
    result = build_test_result(
        suite_name,
        passed=test_proc.returncode == 0,
        error=None if test_proc.returncode == 0 else f"xcodebuild test-without-building exited with {test_proc.returncode}",
        duration_ms=int((time.perf_counter() - start) * 1000),
        details=details,
    )
    return build_suite_result(suite_name, [result], result["duration_ms"])


def _xcresult_summary(result_bundle_path: Path, *, stage: str) -> dict[str, Any] | None:
    if not result_bundle_path.exists():
        return None

    if stage == "build":
        command = [
            "xcrun",
            "xcresulttool",
            "get",
            "build-results",
            "--path",
            str(result_bundle_path),
            "--compact",
        ]
    else:
        command = [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            str(result_bundle_path),
            "--compact",
        ]

    proc = subprocess.run(
        command,
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return {
            "error": f"xcresulttool exited with {proc.returncode}",
            "stderr_tail": proc.stderr.splitlines()[-20:],
        }

    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {
            "error": "xcresulttool produced unreadable JSON",
            "stdout_tail": proc.stdout.splitlines()[-20:],
        }
