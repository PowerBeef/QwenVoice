"""Shared launch helpers for UI, design, and perf harness layers."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .contract import model_ids, model_is_installed
from .paths import APP_MODELS_DIR, APP_SUPPORT_DIR, APP_VENV_PYTHON, PROJECT_DIR, ensure_directory


@dataclass
class UILaunchContext:
    backend_mode: str
    data_root: str
    app_support_dir: Path
    fixture_root: Path | None
    defaults_suite: str
    should_cleanup: bool


def check_live_prerequisites() -> dict[str, Any]:
    """Return the current live-backend prerequisites."""
    installed_models = [mid for mid in model_ids() if model_is_installed(mid)]
    return {
        "python_exists": APP_VENV_PYTHON.exists(),
        "python_path": str(APP_VENV_PYTHON),
        "models_dir": str(APP_MODELS_DIR),
        "installed_models": installed_models,
        "app_support_dir": str(APP_SUPPORT_DIR),
    }


def prepare_ui_launch_context(
    backend_mode: str = "live",
    data_root: str = "fixture",
) -> UILaunchContext:
    """Create an app-support context for UI-oriented test runs."""
    defaults_suite = f"QwenVoiceHarness.{uuid.uuid4()}"

    if backend_mode == "stub":
        fixture_root = Path(tempfile.mkdtemp(prefix="qwenvoice_ui_stub_"))
        _create_base_directories(fixture_root)
        return UILaunchContext(
            backend_mode=backend_mode,
            data_root="fixture",
            app_support_dir=fixture_root,
            fixture_root=fixture_root,
            defaults_suite=defaults_suite,
            should_cleanup=True,
        )

    if data_root == "real":
        return UILaunchContext(
            backend_mode=backend_mode,
            data_root=data_root,
            app_support_dir=APP_SUPPORT_DIR,
            fixture_root=None,
            defaults_suite=defaults_suite,
            should_cleanup=False,
        )

    fixture_root = Path(tempfile.mkdtemp(prefix="qwenvoice_ui_live_"))
    _create_base_directories(fixture_root)
    _mirror_item(APP_MODELS_DIR, fixture_root / "models")
    _mirror_item(APP_SUPPORT_DIR / "python", fixture_root / "python")
    _copy_optional_tree(APP_SUPPORT_DIR / "voices", fixture_root / "voices")
    _copy_optional_file(APP_SUPPORT_DIR / "history.sqlite", fixture_root / "history.sqlite")

    return UILaunchContext(
        backend_mode=backend_mode,
        data_root=data_root,
        app_support_dir=fixture_root,
        fixture_root=fixture_root,
        defaults_suite=defaults_suite,
        should_cleanup=True,
    )


def cleanup_ui_launch_context(context: UILaunchContext | None) -> None:
    """Remove any disposable launch context."""
    if context is None or not context.should_cleanup or context.fixture_root is None:
        return
    shutil.rmtree(context.fixture_root, ignore_errors=True)


def build_ui_launch_environment(
    context: UILaunchContext,
    *,
    setup_scenario: str = "success",
    setup_delay_ms: str = "1",
    screenshot_dir: str | None = None,
    extra_environment: dict[str, str] | None = None,
) -> dict[str, str]:
    """Return the app environment for a UI-oriented launch."""
    env = dict(os.environ)
    env["QWENVOICE_UI_TEST"] = "1"
    env["QWENVOICE_UI_TEST_BACKEND_MODE"] = context.backend_mode
    env["QWENVOICE_UI_TEST_SETUP_SCENARIO"] = setup_scenario
    env["QWENVOICE_UI_TEST_SETUP_DELAY_MS"] = setup_delay_ms
    env["QWENVOICE_UI_TEST_DEFAULTS_SUITE"] = context.defaults_suite
    env.pop("QWENVOICE_UI_TEST_FIXTURE_ROOT", None)
    env.pop("QWENVOICE_APP_SUPPORT_DIR", None)

    if context.backend_mode == "stub":
        env["QWENVOICE_UI_TEST_FIXTURE_ROOT"] = str(context.app_support_dir)
    else:
        env["QWENVOICE_APP_SUPPORT_DIR"] = str(context.app_support_dir)

    if screenshot_dir:
        env["QWENVOICE_UITEST_SCREENSHOT_DIR"] = screenshot_dir
    if extra_environment:
        env.update(extra_environment)
    return env


def build_app_binary(timeout: int = 300) -> tuple[bool, str | None, dict[str, Any]]:
    """Build the app and return the app binary path when successful."""
    build_proc = subprocess.run(
        [
            "xcodebuild",
            "-project",
            str(PROJECT_DIR / "QwenVoice.xcodeproj"),
            "-scheme",
            "QwenVoice",
            "build",
            "-quiet",
        ],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if build_proc.returncode != 0:
        return False, None, {"error": "build_failed", "stderr_tail": build_proc.stderr.splitlines()[-20:]}

    settings = subprocess.run(
        [
            "xcodebuild",
            "-project",
            str(PROJECT_DIR / "QwenVoice.xcodeproj"),
            "-scheme",
            "QwenVoice",
            "-showBuildSettings",
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    app_dir = None
    for line in settings.stdout.splitlines():
        if "BUILT_PRODUCTS_DIR" in line:
            app_dir = line.split("=", 1)[1].strip()
            break
    if not app_dir:
        return False, None, {"error": "no_build_dir"}

    app_binary = Path(app_dir) / "QwenVoice.app" / "Contents" / "MacOS" / "QwenVoice"
    return app_binary.exists(), str(app_binary) if app_binary.exists() else None, {
        "app_binary": str(app_binary),
        "built_products_dir": app_dir,
    }


def kill_running_app_instances() -> None:
    """Terminate existing QwenVoice instances to avoid cross-run interference."""
    subprocess.run(["killall", "QwenVoice"], capture_output=True)
    time.sleep(0.5)


def launch_ui_app(
    app_binary: str,
    environment: dict[str, str],
    *,
    initial_screen: str | None = None,
    fast_idle: bool = True,
) -> subprocess.Popen[Any]:
    """Launch the built app in UI-test mode."""
    app_bundle = app_binary.split("/Contents/MacOS/")[0]
    args = ["open", "-n", app_bundle, "--args", "--uitest", "--uitest-disable-animations"]
    if fast_idle:
        args.append("--uitest-fast-idle")
    if initial_screen:
        args.append(f"--uitest-screen={initial_screen}")
    return subprocess.Popen(
        args,
        env=environment,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def describe_launch_context(context: UILaunchContext) -> dict[str, Any]:
    """Return a JSON-serializable summary of the launch context."""
    return {
        "backend_mode": context.backend_mode,
        "data_root": context.data_root,
        "app_support_dir": str(context.app_support_dir),
        "fixture_root": str(context.fixture_root) if context.fixture_root else None,
        "defaults_suite": context.defaults_suite,
        "should_cleanup": context.should_cleanup,
    }


def _create_base_directories(root: Path) -> None:
    for relative in (
        "models",
        "python",
        "outputs/CustomVoice",
        "outputs/VoiceDesign",
        "outputs/Clones",
        "voices",
        "cache/normalized_clone_refs",
        "cache/stream_sessions",
    ):
        ensure_directory(root / relative)


def _mirror_item(source: Path, destination: Path) -> None:
    if not source.exists():
        return
    if destination.exists() or destination.is_symlink():
        if destination.is_dir() and not destination.is_symlink():
            shutil.rmtree(destination, ignore_errors=True)
        else:
            destination.unlink(missing_ok=True)
    try:
        destination.symlink_to(source, target_is_directory=source.is_dir())
    except OSError:
        if source.is_dir():
            shutil.copytree(source, destination, dirs_exist_ok=True)
        else:
            shutil.copy2(source, destination)


def _copy_optional_tree(source: Path, destination: Path) -> None:
    if not source.exists():
        return
    if destination.exists():
        shutil.rmtree(destination, ignore_errors=True)
    shutil.copytree(source, destination, dirs_exist_ok=True)


def _copy_optional_file(source: Path, destination: Path) -> None:
    if not source.exists():
        return
    ensure_directory(destination.parent)
    shutil.copy2(source, destination)
