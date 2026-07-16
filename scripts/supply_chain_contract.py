#!/usr/bin/env python3
"""Validate immutable CI actions, release ordering, governance, and tool versions."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
from typing import Any


ACTION = re.compile(
    r"^\s*uses:\s*([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(?:/[A-Za-z0-9_./-]+)?@([^\s#]+)",
    re.MULTILINE,
)


def _workflow_job(text: str, name: str) -> str:
    match = re.search(rf"(?m)^  {re.escape(name)}:\s*$", text)
    if not match:
        return ""
    next_job = re.search(r"(?m)^  [A-Za-z0-9_-]+:\s*$", text[match.end():])
    end = match.end() + next_job.start() if next_job else len(text)
    return text[match.start():end]


def _job_permissions(job: str) -> list[str]:
    match = re.search(r"(?ms)^    permissions:\s*$\n(.*?)(?=^    [A-Za-z0-9_-]+:|\Z)", job)
    if not match:
        return []
    return [line.strip() for line in match.group(1).splitlines() if line.strip()]


def _tool_output(command: list[str]) -> str:
    try:
        return subprocess.check_output(command, stderr=subprocess.STDOUT, text=True)
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError(f"could not execute {' '.join(command)}: {error}") from error


def validate(root: Path, installed: str | None = None) -> list[str]:
    errors: list[str] = []
    manifest_path = root / "config/toolchain.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return [f"config/toolchain.json: {error}"]
    if manifest.get("schemaVersion") != 1:
        errors.append("config/toolchain.json: unsupported schemaVersion")

    configured_actions = manifest.get("actions", {})
    workflows = sorted((root / ".github/workflows").glob("*.yml"))
    used_actions: set[str] = set()
    for workflow in workflows:
        text = workflow.read_text(encoding="utf-8")
        for repository, reference in ACTION.findall(text):
            used_actions.add(repository)
            if not re.fullmatch(r"[0-9a-f]{40}", reference):
                errors.append(f"{workflow.relative_to(root)}: action is not pinned to a full SHA: {repository}@{reference}")
                continue
            configured = configured_actions.get(repository)
            if not configured:
                errors.append(f"{workflow.relative_to(root)}: action is absent from config/toolchain.json: {repository}")
            elif configured.get("sha") != reference:
                errors.append(f"{workflow.relative_to(root)}: {repository} SHA differs from config/toolchain.json")
    for repository in sorted(set(configured_actions) - used_actions):
        errors.append(f"config/toolchain.json: configured action is unused: {repository}")

    release_path = root / ".github/workflows/release.yml"
    release = release_path.read_text(encoding="utf-8") if release_path.is_file() else ""
    if re.search(r"\brelease\s*:\s*\n\s*types\s*:\s*\[?published", release):
        errors.append("release workflow must not trigger after a Release is published")
    if not re.search(r"push:\s*\n\s*tags:\s*\[?['\"]?v\*", release):
        errors.append("release workflow must accept protected v* tag pushes")
    ordered = [
        "Verify release tag and source identity",
        "Generate and validate release evidence",
        "Attest verified DMG provenance",
        "Create or reuse draft GitHub Release",
        "Reset draft Release assets",
        "Upload verified assets to draft Release",
        "Verify downloaded Release assets",
        "Publish verified GitHub Release",
    ]
    positions = [release.find(value) for value in ordered]
    if any(value < 0 for value in positions) or positions != sorted(positions):
        errors.append("release workflow does not preserve verify -> draft -> upload -> remote verify -> publish ordering")
    for required in (
        "gh release delete-asset",
        'gh release view "$RELEASE_TAG" --json assets',
        "unexpected or missing draft Release assets",
    ):
        if required not in release:
            errors.append(f"release workflow does not enforce an exact draft asset set: {required}")

    ios_release_order = re.compile(
        r"Run process-bound iOS release readiness.*Archive VocelloiOS.*"
        r"Export App Store IPA.*Verify exported IPA identity and signing contract.*"
        r"Generate and validate iOS release evidence",
        re.DOTALL,
    )
    if not ios_release_order.search(release):
        errors.append(
            "iOS release workflow must preserve readiness -> archive -> export -> artifact verification -> evidence ordering"
        )
    for required in (
        "--step platform-readiness",
        "scripts/macos_test.sh gate",
        "./scripts/build_foundation_targets.sh ios",
    ):
        if required not in release:
            errors.append(f"iOS release workflow is missing process-bound readiness binding: {required}")
    for required in (
        "--step ipa-verification",
        "scripts/verify_ios_release_artifacts.py",
        "ios-release-artifact-verification.json",
    ):
        if required not in release:
            errors.append(f"iOS release workflow is missing artifact-verification binding: {required}")

    required = [
        "SECURITY.md", ".github/CODEOWNERS", ".github/dependabot.yml",
        ".github/workflows/security.yml", ".github/ISSUE_TEMPLATE/config.yml",
        ".github/ISSUE_TEMPLATE/bug_report.yml", ".github/ISSUE_TEMPLATE/feature_request.yml",
        "scripts/release_evidence.py", "scripts/release_sbom.py",
        "scripts/swift_dependency_snapshot.py",
        "scripts/verify_ios_release_artifacts.py",
    ]
    for relative in required:
        if not (root / relative).is_file():
            errors.append(f"required supply-chain surface is missing: {relative}")
    dependabot_path = root / ".github/dependabot.yml"
    dependabot = dependabot_path.read_text(encoding="utf-8") if dependabot_path.is_file() else ""
    for ecosystem in ("github-actions", "npm", "swift"):
        if f'package-ecosystem: "{ecosystem}"' not in dependabot:
            errors.append(f"Dependabot does not cover {ecosystem}")

    security_path = root / ".github/workflows/security.yml"
    security = security_path.read_text(encoding="utf-8") if security_path.is_file() else ""
    if not re.search(r"(?m)^  push:\s*$\n^    branches:\s*\[main\]\s*$", security):
        errors.append("security workflow push trigger must remain limited to main")
    submission = _workflow_job(security, "swift-dependency-submission")
    expected_submission_condition = (
        "if: github.event_name == 'push' || github.event_name == 'schedule' || "
        "github.event_name == 'workflow_dispatch'"
    )
    if not submission:
        errors.append("security workflow is missing Swift dependency submission")
    else:
        if expected_submission_condition not in submission:
            errors.append("Swift dependency submission must run only on main push, schedule, or manual dispatch")
        if _job_permissions(submission) != ["contents: write"]:
            errors.append("Swift dependency submission must have only contents:write permission")
        for required_command in (
            "python3 scripts/swift_dependency_snapshot.py",
            "dependency-graph/snapshots",
            "--input \"$RUNNER_TEMP/swift-dependency-snapshot.json\"",
        ):
            if required_command not in submission:
                errors.append(f"Swift dependency submission is missing: {required_command}")

    npm_audit = _workflow_job(security, "npm-advisory-audit")
    expected_audit_condition = "if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'"
    if not npm_audit:
        errors.append("security workflow is missing the scheduled npm advisory audit")
    else:
        if expected_audit_condition not in npm_audit:
            errors.append("npm advisory audit must run only on schedule or manual dispatch")
        if "npm --prefix website audit --package-lock-only --audit-level=high" not in npm_audit:
            errors.append("npm advisory audit must inspect the committed website lock at high severity")

    snapshot_path = root / "scripts/swift_dependency_snapshot.py"
    snapshot_source = snapshot_path.read_text(encoding="utf-8") if snapshot_path.is_file() else ""
    for lock_path in (
        "QwenVoice.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
        "Packages/VocelloQwen3Core/Package.resolved",
    ):
        if lock_path not in snapshot_source:
            errors.append(f"Swift dependency snapshot does not cover tracked lock: {lock_path}")
    package_path = root / "website/package.json"
    if package_path.is_file():
        package = json.loads(package_path.read_text(encoding="utf-8"))
        scripts = package.get("scripts", {})
        for command in ("lint", "test", "build", "check"):
            if not scripts.get(command):
                errors.append(f"website/package.json is missing the deterministic {command} script")

    if installed:
        groups = ("native", "release", "website") if installed == "all" else (installed,)
        for group in groups:
            for name, spec in manifest.get(group, {}).items():
                command = spec.get("versionCommand")
                expected = spec.get("version")
                if not isinstance(command, list) or not expected:
                    errors.append(f"config/toolchain.json: invalid {group}.{name} entry")
                    continue
                try:
                    output = _tool_output(command)
                except ValueError as error:
                    errors.append(str(error))
                    continue
                if not re.search(rf"(?<![0-9]){re.escape(str(expected))}(?![0-9])", output):
                    first = output.splitlines()[0] if output.splitlines() else "<empty>"
                    errors.append(f"{name}: expected {expected}, observed {first}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--installed", choices=("native", "release", "website", "all"))
    args = parser.parse_args()
    errors = validate(args.root.resolve(), args.installed)
    if errors:
        for error in errors:
            print(f"error: {error}")
        return 1
    print("Supply-chain contract: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
