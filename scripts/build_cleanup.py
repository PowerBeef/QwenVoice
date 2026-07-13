#!/usr/bin/env python3
"""Bounded cleanup for repository-owned build outputs.

The machine-readable build-output policy owns every normal target.  This
command is deliberately conservative: inventory is the default, cleanup tiers
are explicit, tracked files are never removed, and unresolved evidence is
preserved.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]
POLICY_PATH = REPO_ROOT / "config" / "build-output-policy.json"
HISTORY_HELPER = REPO_ROOT / "scripts" / "benchmark_history.py"
DEBUG_MODELS = Path.home() / "Library" / "Application Support" / "QwenVoice-Debug" / "models"
SHIPPED_MODELS = Path.home() / "Library" / "Application Support" / "QwenVoice" / "models"


class CleanupError(RuntimeError):
    pass


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CleanupError(f"could not read {path}: {error}") from error
    if not isinstance(value, dict):
        raise CleanupError(f"{path} must contain a JSON object")
    return value


def load_policy() -> dict[str, Any]:
    policy = load_json(POLICY_PATH)
    if policy.get("schemaVersion") != 1 or policy.get("buildRoot") != "build":
        raise CleanupError("unsupported build-output policy")
    entries = policy.get("entries")
    if not isinstance(entries, list) or not entries:
        raise CleanupError("build-output policy has no entries")
    seen: set[str] = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise CleanupError("build-output policy entry must be an object")
        path = entry.get("path")
        if not isinstance(path, str) or not path.startswith("build/"):
            raise CleanupError(f"invalid managed build path: {path!r}")
        resolved = (REPO_ROOT / path).resolve(strict=False)
        try:
            resolved.relative_to((REPO_ROOT / "build").resolve(strict=False))
        except ValueError as error:
            raise CleanupError(f"managed path escapes build/: {path}") from error
        if path in seen:
            raise CleanupError(f"duplicate managed build path: {path}")
        seen.add(path)
    return policy


def allocated_bytes(path: Path) -> int:
    if not path.exists() and not path.is_symlink():
        return 0
    try:
        if path.is_symlink() or path.is_file():
            return path.lstat().st_blocks * 512
    except FileNotFoundError:
        return 0
    total = 0
    for parent, directories, files in os.walk(path, followlinks=False):
        parent_path = Path(parent)
        kept: list[str] = []
        for name in directories:
            child = parent_path / name
            try:
                if child.is_symlink():
                    total += child.lstat().st_blocks * 512
                else:
                    kept.append(name)
            except FileNotFoundError:
                continue
        directories[:] = kept
        for name in files:
            try:
                total += (parent_path / name).lstat().st_blocks * 512
            except FileNotFoundError:
                continue
    return total


def human_bytes(value: int) -> str:
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    amount = float(value)
    index = 0
    while amount >= 1024 and index < len(units) - 1:
        amount /= 1024
        index += 1
    return f"{amount:.0f}{units[index]}" if index == 0 else f"{amount:.2f}{units[index]}"


def canonical_digest(value: Any) -> str:
    encoded = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def trace_digest(trace: Path) -> str:
    rows = [
        [path.relative_to(trace).as_posix(), file_digest(path)]
        for path in sorted(trace.rglob("*"))
        if path.is_file() and not path.is_symlink()
    ]
    return canonical_digest(rows)


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True, ensure_ascii=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def tracked_paths_below(path: Path) -> list[str]:
    try:
        relative = path.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return []
    result = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "ls-files", "-z", "--", relative],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return [part.decode("utf-8", "replace") for part in result.stdout.split(b"\0") if part]


def assert_repository_target(path: Path, *, allow_build_root: bool = False) -> None:
    root = REPO_ROOT.resolve()
    build = (REPO_ROOT / "build").resolve(strict=False)
    absolute = Path(os.path.abspath(path))
    if REPO_ROOT.is_symlink() or not REPO_ROOT.is_dir():
        raise CleanupError("repository root must be a real directory")
    try:
        absolute.relative_to(build)
    except ValueError as error:
        raise CleanupError(f"cleanup target escapes repository build root: {absolute}") from error
    if absolute == build and not allow_build_root:
        raise CleanupError("build root removal requires the explicit clobber path")
    current = REPO_ROOT
    for component in absolute.relative_to(REPO_ROOT).parts[:-1]:
        current /= component
        if current.is_symlink():
            raise CleanupError(f"cleanup target crosses a symlink: {current}")
    tracked = tracked_paths_below(absolute)
    if tracked:
        raise CleanupError(
            "refusing cleanup target containing tracked files: " + ", ".join(tracked[:5])
        )
    try:
        absolute.parent.resolve(strict=False).relative_to(root)
    except ValueError as error:
        raise CleanupError(f"cleanup target parent escapes repository: {absolute}") from error


class Cleaner:
    def __init__(self, *, dry_run: bool) -> None:
        self.dry_run = dry_run
        self.planned = 0

    def remove(self, path: Path, *, allow_build_root: bool = False, reason: str = "policy") -> None:
        if not path.exists() and not path.is_symlink():
            return
        assert_repository_target(path, allow_build_root=allow_build_root)
        size = allocated_bytes(path)
        self.planned += size
        verb = "would-remove" if self.dry_run else "removed"
        print(f"{verb}: bytes={size} human={human_bytes(size)} path={path} reason={reason}")
        if self.dry_run:
            return
        if path.is_symlink() or path.is_file():
            path.unlink()
        else:
            shutil.rmtree(path)


def policy_entries(policy: dict[str, Any], *, cleanup: str | None = None) -> list[dict[str, Any]]:
    result = [entry for entry in policy["entries"] if isinstance(entry, dict)]
    if cleanup is not None:
        result = [entry for entry in result if entry.get("cleanup") == cleanup]
    return result


def managed_path(entry: dict[str, Any]) -> Path:
    return REPO_ROOT / str(entry["path"])


def flatten_strings(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from flatten_strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from flatten_strings(child)


def matching_external_derived_data(policy: dict[str, Any]) -> list[Path]:
    external = policy.get("externalXcodeDerivedData") or {}
    root = Path(os.path.expanduser(str(external.get("path", ""))))
    if not root.is_dir():
        return []
    exact_paths = {
        str((REPO_ROOT / "QwenVoice.xcodeproj").resolve()),
        str(REPO_ROOT.resolve()),
    }
    matches: list[Path] = []
    for candidate in sorted(root.iterdir()):
        info = candidate / "info.plist"
        if candidate.is_symlink() or not candidate.is_dir() or not info.is_file():
            continue
        try:
            with info.open("rb") as stream:
                payload = plistlib.load(stream)
        except (OSError, plistlib.InvalidFileException):
            continue
        values = set(flatten_strings(payload))
        normalized_values = set(values)
        for value in values:
            if value.startswith("/"):
                normalized_values.add(str(Path(value).resolve(strict=False)))
        if normalized_values & exact_paths:
            matches.append(candidate)
    return matches


def inventory(policy: dict[str, Any]) -> None:
    repository_bytes = allocated_bytes(REPO_ROOT)
    print("==> Build-output inventory")
    print(
        f"inventory: id=repository class=source bytes={repository_bytes} "
        f"human={human_bytes(repository_bytes)} path={REPO_ROOT} policy=never-remove"
    )
    for entry in policy_entries(policy):
        path = managed_path(entry)
        size = allocated_bytes(path)
        print(
            "inventory: "
            f"id={entry.get('id')} class={entry.get('class')} bytes={size} "
            f"human={human_bytes(size)} path={path} cleanup={entry.get('cleanup')} "
            f"owner={json.dumps(entry.get('owner'), ensure_ascii=True)}"
        )
    for link in policy.get("publicLinks") or []:
        path = REPO_ROOT / str(link.get("path"))
        target = os.readlink(path) if path.is_symlink() else "not-a-symlink"
        print(f"public-link: path={path} target={target}")
    for candidate in matching_external_derived_data(policy):
        size = allocated_bytes(candidate)
        print(
            f"external-xcode: bytes={size} human={human_bytes(size)} "
            f"path={candidate} action=report-only"
        )
    print(
        f"models: debugBytes={allocated_bytes(DEBUG_MODELS)} shippedBytes={allocated_bytes(SHIPPED_MODELS)} "
        "shippedPolicy=never-remove"
    )


def valid_ui_history(run_id: str, platform: str) -> bool:
    record = REPO_ROOT / "benchmarks" / "runs" / "ui-generation" / f"{run_id}.json"
    try:
        payload = load_json(record)
    except CleanupError:
        return False
    run = payload.get("run") or {}
    if not (
        run.get("id") == run_id
        and run.get("kind") == "ui-generation"
        and run.get("platform") == platform
        and run.get("status") in {"passed", "passedWithWarnings"}
    ):
        return False
    result = subprocess.run(
        [sys.executable, str(HISTORY_HELPER), "validate", str(record)],
        cwd=REPO_ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def prune_ui(cleaner: Cleaner, ui_root: Path, keep: int) -> None:
    if not ui_root.is_dir():
        return
    groups: dict[tuple[str, str, str], list[tuple[str, Path]]] = {}
    for platform in ("macos", "ios"):
        platform_root = ui_root / platform
        if not platform_root.is_dir():
            continue
        for run_dir in sorted(platform_root.iterdir()):
            if run_dir.is_symlink() or not run_dir.is_dir():
                continue
            try:
                payload = load_json(run_dir / "run.json")
            except CleanupError:
                continue
            lane = payload.get("lane")
            run_id = payload.get("runID")
            status = payload.get("status")
            if (
                payload.get("platform") != platform
                or lane not in {"smoke", "benchmark"}
                or status not in {"running", "failed", "passed"}
                or not isinstance(run_id, str)
                or run_id != run_dir.name
            ):
                continue
            groups.setdefault((platform, lane, status), []).append((run_id, run_dir))
    for (platform, lane, status), runs in groups.items():
        ordered = sorted(runs, reverse=True)
        for run_id, path in ordered[keep:]:
            if status == "passed" and lane == "benchmark" and not valid_ui_history(run_id, platform):
                print(
                    f"ui-result-preserved: path={path} "
                    "reason=benchmark-publication-repair-evidence"
                )
                continue
            cleaner.remove(path, reason=f"superseded-ui-{status}")


def compact_profile_failures(cleaner: Cleaner, root: Path) -> None:
    for platform in ("macos", "ios"):
        profiles = root / platform / "profiles"
        if not profiles.is_dir() or profiles.is_symlink():
            continue
        failed: dict[str, list[tuple[str, Path, Path, dict[str, Any]]]] = {}
        for run in sorted(profiles.iterdir()):
            marker_path = run / "profile-retention.json"
            if run.is_symlink() or not run.is_dir() or not marker_path.is_file():
                continue
            try:
                marker = load_json(marker_path)
            except CleanupError:
                continue
            kind = marker.get("profileKind")
            trace = run / f"{run.name}.trace"
            if kind not in {"cpu", "memory"} or not trace.is_dir() or trace.is_symlink():
                continue
            if marker.get("status") == "failed":
                capture = str(marker.get("captureTime") or run.name)
                failed.setdefault(kind, []).append((capture, run, trace, marker))
                continue
            if marker.get("status") != "published":
                continue
            if marker.get("retentionPolicy") == "keptExplicitly":
                print(f"profile-retained: path={trace} policy=keptExplicitly")
                continue
            if marker.get("retentionPolicy") != "summaryOnly":
                continue
            history = REPO_ROOT / "benchmarks" / "runs" / "instrument-profile" / f"{run.name}.json"
            try:
                record = load_json(history)
            except CleanupError:
                print(f"profile-retained: path={trace} reason=missing-history-proof")
                continue
            trace_evidence = (record.get("evidence") or {}).get("trace") or {}
            if not (
                (record.get("run") or {}).get("id") == run.name
                and (record.get("run") or {}).get("status") in {"passed", "passedWithWarnings"}
                and trace_evidence.get("validated") is True
                and trace_evidence.get("digest") == trace_digest(trace)
            ):
                print(f"profile-retained: path={trace} reason=invalid-history-proof")
                continue
            cleaner.remove(trace, reason="published-profile-summary")
            if not cleaner.dry_run:
                marker["rawTraceRetained"] = False
                marker["retentionPolicy"] = "summaryOnly"
                atomic_json(marker_path, marker)
        for kind, candidates in failed.items():
            ordered = sorted(candidates, key=lambda item: (item[0], item[1].name), reverse=True)
            for _, run, trace, marker in ordered[1:]:
                cleaner.remove(trace, reason="superseded-failed-profile")
                if cleaner.dry_run:
                    continue
                marker["rawTraceRetained"] = False
                marker["retentionPolicy"] = "failedCompacted"
                atomic_json(run / "profile-retention.json", marker)
                summary_path = run / "profile-failure-summary.json"
                if summary_path.is_file():
                    summary = load_json(summary_path)
                    summary["rawTraceRetained"] = False
                    atomic_json(summary_path, summary)


def remove_models(cleaner: Cleaner) -> None:
    if not DEBUG_MODELS.exists() and not DEBUG_MODELS.is_symlink():
        return
    if DEBUG_MODELS == SHIPPED_MODELS:
        raise CleanupError("debug and shipped model paths unexpectedly match")
    size = allocated_bytes(DEBUG_MODELS)
    cleaner.planned += size
    verb = "would-remove" if cleaner.dry_run else "removed"
    print(f"{verb}: bytes={size} human={human_bytes(size)} path={DEBUG_MODELS} reason=models")
    if cleaner.dry_run:
        return
    if DEBUG_MODELS.is_symlink() or DEBUG_MODELS.is_file():
        DEBUG_MODELS.unlink()
    else:
        shutil.rmtree(DEBUG_MODELS)


def remove_external_xcode(cleaner: Cleaner, policy: dict[str, Any]) -> None:
    for candidate in matching_external_derived_data(policy):
        probe = subprocess.run(
            ["lsof", "+D", str(candidate)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ) if shutil.which("lsof") else None
        if probe is not None and probe.returncode == 0:
            raise CleanupError(f"external Xcode DerivedData appears to be in use: {candidate}")
        size = allocated_bytes(candidate)
        cleaner.planned += size
        verb = "would-remove" if cleaner.dry_run else "removed"
        print(
            f"{verb}: bytes={size} human={human_bytes(size)} path={candidate} "
            "reason=exact-project-external-xcode"
        )
        if not cleaner.dry_run:
            shutil.rmtree(candidate)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_argument_group("cleanup modes")
    modes.add_argument("--routine", action="store_true")
    modes.add_argument("--aggressive", action="store_true")
    modes.add_argument("--prune-ui-results", action="store_true")
    modes.add_argument("--dist", action="store_true")
    modes.add_argument("--models", action="store_true")
    modes.add_argument("--external-xcode", action="store_true")
    modes.add_argument("--clobber", action="store_true")
    parser.add_argument("--ui-keep", type=int, default=1)
    parser.add_argument("--yes", action="store_true")
    parser.add_argument("--dry-run", "-n", action="store_true")
    args = parser.parse_args()
    if args.ui_keep < 1:
        parser.error("--ui-keep must be at least 1")
    selected = sum(
        bool(value)
        for value in (
            args.routine, args.aggressive, args.prune_ui_results, args.dist,
            args.models, args.external_xcode, args.clobber,
        )
    )
    if args.aggressive and args.routine:
        selected -= 1
    if selected > 1:
        parser.error("cleanup modes are mutually exclusive")
    if args.ui_keep != 1 and not args.prune_ui_results:
        parser.error("--ui-keep is valid only with --prune-ui-results")
    if (args.external_xcode or args.clobber) and not args.yes:
        parser.error("--external-xcode and --clobber require --yes")
    if args.yes and not (args.external_xcode or args.clobber):
        parser.error("--yes is valid only with --external-xcode or --clobber")
    return args


def main() -> int:
    args = parse_arguments()
    try:
        policy = load_policy()
        before = allocated_bytes(REPO_ROOT)
        inventory(policy)
        any_mode = any(
            (
                args.routine, args.aggressive, args.prune_ui_results, args.dist,
                args.models, args.external_xcode, args.clobber,
            )
        )
        if not any_mode:
            if args.dry_run:
                print("dryRun=true (inventory only; no cleanup mode selected)")
            return 0
        cleaner = Cleaner(dry_run=args.dry_run)
        by_env = {entry.get("env"): entry for entry in policy_entries(policy)}
        if args.prune_ui_results:
            prune_ui(cleaner, managed_path(by_env["QVOICE_ARTIFACTS_UI_TESTS"]), args.ui_keep)
        elif args.routine or args.aggressive:
            for entry in policy_entries(policy, cleanup="routine"):
                cleaner.remove(managed_path(entry), reason="routine")
            compact_profile_failures(cleaner, REPO_ROOT / "build" / "artifacts")
            prune_ui(cleaner, managed_path(by_env["QVOICE_ARTIFACTS_UI_TESTS"]), 1)
            if args.aggressive:
                for entry in policy_entries(policy, cleanup="aggressive"):
                    cleaner.remove(managed_path(entry), reason="aggressive")
                for link in policy.get("publicLinks") or []:
                    cleaner.remove(REPO_ROOT / str(link["path"]), reason="aggressive-public-link")
        elif args.dist:
            for entry in policy_entries(policy, cleanup="dist"):
                cleaner.remove(managed_path(entry), reason="distribution")
        elif args.models:
            remove_models(cleaner)
        elif args.external_xcode:
            remove_external_xcode(cleaner, policy)
        elif args.clobber:
            cleaner.remove(REPO_ROOT / "build", allow_build_root=True, reason="clobber")
            for migration in policy.get("migrations") or []:
                source = REPO_ROOT / str(migration.get("source", ""))
                if source.parts[-1:] == (".build",) and source.exists():
                    if tracked_paths_below(source):
                        raise CleanupError(f"clobber refuses tracked generated path: {source}")
                    size = allocated_bytes(source)
                    cleaner.planned += size
                    verb = "would-remove" if cleaner.dry_run else "removed"
                    print(f"{verb}: bytes={size} human={human_bytes(size)} path={source} reason=clobber")
                    if not cleaner.dry_run:
                        shutil.rmtree(source)

        after = before if args.dry_run else allocated_bytes(REPO_ROOT)
        reclaimed = max(0, before - after)
        print("==> Cleanup summary")
        print(f"repositoryBytesBefore={before}")
        print(f"plannedReclaimBytes={cleaner.planned}")
        print(f"dryRun={'true' if args.dry_run else 'false'}")
        if not args.dry_run:
            print(f"repositoryReclaimedBytes={reclaimed}")
            print(f"repositoryBytesAfter={after}")
        print(f"shippedModelsPreserved={SHIPPED_MODELS}")
        return 0
    except CleanupError as error:
        print(f"build cleanup error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
