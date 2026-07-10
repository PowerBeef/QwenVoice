#!/usr/bin/env python3
"""Deterministic lifecycle, evidence, and probe verifier for Codex macOS UI QA.

Computer Use owns every UI action. This module owns everything that must be
repeatable: exact-bundle launch, isolated debug storage, fingerprints, report
updates, history/WAV verification, and cross-layer telemetry assertions.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
import wave


ROOT = Path(__file__).resolve().parents[2]
BUILD_ROOT = ROOT / "build" / "macos" / "agent-ui"
APP = ROOT / "build" / "Vocello.app"
APP_BINARY = APP / "Contents" / "MacOS" / "Vocello"
DEBUG_ROOT = Path.home() / "Library" / "Application Support" / "QwenVoice-Debug"
PRODUCTION_ROOT = Path.home() / "Library" / "Application Support" / "QwenVoice"
SCENARIOS = ROOT / "config" / "macos-ui-scenarios.json"
IMPACT = ROOT / "config" / "macos-test-impact.json"
RISK = ROOT / "config" / "backend-risk-spine.json"
ATTESTATION = ROOT / "qa" / "macos-ui-attestation.json"
CURRENT = BUILD_ROOT / "current-run.json"
BENCH_TAKE_FILE = Path("/tmp/vocello-bench-current-take.json")
BUNDLE_ID = "com.qwenvoice.app"
DEBUG_KEY = "QwenVoice.DebugModeEnabled"
APP_PROCESS = "Vocello"
SERVICE_PROCESS = "QwenVoiceEngineService"
SEVERITIES = ("blocker", "major", "minor", "note")
SUITES = ("quick", "full", "benchmark", "destructive")
ATTESTABLE_SUITES = ("quick", "full", "benchmark")
SUITE_SATISFIERS = {
    "quick": {"quick", "full"},
    "full": {"full"},
    "benchmark": {"benchmark"},
}


class HarnessError(RuntimeError):
    pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def local_timestamp() -> str:
    value = dt.datetime.now().astimezone()
    return value.strftime("%Y-%m-%d %H:%M:%S.") + value.strftime("%f")[:3]


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise HarnessError(f"missing JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise HarnessError(f"invalid JSON in {path}: {exc}") from exc


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def append_jsonl(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(value, sort_keys=True) + "\n")


def run(command: list[str], *, check: bool = True, capture: bool = True, env: dict | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        command,
        cwd=ROOT,
        check=check,
        text=True,
        capture_output=capture,
        env=env,
    )


def process_ids(name: str) -> list[int]:
    result = run(["/usr/bin/pgrep", "-x", name], check=False)
    return [int(line) for line in result.stdout.splitlines() if line.strip().isdigit()]


def terminate_process(name: str) -> None:
    pids = process_ids(name)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 5
    while process_ids(name) and time.monotonic() < deadline:
        time.sleep(0.1)
    for pid in process_ids(name):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def clear_debug_flag() -> None:
    run(["/usr/bin/defaults", "delete", BUNDLE_ID, DEBUG_KEY], check=False)


def set_debug_flag() -> None:
    run(["/usr/bin/defaults", "write", BUNDLE_ID, DEBUG_KEY, "-bool", "true"])


def cleanup_processes() -> None:
    terminate_process(APP_PROCESS)
    terminate_process(SERVICE_PROCESS)
    clear_debug_flag()


def exact_launch_command(run_id: str, app_support_root: Path, *, force_cold: bool = False) -> list[str]:
    launch = [
        "/usr/bin/open", "-n", "--env", "QWENVOICE_DEBUG=1",
        "--env", "QWENVOICE_NATIVE_TELEMETRY_MODE=verbose",
        "--env", f"QWENVOICE_APP_SUPPORT_DIR={app_support_root}",
        "--env", f"QVOICE_MAC_BENCH_RUN_ID={run_id}",
        "--env", f"QVOICE_MAC_BENCH_LABEL={run_id}",
    ]
    if force_cold:
        launch.extend(["--env", "QWENVOICE_BENCH_FORCE_COLD=1"])
    launch.append(str(APP))
    return launch


def launch_exact_app(run_id: str, app_support_root: Path, *, force_cold: bool = False) -> int:
    launch = exact_launch_command(run_id, app_support_root, force_cold=force_cold)
    run(launch)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline and len(process_ids(APP_PROCESS)) != 1:
        time.sleep(0.25)
    pids = process_ids(APP_PROCESS)
    if len(pids) != 1:
        cleanup_processes()
        raise HarnessError(f"expected one {APP_PROCESS} process after exact-path launch, found {pids}")
    return pids[0]


def benchmark_scenario() -> dict:
    scenarios = read_json(SCENARIOS)
    for scenario in scenarios.get("scenarios", []):
        if scenario.get("id") == "generation-matrix":
            return scenario
    raise HarnessError("generation-matrix scenario is missing")


def benchmark_manifest() -> list[dict]:
    matrix = benchmark_scenario().get("matrix") or {}
    modes = matrix.get("modes") or []
    lengths = matrix.get("lengths") or []
    corpus = matrix.get("corpus") or {}
    warm_repetitions = max(1, int(matrix.get("warmRepetitions", 1)))
    cold_length = matrix.get("coldLength")
    cold_modes = set(matrix.get("coldModes") or [])
    takes: list[dict] = []
    for mode in modes:
        if mode in cold_modes and cold_length in lengths:
            text = corpus.get(cold_length)
            if not text:
                raise HarnessError(f"benchmark corpus is missing cold length {cold_length}")
            takes.append({
                "index": len(takes) + 1,
                "mode": mode,
                "length": cold_length,
                "warmState": "cold",
                "repetition": 0,
                "text": text,
            })
        for length in lengths:
            text = corpus.get(length)
            if not text:
                raise HarnessError(f"benchmark corpus is missing length {length}")
            for repetition in range(warm_repetitions):
                takes.append({
                    "index": len(takes) + 1,
                    "mode": mode,
                    "length": length,
                    "warmState": "warm",
                    "repetition": repetition,
                    "text": text,
                })
    return takes


def public_benchmark_take(take: dict) -> dict:
    return {key: value for key, value in take.items() if key != "text"} | {
        "textLength": len(take["text"]),
        "textDigest": hashlib.sha256(take["text"].encode()).hexdigest(),
    }


def relative_files(*, build_inputs_only: bool = False) -> list[Path]:
    if build_inputs_only:
        candidates = [
            Path("project.yml"),
            Path("Package.resolved"),
            Path("Sources/Resources/qwenvoice_contract.json"),
            Path("third_party_patches/mlx-audio-swift/Package.swift"),
        ]
        return [path for path in candidates if (ROOT / path).is_file()]

    include_roots = [
        ".agents",
        ".github",
        "Sources",
        "Tests",
        "config",
        "scripts",
        "third_party_patches/mlx-audio-swift/Sources",
        "third_party_patches/mlx-audio-swift/Tests",
    ]
    paths: set[Path] = set()
    for root_name in include_roots:
        root = ROOT / root_name
        if root.is_file():
            paths.add(Path(root_name))
        elif root.is_dir():
            paths.update(path.relative_to(ROOT) for path in root.rglob("*") if path.is_file())
    for name in ("project.yml", "Package.resolved", "AGENTS.md"):
        if (ROOT / name).is_file():
            paths.add(Path(name))
    paths.discard(ATTESTATION.relative_to(ROOT))
    return sorted(paths, key=lambda value: value.as_posix())


def fingerprint(*, build_inputs_only: bool = False) -> str:
    digest = hashlib.sha256()
    for relative in relative_files(build_inputs_only=build_inputs_only):
        absolute = ROOT / relative
        digest.update(relative.as_posix().encode())
        digest.update(b"\0")
        digest.update(absolute.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def sha256(path: Path) -> str | None:
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def toolchain_identity() -> dict:
    values = {
        "xcode": run(["/usr/bin/xcodebuild", "-version"]).stdout.strip(),
        "swift": run(["/usr/bin/xcrun", "swift", "--version"]).stdout.strip(),
    }
    values["digest"] = hashlib.sha256(
        json.dumps(values, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    return values


def executable_identity() -> dict:
    return {
        "path": str(APP),
        "binaryPath": str(APP_BINARY),
        "sha256": sha256(APP_BINARY),
    }


def report_support_root(report: dict) -> Path:
    return Path((report.get("environment") or {}).get("appSupportRoot", DEBUG_ROOT))


def report_db(report: dict) -> Path:
    return report_support_root(report) / "history.sqlite"


def report_diagnostics(report: dict) -> Path:
    return report_support_root(report) / "diagnostics"


def current_run_dir(explicit: str | None = None) -> Path:
    if explicit:
        candidate = Path(explicit)
        if not candidate.is_absolute():
            candidate = BUILD_ROOT / explicit
        if candidate.name == "run.json":
            candidate = candidate.parent
        return candidate
    value = read_json(CURRENT)
    return Path(value["runDirectory"])


def load_run(explicit: str | None = None) -> tuple[Path, dict]:
    directory = current_run_dir(explicit)
    return directory, read_json(directory / "run.json")


def store_run(directory: Path, report: dict) -> None:
    report["updatedAt"] = utc_now()
    write_json(directory / "run.json", report)


def test_reference_exists(reference: str) -> bool:
    parts = reference.split("/")
    if len(parts) != 3:
        return False
    target, suite, test = parts
    roots = {
        "VocelloCoreTests": ROOT / "Tests" / "VocelloCoreTests",
        "VocelloEngineIntegrationTests": ROOT / "Tests" / "VocelloEngineIntegrationTests",
        "Qwen3RuntimeTests": ROOT / "third_party_patches" / "mlx-audio-swift" / "Tests" / "Qwen3RuntimeTests",
        "HarnessTests": ROOT / "scripts",
    }
    root = roots.get(target)
    if root is None or not root.is_dir():
        return False
    suffix = "*.py" if target == "HarnessTests" else "*.swift"
    for path in root.rglob(suffix):
        text = path.read_text(errors="ignore")
        if suite in text and re.search(rf"\b(?:func\s+)?{re.escape(test)}\b", text):
            return True
    return False


def validate_config() -> list[str]:
    errors: list[str] = []
    scenarios = read_json(SCENARIOS)
    if scenarios.get("schemaVersion") != 2:
        errors.append("macos-ui-scenarios schemaVersion must be 2")
    scenario_ids = {item.get("id") for item in scenarios.get("scenarios", [])}
    if None in scenario_ids or len(scenario_ids) != len(scenarios.get("scenarios", [])):
        errors.append("scenario IDs must be present and unique")
    for name, suite in scenarios.get("suites", {}).items():
        missing = set(suite.get("includes", [])) - scenario_ids
        if missing:
            errors.append(f"suite {name} references missing scenarios: {sorted(missing)}")
        if name == "destructive" and not suite.get("requiresDisposableAppSupport"):
            errors.append("destructive suite must require disposable app support")
    impact = read_json(IMPACT)
    if impact.get("schemaVersion") != 2:
        errors.append("macos-test-impact schemaVersion must be 2")
    risk = read_json(RISK)
    if risk.get("schemaVersion") != 2:
        errors.append("backend-risk-spine schemaVersion must be 2")
    for item in risk.get("items", []):
        source = item.get("source")
        if not source or not (ROOT / source).exists():
            errors.append(f"risk item {item.get('id')} source missing: {source}")
        missing_tests = [reference for reference in item.get("tests", []) if not test_reference_exists(reference)]
        if missing_tests:
            errors.append(f"risk item {item.get('id')} has unresolved tests: {missing_tests}")
        if item.get("status") == "implemented" and item.get("remaining"):
            errors.append(f"risk item {item.get('id')} is implemented but remaining is non-empty")

    source_text = "\n".join(
        path.read_text(errors="ignore")
        for path in (ROOT / "Sources").rglob("*.swift")
    )
    dynamic_prefixes = {
        prefix for prefix in re.findall(r'"([A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]*)', source_text)
        if prefix.endswith("_")
    }
    for scenario in scenarios.get("scenarios", []):
        if "restorationPolicy" not in scenario:
            errors.append(f"scenario {scenario.get('id')} is missing restorationPolicy")
        if "timeoutSeconds" not in scenario:
            errors.append(f"scenario {scenario.get('id')} is missing timeoutSeconds")
        if "requiresActionTimeConfirmation" not in scenario:
            errors.append(f"scenario {scenario.get('id')} is missing requiresActionTimeConfirmation")
        for step in scenario.get("steps", []):
            target = step.get("target") or step.get("targetPrefix")
            for required in ("semanticResult", "deterministicPostcondition", "restorationPolicy", "timeoutSeconds", "confirmation"):
                if required not in step:
                    errors.append(f"scenario {scenario.get('id')} step {step.get('id')} is missing {required}")
            if not step.get("id"):
                errors.append(f"scenario {scenario.get('id')} contains a step without an id")
            target_is_dynamic = bool(target and any(target.startswith(prefix) for prefix in dynamic_prefixes))
            if target and target not in {"system-file-panel", "harness:xpc-kill", "harness:verify-probes"} and target not in source_text and not target_is_dynamic:
                errors.append(f"scenario {scenario['id']} target not found in source: {target}")
    return errors


def cmd_doctor(args: argparse.Namespace) -> None:
    errors = validate_config()
    checks = {
        "appBundle": APP.is_dir(),
        "appBinary": APP_BINARY.is_file(),
        "scenarioContract": SCENARIOS.is_file(),
        "impactContract": IMPACT.is_file(),
        "riskContract": RISK.is_file(),
        "python": sys.version_info >= (3, 10),
        "sqlite": shutil.which("sqlite3") is not None,
        "configErrors": errors,
        "suite": args.suite,
    }
    checks["ready"] = all(
        checks[key] for key in ("appBundle", "appBinary", "scenarioContract", "impactContract", "riskContract", "python", "sqlite")
    ) and not errors
    if args.json:
        print(json.dumps(checks, indent=2, sort_keys=True))
    else:
        for key, value in checks.items():
            print(f"{key}: {value}")
    if not checks["ready"]:
        raise HarnessError("doctor found blocking problems")


def reset_runtime_state(root: Path) -> None:
    database = root / "history.sqlite"
    diagnostics = root / "diagnostics"
    if database.is_file():
        try:
            connection = sqlite3.connect(database)
            connection.execute("DELETE FROM generations")
            connection.commit()
            connection.close()
        except sqlite3.Error as exc:
            raise HarnessError(f"could not clear debug history: {exc}") from exc
    outputs = root / "outputs"
    if outputs.is_dir():
        for path in outputs.rglob("*"):
            if path.is_file() or path.is_symlink():
                path.unlink(missing_ok=True)
    if diagnostics.is_dir():
        shutil.rmtree(diagnostics)
    for subdirectory in ("engine", "engine-service", "app"):
        (diagnostics / subdirectory).mkdir(parents=True, exist_ok=True)


def snapshot_state(directory: Path, root: Path) -> dict:
    state_dir = directory / "state-snapshot"
    state_dir.mkdir(parents=True, exist_ok=True)
    preferences = state_dir / "preferences.plist"
    exported = run(["/usr/bin/defaults", "export", BUNDLE_ID, str(preferences)], check=False)
    if exported.returncode != 0:
        preferences.unlink(missing_ok=True)
    voices = root / "voices"
    voices_snapshot = state_dir / "voices"
    if voices.is_dir():
        shutil.copytree(voices, voices_snapshot, symlinks=True)
    return {
        "preferencesExisted": preferences.is_file(),
        "preferencesPath": str(preferences),
        "voicesExisted": voices.is_dir(),
        "voicesPath": str(voices_snapshot),
        "restored": False,
    }


def restore_state(report: dict) -> None:
    if "stateSnapshot" not in report:
        return
    snapshot = report.get("stateSnapshot") or {}
    if snapshot.get("restored"):
        return
    preferences = Path(snapshot.get("preferencesPath", ""))
    if snapshot.get("preferencesExisted") and preferences.is_file():
        run(["/usr/bin/defaults", "import", BUNDLE_ID, str(preferences)], check=False)
    else:
        run(["/usr/bin/defaults", "delete", BUNDLE_ID], check=False)
    root = report_support_root(report)
    voices = root / "voices"
    voices_snapshot = Path(snapshot.get("voicesPath", ""))
    if voices.is_dir() or voices.is_symlink():
        if voices.is_symlink() or voices.is_file():
            voices.unlink(missing_ok=True)
        else:
            shutil.rmtree(voices)
    if snapshot.get("voicesExisted") and voices_snapshot.is_dir():
        shutil.copytree(voices_snapshot, voices, symlinks=True)
    snapshot["restored"] = True
    report["stateSnapshot"] = snapshot


def destructive_root(directory: Path) -> Path:
    root = (directory / "disposable-app-support").resolve()
    forbidden = {PRODUCTION_ROOT.resolve(), DEBUG_ROOT.resolve()}
    if root in forbidden or not root.is_relative_to(directory.resolve()):
        raise HarnessError(f"destructive app-support root is unsafe: {root}")
    root.mkdir(parents=True, exist_ok=False)
    for name in ("models", "voices"):
        candidate = root / name
        candidate.mkdir()
        if candidate.is_symlink() or candidate.resolve() in forbidden:
            raise HarnessError(f"destructive {name} root is not disposable: {candidate}")
    return root


def cmd_start(args: argparse.Namespace) -> None:
    if args.suite == "destructive" and not args.allow_destructive:
        raise HarnessError("destructive suite requires --allow-destructive and action-time Computer Use confirmations")
    if not APP_BINARY.is_file():
        raise HarnessError(f"app not built at {APP}; run scripts/build.sh build")
    errors = validate_config()
    if errors:
        raise HarnessError("invalid QA contracts: " + "; ".join(errors))

    cleanup_processes()
    run_id = f"mac-ui-{args.suite}-{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}"
    directory = BUILD_ROOT / run_id
    directory.mkdir(parents=True, exist_ok=False)
    (directory / "screenshots").mkdir()
    root = destructive_root(directory) if args.suite == "destructive" else DEBUG_ROOT
    state_snapshot = snapshot_state(directory, root)
    reset_runtime_state(root)
    set_debug_flag()
    started = utc_now()
    report = {
        "schemaVersion": 2,
        "runID": run_id,
        "suite": args.suite,
        "status": "running",
        "startedAt": started,
        "updatedAt": started,
        "completedAt": None,
        "sourceFingerprint": fingerprint(),
        "buildInputFingerprint": fingerprint(build_inputs_only=True),
        "appPath": str(APP),
        "appBinarySHA256": sha256(APP_BINARY),
        "executableIdentity": executable_identity(),
        "environment": {
            "os": run(["/usr/bin/sw_vers", "-productVersion"]).stdout.strip(),
            "architecture": run(["/usr/bin/uname", "-m"]).stdout.strip(),
            "appSupportRoot": str(root),
            "disposableAppSupport": args.suite == "destructive",
            "toolchain": toolchain_identity(),
        },
        "stateSnapshot": state_snapshot,
        "scenarios": {},
        "issues": [],
        "deterministicAssertions": [],
        "probeVerdict": "missing",
        "cleanupVerdict": "pending",
    }
    if args.suite == "benchmark":
        manifest = benchmark_manifest()
        report["benchmark"] = {
            "expectedTakeCount": len(manifest),
            "activeTakeIndex": None,
            "takes": [{**public_benchmark_take(take), "status": "pending"} for take in manifest],
        }
    store_run(directory, report)
    write_json(directory / "issues.json", [])
    write_json(CURRENT, {"runID": run_id, "runDirectory": str(directory)})
    append_jsonl(directory / "events.jsonl", {"timestamp": started, "event": "run-started", "suite": args.suite})

    try:
        report["appPID"] = launch_exact_app(run_id, root)
    except HarnessError:
        restore_state(report)
        report["status"] = "blocked"
        report["cleanupVerdict"] = "pass"
        store_run(directory, report)
        raise
    store_run(directory, report)
    print(json.dumps({"runID": run_id, "runDirectory": str(directory), "appPath": str(APP), "appPID": report["appPID"]}, indent=2))


def cmd_benchmark_manifest(_: argparse.Namespace) -> None:
    manifest = benchmark_manifest()
    scenario = benchmark_scenario()
    matrix = scenario.get("matrix") or {}
    print(json.dumps({
        "schemaVersion": 1,
        "takeCount": len(manifest),
        "designBrief": matrix.get("designBrief"),
        "cloneVoice": matrix.get("cloneVoice"),
        "takes": manifest,
    }, indent=2))


def cmd_benchmark_take(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    if report.get("suite") != "benchmark":
        raise HarnessError("benchmark-take requires a benchmark run")
    manifest = benchmark_manifest()
    if args.index < 1 or args.index > len(manifest):
        raise HarnessError(f"benchmark take index must be 1...{len(manifest)}")
    take = manifest[args.index - 1]
    progress = report["benchmark"]["takes"][args.index - 1]

    if args.phase == "begin":
        expected_index = next(
            (item["index"] for item in report["benchmark"]["takes"] if item["status"] != "pass"),
            None,
        )
        if expected_index != args.index:
            raise HarnessError(f"benchmark takes must run in order; next index is {expected_index}")
        if report["benchmark"].get("activeTakeIndex") is not None:
            raise HarnessError("another benchmark take is already active")
        if take["warmState"] == "cold":
            terminate_process(APP_PROCESS)
            terminate_process(SERVICE_PROCESS)
            set_debug_flag()
            report["appPID"] = launch_exact_app(
                report["runID"], report_support_root(report), force_cold=True
            )
        elif len(process_ids(APP_PROCESS)) != 1:
            raise HarnessError("warm benchmark take requires the existing exact-path app process")
        cell = f"{take['mode']}/{take['length']}/{take['warmState']}#{take['repetition']}"
        write_json(BENCH_TAKE_FILE, {
            "benchRunID": report["runID"],
            "benchTakeIndex": str(take["index"]),
            "benchCell": cell,
            "benchWarmState": take["warmState"],
        })
        since = local_timestamp()
        progress.update({
            "status": "running",
            "startedAt": utc_now(),
            "since": since,
            "cell": cell,
            "attempt": int(progress.get("attempt", 0)) + 1,
        })
        report["benchmark"]["activeTakeIndex"] = args.index
        store_run(directory, report)
        append_jsonl(directory / "events.jsonl", {
            "timestamp": utc_now(), "event": "benchmark-take-began", **public_benchmark_take(take), "cell": cell,
        })
        print(json.dumps({**take, "cell": cell, "since": since, "appPID": report["appPID"]}, indent=2))
        return

    if report["benchmark"].get("activeTakeIndex") != args.index:
        raise HarnessError(f"benchmark take {args.index} is not active")
    text_digest = hashlib.sha256(take["text"].encode()).hexdigest()
    verified = any(
        assertion.get("kind") == "generation"
        and assertion.get("pass") is True
        and assertion.get("benchmarkTakeIndex") == args.index
        and assertion.get("mode") == take["mode"]
        and assertion.get("textDigest") == text_digest
        for assertion in report.get("deterministicAssertions", [])
    )
    if args.phase == "complete" and not verified:
        raise HarnessError(f"benchmark take {args.index} lacks matching deterministic generation proof")
    progress["status"] = "pass" if args.phase == "complete" else "fail"
    progress["completedAt"] = utc_now()
    report["benchmark"]["activeTakeIndex"] = None
    completed = sum(item["status"] == "pass" for item in report["benchmark"]["takes"])
    if completed == len(manifest):
        report["scenarios"]["generation-matrix"] = {
            "status": "pass",
            "message": f"Completed and deterministically verified {completed}/{len(manifest)} UI-driven takes",
            "evidence": "benchmark.takes",
            "updatedAt": utc_now(),
        }
    store_run(directory, report)
    append_jsonl(directory / "events.jsonl", {
        "timestamp": utc_now(), "event": f"benchmark-take-{args.phase}", **public_benchmark_take(take),
    })
    print(json.dumps({"index": args.index, "status": progress["status"], "completed": completed, "expected": len(manifest)}, indent=2))


def cmd_now(_: argparse.Namespace) -> None:
    print(local_timestamp())


def cmd_checkpoint(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    entry = {
        "status": args.status,
        "message": args.message,
        "evidence": args.evidence,
        "updatedAt": utc_now(),
    }
    report["scenarios"][args.scenario] = entry
    append_jsonl(directory / "events.jsonl", {"timestamp": utc_now(), "event": "checkpoint", "scenario": args.scenario, **entry})
    store_run(directory, report)


def cmd_issue(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    issue = {
        "id": f"issue-{len(report['issues']) + 1}",
        "scenario": args.scenario,
        "severity": args.severity,
        "category": args.category,
        "summary": args.summary,
        "expected": args.expected,
        "actual": args.actual,
        "evidence": args.evidence,
        "recordedAt": utc_now(),
    }
    report["issues"].append(issue)
    write_json(directory / "issues.json", report["issues"])
    append_jsonl(directory / "events.jsonl", {"timestamp": utc_now(), "event": "issue", **issue})
    store_run(directory, report)


def parse_since(value: str) -> dt.datetime:
    try:
        return dt.datetime.strptime(value, "%Y-%m-%d %H:%M:%S.%f").astimezone()
    except ValueError as exc:
        raise HarnessError("--since must be YYYY-MM-DD HH:MM:SS.mmm from the now command") from exc


def latest_history(database: Path, since: dt.datetime, expected_mode: str | None = None, expected_text: str | None = None) -> dict | None:
    if not database.is_file():
        return None
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    rows = connection.execute(
        "SELECT id, text, mode, modelTier, voice, audioPath, duration, createdAt FROM generations ORDER BY createdAt DESC"
    ).fetchall()
    connection.close()
    for row in rows:
        created = dt.datetime.strptime(row["createdAt"], "%Y-%m-%d %H:%M:%S.%f").replace(tzinfo=dt.timezone.utc)
        if created <= since.astimezone(dt.timezone.utc):
            continue
        if expected_mode and row["mode"] != expected_mode:
            continue
        if expected_text and row["text"] != expected_text:
            continue
        return dict(row)
    return None


def wav_metadata(path: Path) -> dict:
    if not path.is_file() or path.stat().st_size <= 44:
        raise HarnessError(f"missing or empty WAV: {path}")
    try:
        with wave.open(str(path), "rb") as stream:
            frames = stream.getnframes()
            rate = stream.getframerate()
            duration = frames / rate if rate else 0
            return {"frames": frames, "sampleRate": rate, "channels": stream.getnchannels(), "durationSeconds": duration, "bytes": path.stat().st_size}
    except (wave.Error, EOFError) as exc:
        raise HarnessError(f"unreadable WAV {path}: {exc}") from exc


def cmd_verify_history(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    row = latest_history(report_db(report), parse_since(args.since), args.mode, args.text)
    if row is None:
        raise HarnessError("no matching history row after --since")
    assertion = {"kind": "history", "pass": True, "mode": row["mode"], "historyID": row["id"], "audioPathDigest": hashlib.sha256(row["audioPath"].encode()).hexdigest()}
    report["deterministicAssertions"].append(assertion)
    store_run(directory, report)
    print(json.dumps(assertion, indent=2))


def cmd_verify_generation(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    since = parse_since(args.since)
    deadline = time.monotonic() + args.timeout
    row = None
    while time.monotonic() < deadline:
        row = latest_history(report_db(report), since, args.mode, args.text)
        if row is not None:
            break
        time.sleep(1)
    if row is None:
        raise HarnessError(f"no matching {args.mode} generation within {args.timeout}s")
    audio = Path(row["audioPath"])
    metadata = wav_metadata(audio)
    if not row["duration"] or row["duration"] <= 0 or metadata["durationSeconds"] <= 0:
        raise HarnessError("generation duration is non-positive")
    assertion = {
        "kind": "generation",
        "pass": True,
        "mode": row["mode"],
        "historyID": row["id"],
        "textDigest": hashlib.sha256(row["text"].encode()).hexdigest(),
        "audioPathDigest": hashlib.sha256(str(audio).encode()).hexdigest(),
        "wav": metadata,
    }
    active_take = (report.get("benchmark") or {}).get("activeTakeIndex")
    if active_take is not None:
        assertion["benchmarkTakeIndex"] = active_take
    report["deterministicAssertions"].append(assertion)
    store_run(directory, report)
    write_json(directory / f"generation-{row['id']}.json", assertion)
    print(json.dumps(assertion, indent=2))


def read_jsonl(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    rows = []
    for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError as exc:
            raise HarnessError(f"invalid JSONL {path}:{number}: {exc}") from exc
    return rows


def recorded_after(row: dict, started: str) -> bool:
    return str(row.get("recordedAt", "")) >= started


def run_rows(report: dict, layer: str) -> list[dict]:
    path = report_diagnostics(report) / layer / "generations.jsonl"
    rows = read_jsonl(path)
    run_id = report["runID"]
    return [
        row for row in rows
        if (row.get("notes") or {}).get("benchRunID") == run_id
    ]


def terminal_reason(row: dict) -> str | None:
    backend = row.get("backendMetrics") or {}
    transport = row.get("transportMetrics") or {}
    return backend.get("finishReason") or transport.get("finishReason") or row.get("finishReason")


def validate_probe_rows(engine_rows: list[dict], transport_rows: list[dict]) -> tuple[list[dict], list[str]]:
    errors: list[str] = []
    if not engine_rows:
        errors.append("missing backend engine telemetry")
    if not transport_rows:
        errors.append("missing middle-layer engine-service telemetry")

    for layer, rows in (("backend", engine_rows), ("transport", transport_rows)):
        forbidden_keys = {"text", "transcript", "filepath", "audiopath", "voicedescription"}
        for row in rows:
            stack: list[object] = [row]
            while stack:
                value = stack.pop()
                if isinstance(value, dict):
                    for key, child in value.items():
                        if key.lower() in forbidden_keys:
                            errors.append(f"{layer} telemetry contains forbidden raw field: {key}")
                        stack.append(child)
                elif isinstance(value, list):
                    stack.extend(value)
                elif isinstance(value, str) and ("/Users/" in value or "file://" in value):
                    errors.append(f"{layer} telemetry contains a raw local path")
        identities = [row.get("generationID") for row in rows if row.get("generationID")]
        duplicates = sorted({identity for identity in identities if identities.count(identity) > 1})
        if duplicates:
            errors.append(f"{layer} emitted duplicate terminal rows for: {', '.join(duplicates)}")

    engine_by_id = {row.get("generationID"): row for row in engine_rows if row.get("generationID")}
    transport_by_id = {row.get("generationID"): row for row in transport_rows if row.get("generationID")}
    common = sorted(set(engine_by_id) & set(transport_by_id))
    if not common:
        errors.append("no generationID is present in both backend and transport telemetry")

    checked = []
    for generation_id in common:
        engine = engine_by_id[generation_id]
        transport = transport_by_id[generation_id]
        engine_reason = terminal_reason(engine)
        transport_reason = terminal_reason(transport)
        if engine_reason and transport_reason and engine_reason != transport_reason:
            completed_aliases = {"completed", "eos"}
            if {engine_reason, transport_reason} - completed_aliases:
                errors.append(f"{generation_id}: terminal mismatch engine={engine_reason} transport={transport_reason}")
        if int(engine.get("schemaVersion", 0)) < 6 or not engine.get("backendMetrics"):
            errors.append(f"{generation_id}: missing typed backend schema-v6 metrics")
        if int(transport.get("schemaVersion", 0)) < 6 or not transport.get("transportMetrics"):
            errors.append(f"{generation_id}: missing typed transport schema-v6 metrics")
        counters = transport.get("transportMetrics", {}).get("counters") or transport.get("counters") or {}
        gaps = counters.get("chunkGaps", 0)
        duplicates = counters.get("duplicateChunks", 0)
        reordered = counters.get("outOfOrderChunks", 0)
        if gaps:
            errors.append(f"{generation_id}: transport reported {gaps} chunk gaps")
        if duplicates:
            errors.append(f"{generation_id}: transport reported {duplicates} duplicate chunks")
        if reordered:
            errors.append(f"{generation_id}: transport reported {reordered} out-of-order chunks")
        if counters.get("chunksForwarded", 0) <= 0:
            errors.append(f"{generation_id}: transport forwarded no chunks")
        stages = engine.get("stageMarks") or []
        times = [mark.get("tNS", mark.get("tMS", 0)) for mark in stages]
        if times != sorted(times):
            errors.append(f"{generation_id}: backend stage marks are not monotonic")
        completed = engine_reason in {"completed", "eos"} and transport_reason in {"completed", "eos"}
        barrier = (engine.get("backendMetrics") or {}).get("finalChunkBarrierObserved")
        if completed and engine.get("usedStreaming") and barrier is not True:
            errors.append(f"{generation_id}: completed stream lacks final-chunk barrier evidence")
        engine_at = str(engine.get("recordedAt", ""))
        transport_at = str(transport.get("recordedAt", ""))
        if engine_at and transport_at and engine_at > transport_at:
            errors.append(f"{generation_id}: transport completed before backend telemetry terminal")
        checked.append({
            "generationID": generation_id,
            "engineFinish": engine_reason,
            "transportFinish": transport_reason,
            "chunkGaps": gaps,
            "duplicateChunks": duplicates,
            "outOfOrderChunks": reordered,
            "finalChunkBarrierObserved": barrier,
        })
    return checked, errors


def cmd_verify_probes(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    deadline = time.monotonic() + args.timeout
    while True:
        engine_rows = run_rows(report, "engine")
        transport_rows = run_rows(report, "engine-service")
        checked, errors = validate_probe_rows(engine_rows, transport_rows)
        if checked or time.monotonic() >= deadline:
            break
        time.sleep(0.25)

    correlated = len(checked)
    verdict = {
        "schemaVersion": 1,
        "pass": not errors,
        "runID": report["runID"],
        "engineRows": len(engine_rows),
        "transportRows": len(transport_rows),
        "correlatedRows": correlated,
        "checked": checked,
        "errors": errors,
        "verifiedAt": utc_now(),
    }
    write_json(directory / "probe-verdict.json", verdict)
    report["probeVerdict"] = "pass" if verdict["pass"] else "fail"
    report["deterministicAssertions"].append({"kind": "cross-layer-probes", "pass": verdict["pass"], "correlatedRows": correlated})
    store_run(directory, report)
    print(json.dumps(verdict, indent=2))
    if errors:
        raise HarnessError("cross-layer probe verification failed")


def cmd_xpc_status(_: argparse.Namespace) -> None:
    print(json.dumps({"appPIDs": process_ids(APP_PROCESS), "servicePIDs": process_ids(SERVICE_PROCESS)}, indent=2))


def cmd_xpc_kill(_: argparse.Namespace) -> None:
    pids = process_ids(SERVICE_PROCESS)
    if not pids:
        raise HarnessError("engine service is not running")
    for pid in pids:
        os.kill(pid, signal.SIGKILL)
    time.sleep(1)
    if not process_ids(APP_PROCESS):
        raise HarnessError("Vocello exited after engine-service kill")
    print(json.dumps({"killedServicePIDs": pids, "appSurvived": True}, indent=2))


def cmd_xpc_wait(args: argparse.Namespace) -> None:
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        present = bool(process_ids(SERVICE_PROCESS))
        if present == args.present:
            print(json.dumps({"present": present, "servicePIDs": process_ids(SERVICE_PROCESS)}, indent=2))
            return
        time.sleep(0.5)
    raise HarnessError(f"engine service did not reach present={args.present} within {args.timeout}s")


def issue_counts(report: dict) -> dict[str, int]:
    return {severity: sum(issue.get("severity") == severity for issue in report.get("issues", [])) for severity in SEVERITIES}


def cmd_cleanup(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    cleanup_processes()
    restore_state(report)
    passed = not process_ids(APP_PROCESS) and not process_ids(SERVICE_PROCESS)
    passed = passed and bool((report.get("stateSnapshot") or {}).get("restored"))
    report["cleanupVerdict"] = "pass" if passed else "fail"
    append_jsonl(directory / "events.jsonl", {"timestamp": utc_now(), "event": "cleanup", "pass": passed})
    store_run(directory, report)
    if not passed:
        raise HarnessError("cleanup left app or engine-service processes running")


def cmd_finish(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    cleanup_processes()
    restore_state(report)
    cleanup_ok = not process_ids(APP_PROCESS) and not process_ids(SERVICE_PROCESS)
    cleanup_ok = cleanup_ok and bool((report.get("stateSnapshot") or {}).get("restored"))
    counts = issue_counts(report)
    severe = counts["blocker"] + counts["major"]
    scenarios = read_json(SCENARIOS).get("suites", {}).get(report.get("suite"), {}).get("includes", [])
    scenarios_ok = all((report.get("scenarios", {}).get(scenario) or {}).get("status") == "pass" for scenario in scenarios)
    requested = args.status
    final = requested
    if requested == "pass" and (severe or report.get("probeVerdict") != "pass" or not cleanup_ok or not scenarios_ok):
        final = "fail"
    completed = utc_now()
    report["status"] = final
    report["completedAt"] = completed
    try:
        started_at = dt.datetime.fromisoformat(report["startedAt"].replace("Z", "+00:00"))
        completed_at = dt.datetime.fromisoformat(completed.replace("Z", "+00:00"))
        report["durationSeconds"] = max(0.0, (completed_at - started_at).total_seconds())
    except (KeyError, TypeError, ValueError):
        report["durationSeconds"] = None
    report["cleanupVerdict"] = "pass" if cleanup_ok else "fail"
    report["issueCounts"] = counts
    store_run(directory, report)
    append_jsonl(directory / "events.jsonl", {"timestamp": utc_now(), "event": "run-finished", "status": final})
    print(json.dumps({"runID": report["runID"], "status": final, "cleanupVerdict": report["cleanupVerdict"], "issueCounts": counts}, indent=2))
    if final != "pass":
        raise HarnessError(f"run finished with status={final}")


def validate_report(report: dict, *, required_suite: str | None = None, current_fingerprints: bool = True) -> list[str]:
    errors = []
    required = [
        "schemaVersion", "runID", "suite", "status", "sourceFingerprint",
        "buildInputFingerprint", "appBinarySHA256", "executableIdentity",
        "environment", "probeVerdict", "cleanupVerdict",
    ]
    for key in required:
        if key not in report:
            errors.append(f"missing report field: {key}")
    if report.get("schemaVersion") != 2:
        errors.append(f"report schemaVersion {report.get('schemaVersion')} is diagnostic-only; schemaVersion 2 is required")
    if report.get("status") != "pass":
        errors.append(f"report status is {report.get('status')}, not pass")
    if report.get("probeVerdict") != "pass":
        errors.append("probe verdict is not pass")
    if report.get("cleanupVerdict") != "pass":
        errors.append("cleanup verdict is not pass")
    counts = issue_counts(report)
    if counts["blocker"] or counts["major"]:
        errors.append("report contains blocker or major issues")
    required_scenarios = read_json(SCENARIOS).get("suites", {}).get(report.get("suite"), {}).get("includes", [])
    incomplete = [
        scenario for scenario in required_scenarios
        if (report.get("scenarios", {}).get(scenario) or {}).get("status") != "pass"
    ]
    if incomplete:
        errors.append("required scenarios are not passing: " + ", ".join(incomplete))
    suite_contract = read_json(SCENARIOS).get("suites", {}).get(report.get("suite"), {})
    budget_minutes = suite_contract.get("budgetMinutes")
    if budget_minutes is not None:
        duration = report.get("durationSeconds")
        if not isinstance(duration, (int, float)):
            errors.append("report is missing a numeric durationSeconds")
        elif duration > float(budget_minutes) * 60:
            errors.append(
                f"suite duration {duration:.1f}s exceeds the {budget_minutes}-minute budget"
            )
    if report.get("suite") == "benchmark":
        benchmark = report.get("benchmark") or {}
        takes = benchmark.get("takes") or []
        expected = benchmark.get("expectedTakeCount")
        if expected != len(benchmark_manifest()) or len(takes) != expected:
            errors.append("benchmark take manifest is incomplete")
        elif any(take.get("status") != "pass" for take in takes):
            errors.append("benchmark contains an incomplete or failed take")
    if required_suite and report.get("suite") not in SUITE_SATISFIERS.get(required_suite, set()):
        errors.append(f"suite {report.get('suite')} is insufficient; require an actual {required_suite} report")
    if current_fingerprints:
        if report.get("sourceFingerprint") != fingerprint():
            errors.append("source fingerprint is stale")
        if report.get("buildInputFingerprint") != fingerprint(build_inputs_only=True):
            errors.append("build-input fingerprint is stale")
        if APP_BINARY.is_file() and report.get("appBinarySHA256") != sha256(APP_BINARY):
            errors.append("app binary SHA-256 is stale")
        if (report.get("environment") or {}).get("toolchain") != toolchain_identity():
            errors.append("toolchain identity is stale")
    return errors


def cmd_validate_report(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    errors = validate_report(report, required_suite=args.suite)
    result = {"pass": not errors, "runID": report.get("runID"), "requiredSuite": args.suite, "errors": errors}
    write_json(directory / "report-validation.json", result)
    print(json.dumps(result, indent=2))
    if errors:
        raise HarnessError("report validation failed")


def evidence_digest(directory: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted((item for item in directory.rglob("*") if item.is_file()), key=lambda item: item.as_posix()):
        if path.name == "report-validation.json":
            continue
        digest.update(path.relative_to(directory).as_posix().encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def cmd_attest(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    errors = validate_report(report, required_suite=args.suite)
    if errors:
        raise HarnessError("cannot attest invalid report: " + "; ".join(errors))
    counts = issue_counts(report)
    identity = {
        "sourceFingerprint": report["sourceFingerprint"],
        "buildInputFingerprint": report["buildInputFingerprint"],
        "toolchainIdentity": report["environment"]["toolchain"],
    }
    existing = read_json(ATTESTATION) if ATTESTATION.is_file() else {}
    preserve = (
        existing.get("schemaVersion") == 2
        and all(existing.get(key) == value for key, value in identity.items())
    )
    entries = dict(existing.get("entries") or {}) if preserve else {}
    runtime_checks = dict(existing.get("runtimeChecks") or {}) if preserve else {}
    entries[report["suite"]] = {
        "status": report["status"],
        "suite": report["suite"],
        "runID": report["runID"],
        "completedAt": report["completedAt"],
        "issues": counts,
        "probeVerdict": report["probeVerdict"],
        "evidenceDigest": evidence_digest(directory),
        "cleanupVerdict": report["cleanupVerdict"],
        "durationSeconds": report.get("durationSeconds"),
        "executableIdentity": report["executableIdentity"],
    }
    attestation = {
        "schemaVersion": 2,
        **identity,
        "entries": {suite: entries.get(suite) for suite in ATTESTABLE_SUITES},
        "runtimeChecks": runtime_checks,
        "updatedAt": utc_now(),
    }
    write_json(ATTESTATION, attestation)
    print(json.dumps(attestation, indent=2))


def cmd_attest_runtime(args: argparse.Namespace) -> None:
    verdict = read_json(Path(args.file))
    if verdict.get("schemaVersion") != 1 or verdict.get("status") != "pass":
        raise HarnessError("runtime-check verdict must be schemaVersion 1 with status=pass")
    identity = {
        "sourceFingerprint": fingerprint(),
        "buildInputFingerprint": fingerprint(build_inputs_only=True),
        "toolchainIdentity": toolchain_identity(),
    }
    existing = read_json(ATTESTATION) if ATTESTATION.is_file() else {}
    preserve = (
        existing.get("schemaVersion") == 2
        and all(existing.get(key) == value for key, value in identity.items())
    )
    entries = dict(existing.get("entries") or {}) if preserve else {}
    runtime_checks = dict(existing.get("runtimeChecks") or {}) if preserve else {}
    runtime_checks[args.name] = {
        "status": "pass",
        "completedAt": verdict.get("completedAt") or utc_now(),
        "evidenceDigest": sha256(Path(args.file)),
        "summary": verdict.get("attestationSummary") or verdict.get("summary") or {},
    }
    attestation = {
        "schemaVersion": 2,
        **identity,
        "entries": {suite: entries.get(suite) for suite in ATTESTABLE_SUITES},
        "runtimeChecks": runtime_checks,
        "updatedAt": utc_now(),
    }
    write_json(ATTESTATION, attestation)
    print(json.dumps(attestation, indent=2))


def changed_paths(base: str) -> list[str]:
    if run(["/usr/bin/git", "rev-parse", "--verify", base], check=False).returncode != 0:
        raise HarnessError(f"base ref not found: {base}; set QVOICE_BASE_REF explicitly")
    paths = set(run(["/usr/bin/git", "diff", "--name-only", f"{base}...HEAD"]).stdout.splitlines())
    paths.update(run(["/usr/bin/git", "diff", "--name-only"]).stdout.splitlines())
    untracked = run(["/usr/bin/git", "ls-files", "--others", "--exclude-standard"]).stdout.splitlines()
    paths.update(untracked)
    paths.discard(ATTESTATION.relative_to(ROOT).as_posix())
    paths = {path for path in paths if path and not path.startswith("QwenVoice_MLXAudio_Corrected_Report_Series_2026-07-10/")}
    return sorted(paths)


def classify_paths(paths: list[str], config: dict) -> tuple[list[str], list[str], list[dict]]:
    suites: set[str] = set(config.get("defaultRequiredSuites") or [])
    runtime_checks: set[str] = set(config.get("defaultRequiredRuntimeChecks") or [])
    matches: list[dict] = []
    for path in paths:
        for rule in config.get("rules", []):
            if any(fnmatch.fnmatch(path, pattern) for pattern in rule.get("patterns", [])):
                rule_suites = set(rule.get("requiredSuites") or [])
                rule_checks = set(rule.get("requiredRuntimeChecks") or [])
                suites.update(rule_suites)
                runtime_checks.update(rule_checks)
                matches.append({
                    "path": path,
                    "requiredSuites": sorted(rule_suites),
                    "requiredRuntimeChecks": sorted(rule_checks),
                })
    return sorted(suites), sorted(runtime_checks), matches


def validate_attestation(attestation: dict, required_suites: list[str], required_runtime_checks: list[str], *, ci: bool = False) -> list[str]:
    errors: list[str] = []
    if attestation.get("schemaVersion") != 2:
        return [f"attestation schemaVersion {attestation.get('schemaVersion')} is diagnostic-only; schemaVersion 2 is required"]
    if attestation.get("sourceFingerprint") != fingerprint():
        errors.append("attestation source fingerprint is stale")
    if attestation.get("buildInputFingerprint") != fingerprint(build_inputs_only=True):
        errors.append("attestation build-input fingerprint is stale")
    if attestation.get("toolchainIdentity") != toolchain_identity():
        errors.append("attestation toolchain identity is stale")
    entries = attestation.get("entries") or {}
    for required in required_suites:
        satisfiers = SUITE_SATISFIERS[required]
        candidates = [entries.get(suite) for suite in satisfiers if entries.get(suite)]
        valid = []
        for entry in candidates:
            entry_errors = []
            if entry.get("status") != "pass":
                entry_errors.append("status")
            if entry.get("probeVerdict") != "pass":
                entry_errors.append("probe")
            if entry.get("cleanupVerdict") != "pass":
                entry_errors.append("cleanup")
            counts = entry.get("issues") or {}
            if counts.get("blocker", 0) or counts.get("major", 0):
                entry_errors.append("issues")
            executable = entry.get("executableIdentity") or {}
            if not ci and executable.get("sha256") != sha256(APP_BINARY):
                entry_errors.append("local executable")
            if not entry_errors:
                valid.append(entry)
        if not valid:
            errors.append(f"missing valid {required} evidence (accepted suites: {', '.join(sorted(satisfiers))})")
    runtime = attestation.get("runtimeChecks") or {}
    for check in required_runtime_checks:
        if (runtime.get(check) or {}).get("status") != "pass":
            errors.append(f"missing passing runtime check: {check}")
    if not APP_BINARY.is_file():
        errors.append(f"current exact-path app binary is missing: {APP_BINARY}")
    return errors


def cmd_impact(args: argparse.Namespace) -> None:
    config = read_json(IMPACT)
    base = args.base or os.environ.get("QVOICE_BASE_REF") or "origin/main"
    paths = changed_paths(base)
    suites, runtime_checks, matches = classify_paths(paths, config)
    result = {
        "schemaVersion": 2,
        "base": base,
        "requiredSuites": suites,
        "requiredRuntimeChecks": runtime_checks,
        "changedPaths": paths,
        "matches": matches,
    }
    print(json.dumps(result, indent=2))
    if args.check and (suites or runtime_checks):
        attestation = read_json(ATTESTATION)
        errors = validate_attestation(attestation, suites, runtime_checks, ci=args.ci)
        if errors:
            raise HarnessError("Computer Use attestation required: " + "; ".join(errors))


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    sub = root.add_subparsers(dest="command", required=True)

    doctor = sub.add_parser("doctor")
    doctor.add_argument("--suite", choices=SUITES, default="quick")
    doctor.add_argument("--json", action="store_true")
    doctor.set_defaults(func=cmd_doctor)

    start = sub.add_parser("start")
    start.add_argument("--suite", choices=("quick", "full", "benchmark", "destructive"), required=True)
    start.add_argument("--allow-destructive", action="store_true")
    start.set_defaults(func=cmd_start)

    now = sub.add_parser("now")
    now.set_defaults(func=cmd_now)

    manifest = sub.add_parser("benchmark-manifest")
    manifest.set_defaults(func=cmd_benchmark_manifest)

    take = sub.add_parser("benchmark-take")
    take.add_argument("--run")
    take.add_argument("--index", type=int, required=True)
    take.add_argument("--phase", choices=("begin", "complete", "fail"), required=True)
    take.set_defaults(func=cmd_benchmark_take)

    checkpoint = sub.add_parser("checkpoint")
    checkpoint.add_argument("--run")
    checkpoint.add_argument("--scenario", required=True)
    checkpoint.add_argument("--status", choices=("running", "pass", "fail", "blocked", "skipped"), required=True)
    checkpoint.add_argument("--message", required=True)
    checkpoint.add_argument("--evidence")
    checkpoint.set_defaults(func=cmd_checkpoint)

    issue = sub.add_parser("issue")
    issue.add_argument("--run")
    issue.add_argument("--scenario", required=True)
    issue.add_argument("--severity", choices=SEVERITIES, required=True)
    issue.add_argument("--category", choices=("functional", "visual", "accessibility", "automation", "environment"), required=True)
    issue.add_argument("--summary", required=True)
    issue.add_argument("--expected", required=True)
    issue.add_argument("--actual", required=True)
    issue.add_argument("--evidence")
    issue.set_defaults(func=cmd_issue)

    for name, function in (("verify-generation", cmd_verify_generation), ("verify-history", cmd_verify_history)):
        command = sub.add_parser(name)
        command.add_argument("--run")
        command.add_argument("--since", required=True)
        command.add_argument("--mode", choices=("custom", "design", "clone"))
        command.add_argument("--text")
        if name == "verify-generation":
            command.add_argument("--timeout", type=int, default=300)
        command.set_defaults(func=function)

    probes = sub.add_parser("verify-probes")
    probes.add_argument("--run")
    probes.add_argument("--timeout", type=int, default=20)
    probes.set_defaults(func=cmd_verify_probes)

    status = sub.add_parser("xpc-status")
    status.set_defaults(func=cmd_xpc_status)
    kill = sub.add_parser("xpc-kill")
    kill.set_defaults(func=cmd_xpc_kill)
    wait = sub.add_parser("xpc-wait")
    group = wait.add_mutually_exclusive_group(required=True)
    group.add_argument("--present", action="store_true")
    group.add_argument("--absent", action="store_true")
    wait.add_argument("--timeout", type=int, default=60)
    wait.set_defaults(func=cmd_xpc_wait)

    cleanup = sub.add_parser("cleanup")
    cleanup.add_argument("--run")
    cleanup.set_defaults(func=cmd_cleanup)
    finish = sub.add_parser("finish")
    finish.add_argument("--run")
    finish.add_argument("--status", choices=("pass", "fail", "blocked"), required=True)
    finish.set_defaults(func=cmd_finish)

    validate = sub.add_parser("validate-report")
    validate.add_argument("--run")
    validate.add_argument("--suite", choices=("quick", "full", "benchmark"))
    validate.set_defaults(func=cmd_validate_report)
    attest = sub.add_parser("attest")
    attest.add_argument("--run")
    attest.add_argument("--suite", choices=("quick", "full", "benchmark"))
    attest.set_defaults(func=cmd_attest)

    attest_runtime = sub.add_parser("attest-runtime")
    attest_runtime.add_argument("--name", required=True)
    attest_runtime.add_argument("--file", required=True)
    attest_runtime.set_defaults(func=cmd_attest_runtime)

    impact = sub.add_parser("impact")
    impact.add_argument("--base")
    impact.add_argument("--check", action="store_true")
    impact.add_argument("--ci", action="store_true", help="skip local signed executable hash comparison")
    impact.set_defaults(func=cmd_impact)
    return root


def main() -> int:
    args = parser().parse_args()
    if getattr(args, "absent", False):
        args.present = False
    try:
        args.func(args)
        return 0
    except HarnessError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
