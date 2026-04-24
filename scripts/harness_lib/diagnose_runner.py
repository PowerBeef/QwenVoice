"""Diagnose subcommand — native-only environment and health diagnostics."""

from __future__ import annotations

import sqlite3
import subprocess
import time
from typing import Any

from .contract import load_contract, model_is_installed
from .output import build_suite_result, build_test_result, eprint
from .paths import (
    APP_MODELS_DIR,
    APP_SUPPORT_DIR,
    HARNESS_DERIVED_DATA_ROOT,
    HARNESS_RESULT_BUNDLES_ROOT,
    HARNESS_SOURCE_PACKAGES_ROOT,
    PROJECT_DIR,
)


def run_diagnose() -> list[dict[str, Any]]:
    """Run diagnostic checks, each independent and wrapped in try/except."""
    eprint("==> Running diagnostics...")
    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    def test_runtime_environment() -> dict[str, Any]:
        import platform

        return {
            "details": {
                "app_support_dir": str(APP_SUPPORT_DIR),
                "models_dir": str(APP_MODELS_DIR),
                "project_dir": str(PROJECT_DIR),
                "arch": platform.machine(),
                "is_apple_silicon": platform.machine() == "arm64",
            }
        }

    def test_xcode_environment() -> dict[str, Any]:
        xcodebuild = subprocess.run(
            ["xcodebuild", "-version"],
            cwd=str(PROJECT_DIR),
            capture_output=True,
            text=True,
            timeout=20,
        )
        xcode_select = subprocess.run(
            ["xcode-select", "-p"],
            cwd=str(PROJECT_DIR),
            capture_output=True,
            text=True,
            timeout=20,
        )
        return {
            "details": {
                "xcodebuild_version": xcodebuild.stdout.splitlines(),
                "xcodebuild_status": xcodebuild.returncode,
                "developer_dir": xcode_select.stdout.strip(),
                "xcode_select_status": xcode_select.returncode,
            }
        }

    def test_model_inventory() -> dict[str, Any]:
        contract = load_contract()
        inventory: list[dict[str, Any]] = []
        for model in contract["models"]:
            model_dir = APP_MODELS_DIR / model["folder"]
            size_bytes = 0
            if model_dir.is_dir():
                for item in model_dir.rglob("*"):
                    if item.is_file():
                        size_bytes += item.stat().st_size
            inventory.append(
                {
                    "id": model["id"],
                    "name": model["name"],
                    "installed": model_is_installed(model["id"]),
                    "folder": model["folder"],
                    "size_mb": round(size_bytes / (1024 * 1024), 1),
                }
            )
        return {"details": {"models": inventory}}

    def test_voice_inventory() -> dict[str, Any]:
        voices_dir = APP_SUPPORT_DIR / "voices"
        voices: list[dict[str, Any]] = []
        if voices_dir.is_dir():
            for entry in sorted(voices_dir.iterdir()):
                if entry.is_dir():
                    audio_files = list(entry.glob("*.wav")) + list(entry.glob("*.mp3"))
                    voices.append(
                        {
                            "name": entry.name,
                            "audio_files": len(audio_files),
                            "files_exist": all(path.exists() for path in audio_files),
                        }
                    )
        return {"details": {"voices": voices, "count": len(voices)}}

    def test_history_db() -> dict[str, Any]:
        db_path = APP_SUPPORT_DIR / "history.sqlite"
        if not db_path.exists():
            return {"details": {"exists": False}}

        try:
            conn = sqlite3.connect(str(db_path))
            cursor = conn.cursor()
            cursor.execute("SELECT name FROM sqlite_master WHERE type='table'")
            tables = [row[0] for row in cursor.fetchall()]
            row_counts: dict[str, int] = {}
            for table in tables:
                cursor.execute(f"SELECT COUNT(*) FROM [{table}]")
                row_counts[table] = cursor.fetchone()[0]
            conn.close()
            return {"details": {"exists": True, "tables": tables, "row_counts": row_counts}}
        except Exception as exc:
            return {"details": {"exists": True, "error": str(exc)}}

    def test_disk_usage() -> dict[str, Any]:
        dirs = {
            "models": APP_SUPPORT_DIR / "models",
            "outputs": APP_SUPPORT_DIR / "outputs",
            "voices": APP_SUPPORT_DIR / "voices",
            "cache": APP_SUPPORT_DIR / "cache",
            "harness_derived_data": HARNESS_DERIVED_DATA_ROOT,
            "harness_results": HARNESS_RESULT_BUNDLES_ROOT,
            "harness_source_packages": HARNESS_SOURCE_PACKAGES_ROOT,
        }
        usage: dict[str, float] = {}
        for label, path in dirs.items():
            size_bytes = 0
            if path.is_dir():
                for item in path.rglob("*"):
                    if item.is_file():
                        try:
                            size_bytes += item.stat().st_size
                        except OSError:
                            pass
            usage[label] = round(size_bytes / (1024 * 1024), 1)
        return {"details": {"size_mb": usage}}

    def test_package_inventory() -> dict[str, Any]:
        resolved = PROJECT_DIR / "QwenVoice.xcodeproj" / "project.xcworkspace" / "xcshareddata" / "swiftpm" / "Package.resolved"
        local_mlx_audio = PROJECT_DIR / "third_party_patches" / "mlx-audio-swift" / "Package.swift"
        return {
            "details": {
                "package_resolved_exists": resolved.exists(),
                "package_resolved_path": str(resolved),
                "local_mlx_audio_package_exists": local_mlx_audio.exists(),
                "local_mlx_audio_package_path": str(local_mlx_audio),
                "harness_source_packages_root": str(HARNESS_SOURCE_PACKAGES_ROOT),
            }
        }

    def test_packaged_app_signing() -> dict[str, Any]:
        app_path = PROJECT_DIR / "build" / "Vocello.app"
        if not app_path.exists():
            return {
                "details": {
                    "app_exists": False,
                    "app_path": str(app_path),
                    "note": "Run ./scripts/release.sh to generate the packaged app.",
                }
            }

        codesign = subprocess.run(
            ["codesign", "-dv", "--verbose=4", str(app_path)],
            cwd=str(PROJECT_DIR),
            capture_output=True,
            text=True,
            timeout=30,
        )
        xpc_path = app_path / "Contents" / "XPCServices" / "QwenVoiceEngineService.xpc"
        xpc_codesign = subprocess.run(
            ["codesign", "-dv", "--verbose=4", str(xpc_path)],
            cwd=str(PROJECT_DIR),
            capture_output=True,
            text=True,
            timeout=30,
        ) if xpc_path.exists() else None
        return {
            "details": {
                "app_exists": True,
                "app_path": str(app_path),
                "app_codesign_status": codesign.returncode,
                "app_codesign_tail": codesign.stderr.splitlines()[-20:],
                "xpc_exists": xpc_path.exists(),
                "xpc_path": str(xpc_path),
                "xpc_codesign_status": xpc_codesign.returncode if xpc_codesign else None,
                "xpc_codesign_tail": xpc_codesign.stderr.splitlines()[-20:] if xpc_codesign else [],
            }
        }

    tests = [
        ("runtime_environment", test_runtime_environment),
        ("xcode_environment", test_xcode_environment),
        ("model_inventory", test_model_inventory),
        ("voice_inventory", test_voice_inventory),
        ("history_database", test_history_db),
        ("disk_usage", test_disk_usage),
        ("package_inventory", test_package_inventory),
        ("packaged_app_signing", test_packaged_app_signing),
    ]

    for name, fn in tests:
        t0 = time.perf_counter()
        try:
            result = fn()
            dt = int((time.perf_counter() - t0) * 1000)
            if isinstance(result, dict) and "details" in result:
                results.append(build_test_result(name, passed=True, duration_ms=dt, details=result["details"]))
            else:
                results.append(build_test_result(name, passed=True, duration_ms=dt))
        except Exception as exc:
            dt = int((time.perf_counter() - t0) * 1000)
            results.append(build_test_result(name, passed=False, error=str(exc), duration_ms=dt))

    duration_ms = int((time.perf_counter() - start) * 1000)
    return [build_suite_result("diagnostics", results, duration_ms)]
