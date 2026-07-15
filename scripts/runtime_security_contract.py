#!/usr/bin/env python3
"""Validate runtime debug, unchecked concurrency, and release-evidence contracts."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ENV_PATTERN = re.compile(r'["\']((?:QWENVOICE|QVOICE)_[A-Z0-9_]+)["\']')
ENV_KEY_PATTERN = re.compile(r'(?:QWENVOICE|QVOICE)_[A-Z0-9_]+')
UNCHECKED_PATTERN = re.compile(
    r"\b(?:final\s+|private\s+|public\s+|internal\s+)*"
    r"(?:class|struct|actor)\s+([A-Za-z_][A-Za-z0-9_]*)[^\n{]*@unchecked\s+Sendable"
)
UNSAFE_DECLARATION_PATTERN = re.compile(
    r"nonisolated\(unsafe\)[^\n]*(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)"
)


def load_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot read {path.relative_to(ROOT)}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"{path.relative_to(ROOT)} must contain an object")
    return value


def swift_files(roots: list[str]) -> list[Path]:
    result: list[Path] = []
    for relative in roots:
        path = ROOT / relative
        if not path.is_dir():
            raise ValueError(f"source root does not exist: {relative}")
        result.extend(path.rglob("*.swift"))
    return sorted(set(result))


def debug_gate_enforcement_errors(
    *, relative_path: str, source: str, gated_keys: set[str], master_gate: str
) -> list[str]:
    """Reject a production-affecting key read outside the single gate API.

    Keys may be stored in a local constant before being passed to the gate, so
    enforcement is intentionally file-scoped. This is stricter than inventory
    alone while remaining stable under ordinary Swift refactors.
    """
    observed = set(ENV_PATTERN.findall(source)) & gated_keys
    observed.discard(master_gate)
    if not observed or relative_path.endswith("/RuntimeDebugGate.swift"):
        return []
    errors: list[str] = []
    for key in sorted(observed):
        direct_read = re.compile(
            rf"(?:ProcessInfo\.processInfo\.environment|environment|env)\s*"
            rf"\[\s*[\"']{re.escape(key)}[\"']\s*\]"
        )
        if direct_read.search(source):
            errors.append(
                f"production-affecting runtime key bypasses RuntimeDebugGate.value: "
                f"{relative_path}:{key}"
            )
    if errors:
        return errors
    if (
        "RuntimeDebugGate.value(" in source
        or "VocelloQwen3ImplementationDebugGate.value(" in source
    ):
        return []
    return [
        f"production-affecting runtime key has no explicit RuntimeDebugGate.value path: "
        f"{relative_path}:{key}"
        for key in sorted(observed)
    ]


def validate_debug_contract() -> list[str]:
    errors: list[str] = []
    contract = load_json(ROOT / "config/runtime-debug-knobs.json")
    if contract.get("schemaVersion") != 1:
        errors.append("runtime-debug-knobs schemaVersion must be 1")
    if contract.get("masterGate") != "QWENVOICE_DEBUG":
        errors.append("runtime-debug-knobs masterGate must be QWENVOICE_DEBUG")

    groups = contract.get("groups")
    if not isinstance(groups, list) or not groups:
        return errors + ["runtime-debug-knobs groups must be a non-empty array"]
    registered: set[str] = set()
    gated: set[str] = set()
    for index, group in enumerate(groups):
        if not isinstance(group, dict):
            errors.append(f"runtime-debug-knobs groups[{index}] must be an object")
            continue
        keys = group.get("keys")
        if not isinstance(keys, list) or not keys:
            errors.append(f"runtime-debug-knobs groups[{index}].keys must be non-empty")
            continue
        if not isinstance(group.get("purpose"), str) or not group["purpose"].strip():
            errors.append(f"runtime-debug-knobs groups[{index}] requires purpose")
        if group.get("gateRequired") is True and group.get("releaseBehavior") != "ignored-unless-master-gate-enabled":
            errors.append(f"runtime-debug-knobs groups[{index}] has invalid gated releaseBehavior")
        for key in keys:
            if not isinstance(key, str) or ENV_KEY_PATTERN.fullmatch(key) is None:
                errors.append(f"invalid runtime environment key: {key!r}")
            elif key in registered:
                errors.append(f"duplicate runtime environment key: {key}")
            else:
                registered.add(key)
                if group.get("gateRequired") is True:
                    gated.add(key)

    observed: set[str] = set()
    for path in swift_files(contract.get("sourceRoots", [])):
        source = path.read_text(encoding="utf-8")
        observed.update(ENV_PATTERN.findall(source))
        errors.extend(
            debug_gate_enforcement_errors(
                relative_path=path.relative_to(ROOT).as_posix(),
                source=source,
                gated_keys=gated,
                master_gate=contract["masterGate"],
            )
        )
    for missing in sorted(observed - registered):
        errors.append(f"unregistered runtime environment key: {missing}")
    for stale in sorted(registered - observed):
        errors.append(f"registered runtime environment key is not present in production Swift: {stale}")
    persisted_toggle = "QwenVoice.DebugModeEnabled"
    for path in swift_files(contract.get("sourceRoots", [])):
        if persisted_toggle in path.read_text(encoding="utf-8"):
            errors.append(
                f"persisted debug toggle bypasses the explicit process gate: "
                f"{path.relative_to(ROOT)}"
            )
    return errors


def validate_concurrency_contract() -> list[str]:
    errors: list[str] = []
    contract = load_json(ROOT / "config/concurrency-safety.json")
    if contract.get("schemaVersion") != 1:
        errors.append("concurrency-safety schemaVersion must be 1")
    entries = contract.get("entries")
    if not isinstance(entries, list) or not entries:
        return errors + ["concurrency-safety entries must be a non-empty array"]

    observed: set[tuple[str, str]] = set()
    observed_unsafe: set[tuple[str, str]] = set()
    for path in swift_files(contract.get("sourceRoots", [])):
        relative = path.relative_to(ROOT).as_posix()
        text = path.read_text(encoding="utf-8")
        for match in UNCHECKED_PATTERN.finditer(text):
            observed.add((relative, match.group(1)))
        for match in UNSAFE_DECLARATION_PATTERN.finditer(text):
            observed_unsafe.add((relative, match.group(1)))

    registered_unsafe: set[tuple[str, str]] = set()
    unsafe_entries = contract.get("unsafeDeclarations")
    if not isinstance(unsafe_entries, list):
        errors.append("concurrency-safety unsafeDeclarations must be an array")
        unsafe_entries = []
    for index, entry in enumerate(unsafe_entries):
        if not isinstance(entry, dict):
            errors.append(f"concurrency-safety unsafeDeclarations[{index}] must be an object")
            continue
        source = entry.get("source")
        names = entry.get("names")
        if not isinstance(source, str) or not (ROOT / source).is_file():
            errors.append(f"concurrency-safety unsafeDeclarations[{index}] has missing source")
            continue
        if not isinstance(names, list) or not names:
            errors.append(f"concurrency-safety unsafeDeclarations[{index}] requires names")
            continue
        for field in ("owner", "invariant"):
            if not isinstance(entry.get(field), str) or not entry[field].strip():
                errors.append(f"concurrency-safety unsafeDeclarations[{index}] requires {field}")
        for name in names:
            identity = (source, name)
            if identity not in observed_unsafe:
                errors.append(f"unsafe declaration entry does not resolve: {source}:{name}")
            registered_unsafe.add(identity)

    registered: set[tuple[str, str]] = set()
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            errors.append(f"concurrency-safety entries[{index}] must be an object")
            continue
        sources = entry.get("sources") or [entry.get("source")]
        types = entry.get("types") or ([entry.get("type")] if entry.get("type") else [])
        if not all(isinstance(item, str) and (ROOT / item).is_file() for item in sources):
            errors.append(f"concurrency-safety entries[{index}] has missing source")
            continue
        if not types or not all(isinstance(item, str) and item for item in types):
            errors.append(f"concurrency-safety entries[{index}] requires types")
            continue
        if not isinstance(entry.get("owner"), str) or not entry["owner"].strip():
            errors.append(f"concurrency-safety entries[{index}] requires owner")
        if not isinstance(entry.get("invariant"), str) or not entry["invariant"].strip():
            errors.append(f"concurrency-safety entries[{index}] requires invariant")
        tests = entry.get("tests")
        if not isinstance(tests, list) or not tests:
            errors.append(f"concurrency-safety entries[{index}] requires tests")
        else:
            for test in tests:
                if not isinstance(test, str) or not (ROOT / test).is_file():
                    errors.append(f"concurrency-safety test does not resolve: {test!r}")
        for type_name in types:
            matches = [(source, type_name) for source in sources if (source, type_name) in observed]
            if len(matches) != 1:
                errors.append(
                    f"unchecked Sendable entry must resolve once: {entry.get('id')}:{type_name}"
                )
                continue
            registered.add(matches[0])
    for source, type_name in sorted(observed - registered):
        errors.append(f"unregistered unchecked Sendable declaration: {source}:{type_name}")
    for source, type_name in sorted(registered - observed):
        errors.append(f"stale unchecked Sendable registration: {source}:{type_name}")
    for source, name in sorted(observed_unsafe - registered_unsafe):
        errors.append(f"unregistered nonisolated unsafe declaration: {source}:{name}")
    for source, name in sorted(registered_unsafe - observed_unsafe):
        errors.append(f"stale nonisolated unsafe registration: {source}:{name}")
    return errors


def validate_release_contract() -> list[str]:
    errors: list[str] = []
    contract = load_json(ROOT / "config/release-evidence-contract.json")
    if contract.get("schemaVersion") != 1:
        errors.append("release-evidence-contract schemaVersion must be 1")
    if contract.get("publicationPolicy") != "draft-build-verify-attest-publish":
        errors.append("release evidence must use draft-build-verify-attest-publish")
    for key in ("sourceIdentity", "artifacts"):
        value = contract.get(key)
        if not isinstance(value, list) or not value or len(value) != len(set(value)):
            errors.append(f"release-evidence-contract {key} must be a unique non-empty array")
    if "requiredDeterministicChecks" in contract:
        errors.append(
            "release-evidence-contract cannot claim checks that are not bound to managed step manifests"
        )
    identity = contract.get("sourceIdentity") or []
    inputs = contract.get("sourceIdentityInputs")
    expected_digests = set(identity) - {"gitCommit", "treeDirty"}
    if not isinstance(inputs, dict) or set(inputs) != expected_digests:
        errors.append("release-evidence-contract must map every source digest to exact input paths")
    elif any(
        not isinstance(paths, list) or not paths or len(paths) != len(set(paths))
        for paths in inputs.values()
    ):
        errors.append("release-evidence-contract source input groups must be unique non-empty arrays")
    if not isinstance(contract.get("verificationFreshnessSeconds"), int):
        errors.append("release-evidence-contract must bound verification freshness")
    platforms = contract.get("platformVerification")
    if not isinstance(platforms, dict) or set(platforms) != {"macos", "ios"}:
        errors.append("release-evidence-contract must define macOS and iOS managed verification")
    else:
        workflows = load_json(ROOT / "config/orchestration-contract.json").get("workflows", {})
        for platform, definition in platforms.items():
            managed = workflows.get(definition.get("workflow"))
            if (
                not isinstance(managed, dict)
                or managed.get("sourceIdentityRequired") is not True
                or managed.get("requiredSteps") != definition.get("requiredSteps")
            ):
                errors.append(
                    f"release-evidence-contract {platform} steps differ from managed orchestration"
                )
    workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
    if "release.published" in workflow:
        errors.append("release workflow must not trigger after public release publication")
    if "--draft" not in workflow or "--latest" not in workflow:
        errors.append("release workflow must create a draft and publish it only after verification")
    if "release_evidence.py" not in workflow:
        errors.append("release workflow does not invoke release_evidence.py")
    for required in (
        "capture-source-identity", "required_step_ledger.py run", "required_step_ledger.py finalize",
        "--source-identity", "--step-ledger", "release-verification.json",
    ):
        if required not in workflow:
            errors.append(f"release workflow does not bind managed verification evidence: {required}")
    evidence_source = (ROOT / "scripts/release_evidence.py").read_text(encoding="utf-8")
    if "import release_sbom" not in evidence_source:
        errors.append("release evidence does not generate the release SBOM")
    if '"managed-subprocess"' not in evidence_source or "validate_step_ledger" not in evidence_source:
        errors.append("release evidence can self-assert verification without managed step manifests")
    return errors


def validate_docs() -> list[str]:
    errors: list[str] = []
    threat = ROOT / "docs/decisions/runtime-hardening-and-trust-boundary.md"
    naming = ROOT / "docs/decisions/product-identity-compatibility.md"
    if not threat.is_file():
        errors.append("missing runtime hardening threat-model ADR")
    else:
        text = threat.read_text(encoding="utf-8")
        for required in ("app-sandbox", "disable-library-validation", "allow-unsigned-executable-memory"):
            if required not in text:
                errors.append(f"runtime hardening ADR missing entitlement: {required}")
    if not naming.is_file():
        errors.append("missing product identity compatibility ADR")
    return errors


def main() -> int:
    errors: list[str] = []
    try:
        errors.extend(validate_debug_contract())
        errors.extend(validate_concurrency_contract())
        errors.extend(validate_release_contract())
        errors.extend(validate_docs())
    except ValueError as exc:
        errors.append(str(exc))
    if errors:
        for error in errors:
            print(f"error: {error}")
        return 1
    print("runtime security contract: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
