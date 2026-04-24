"""Shared launch helpers for UI and perf harness layers."""

from __future__ import annotations

import os
import shutil
import subprocess
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .contract import model_ids, model_is_installed
from .fixtures import (
    copy_optional_file,
    copy_optional_tree,
    create_fixture_root,
    install_stub_models,
    mirror_item,
)
from .paths import APP_MODELS_DIR, APP_SUPPORT_DIR, PROJECT_DIR


XCODEBUILD_TIMEOUT_ENV = "QWENVOICE_XCODEBUILD_TIMEOUT_SECONDS"
DEFAULT_XCODEBUILD_TIMEOUT_SECONDS = 1800


@dataclass
class UILaunchContext:
    backend_mode: str
    data_root: str
    app_support_dir: Path
    fixture_root: Path | None
    defaults_suite: str
    should_cleanup: bool


def resolve_xcodebuild_timeout_seconds(default: int = DEFAULT_XCODEBUILD_TIMEOUT_SECONDS) -> int:
    """Return the repo-owned xcodebuild timeout override when configured."""
    raw_value = os.environ.get(XCODEBUILD_TIMEOUT_ENV, "").strip()
    if not raw_value:
        return default

    try:
        parsed = int(raw_value)
    except ValueError:
        return default

    return parsed if parsed > 0 else default


def check_live_prerequisites() -> dict[str, Any]:
    """Return the current live-backend prerequisites."""
    installed_models = [mid for mid in model_ids() if model_is_installed(mid)]
    return {
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
        fixture_root = create_fixture_root(prefix="qwenvoice_ui_stub_")
        install_stub_models(fixture_root)
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

    fixture_root = create_fixture_root(prefix="qwenvoice_ui_live_")
    mirror_item(APP_MODELS_DIR, fixture_root / "models")
    copy_optional_tree(APP_SUPPORT_DIR / "voices", fixture_root / "voices")
    copy_optional_file(APP_SUPPORT_DIR / "history.sqlite", fixture_root / "history.sqlite")

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

    if extra_environment:
        env.update(extra_environment)
    return env


def build_app_binary(timeout: int = 300) -> tuple[bool, str | None, dict[str, Any]]:
    """Build the app and return the app binary path when successful."""
    timeout = resolve_xcodebuild_timeout_seconds(timeout)
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

    app_binary = Path(app_dir) / "Vocello.app" / "Contents" / "MacOS" / "Vocello"
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
