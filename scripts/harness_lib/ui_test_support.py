"""Shared launch helpers for UI, design, and perf harness layers."""

from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .contract import load_contract, model_ids, model_is_installed
from .paths import APP_MODELS_DIR, APP_SUPPORT_DIR, APP_VENV_PYTHON, PROJECT_DIR, ensure_directory


@dataclass
class UILaunchContext:
    backend_mode: str
    data_root: str
    app_support_dir: Path
    fixture_root: Path | None
    defaults_suite: str
    should_cleanup: bool


@dataclass
class UIAppTarget:
    app_bundle: Path
    app_binary: Path
    source: str
    variant_id: str | None = None
    ui_profile: str | None = None
    metadata: dict[str, str] | None = None
    metadata_path: Path | None = None
    temp_root: Path | None = None
    mounted_device: str | None = None
    mounted_mount_point: Path | None = None


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
        _install_stub_models(fixture_root)
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
        env.setdefault("QWENVOICE_UITEST_CAPTURE_MODE", "content")
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


def resolve_ui_app_target(
    *,
    app_bundle: str | None = None,
    dmg: str | None = None,
    timeout: int = 300,
) -> tuple[bool, UIAppTarget | None, dict[str, Any]]:
    """Resolve the app target for UI-oriented tests."""
    if app_bundle and dmg:
        return False, None, {"error": "conflicting_app_target", "app_bundle": app_bundle, "dmg": dmg}

    if dmg:
        return _resolve_dmg_app_target(Path(dmg))

    if app_bundle:
        return _resolve_app_bundle_target(Path(app_bundle))

    built, app_binary, details = build_app_binary(timeout=timeout)
    if not built or not app_binary:
        return False, None, details

    bundle_path = Path(app_binary).parents[2]
    return True, UIAppTarget(
        app_bundle=bundle_path,
        app_binary=Path(app_binary),
        source="build",
    ), {
        **details,
        "source": "build",
        "app_bundle": str(bundle_path),
    }


def cleanup_ui_app_target(target: UIAppTarget | None) -> None:
    """Clean up temporary packaged-app state."""
    if target is None:
        return

    if target.mounted_device:
        subprocess.run(
            ["hdiutil", "detach", target.mounted_device],
            capture_output=True,
            text=True,
        )

    if target.temp_root is not None:
        shutil.rmtree(target.temp_root, ignore_errors=True)


def discover_release_artifacts(artifacts_root: str | None = None) -> list[dict[str, Any]]:
    """Find downloaded release artifacts and their metadata."""
    root = _resolve_release_download_root(artifacts_root)
    if root is None or not root.exists():
        return []

    artifacts: list[dict[str, Any]] = []
    for directory in sorted({path.parent for path in root.rglob("QwenVoice-macos*.dmg")}):
        dmg_paths = sorted(directory.glob("QwenVoice-macos*.dmg"))
        if not dmg_paths:
            continue
        metadata_path = next(iter(sorted(directory.glob("release-metadata-*.txt"))), None)
        metadata = _read_release_metadata(metadata_path) if metadata_path else {}
        artifact = {
            "directory": str(directory),
            "dmg_path": str(dmg_paths[0]),
            "metadata_path": str(metadata_path) if metadata_path else None,
            "variant_id": metadata.get("variant_id"),
            "ui_profile": metadata.get("ui_profile"),
            "commit_sha": metadata.get("commit_sha"),
            "metadata": metadata,
        }
        artifacts.append(artifact)

    preferred_order = {"legacy-glass": 0, "modern-liquid": 1}
    artifacts.sort(key=lambda item: (
        preferred_order.get(item.get("variant_id"), 99),
        item.get("dmg_path", ""),
    ))
    return artifacts


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


def _install_stub_models(root: Path) -> None:
    contract = load_contract()
    models_root = root / "models"
    for model in contract.get("models", []):
        folder = model.get("folder")
        if not folder:
            continue
        model_root = models_root / folder
        ensure_directory(model_root)
        for relative_path in model.get("requiredRelativePaths", []):
            file_path = model_root / relative_path
            ensure_directory(file_path.parent)
            file_path.touch(exist_ok=True)


def _resolve_app_bundle_target(app_bundle: Path) -> tuple[bool, UIAppTarget | None, dict[str, Any]]:
    app_bundle = app_bundle.expanduser().resolve()
    app_binary = app_bundle / "Contents" / "MacOS" / "QwenVoice"
    if not app_bundle.exists():
        return False, None, {"error": "app_bundle_not_found", "app_bundle": str(app_bundle)}
    if not app_binary.exists():
        return False, None, {
            "error": "app_binary_not_found",
            "app_bundle": str(app_bundle),
            "app_binary": str(app_binary),
        }

    metadata_path = _locate_metadata_near(app_bundle)
    metadata = _read_release_metadata(metadata_path) if metadata_path else {}
    target = UIAppTarget(
        app_bundle=app_bundle,
        app_binary=app_binary,
        source="bundle",
        variant_id=metadata.get("variant_id"),
        ui_profile=metadata.get("ui_profile"),
        metadata=metadata or None,
        metadata_path=metadata_path,
    )
    return True, target, {
        "source": "bundle",
        "app_bundle": str(app_bundle),
        "app_binary": str(app_binary),
        "variant_id": target.variant_id,
        "ui_profile": target.ui_profile,
        "metadata_path": str(metadata_path) if metadata_path else None,
    }


def _resolve_dmg_app_target(dmg_path: Path) -> tuple[bool, UIAppTarget | None, dict[str, Any]]:
    dmg_path = dmg_path.expanduser().resolve()
    if not dmg_path.exists():
        return False, None, {"error": "dmg_not_found", "dmg": str(dmg_path)}

    mounted_device = None
    temp_root = None
    try:
        attach_proc = subprocess.run(
            ["hdiutil", "attach", "-nobrowse", "-readonly", "-plist", str(dmg_path)],
            capture_output=True,
            check=False,
        )
        if attach_proc.returncode != 0:
            return False, None, {
                "error": "dmg_attach_failed",
                "dmg": str(dmg_path),
                "stderr": attach_proc.stderr.decode("utf-8", errors="ignore").splitlines()[-20:],
            }

        plist = plistlib.loads(attach_proc.stdout)
        mount_point = None
        for entity in plist.get("system-entities", []):
            mounted_device = entity.get("dev-entry") or mounted_device
            candidate = entity.get("mount-point")
            if candidate:
                mount_point = Path(candidate)
                break
        if mount_point is None:
            return False, None, {"error": "dmg_mount_point_missing", "dmg": str(dmg_path)}

        source_app = next(iter(sorted(mount_point.glob("*.app"))), None)
        if source_app is None:
            return False, None, {
                "error": "mounted_app_not_found",
                "dmg": str(dmg_path),
                "mount_point": str(mount_point),
            }

        temp_root = Path(tempfile.mkdtemp(prefix="qwenvoice_release_app_"))
        installed_app = temp_root / source_app.name
        subprocess.run(
            ["ditto", str(source_app), str(installed_app)],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["xattr", "-dr", "com.apple.quarantine", str(installed_app)],
            check=False,
            capture_output=True,
        )

        metadata_path = _locate_metadata_near(dmg_path)
        metadata = _read_release_metadata(metadata_path) if metadata_path else {}
        app_binary = installed_app / "Contents" / "MacOS" / "QwenVoice"
        target = UIAppTarget(
            app_bundle=installed_app,
            app_binary=app_binary,
            source="dmg",
            variant_id=metadata.get("variant_id"),
            ui_profile=metadata.get("ui_profile"),
            metadata=metadata or None,
            metadata_path=metadata_path,
            temp_root=temp_root,
            mounted_device=mounted_device,
            mounted_mount_point=mount_point,
        )
        return True, target, {
            "source": "dmg",
            "dmg": str(dmg_path),
            "mount_point": str(mount_point),
            "mounted_device": mounted_device,
            "app_bundle": str(installed_app),
            "app_binary": str(app_binary),
            "variant_id": target.variant_id,
            "ui_profile": target.ui_profile,
            "metadata_path": str(metadata_path) if metadata_path else None,
        }
    except Exception as exc:
        if mounted_device:
            subprocess.run(
                ["hdiutil", "detach", mounted_device],
                capture_output=True,
                text=True,
            )
        if temp_root is not None:
            shutil.rmtree(temp_root, ignore_errors=True)
        return False, None, {
            "error": "dmg_resolution_failed",
            "dmg": str(dmg_path),
            "detail": str(exc),
        }


def _resolve_release_download_root(artifacts_root: str | None) -> Path | None:
    if artifacts_root:
        return Path(artifacts_root).expanduser().resolve()

    downloads_root = PROJECT_DIR / "build" / "release-downloads"
    if not downloads_root.exists():
        return None

    numeric_children = [
        child for child in downloads_root.iterdir()
        if child.is_dir() and child.name.isdigit()
    ]
    if not numeric_children:
        return downloads_root
    return max(numeric_children, key=lambda child: int(child.name))


def _locate_metadata_near(path: Path) -> Path | None:
    if path.is_dir():
        candidate = next(iter(sorted(path.glob("release-metadata-*.txt"))), None)
        if candidate is not None:
            return candidate
    else:
        candidate = next(iter(sorted(path.parent.glob("release-metadata-*.txt"))), None)
        if candidate is not None:
            return candidate

    return None


def _read_release_metadata(path: Path | None) -> dict[str, str]:
    if path is None or not path.exists():
        return {}

    metadata: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        metadata[key.strip()] = value.strip()
    return metadata
