"""Diagnose subcommand — environment and health diagnostics."""

from __future__ import annotations

import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from .contract import load_contract, model_ids, model_is_installed
from .output import build_suite_result, build_test_result, eprint
from .paths import APP_MODELS_DIR, APP_SUPPORT_DIR, APP_VENV_PYTHON, resolve_backend_python


def run_diagnose(python_path: str | None = None) -> list[dict[str, Any]]:
    """Run diagnostic checks, each independent and wrapped in try/except."""
    eprint("==> Running diagnostics...")
    start = time.perf_counter()
    results: list[dict[str, Any]] = []

    # Backend health
    def test_backend_health():
        try:
            py = resolve_backend_python(python_path)
        except RuntimeError as exc:
            return {"details": {"status": "unavailable", "reason": str(exc)}}

        from .backend_client import BackendClient

        client = BackendClient(py)
        try:
            client.start()
            ping_result = client.call("ping", timeout=10)
            return {"details": {
                "status": "healthy",
                "ping": ping_result,
            }}
        except Exception as exc:
            stderr = client.stderr_excerpt(10)
            return {"details": {
                "status": "unhealthy",
                "error": str(exc),
                "stderr_tail": stderr,
            }}
        finally:
            client.stop()

    def test_runtime_environment():
        details: dict[str, Any] = {
            "python_path": str(APP_VENV_PYTHON),
            "python_exists": APP_VENV_PYTHON.exists(),
        }
        if APP_VENV_PYTHON.exists():
            proc = subprocess.run(
                [str(APP_VENV_PYTHON), "--version"],
                capture_output=True, text=True, timeout=10,
            )
            details["python_version"] = proc.stdout.strip()

            # Check key packages
            for pkg in ["mlx", "librosa", "transformers", "numpy", "soundfile"]:
                check = subprocess.run(
                    [str(APP_VENV_PYTHON), "-c", f"import {pkg}; print({pkg}.__version__ if hasattr({pkg}, '__version__') else 'installed')"],
                    capture_output=True, text=True, timeout=10,
                )
                details[f"pkg_{pkg}"] = check.stdout.strip() if check.returncode == 0 else "missing"

        # Apple Silicon check
        import platform
        details["arch"] = platform.machine()
        details["is_apple_silicon"] = platform.machine() == "arm64"

        return {"details": details}

    def test_model_inventory():
        contract = load_contract()
        inventory: list[dict[str, Any]] = []
        for model in contract["models"]:
            mid = model["id"]
            installed = model_is_installed(mid)
            model_dir = APP_MODELS_DIR / model["folder"]
            size_bytes = 0
            if model_dir.is_dir():
                for f in model_dir.rglob("*"):
                    if f.is_file():
                        size_bytes += f.stat().st_size
            inventory.append({
                "id": mid,
                "name": model["name"],
                "installed": installed,
                "folder": model["folder"],
                "size_mb": round(size_bytes / (1024 * 1024), 1),
            })
        return {"details": {"models": inventory}}

    def test_voice_inventory():
        voices_dir = APP_SUPPORT_DIR / "voices"
        voices: list[dict[str, Any]] = []
        if voices_dir.is_dir():
            for entry in sorted(voices_dir.iterdir()):
                if entry.is_dir():
                    audio_files = list(entry.glob("*.wav")) + list(entry.glob("*.mp3"))
                    voices.append({
                        "name": entry.name,
                        "audio_files": len(audio_files),
                        "files_exist": all(f.exists() for f in audio_files),
                    })
        return {"details": {"voices": voices, "count": len(voices)}}

    def test_history_db():
        db_path = APP_SUPPORT_DIR / "history.sqlite"
        if not db_path.exists():
            return {"details": {"exists": False}}
        try:
            conn = sqlite3.connect(str(db_path))
            cursor = conn.cursor()
            # Check tables
            cursor.execute("SELECT name FROM sqlite_master WHERE type='table'")
            tables = [row[0] for row in cursor.fetchall()]
            row_counts: dict[str, int] = {}
            for table in tables:
                cursor.execute(f"SELECT COUNT(*) FROM [{table}]")
                row_counts[table] = cursor.fetchone()[0]
            conn.close()
            return {"details": {
                "exists": True,
                "tables": tables,
                "row_counts": row_counts,
            }}
        except Exception as exc:
            return {"details": {"exists": True, "error": str(exc)}}

    def test_disk_usage():
        dirs = {
            "models": APP_SUPPORT_DIR / "models",
            "outputs": APP_SUPPORT_DIR / "outputs",
            "voices": APP_SUPPORT_DIR / "voices",
            "cache": APP_SUPPORT_DIR / "cache",
        }
        usage: dict[str, float] = {}
        for label, path in dirs.items():
            size_bytes = 0
            if path.is_dir():
                for f in path.rglob("*"):
                    if f.is_file():
                        try:
                            size_bytes += f.stat().st_size
                        except OSError:
                            pass
            usage[label] = round(size_bytes / (1024 * 1024), 1)
        return {"details": {"size_mb": usage}}

    tests = [
        ("backend_health", test_backend_health),
        ("runtime_environment", test_runtime_environment),
        ("model_inventory", test_model_inventory),
        ("voice_inventory", test_voice_inventory),
        ("history_database", test_history_db),
        ("disk_usage", test_disk_usage),
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
