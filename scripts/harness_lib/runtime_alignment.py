"""Shared runtime version alignment helpers."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

from .paths import (
    APP_REQUIREMENTS_PATH,
    CLI_REQUIREMENTS_PATH,
    PYTHON_BRIDGE_PATH,
    STUB_BACKEND_TRANSPORT_PATH,
)

CORE_PACKAGES = ("mlx", "mlx-metal", "mlx-lm", "mlx-audio", "transformers")
MANIFEST_VERSION_KEYS = {
    "mlx": "mlx_version",
    "mlx-metal": "mlx_metal_version",
    "mlx-lm": "mlx_lm_version",
    "mlx-audio": "mlx_audio_version",
    "transformers": "transformers_version",
}


def parse_core_requirements(path: Path) -> dict[str, str]:
    """Return pinned core package versions from a requirements file."""
    versions: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or line.startswith("--"):
            continue
        requirement = line.split(";", 1)[0].strip()
        if "==" not in requirement:
            continue
        package, version = requirement.split("==", 1)
        package = package.strip()
        if package in CORE_PACKAGES:
            versions[package] = version.strip()

    missing = [package for package in CORE_PACKAGES if package not in versions]
    if missing:
        raise RuntimeError(
            f"Missing core package pins in {path}: {', '.join(missing)}"
        )
    return versions


def app_core_requirements() -> dict[str, str]:
    return parse_core_requirements(APP_REQUIREMENTS_PATH)


def cli_core_requirements() -> dict[str, str]:
    return parse_core_requirements(CLI_REQUIREMENTS_PATH)


def read_pythonbridge_mlx_audio_versions(
    paths: tuple[Path, ...] = (PYTHON_BRIDGE_PATH, STUB_BACKEND_TRANSPORT_PATH),
) -> set[str]:
    versions: set[str] = set()
    searched: list[str] = []
    for path in paths:
        searched.append(str(path))
        text = path.read_text(encoding="utf-8")
        versions.update(
            re.findall(r'mlx_audio_version": \.string\("([^"]+)"\)', text)
        )
    if not versions:
        raise RuntimeError(
            "Could not find stub mlx_audio_version echoes in "
            + ", ".join(searched)
        )
    return versions


def inspect_python_environment(
    python_path: str,
    packages: tuple[str, ...] = CORE_PACKAGES,
) -> dict[str, str]:
    """Resolve installed versions for the core packages in a Python environment."""
    script = """
import json
import sys
from importlib.metadata import version

packages = sys.argv[1:]
resolved = {package: version(package) for package in packages}
print(json.dumps(resolved, sort_keys=True))
"""
    proc = subprocess.run(
        [python_path, "-c", script, *packages],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"Failed to inspect runtime versions via {python_path}: {proc.stderr.strip()}"
        )
    try:
        parsed = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(
            f"Failed to parse runtime version output from {python_path}: {exc}"
        ) from exc
    return {str(key): str(value) for key, value in parsed.items()}


def load_runtime_manifest(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def manifest_core_versions(manifest: dict[str, Any]) -> dict[str, str]:
    versions: dict[str, str] = {}
    missing: list[str] = []
    for package, manifest_key in MANIFEST_VERSION_KEYS.items():
        value = manifest.get(manifest_key)
        if not value:
            missing.append(manifest_key)
            continue
        versions[package] = str(value)

    if missing:
        raise RuntimeError(
            f"Runtime manifest missing core version keys: {', '.join(missing)}"
        )
    return versions


def compare_expected_versions(
    expected: dict[str, str],
    actual: dict[str, str],
) -> dict[str, dict[str, str]]:
    mismatches: dict[str, dict[str, str]] = {}
    for package, expected_version in expected.items():
        actual_version = actual.get(package)
        if actual_version != expected_version:
            mismatches[package] = {
                "expected": expected_version,
                "actual": "" if actual_version is None else actual_version,
            }
    return mismatches


def describe_version_alignment(
    label: str,
    expected: dict[str, str],
    actual: dict[str, str],
) -> dict[str, Any]:
    mismatches = compare_expected_versions(expected, actual)
    return {
        "label": label,
        "expected": expected,
        "actual": actual,
        "mismatches": mismatches,
    }


def resolved_python_for_environment(path: Path) -> str | None:
    if path.exists():
        return str(path)
    fallback = path.with_name("python3.13")
    if fallback.exists():
        return str(fallback)
    return None


def print_core_versions() -> int:
    payload = app_core_requirements()
    json.dump(payload, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(print_core_versions())
