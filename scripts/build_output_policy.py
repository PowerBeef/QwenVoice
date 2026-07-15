#!/usr/bin/env python3
"""Validate, inventory, and conservatively migrate Vocello build outputs.

The checked-in manifest is the build-output contract.  This helper intentionally
does not build, clean, or resolve packages.  Migration is opt-in and refuses to
merge divergent trees or move tracked files.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Sequence


SCRIPT_PATH = Path(__file__).resolve()
DEFAULT_REPO_ROOT = SCRIPT_PATH.parent.parent
DEFAULT_MANIFEST_RELATIVE = Path("config/build-output-policy.json")
POLICY_DOCUMENTATION_RELATIVE = Path("docs/reference/privacy-storage.md")
POLICY_TABLE_BEGIN = "<!-- BEGIN GENERATED BUILD OUTPUT POLICY TABLE -->"
POLICY_TABLE_END = "<!-- END GENERATED BUILD OUTPUT POLICY TABLE -->"

ENTRY_CLASSES = {"cache", "scratch", "artifact", "distribution"}
CLEANUP_POLICIES = {
    "routine",
    "aggressive",
    "prune-ui-results",
    "governed",
    "preserve",
    "dist",
    "clobber-only",
}
DIRECT_RECLAIM_POLICIES = {
    "routine",
    "aggressive",
    "prune-ui-results",
    "dist",
    "clobber-only",
}
IDENTIFIER_RE = re.compile(r"^[a-z][a-z0-9-]*$")
ENV_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
MACHO_UUID_RE = re.compile(r"^UUID:\s+([0-9A-Fa-f-]{36})\s+", re.MULTILINE)
METADATA_ALLOWLIST = (
    "producer",
    "status",
    "platform",
    "scheme",
    "configuration",
    "startedAt",
    "finishedAt",
    "gitRevision",
)


class PolicyError(ValueError):
    """The checked-in policy or repository state violates the contract."""


@dataclass(frozen=True)
class LoadedPolicy:
    repo_root: Path
    manifest_path: Path
    document: dict[str, Any]
    entries: tuple[dict[str, Any], ...]
    entries_by_id: dict[str, dict[str, Any]]

    @property
    def build_root(self) -> Path:
        return self.repo_root / self.document["buildRoot"]


def _relative_posix(value: Any, label: str) -> PurePosixPath:
    if not isinstance(value, str) or not value:
        raise PolicyError(f"{label} must be a non-empty relative POSIX path")
    if "\\" in value:
        raise PolicyError(f"{label} must use POSIX separators: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or value.startswith("~"):
        raise PolicyError(f"{label} must be repository-relative: {value!r}")
    if any(component in {"", ".", ".."} for component in value.split("/")):
        raise PolicyError(f"{label} must be normalized and cannot escape: {value!r}")
    if path.as_posix() != value:
        raise PolicyError(f"{label} must be normalized: {value!r}")
    return path


def _is_same_or_descendant(path: PurePosixPath, parent: PurePosixPath) -> bool:
    return path == parent or path.parts[: len(parent.parts)] == parent.parts


def _assert_non_overlapping(paths: Sequence[tuple[str, PurePosixPath]]) -> None:
    for index, (left_id, left_path) in enumerate(paths):
        for right_id, right_path in paths[index + 1 :]:
            if _is_same_or_descendant(left_path, right_path) or _is_same_or_descendant(
                right_path, left_path
            ):
                raise PolicyError(
                    "managed output roots cannot overlap: "
                    f"{left_id}={left_path} and {right_id}={right_path}"
                )


def _validate_string_list(value: Any, label: str) -> list[str]:
    if not isinstance(value, list) or not all(
        isinstance(item, str) and item for item in value
    ):
        raise PolicyError(f"{label} must be a list of non-empty strings")
    if len(set(value)) != len(value):
        raise PolicyError(f"{label} cannot contain duplicates")
    return value


def _validate_policy_document(document: Any) -> tuple[tuple[dict[str, Any], ...], dict[str, dict[str, Any]]]:
    if not isinstance(document, dict):
        raise PolicyError("policy root must be a JSON object")
    if document.get("schemaVersion") != 1:
        raise PolicyError("unsupported build-output policy schemaVersion")

    build_root = _relative_posix(document.get("buildRoot"), "buildRoot")
    if build_root != PurePosixPath("build"):
        raise PolicyError("buildRoot must remain the repository-local build directory")
    build_root_env = document.get("buildRootEnv")
    if not isinstance(build_root_env, str) or not ENV_RE.fullmatch(build_root_env):
        raise PolicyError("buildRootEnv must be an uppercase shell variable name")
    metadata_filename = document.get("producerMetadataFilename")
    if metadata_filename != "last-build.json":
        raise PolicyError("producerMetadataFilename must be last-build.json")

    raw_entries = document.get("entries")
    if not isinstance(raw_entries, list) or not raw_entries:
        raise PolicyError("entries must be a non-empty array")

    ids: set[str] = set()
    envs: set[str] = {build_root_env}
    paths: list[tuple[str, PurePosixPath]] = []
    entries: list[dict[str, Any]] = []
    for index, raw_entry in enumerate(raw_entries):
        label = f"entries[{index}]"
        if not isinstance(raw_entry, dict):
            raise PolicyError(f"{label} must be an object")
        required = {"id", "path", "class", "owner", "cleanup", "retention", "env"}
        missing = sorted(required.difference(raw_entry))
        if missing:
            raise PolicyError(f"{label} is missing required fields: {', '.join(missing)}")

        entry_id = raw_entry["id"]
        if not isinstance(entry_id, str) or not IDENTIFIER_RE.fullmatch(entry_id):
            raise PolicyError(f"{label}.id is invalid: {entry_id!r}")
        if entry_id in ids:
            raise PolicyError(f"duplicate entry id: {entry_id}")
        ids.add(entry_id)

        entry_path = _relative_posix(raw_entry["path"], f"{label}.path")
        if not _is_same_or_descendant(entry_path, build_root) or entry_path == build_root:
            raise PolicyError(f"{label}.path must be a child of build/: {entry_path}")
        paths.append((entry_id, entry_path))

        entry_class = raw_entry["class"]
        if entry_class not in ENTRY_CLASSES:
            raise PolicyError(f"{label}.class is invalid: {entry_class!r}")
        cleanup = raw_entry["cleanup"]
        if cleanup not in CLEANUP_POLICIES:
            raise PolicyError(f"{label}.cleanup is invalid: {cleanup!r}")
        for field in ("owner", "retention"):
            if not isinstance(raw_entry[field], str) or not raw_entry[field].strip():
                raise PolicyError(f"{label}.{field} must be a non-empty string")

        env = raw_entry["env"]
        if not isinstance(env, str) or not ENV_RE.fullmatch(env):
            raise PolicyError(f"{label}.env is invalid: {env!r}")
        if env in envs:
            raise PolicyError(f"duplicate shell environment name: {env}")
        envs.add(env)
        entries.append(dict(raw_entry))

    _assert_non_overlapping(paths)
    entries_by_id = {entry["id"]: entry for entry in entries}

    raw_links = document.get("publicLinks", [])
    if not isinstance(raw_links, list):
        raise PolicyError("publicLinks must be an array")
    link_paths: set[PurePosixPath] = set()
    for index, link in enumerate(raw_links):
        label = f"publicLinks[{index}]"
        if not isinstance(link, dict):
            raise PolicyError(f"{label} must be an object")
        link_path = _relative_posix(link.get("path"), f"{label}.path")
        if not _is_same_or_descendant(link_path, build_root) or link_path == build_root:
            raise PolicyError(f"{label}.path must be a child of build/")
        if link_path in link_paths:
            raise PolicyError(f"duplicate public link path: {link_path}")
        link_paths.add(link_path)
        if any(_is_same_or_descendant(link_path, path) for _, path in paths):
            raise PolicyError(f"{label}.path cannot be inside a managed output root")
        target_id = link.get("targetEntry")
        if target_id not in entries_by_id:
            raise PolicyError(f"{label}.targetEntry is unknown: {target_id!r}")
        suffix = _relative_posix(link.get("targetSuffix"), f"{label}.targetSuffix")
        if suffix.parts[0] == "build":
            raise PolicyError(f"{label}.targetSuffix must be relative to its target entry")

    external = document.get("externalXcodeDerivedData")
    if not isinstance(external, dict):
        raise PolicyError("externalXcodeDerivedData must be an object")
    external_path = external.get("path")
    if not isinstance(external_path, str) or not external_path.startswith("~/"):
        raise PolicyError("externalXcodeDerivedData.path must be a HOME-relative path")
    if ".." in PurePosixPath(external_path[2:]).parts:
        raise PolicyError("externalXcodeDerivedData.path cannot escape HOME")
    if external.get("policy") != "report-only":
        raise PolicyError("external Xcode DerivedData must remain report-only")
    _validate_string_list(external.get("projectNames"), "externalXcodeDerivedData.projectNames")

    migrations = document.get("migrations", [])
    if not isinstance(migrations, list):
        raise PolicyError("migrations must be an array")
    migration_ids: set[str] = set()
    for index, migration in enumerate(migrations):
        label = f"migrations[{index}]"
        if not isinstance(migration, dict):
            raise PolicyError(f"{label} must be an object")
        migration_id = migration.get("id")
        if not isinstance(migration_id, str) or not IDENTIFIER_RE.fullmatch(migration_id):
            raise PolicyError(f"{label}.id is invalid: {migration_id!r}")
        if migration_id in migration_ids:
            raise PolicyError(f"duplicate migration id: {migration_id}")
        migration_ids.add(migration_id)
        source = _relative_posix(migration.get("source"), f"{label}.source")
        destination = _relative_posix(
            migration.get("destination"), f"{label}.destination"
        )
        mode = migration.get("mode", "move")
        if mode not in {"move", "merge"}:
            raise PolicyError(f"{label}.mode must be move or merge")
        equivalence = migration.get("equivalence", "byte-identical")
        if equivalence not in {"byte-identical", "swiftpm-checkouts"}:
            raise PolicyError(
                f"{label}.equivalence must be byte-identical or swiftpm-checkouts"
            )
        source_allowed = _is_same_or_descendant(source, build_root) or (
            len(source.parts) >= 3
            and source.parts[0] in {"third_party_patches", "Packages"}
            and source.parts[-1] == ".build"
        )
        if not source_allowed:
            raise PolicyError(
                f"{label}.source must be a legacy build root or owned-package .build: {source}"
            )
        if not any(
            _is_same_or_descendant(destination, entry_path) for _, entry_path in paths
        ):
            raise PolicyError(
                f"{label}.destination must be inside a managed output root: {destination}"
            )
        if source == destination or _is_same_or_descendant(destination, source):
            raise PolicyError(f"{label} cannot move a root into itself")

    reference_policy = document.get("referencePolicy")
    if not isinstance(reference_policy, dict):
        raise PolicyError("referencePolicy must be an object")
    for key in ("scanRoots", "excludePrefixes", "retiredPrefixes", "retiredFragments"):
        values = _validate_string_list(reference_policy.get(key), f"referencePolicy.{key}")
        if key == "retiredPrefixes":
            for value in values:
                _relative_posix(value.rstrip("/"), f"referencePolicy.{key}")
        elif key != "retiredFragments":
            for value in values:
                _relative_posix(value, f"referencePolicy.{key}")

    return tuple(entries), entries_by_id


def load_policy(repo_root: Path, manifest_path: Path | None = None) -> LoadedPolicy:
    repo_root = repo_root.expanduser().absolute()
    if not repo_root.is_dir() or repo_root.is_symlink():
        raise PolicyError(f"repository root must be a real directory: {repo_root}")
    selected_manifest = manifest_path or (repo_root / DEFAULT_MANIFEST_RELATIVE)
    if not selected_manifest.is_absolute():
        selected_manifest = repo_root / selected_manifest
    selected_manifest = selected_manifest.absolute()
    try:
        selected_manifest.relative_to(repo_root)
    except ValueError as error:
        raise PolicyError("policy manifest must be inside the repository") from error
    try:
        raw = selected_manifest.read_text(encoding="utf-8")
    except OSError as error:
        raise PolicyError(f"cannot read policy manifest {selected_manifest}: {error}") from error
    try:
        document = json.loads(raw)
    except json.JSONDecodeError as error:
        raise PolicyError(f"invalid policy JSON: {error}") from error
    entries, entries_by_id = _validate_policy_document(document)
    return LoadedPolicy(repo_root, selected_manifest, document, entries, entries_by_id)


def _ensure_existing_path_is_contained(repo_root: Path, path: Path, label: str) -> None:
    try:
        path.relative_to(repo_root)
    except ValueError as error:
        raise PolicyError(f"{label} escapes the repository: {path}") from error
    current = repo_root
    relative = path.relative_to(repo_root)
    for component in relative.parts:
        current = current / component
        if current.is_symlink():
            raise PolicyError(f"{label} contains a symlink path component: {current}")
        if not current.exists():
            break
    if path.exists():
        try:
            path.resolve(strict=True).relative_to(repo_root.resolve(strict=True))
        except (OSError, ValueError) as error:
            raise PolicyError(f"{label} resolves outside the repository: {path}") from error


def _allocated_bytes(path: Path) -> tuple[int, str | None]:
    """Return allocated bytes without following symlinks or double-counting hard links."""

    seen: set[tuple[int, int]] = set()
    total = 0
    errors: list[str] = []

    def visit(candidate: Path) -> None:
        nonlocal total
        try:
            info = candidate.lstat()
        except FileNotFoundError:
            return
        except OSError as error:
            errors.append(f"{candidate}: {error}")
            return
        identity = (info.st_dev, info.st_ino)
        if identity in seen:
            return
        seen.add(identity)
        total += info.st_blocks * 512
        if stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode):
            try:
                with os.scandir(candidate) as children:
                    for child in children:
                        visit(Path(child.path))
            except OSError as error:
                errors.append(f"{candidate}: {error}")

    visit(path)
    return total, "; ".join(errors[:5]) or None


def _read_last_producer(root: Path, filename: str) -> dict[str, Any] | None:
    metadata = root / filename
    if not metadata.is_file() or metadata.is_symlink():
        return None
    try:
        document = json.loads(metadata.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"valid": False}
    if not isinstance(document, dict):
        return {"valid": False}
    result = {key: document[key] for key in METADATA_ALLOWLIST if key in document}
    result["valid"] = True
    return result


def _path_kind(path: Path) -> str:
    if path.is_symlink():
        return "symlink"
    if path.is_dir():
        return "directory"
    if path.is_file():
        return "file"
    return "missing"


def _plist_path_value(value: Any) -> Path | None:
    if not isinstance(value, str) or not value:
        return None
    if value.startswith("file://"):
        value = value[7:]
    return Path(value).expanduser().absolute()


def _external_xcode_matches(policy: LoadedPolicy) -> dict[str, Any]:
    config = policy.document["externalXcodeDerivedData"]
    configured = os.path.expanduser(config["path"])
    root = Path(os.environ.get("QVOICE_EXTERNAL_XCODE_DERIVED_DATA", configured)).absolute()
    project_path = (policy.repo_root / "QwenVoice.xcodeproj").absolute()
    names = set(config["projectNames"])
    matches: list[dict[str, Any]] = []
    if root.is_dir() and not root.is_symlink():
        try:
            children = sorted(root.iterdir(), key=lambda item: item.name)
        except OSError:
            children = []
        for child in children:
            if not child.is_dir() or child.is_symlink():
                continue
            info_path = child / "info.plist"
            try:
                info = plistlib.loads(info_path.read_bytes())
            except (OSError, plistlib.InvalidFileException):
                continue
            if not isinstance(info, dict):
                continue
            reason: str | None = None
            path_values: list[Path] = []
            for key in ("WorkspacePath", "ProjectPath"):
                candidate = _plist_path_value(info.get(key))
                if candidate is not None:
                    path_values.append(candidate)
                if candidate == project_path:
                    reason = key
                    break
            if reason is None and not path_values:
                candidate_names = {
                    value
                    for key in ("WorkspaceName", "ProjectName")
                    if isinstance((value := info.get(key)), str)
                }
                if candidate_names.intersection(names):
                    reason = "project-name"
            if reason is None:
                continue
            allocated, error = _allocated_bytes(child)
            item: dict[str, Any] = {
                "path": str(child),
                "allocatedBytes": allocated,
                "matchReason": reason,
            }
            if error:
                item["inventoryError"] = error
            matches.append(item)
    return {
        "root": str(root),
        "policy": "report-only",
        "matchingEntries": matches,
        "allocatedBytes": sum(item["allocatedBytes"] for item in matches),
    }


def build_status(policy: LoadedPolicy) -> dict[str, Any]:
    roots: list[dict[str, Any]] = []
    totals: dict[str, int] = {cleanup: 0 for cleanup in sorted(CLEANUP_POLICIES)}
    allocated_total = 0
    metadata_filename = policy.document["producerMetadataFilename"]
    for entry in policy.entries:
        path = policy.repo_root / entry["path"]
        _ensure_existing_path_is_contained(policy.repo_root, path, entry["id"])
        allocated, error = _allocated_bytes(path)
        allocated_total += allocated
        reclaimable = allocated if entry["cleanup"] in DIRECT_RECLAIM_POLICIES else 0
        totals[entry["cleanup"]] += reclaimable
        item: dict[str, Any] = {
            "id": entry["id"],
            "path": entry["path"],
            "class": entry["class"],
            "owner": entry["owner"],
            "cleanup": entry["cleanup"],
            "retention": entry["retention"],
            "exists": path.exists(),
            "kind": _path_kind(path),
            "allocatedBytes": allocated,
            "reclaimableBytes": reclaimable,
            "lastProducer": _read_last_producer(path, metadata_filename),
        }
        if error:
            item["inventoryError"] = error
        roots.append(item)

    unowned_roots = _unowned_build_roots(policy)
    unowned_allocated = sum(item["allocatedBytes"] for item in unowned_roots)
    return {
        "schemaVersion": 1,
        "manifest": str(policy.manifest_path),
        "repositoryRoot": str(policy.repo_root),
        "buildRoot": policy.document["buildRoot"],
        "allocatedBytes": allocated_total + unowned_allocated,
        "managedAllocatedBytes": allocated_total,
        "unownedAllocatedBytes": unowned_allocated,
        "reclaimableBytesByPolicy": totals,
        "roots": roots,
        "unownedRoots": unowned_roots,
        "externalXcodeDerivedData": _external_xcode_matches(policy),
    }


def _unowned_build_roots(policy: LoadedPolicy) -> list[dict[str, Any]]:
    """Report generated top-level roots that are outside the manifest contract."""

    build = policy.build_root
    if not build.is_dir() or build.is_symlink():
        return []
    allowed = {
        PurePosixPath(entry["path"]).parts[1]
        for entry in policy.entries
    }
    allowed.update(
        PurePosixPath(link["path"]).parts[1]
        for link in policy.document.get("publicLinks", [])
    )
    # Finder may recreate this metadata file whenever the ignored build folder
    # is viewed. It is neither a producer root nor build evidence.
    allowed.add(".DS_Store")
    result: list[dict[str, Any]] = []
    for child in sorted(build.iterdir(), key=lambda item: item.name):
        if child.name in allowed:
            continue
        _ensure_existing_path_is_contained(policy.repo_root, child, "unowned build root")
        allocated, error = _allocated_bytes(child)
        item: dict[str, Any] = {
            "path": child.relative_to(policy.repo_root).as_posix(),
            "kind": _path_kind(child),
            "allocatedBytes": allocated,
        }
        if error:
            item["inventoryError"] = error
        result.append(item)
    return result


def _markdown_cell(value: Any) -> str:
    """Render one manifest string as a stable single-line Markdown table cell."""

    return " ".join(str(value).split()).replace("|", "\\|")


def render_policy_markdown_table(policy: LoadedPolicy) -> str:
    """Render the checked-in owner/lifetime table directly from the manifest."""

    lines = [
        POLICY_TABLE_BEGIN,
        "| Path | Owner | Class | Cleanup | Retention |",
        "| --- | --- | --- | --- | --- |",
    ]
    for entry in policy.entries:
        path = _markdown_cell(entry["path"] + "/")
        owner = _markdown_cell(entry["owner"])
        entry_class = _markdown_cell(entry["class"])
        cleanup = _markdown_cell(entry["cleanup"])
        retention = _markdown_cell(entry["retention"])
        lines.append(
            f"| `{path}` | {owner} | `{entry_class}` | `{cleanup}` | {retention} |"
        )
    lines.append(POLICY_TABLE_END)
    return "\n".join(lines)


def _git_tracked_files(policy: LoadedPolicy) -> list[str]:
    if not (policy.repo_root / ".git").exists():
        return []
    result = subprocess.run(
        ["git", "-C", str(policy.repo_root), "ls-files", "-z"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise PolicyError("cannot enumerate tracked files for build-output validation")
    return [
        value.decode("utf-8", "surrogateescape")
        for value in result.stdout.split(b"\0")
        if value
    ]


def _selected_for_reference_scan(path: str, reference_policy: dict[str, Any]) -> bool:
    pure = PurePosixPath(path)
    selected = any(
        _is_same_or_descendant(pure, PurePosixPath(root))
        for root in reference_policy["scanRoots"]
    )
    excluded = any(
        _is_same_or_descendant(pure, PurePosixPath(prefix))
        for prefix in reference_policy["excludePrefixes"]
    )
    return selected and not excluded


def _tracked_reference_violations(policy: LoadedPolicy) -> list[str]:
    reference_policy = policy.document["referencePolicy"]
    retired = list(reference_policy["retiredPrefixes"]) + list(
        reference_policy["retiredFragments"]
    )
    absolute_build = str(policy.repo_root / policy.document["buildRoot"])
    violations: list[str] = []
    for relative in _git_tracked_files(policy):
        if not _selected_for_reference_scan(relative, reference_policy):
            continue
        path = policy.repo_root / relative
        try:
            raw = path.read_bytes()
        except OSError:
            continue
        if b"\0" in raw:
            continue
        text = raw.decode("utf-8", "replace")
        for line_number, line in enumerate(text.splitlines(), start=1):
            for marker in retired:
                if marker in line:
                    violations.append(
                        f"{relative}:{line_number}: retired build-output reference {marker!r}"
                    )
            if absolute_build in line:
                violations.append(
                    f"{relative}:{line_number}: absolute repository build path is not portable"
                )
    return sorted(set(violations))


def _documentation_table_violations(policy: LoadedPolicy) -> list[str]:
    """Require the tracked policy table to equal the deterministic manifest render."""

    relative = POLICY_DOCUMENTATION_RELATIVE.as_posix()
    if relative not in set(_git_tracked_files(policy)):
        return []
    path = policy.repo_root / POLICY_DOCUMENTATION_RELATIVE
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        return [f"{relative}: cannot read generated build-output policy table: {error}"]

    if text.count(POLICY_TABLE_BEGIN) != 1 or text.count(POLICY_TABLE_END) != 1:
        return [
            f"{relative}: generated build-output policy table markers are missing or duplicated"
        ]
    start = text.index(POLICY_TABLE_BEGIN)
    end = text.index(POLICY_TABLE_END, start) + len(POLICY_TABLE_END)
    actual = text[start:end]
    expected = render_policy_markdown_table(policy)
    if actual != expected:
        return [
            f"{relative}: generated build-output policy table is stale; "
            "replace it with `python3 scripts/build_output_policy.py status --markdown` output"
        ]
    return []


def _public_link_violations(policy: LoadedPolicy) -> list[str]:
    violations: list[str] = []
    for link in policy.document.get("publicLinks", []):
        link_path = policy.repo_root / link["path"]
        target_entry = policy.entries_by_id[link["targetEntry"]]
        expected = policy.repo_root / target_entry["path"] / link["targetSuffix"]
        if not link_path.exists() and not link_path.is_symlink():
            continue
        if not link_path.is_symlink():
            violations.append(f"{link['path']}: public compatibility path must be a symlink")
            continue
        actual = (link_path.parent / os.readlink(link_path)).resolve(strict=False)
        if actual != expected.resolve(strict=False):
            violations.append(
                f"{link['path']}: symlink target does not match {expected.relative_to(policy.repo_root)}"
            )
    return violations


def _macho_uuids(path: Path) -> tuple[set[str], str | None]:
    try:
        result = subprocess.run(
            ["xcrun", "dwarfdump", "--uuid", str(path)],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as error:
        return set(), str(error)
    uuids = {value.upper() for value in MACHO_UUID_RE.findall(result.stdout)}
    if result.returncode != 0 or not uuids:
        detail = result.stderr.strip() or "no Mach-O UUID reported"
        return set(), detail
    return uuids, None


def _symbol_identity_violations(policy: LoadedPolicy) -> list[str]:
    """Validate retained symbols whenever their canonical product exists."""

    macos_cache = policy.repo_root / policy.entries_by_id["xcode-macos-derived-data"]["path"]
    ios_cache = policy.repo_root / policy.entries_by_id["xcode-ios-device-derived-data"]["path"]
    macos_symbols = policy.repo_root / policy.entries_by_id["symbols-macos"]["path"]
    ios_symbols = policy.repo_root / policy.entries_by_id["symbols-ios"]["path"]
    checks = (
        (
            "macOS Vocello",
            macos_cache / "Build/Products/Release/Vocello.app/Contents/MacOS/Vocello",
            macos_symbols / "Vocello.app.dSYM",
        ),
        (
            "macOS QwenVoiceEngineService",
            macos_cache
            / "Build/Products/Release/Vocello.app/Contents/XPCServices/"
            "QwenVoiceEngineService.xpc/Contents/MacOS/QwenVoiceEngineService",
            macos_symbols / "QwenVoiceEngineService.xpc.dSYM",
        ),
        (
            "iOS Vocello",
            ios_cache / "Build/Products/Release-iphoneos/Vocello.app/Vocello",
            ios_symbols / "Vocello.app.dSYM",
        ),
    )
    violations: list[str] = []
    for label, binary, dsym in checks:
        if not binary.is_file():
            continue
        binary_uuids, binary_error = _macho_uuids(binary)
        if binary_error:
            violations.append(f"{label}: cannot inspect current binary UUID: {binary_error}")
            continue
        if not dsym.is_dir():
            violations.append(
                f"{label}: current product exists but preserved dSYM is missing at "
                f"{dsym.relative_to(policy.repo_root)}"
            )
            continue
        dsym_uuids, dsym_error = _macho_uuids(dsym)
        if dsym_error:
            violations.append(f"{label}: cannot inspect preserved dSYM UUID: {dsym_error}")
            continue
        missing = sorted(binary_uuids.difference(dsym_uuids))
        if missing:
            violations.append(
                f"{label}: preserved dSYM does not match current product UUID(s): "
                + ", ".join(missing)
            )
    return violations


def validate_repository(policy: LoadedPolicy) -> list[str]:
    violations: list[str] = []
    for entry in policy.entries:
        path = policy.repo_root / entry["path"]
        try:
            _ensure_existing_path_is_contained(policy.repo_root, path, entry["id"])
        except PolicyError as error:
            violations.append(str(error))
    violations.extend(_public_link_violations(policy))
    violations.extend(
        f"{item['path']}: unowned generated root; migrate it into the build-output policy"
        for item in _unowned_build_roots(policy)
    )
    violations.extend(_tracked_reference_violations(policy))
    violations.extend(_documentation_table_violations(policy))
    violations.extend(_symbol_identity_violations(policy))
    return sorted(set(violations))


def shell_environment(policy: LoadedPolicy) -> list[tuple[str, str]]:
    values = [
        (policy.document["buildRootEnv"], str(policy.build_root)),
    ]
    values.extend(
        (entry["env"], str(policy.repo_root / entry["path"]))
        for entry in policy.entries
    )
    return values


def _tracked_under(policy: LoadedPolicy, relative: str) -> list[str]:
    if not (policy.repo_root / ".git").exists():
        return []
    result = subprocess.run(
        ["git", "-C", str(policy.repo_root), "ls-files", "-z", "--", relative],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise PolicyError(f"cannot inspect tracked content under {relative}")
    return [
        value.decode("utf-8", "replace")
        for value in result.stdout.split(b"\0")
        if value
    ]


def _file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _tree_signature(path: Path) -> tuple[Any, ...]:
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode):
        return ("symlink", os.readlink(path))
    if stat.S_ISREG(info.st_mode):
        return ("file", stat.S_IMODE(info.st_mode), info.st_size, _file_digest(path))
    if stat.S_ISDIR(info.st_mode):
        children = tuple(
            (child.name, _tree_signature(child))
            for child in sorted(path.iterdir(), key=lambda item: item.name)
        )
        return ("directory", children)
    return ("special", stat.S_IFMT(info.st_mode), info.st_size)


def _trees_identical(left: Path, right: Path) -> bool:
    try:
        return _tree_signature(left) == _tree_signature(right)
    except OSError:
        return False


def _git_output(checkout: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(checkout), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise PolicyError(
            f"cannot verify SwiftPM checkout {checkout.name}: "
            f"{' '.join(arguments)} failed"
        )
    return result.stdout.strip()


def _swiftpm_store_signature(path: Path) -> tuple[Any, ...]:
    """Compare resolver identity and clean checkout revisions, not Git internals.

    Xcode embeds absolute repository/alternates paths and mutable Git indexes in
    each SourcePackages copy. Those bytes necessarily differ by DerivedData
    location even when both stores resolve the exact same immutable sources.
    """

    workspace = path / "workspace-state.json"
    checkouts = path / "checkouts"
    if not workspace.is_file() or not checkouts.is_dir():
        raise PolicyError(f"incomplete SwiftPM SourcePackages store: {path}")
    try:
        workspace_value = json.loads(workspace.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PolicyError(f"invalid SwiftPM workspace-state.json in {path}") from error
    workspace_digest = hashlib.sha256(
        json.dumps(
            workspace_value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("utf-8")
    ).hexdigest()
    revisions: list[tuple[str, str, str]] = []
    for checkout in sorted(checkouts.iterdir(), key=lambda item: item.name):
        if checkout.name == ".DS_Store":
            continue
        if checkout.is_symlink() or not checkout.is_dir():
            raise PolicyError(f"unexpected SwiftPM checkout entry: {checkout}")
        revision = _git_output(checkout, "rev-parse", "HEAD")
        dirty = _git_output(checkout, "status", "--porcelain", "--untracked-files=no")
        if dirty:
            raise PolicyError(f"SwiftPM checkout has tracked modifications: {checkout}")
        submodules = _git_output(checkout, "submodule", "status", "--recursive")
        if any(line[:1] in {"-", "+", "U"} for line in submodules.splitlines() if line):
            raise PolicyError(f"SwiftPM checkout has unresolved submodule state: {checkout}")
        revisions.append((checkout.name, revision, submodules))
    return (workspace_digest, tuple(revisions))


def _migration_sources_equivalent(
    left: Path, right: Path, equivalence: str
) -> bool:
    if _trees_identical(left, right):
        return True
    if equivalence != "swiftpm-checkouts":
        return False
    try:
        return _swiftpm_store_signature(left) == _swiftpm_store_signature(right)
    except PolicyError:
        return False


def _is_excluded_migration_source(path: Path, exclusions: Sequence[Path]) -> bool:
    return any(path == exclusion or exclusion in path.parents for exclusion in exclusions)


def _merge_conflict(
    source: Path, destination: Path, exclusions: Sequence[Path]
) -> str | None:
    """Return the first unsafe merge collision without mutating either tree."""

    if _is_excluded_migration_source(source, exclusions):
        return None
    if not destination.exists() and not destination.is_symlink():
        return None
    if source.is_symlink() or destination.is_symlink():
        return None if _trees_identical(source, destination) else str(destination)
    if source.is_dir() and destination.is_dir():
        for child in sorted(source.iterdir(), key=lambda item: item.name):
            conflict = _merge_conflict(child, destination / child.name, exclusions)
            if conflict:
                return conflict
        return None
    return None if _trees_identical(source, destination) else str(destination)


def _migration_item(
    migration: dict[str, Any], action: str, reason: str, *, blocking: bool = False
) -> dict[str, Any]:
    item = {
        "id": migration["id"],
        "source": migration["source"],
        "destination": migration["destination"],
        "action": action,
        "reason": reason,
        "blocking": blocking,
    }
    if "equivalence" in migration:
        item["equivalence"] = migration["equivalence"]
    return item


def plan_migration(policy: LoadedPolicy) -> list[dict[str, Any]]:
    planned: list[dict[str, Any]] = []
    future_destinations: dict[Path, Path] = {}
    for migration in policy.document.get("migrations", []):
        source = policy.repo_root / migration["source"]
        destination = policy.repo_root / migration["destination"]
        try:
            _ensure_existing_path_is_contained(policy.repo_root, source, migration["id"])
            _ensure_existing_path_is_contained(
                policy.repo_root, destination.parent, migration["id"]
            )
        except PolicyError as error:
            planned.append(_migration_item(migration, "blocked", str(error), blocking=True))
            continue
        tracked = _tracked_under(policy, migration["source"])
        if tracked:
            planned.append(
                _migration_item(
                    migration,
                    "blocked",
                    "source contains tracked content: " + ", ".join(tracked[:5]),
                    blocking=True,
                )
            )
            continue
        if not source.exists() and not source.is_symlink():
            action = "already-migrated" if destination.exists() else "not-present"
            reason = "legacy source is absent and destination exists" if destination.exists() else "legacy source is absent"
            planned.append(_migration_item(migration, action, reason))
            continue
        if source.is_symlink():
            planned.append(
                _migration_item(
                    migration,
                    "blocked",
                    "legacy source is a symlink",
                    blocking=True,
                )
            )
            continue
        if migration.get("mode", "move") == "merge":
            if not source.is_dir():
                planned.append(
                    _migration_item(
                        migration,
                        "blocked",
                        "merge migration source is not a directory",
                        blocking=True,
                    )
                )
                continue
            prior_sources = [
                policy.repo_root / prior["source"]
                for prior in planned
                if not prior["blocking"]
                and prior["action"] in {"move", "remove-identical-duplicate"}
                and _is_same_or_descendant(
                    PurePosixPath(prior["source"]), PurePosixPath(migration["source"])
                )
            ]
            conflict = _merge_conflict(source, destination, prior_sources)
            if conflict:
                planned.append(
                    _migration_item(
                        migration,
                        "blocked",
                        f"merge would overwrite non-identical destination content: {conflict}",
                        blocking=True,
                    )
                )
            else:
                planned.append(
                    _migration_item(
                        migration,
                        "merge",
                        "remaining untracked content can be merged without overwriting differences",
                    )
                )
            continue
        comparison = destination if destination.exists() else future_destinations.get(destination)
        if comparison is not None:
            if _migration_sources_equivalent(
                source, comparison, migration.get("equivalence", "byte-identical")
            ):
                planned.append(
                    _migration_item(
                        migration,
                        "remove-identical-duplicate",
                        "destination (or an earlier source for it) is equivalent under the declared policy",
                    )
                )
            else:
                planned.append(
                    _migration_item(
                        migration,
                        "blocked",
                        "destination exists or is planned from different content",
                        blocking=True,
                    )
                )
            continue
        future_destinations[destination] = source
        planned.append(
            _migration_item(
                migration,
                "move",
                "untracked legacy source can be atomically renamed",
            )
        )
    planned.extend(_plan_public_links(policy, planned))
    return planned


def _future_source_for_destination(
    policy: LoadedPolicy, expected: Path, migration_plan: Sequence[dict[str, Any]]
) -> Path | None:
    for item in migration_plan:
        if item["blocking"] or item["action"] not in {"move", "merge"}:
            continue
        destination = policy.repo_root / item["destination"]
        try:
            relative = expected.relative_to(destination)
        except ValueError:
            continue
        return policy.repo_root / item["source"] / relative
    return None


def _plan_public_links(
    policy: LoadedPolicy, migration_plan: Sequence[dict[str, Any]]
) -> list[dict[str, Any]]:
    planned: list[dict[str, Any]] = []
    for link in policy.document.get("publicLinks", []):
        link_path = policy.repo_root / link["path"]
        target_entry = policy.entries_by_id[link["targetEntry"]]
        expected = policy.repo_root / target_entry["path"] / link["targetSuffix"]
        comparison = expected if expected.exists() else _future_source_for_destination(
            policy, expected, migration_plan
        )
        item = {
            "id": "public-link-" + link_path.name.lower().replace(".", "-"),
            "source": link["path"],
            "destination": str(expected.relative_to(policy.repo_root)),
            "blocking": False,
        }
        if link_path.is_symlink():
            actual = (link_path.parent / os.readlink(link_path)).resolve(strict=False)
            if actual == expected.resolve(strict=False):
                item.update(action="already-migrated", reason="public symlink already targets the canonical product")
            elif comparison is not None and actual == comparison.resolve(strict=False):
                item.update(action="replace-symlink", reason="public symlink targets the legacy product scheduled for migration")
            else:
                item.update(action="blocked", reason="public symlink has an unknown target", blocking=True)
            planned.append(item)
            continue
        if not link_path.exists():
            if comparison is None or not comparison.exists():
                item.update(action="not-present", reason="neither public path nor canonical product exists")
            else:
                item.update(action="create-symlink", reason="canonical product exists or is scheduled for migration")
            planned.append(item)
            continue
        if comparison is None or not comparison.exists():
            item.update(action="blocked", reason="cannot verify copied public product because canonical product is absent", blocking=True)
        elif _trees_identical(link_path, comparison):
            item.update(action="replace-with-symlink", reason="copied public product is byte-identical to the canonical product")
        else:
            item.update(action="blocked", reason="copied public product differs from the canonical product", blocking=True)
        planned.append(item)
    return planned


def _remove_untracked_duplicate(path: Path) -> None:
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()


def _rewrite_swiftpm_store_location(path: Path, old_root: Path, new_root: Path) -> None:
    """Repair Xcode's location-specific Git metadata after an atomic store move."""

    old = str(old_root.absolute()).encode("utf-8")
    new = str(new_root.absolute()).encode("utf-8")
    for candidate in sorted(path.rglob("*")):
        if candidate.is_symlink() or not candidate.is_file() or ".git" not in candidate.parts:
            continue
        relative_git = candidate.parts[candidate.parts.index(".git") :]
        allowed = (
            candidate.name in {"config", "alternates", ".git"}
            or "logs" in relative_git
        )
        if not allowed:
            continue
        try:
            payload = candidate.read_bytes()
        except OSError as error:
            raise PolicyError(f"cannot inspect moved SwiftPM metadata: {candidate}") from error
        if old not in payload:
            continue
        replacement = payload.replace(old, new)
        temporary = candidate.with_name(f".{candidate.name}.policy-rewrite-{os.getpid()}")
        if temporary.exists() or temporary.is_symlink():
            raise PolicyError(f"temporary SwiftPM metadata path already exists: {temporary}")
        temporary.write_bytes(replacement)
        os.chmod(temporary, stat.S_IMODE(candidate.stat().st_mode))
        os.replace(temporary, candidate)
    _swiftpm_store_signature(path)


def _merge_tree_safely(source: Path, destination: Path) -> None:
    if not destination.exists() and not destination.is_symlink():
        destination.parent.mkdir(parents=True, exist_ok=True)
        os.replace(source, destination)
        return
    if not source.is_dir() or source.is_symlink() or not destination.is_dir() or destination.is_symlink():
        if _trees_identical(source, destination):
            _remove_untracked_duplicate(source)
            return
        raise PolicyError(f"refusing non-identical migration merge at {destination}")
    for child in sorted(source.iterdir(), key=lambda item: item.name):
        _merge_tree_safely(child, destination / child.name)
    source.rmdir()


def _install_relative_symlink(link_path: Path, target: Path, replace_copy: bool) -> None:
    link_path.parent.mkdir(parents=True, exist_ok=True)
    relative_target = os.path.relpath(target, start=link_path.parent)
    temporary_link = link_path.parent / f".{link_path.name}.policy-link-{os.getpid()}"
    backup = link_path.parent / f".{link_path.name}.policy-backup-{os.getpid()}"
    if temporary_link.exists() or temporary_link.is_symlink() or backup.exists():
        raise PolicyError(f"temporary migration path already exists beside {link_path}")
    os.symlink(relative_target, temporary_link)
    if not replace_copy:
        os.replace(temporary_link, link_path)
        return
    os.replace(link_path, backup)
    try:
        os.replace(temporary_link, link_path)
    except BaseException:
        os.replace(backup, link_path)
        if temporary_link.exists() or temporary_link.is_symlink():
            temporary_link.unlink()
        raise
    _remove_untracked_duplicate(backup)


def apply_migration(policy: LoadedPolicy, plan: list[dict[str, Any]]) -> list[dict[str, Any]]:
    blockers = [item for item in plan if item["blocking"]]
    if blockers:
        raise PolicyError("migration has blocking conflicts; no changes were made")
    results: list[dict[str, Any]] = []
    for item in plan:
        source = policy.repo_root / item["source"]
        destination = policy.repo_root / item["destination"]
        action = item["action"]
        if action == "move":
            destination.parent.mkdir(parents=True, exist_ok=True)
            os.replace(source, destination)
            if (
                item.get("equivalence") == "swiftpm-checkouts"
                and (destination / "workspace-state.json").is_file()
                and (destination / "checkouts").is_dir()
            ):
                _rewrite_swiftpm_store_location(destination, source, destination)
            result = dict(item)
            result["applied"] = True
            results.append(result)
        elif action == "merge":
            _merge_tree_safely(source, destination)
            result = dict(item)
            result["applied"] = True
            results.append(result)
        elif action == "remove-identical-duplicate":
            if not _migration_sources_equivalent(
                source,
                destination,
                str(item.get("equivalence", "byte-identical")),
            ):
                raise PolicyError(
                    f"migration duplicate changed after planning: {source}"
                )
            _remove_untracked_duplicate(source)
            result = dict(item)
            result["applied"] = True
            results.append(result)
        elif action in {"create-symlink", "replace-with-symlink", "replace-symlink"}:
            if action == "replace-symlink":
                temporary = source.parent / f".{source.name}.policy-link-{os.getpid()}"
                if temporary.exists() or temporary.is_symlink():
                    raise PolicyError(f"temporary migration path already exists beside {source}")
                os.symlink(os.path.relpath(destination, start=source.parent), temporary)
                os.replace(temporary, source)
            else:
                _install_relative_symlink(
                    source,
                    destination,
                    replace_copy=action == "replace-with-symlink",
                )
            result = dict(item)
            result["applied"] = True
            results.append(result)
        else:
            result = dict(item)
            result["applied"] = False
            results.append(result)
    return results


def _human_bytes(value: int) -> str:
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    amount = float(value)
    unit = units[0]
    for unit in units:
        if amount < 1024 or unit == units[-1]:
            break
        amount /= 1024
    return f"{amount:.0f}{unit}" if unit == "B" else f"{amount:.2f}{unit}"


def _print_status_human(status: dict[str, Any]) -> None:
    print(f"Build output policy: {status['manifest']}")
    print(
        f"Allocated bytes: total={status['allocatedBytes']} ({_human_bytes(status['allocatedBytes'])}) "
        f"managed={status['managedAllocatedBytes']} ({_human_bytes(status['managedAllocatedBytes'])}) "
        f"unowned={status['unownedAllocatedBytes']} ({_human_bytes(status['unownedAllocatedBytes'])})"
    )
    for root in status["roots"]:
        producer = root["lastProducer"] or "none"
        print(
            f"{root['id']}: class={root['class']} cleanup={root['cleanup']} "
            f"bytes={root['allocatedBytes']} ({_human_bytes(root['allocatedBytes'])}) "
            f"path={root['path']} owner={root['owner']} lastProducer={producer}"
        )
    for root in status["unownedRoots"]:
        print(
            f"unowned: class=unowned cleanup=none bytes={root['allocatedBytes']} "
            f"({_human_bytes(root['allocatedBytes'])}) path={root['path']} owner=none"
        )
    external = status["externalXcodeDerivedData"]
    print(
        "external-xcode-derived-data: "
        f"policy={external['policy']} matches={len(external['matchingEntries'])} "
        f"bytes={external['allocatedBytes']} ({_human_bytes(external['allocatedBytes'])}) "
        f"path={external['root']}"
    )


def _print_migration(plan: list[dict[str, Any]], mode: str) -> None:
    print(f"migration-mode: {mode}")
    for item in plan:
        print(
            f"migration: id={item['id']} action={item['action']} blocking={str(item['blocking']).lower()} "
            f"source={item['source']} destination={item['destination']} reason={item['reason']}"
        )


def _add_common_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=DEFAULT_REPO_ROOT,
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        help=argparse.SUPPRESS,
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    status = subparsers.add_parser("status", help="inventory managed and external build output")
    _add_common_arguments(status)
    status_format = status.add_mutually_exclusive_group()
    status_format.add_argument("--json", action="store_true", dest="as_json")
    status_format.add_argument(
        "--markdown",
        action="store_true",
        help="render the manifest-owned documentation table",
    )

    validate = subparsers.add_parser("validate", help="validate policy and tracked references")
    _add_common_arguments(validate)
    validate.add_argument("--json", action="store_true", dest="as_json")

    shell_env = subparsers.add_parser("shell-env", help="emit shell-safe canonical path exports")
    _add_common_arguments(shell_env)

    migrate = subparsers.add_parser("migrate", help="plan or apply conservative legacy migration")
    _add_common_arguments(migrate)
    mode = migrate.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--apply", action="store_true")
    migrate.add_argument("--json", action="store_true", dest="as_json")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        policy = load_policy(args.repo_root, args.manifest)
        if args.command == "status":
            if args.markdown:
                print(render_policy_markdown_table(policy))
                return 0
            status = build_status(policy)
            if args.as_json:
                print(json.dumps(status, sort_keys=True, indent=2))
            else:
                _print_status_human(status)
            return 0
        if args.command == "validate":
            violations = validate_repository(policy)
            if args.as_json:
                print(
                    json.dumps(
                        {"valid": not violations, "violations": violations},
                        sort_keys=True,
                        indent=2,
                    )
                )
            elif violations:
                for violation in violations:
                    print(f"error: {violation}", file=sys.stderr)
            else:
                print("Build output policy: PASS")
            return 1 if violations else 0
        if args.command == "shell-env":
            for name, value in shell_environment(policy):
                print(f"export {name}={shlex.quote(value)}")
            return 0
        if args.command == "migrate":
            migration_plan = plan_migration(policy)
            if args.apply:
                migration_plan = apply_migration(policy, migration_plan)
                mode_name = "apply"
            else:
                mode_name = "dry-run"
            if args.as_json:
                print(
                    json.dumps(
                        {"mode": mode_name, "operations": migration_plan},
                        sort_keys=True,
                        indent=2,
                    )
                )
            else:
                _print_migration(migration_plan, mode_name)
            return 1 if any(item["blocking"] for item in migration_plan) else 0
    except PolicyError as error:
        print(f"build-output-policy error: {error}", file=sys.stderr)
        return 2
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
