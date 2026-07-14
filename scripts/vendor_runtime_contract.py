#!/usr/bin/env python3
"""Validate Vocello's owned Qwen3 runtime provenance and semantic delta coverage."""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import sys
from pathlib import Path


VENDOR_RELATIVE = Path("third_party_patches/mlx-audio-swift")
MANIFEST_NAME = "VENDOR_MANIFEST.json"
BASELINE_NAME = "UPSTREAM_BASELINE.json"
PATCHES_NAME = "PATCHES.json"
BASELINE_SCOPE = (".gitignore", "Package.swift", "Sources/**", "Tests/**", "Examples/**")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def matches(path: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns)


def expanded(root: Path, patterns: list[str]) -> list[Path]:
    found: set[Path] = set()
    for pattern in patterns:
        if any(character in pattern for character in "*?["):
            found.update(path for path in root.glob(pattern) if path.is_file())
        else:
            path = root / pattern
            if path.is_file():
                found.add(path)
    return sorted(found)


def benchmark_ids(repo_root: Path) -> set[str]:
    return {
        path.stem
        for path in (repo_root / "benchmarks/runs").glob("*/*.json")
        if path.is_file()
    }


def validate(repo_root: Path) -> list[str]:
    vendor = repo_root / VENDOR_RELATIVE
    errors: list[str] = []
    required = [vendor / MANIFEST_NAME, vendor / BASELINE_NAME, vendor / PATCHES_NAME]
    for path in required:
        if not path.is_file():
            errors.append(f"missing vendor contract: {path.relative_to(repo_root)}")
    if errors:
        return errors

    manifest = load_json(vendor / MANIFEST_NAME)
    baseline = load_json(vendor / BASELINE_NAME)
    ledger = load_json(vendor / PATCHES_NAME)

    if manifest.get("schemaVersion") != 1 or baseline.get("schemaVersion") != 1 or ledger.get("schemaVersion") != 1:
        errors.append("vendor contracts must use schemaVersion 1")

    import_commit = manifest.get("importBaseline", {}).get("commit")
    import_tag = manifest.get("importBaseline", {}).get("tag")
    if baseline.get("upstreamCommit") != import_commit:
        errors.append("UPSTREAM_BASELINE upstreamCommit differs from VENDOR_MANIFEST import commit")

    backend = (repo_root / "Sources/QwenVoiceBackendCore/QwenVoiceBackendCore.swift").read_text(encoding="utf-8")
    if import_commit not in backend or import_tag not in backend:
        errors.append("BackendCore provenance does not match VENDOR_MANIFEST import baseline")

    package = (vendor / "Package.swift").read_text(encoding="utf-8")
    tools = re.search(r"swift-tools-version:\s*([0-9.]+)", package)
    if not tools or tools.group(1) != manifest.get("swiftToolsVersion"):
        errors.append("Package.swift tools version differs from VENDOR_MANIFEST")
    for dependency, version in manifest.get("directDependencies", {}).items():
        if dependency not in package or f'"{version}"' not in package:
            errors.append(f"Package.swift dependency pin missing or stale: {dependency} {version}")
    for product in manifest.get("products", []):
        if f'.library(name: "{product}"' not in package:
            errors.append(f"Package.swift product missing: {product}")

    patches = ledger.get("patches", [])
    ids = [item.get("id") for item in patches]
    if len(ids) != len(set(ids)) or any(not value for value in ids):
        errors.append("PATCHES entries require unique non-empty ids")
    allowed_states = set(ledger.get("allowedStates", []))
    allowed_dispositions = set(ledger.get("allowedUpstreamDispositions", []))
    known_benchmarks = benchmark_ids(repo_root)
    covered_patterns: list[str] = []
    for item in patches:
        patch_id = item.get("id", "<missing>")
        files = item.get("files", [])
        covered_patterns.extend(files)
        if item.get("state") not in allowed_states:
            errors.append(f"{patch_id}: invalid state {item.get('state')!r}")
        if item.get("upstreamDisposition") not in allowed_dispositions:
            errors.append(f"{patch_id}: invalid upstream disposition")
        if not item.get("removalCriteria"):
            errors.append(f"{patch_id}: missing removalCriteria")
        if not expanded(vendor, files):
            errors.append(f"{patch_id}: source patterns match no files")
        if not expanded(vendor, item.get("tests", [])):
            errors.append(f"{patch_id}: test patterns match no files")
        if not expanded(vendor, item.get("documentation", [])):
            errors.append(f"{patch_id}: documentation patterns match no files")
        records = item.get("benchmarkRecordIDs", [])
        missing_records = sorted(set(records) - known_benchmarks)
        if missing_records:
            errors.append(f"{patch_id}: missing benchmark records {missing_records}")
        if item.get("evidenceClass") == "benchmark" and not records:
            errors.append(f"{patch_id}: benchmark evidence class requires a record")

    baseline_entries = baseline.get("entries", [])
    baseline_paths = [entry.get("path") for entry in baseline_entries]
    if len(baseline_paths) != len(set(baseline_paths)) or any(not value for value in baseline_paths):
        errors.append("UPSTREAM_BASELINE requires unique non-empty paths")
    for entry in baseline_entries:
        relative = entry["path"]
        current = vendor / relative
        if not current.is_file():
            errors.append(f"baseline retained file is missing: {relative}")
            continue
        upstream_digest = entry.get("upstreamSHA256")
        changed = upstream_digest is None or sha256(current) != upstream_digest
        if changed and not matches(relative, covered_patterns):
            errors.append(f"changed vendor file lacks PATCHES coverage: {relative}")

    tracked_scope = sorted(
        path.relative_to(vendor).as_posix()
        for path in vendor.rglob("*")
        if path.is_file()
        and matches(path.relative_to(vendor).as_posix(), list(BASELINE_SCOPE))
        and path.name not in {"Package.resolved", ".DS_Store"}
    )
    missing_baseline = sorted(set(tracked_scope) - set(baseline_paths))
    if missing_baseline:
        errors.append(f"UPSTREAM_BASELINE missing retained paths: {missing_baseline}")

    risk = load_json(repo_root / "config/backend-risk-spine.json")
    patch_ids = set(ids)
    for item in risk.get("items", []):
        if str(item.get("source", "")).startswith(VENDOR_RELATIVE.as_posix()):
            link = item.get("vendorPatchID")
            if link not in patch_ids:
                errors.append(f"backend-risk-spine {item.get('id')}: invalid or missing vendorPatchID")

    return sorted(set(errors))


def make_baseline(upstream: Path, vendor: Path, commit: str) -> dict:
    entries = []
    for path in sorted(vendor.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(vendor).as_posix()
        if not matches(relative, list(BASELINE_SCOPE)) or path.name in {"Package.resolved", ".DS_Store"}:
            continue
        upstream_path = upstream / relative
        entries.append(
            {
                "path": relative,
                "upstreamSHA256": sha256(upstream_path) if upstream_path.is_file() else None,
            }
        )
    return {
        "schemaVersion": 1,
        "upstreamCommit": commit,
        "scope": list(BASELINE_SCOPE),
        "entries": entries,
    }


def write_atomic(path: Path, payload: dict) -> None:
    temporary = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1], help=argparse.SUPPRESS)
    subparsers = parser.add_subparsers(dest="command")
    subparsers.add_parser("validate")
    rebuild = subparsers.add_parser("rebuild-baseline")
    rebuild.add_argument("--upstream-dir", type=Path, required=True)
    arguments = parser.parse_args(argv)
    root = arguments.repo_root.resolve()

    if arguments.command in (None, "validate"):
        errors = validate(root)
        if errors:
            print("\n".join(f"error: {error}" for error in errors), file=sys.stderr)
            return 1
        print("Vendor runtime contract: PASS")
        return 0

    vendor = root / VENDOR_RELATIVE
    manifest = load_json(vendor / MANIFEST_NAME)
    commit = manifest["importBaseline"]["commit"]
    upstream = arguments.upstream_dir.resolve()
    if not (upstream / "Package.swift").is_file():
        print("error: --upstream-dir is not an mlx-audio-swift checkout", file=sys.stderr)
        return 1
    write_atomic(vendor / BASELINE_NAME, make_baseline(upstream, vendor, commit))
    print(f"Rebuilt {VENDOR_RELATIVE / BASELINE_NAME}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
