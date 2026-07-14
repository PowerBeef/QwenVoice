#!/usr/bin/env python3
"""Validate active Vocello documentation against repository-owned interfaces."""

from __future__ import annotations

import argparse
import glob
import json
import re
import subprocess
import sys
import urllib.parse
from pathlib import Path


CONTRACT_PATH = Path("config/documentation-contract.json")
PUBLIC_FACTS_PATH = Path("config/public-product-facts.json")
OPTIONAL_CAPABILITY_CLAIMS = {
    "installed GitHub integration": "describe GitHub integration as conditional and keep gh as fallback",
    "Build iOS Apps supplies": "describe the shared XcodeBuildMCP route as conditional",
    "The plugin supplies the one shared XcodeBuildMCP": "describe the shared XcodeBuildMCP route as conditional",
    "impeccable:impeccable": "use the current impeccable skill name",
}
RETIRED_HARNESS = re.compile(
    r"(?i:cursor IDE|\.cursor(?:/|\b)|computer[- ]use|mirroir|peekaboo|mobile-mcp)"
)
SCRIPT_HELP_SURFACES = {
    "scripts/ui_test.sh",
    "scripts/macos_test.sh",
    "scripts/ios_device.sh",
    "scripts/clean_build_caches.sh",
    "scripts/build.sh",
}


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _expand_group(root: Path, patterns: list[str]) -> set[Path]:
    paths: set[Path] = set()
    for pattern in patterns:
        paths.update(path for path in root.glob(pattern) if path.is_file())
    return paths


def documentation_groups(root: Path) -> list[dict]:
    contract = load_json(root / CONTRACT_PATH)
    return contract["groups"]


def active_markdown_paths(root: Path) -> list[Path]:
    if not (root / CONTRACT_PATH).is_file():
        # Small fixture fallback. Production inventory is always manifest-owned.
        candidates = [root / "AGENTS.md", root / "README.md", root / "PRODUCT.md", root / "website/AGENTS.md"]
        candidates.extend((root / ".agents").glob("*.md"))
        candidates.extend((root / "docs/reference").glob("*.md"))
        return sorted(
            path for path in candidates if path.is_file()
            and path.name != "backend-optimization-research-report.md"
            and "releases" not in path.parts
        )
    paths: set[Path] = set()
    historical: set[Path] = set()
    for group in documentation_groups(root):
        if group["status"] == "historical":
            historical.update(_expand_group(root, group["paths"]))
    for group in documentation_groups(root):
        if group["status"] != "active":
            continue
        paths.update(_expand_group(root, group["paths"]))
    return sorted(paths - historical)


def historical_markdown_paths(root: Path) -> list[Path]:
    if not (root / CONTRACT_PATH).is_file():
        paths = [path for path in (root / "docs").glob("releases/*.md") if path.is_file()]
        backend = root / "docs/reference/backend-optimization-research-report.md"
        if backend.is_file():
            paths.append(backend)
        return sorted(paths)
    paths: set[Path] = set()
    for group in documentation_groups(root):
        if group["status"] == "historical":
            paths.update(_expand_group(root, group["paths"]))
    return sorted(paths)


def markdown_slug(value: str) -> str:
    value = re.sub(r"<[^>]+>", "", value).strip().lower()
    value = re.sub(r"[^\w\- ]", "", value, flags=re.UNICODE)
    return re.sub(r"\s", "-", value)


def headings(path: Path) -> set[str]:
    found: set[str] = set()
    counts: dict[str, int] = {}
    fenced = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if fenced:
            continue
        match = re.match(r"^#{1,6}\s+(.+?)\s*#*\s*$", line)
        if not match:
            continue
        base = markdown_slug(match.group(1))
        index = counts.get(base, 0)
        counts[base] = index + 1
        found.add(base if index == 0 else f"{base}-{index}")
    return found


def validate_relative_links(root: Path, paths: list[Path]) -> list[str]:
    errors: list[str] = []
    pattern = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
    anchor_cache: dict[Path, set[str]] = {}
    for source in paths:
        text = source.read_text(encoding="utf-8")
        for raw_target in pattern.findall(text):
            target = raw_target.strip().strip("<>")
            if not target or target.startswith(("http://", "https://", "mailto:", "plugin://")):
                continue
            path_part, separator, anchor = target.partition("#")
            resolved = source if not path_part else (source.parent / urllib.parse.unquote(path_part)).resolve()
            if not resolved.exists():
                errors.append(f"{source.relative_to(root)}: missing relative link target {raw_target}")
                continue
            if separator and anchor and resolved.suffix.lower() == ".md":
                available = anchor_cache.setdefault(resolved, headings(resolved))
                decoded = urllib.parse.unquote(anchor).lower()
                if decoded not in available and decoded.lstrip("-") not in {item.lstrip("-") for item in available}:
                    errors.append(f"{source.relative_to(root)}: missing Markdown heading anchor {raw_target}")
    return errors


def validate_script_references(root: Path, paths: list[Path]) -> list[str]:
    errors: list[str] = []
    pattern = re.compile(r"(?<![A-Za-z0-9_])(?:\./)?(scripts/[A-Za-z0-9_.*?/-]+\.(?:sh|py))")
    for source in paths:
        for raw in pattern.findall(source.read_text(encoding="utf-8")):
            candidate = raw.rstrip(".,;:")
            matches = glob.glob(str(root / candidate)) if any(char in candidate for char in "*?") else []
            if not matches and not (root / candidate).is_file():
                errors.append(f"{source.relative_to(root)}: missing repository script {candidate}")
    return errors


def validate_repository_paths(root: Path, paths: list[Path]) -> list[str]:
    prefixes = ("Sources/", "Tests/", "scripts/", "config/", ".github/", ".agents/", "docs/", "benchmarks/", "website/", "third_party_patches/")
    errors: list[str] = []
    for source in paths:
        text = source.read_text(encoding="utf-8")
        for value in re.findall(r"`([^`\n]+)`", text):
            candidate = value.strip().split()[0].rstrip(".,;:")
            candidate = re.sub(r":\d+(?:-\d+)?$", "", candidate)
            if not candidate.startswith(prefixes) or any(marker in candidate for marker in ("<", ">", "{", "}", "$", "...")):
                continue
            matches = glob.glob(str(root / candidate)) if "*" in candidate else []
            if not matches and (root / candidate).exists():
                matches = [str(root / candidate)]
            if not matches and candidate.startswith(("Sources/", "Tests/")):
                vendored = root / "third_party_patches/mlx-audio-swift" / candidate
                if vendored.exists():
                    matches = [str(vendored)]
            if not matches:
                errors.append(f"{source.relative_to(root)}: stale inline repository path {candidate}")
    return errors


def validate_retired_harness_terms(root: Path, paths: list[Path]) -> list[str]:
    errors: list[str] = []
    for source in paths:
        text = source.read_text(encoding="utf-8")
        for match in RETIRED_HARNESS.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            errors.append(f"{source.relative_to(root)}:{line}: retired harness term {match.group(0)!r}")
    return errors


def _allowed_build_paths(manifest: dict) -> set[str]:
    paths = {entry["path"].rstrip("/") for entry in manifest["entries"]}
    paths.update(link["path"].rstrip("/") for link in manifest.get("publicLinks", []))
    allowed = {"build"}
    for path in paths:
        parts = Path(path).parts
        allowed.update("/".join(parts[:index]) for index in range(1, len(parts) + 1))
    return allowed | paths


def validate_build_references(root: Path, paths: list[Path]) -> list[str]:
    manifest = load_json(root / "config/build-output-policy.json")
    allowed = _allowed_build_paths(manifest)
    owned_roots = {entry["path"].rstrip("/") for entry in manifest["entries"]}
    owned_roots.update(link["path"].rstrip("/") for link in manifest.get("publicLinks", []))
    pattern = re.compile(r"(?P<path>build/[A-Za-z0-9_.{}<>/,-]+)")
    errors: list[str] = []
    for source in paths:
        text = source.read_text(encoding="utf-8")
        regions = [(match.group(1), match.start(1)) for match in re.finditer(r"`([^`\n]+)`", text)]
        regions.extend((match.group(1), match.start(1)) for match in re.finditer(r"```[^\n]*\n(.*?)```", text, re.DOTALL))
        for region, offset in regions:
            for match in pattern.finditer(region):
                candidate = match.group("path").rstrip("/.,;:")
                static = re.split(r"[<{]", candidate, maxsplit=1)[0].rstrip("/")
                if static in allowed or any(candidate == owned or candidate.startswith(owned + "/") for owned in owned_roots):
                    continue
                line = text.count("\n", 0, offset + match.start("path")) + 1
                errors.append(f"{source.relative_to(root)}:{line}: unowned documented build path {candidate}")
    return errors


def validate_optional_capabilities(root: Path, paths: list[Path]) -> list[str]:
    checked = list(paths)
    for relative in (".xcodebuildmcp/config.yaml", "docs/project-map.html"):
        path = root / relative
        if path.is_file():
            checked.append(path)
    errors: list[str] = []
    for source in checked:
        text = source.read_text(encoding="utf-8")
        for phrase, remediation in OPTIONAL_CAPABILITY_CLAIMS.items():
            if phrase in text:
                errors.append(f"{source.relative_to(root)}: {remediation}; found {phrase!r}")
    return errors


def _top_level_names(project: str, section: str) -> list[str]:
    start = re.search(rf"(?m)^{re.escape(section)}:\s*$", project)
    if not start:
        return []
    values: list[str] = []
    for line in project[start.end():].splitlines():
        if line and not line.startswith(" "):
            break
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if match:
            values.append(match.group(1))
    return values


def benchmark_baseline_status(root: Path, platform: str) -> bool:
    for path in (root / "benchmarks/runs").glob("*/*.json"):
        try:
            record = load_json(path)
        except (OSError, json.JSONDecodeError):
            continue
        run = record.get("run", {})
        source = record.get("source", {})
        if (record.get("schemaVersion") == 2 and run.get("platform") == platform
                and run.get("classification") == "canonical" and not source.get("dirty")
                and run.get("status") in {"passed", "passedWithWarnings"}):
            return True
    return False


def validate_facts(root: Path) -> list[str]:
    errors: list[str] = []
    public = load_json(root / PUBLIC_FACTS_PATH)
    hardware = load_json(root / "benchmarks/hardware-profiles.json")
    models = load_json(root / "Sources/Resources/qwenvoice_contract.json")
    project = (root / "project.yml").read_text(encoding="utf-8")
    targets = _top_level_names(project, "targets")
    schemes = _top_level_names(project, "schemes")
    cli_template = root / "config/xcode-schemes/VocelloCLI.xcscheme.template"
    if len(targets) != 12:
        errors.append(f"project.yml: expected 12 targets, found {len(targets)}")
    if len(schemes) != 4 or not cli_template.is_file():
        errors.append("project schemes must contain four XcodeGen schemes plus the generated VocelloCLI scheme")
    architecture = (root / "docs/ARCHITECTURE.md").read_text(encoding="utf-8")
    if "12 targets" not in architecture or "five shared schemes" not in architecture.lower():
        errors.append("docs/ARCHITECTURE.md: target/scheme inventory must state 12 targets and five shared schemes")
    if re.search(r"QwenVoiceBackendCore[^\n]{0,120}(?:Low-level MLX|MLX/audio primitives|owns model load|owns codecs)", architecture, re.I):
        errors.append("docs/ARCHITECTURE.md: BackendCore is incorrectly described as the MLX/codec implementation boundary")
    qwen = (root / "docs/reference/qwen3-tts-guide.md").read_text(encoding="utf-8")
    if re.search(r"Code Predictor[^\n]{0,100}greedy", qwen, re.I):
        errors.append("docs/reference/qwen3-tts-guide.md: Code Predictor cannot be described as unconditionally greedy")
    mimi = (root / "docs/reference/mimi-codec-guide.md").read_text(encoding="utf-8")
    if any(re.search(r"100[^\n]{0,80}0\.8\s*(?:s|seconds)", line, re.I) and "not 0.8" not in line.lower() for line in mimi.splitlines()):
        errors.append("docs/reference/mimi-codec-guide.md: 100 frames at 12.5 Hz are about 8 seconds, not 0.8")
    profiles = {item["id"] for item in hardware["profiles"]}
    for platform, profile in public["canonicalBenchmarkProfiles"].items():
        if profile not in profiles:
            errors.append(f"public-product-facts: unknown {platform} hardware profile {profile}")
    if not models.get("models") or not models.get("speakers"):
        errors.append("qwenvoice_contract.json: public model/speaker contract is empty")
    version = public["stableMacRelease"]["version"]
    if f'MARKETING_VERSION: "{version}"' not in project:
        errors.append("public-product-facts stable Mac version differs from project.yml")
    readme = (root / "README.md").read_text(encoding="utf-8")
    website = "\n".join(
        path.read_text(encoding="utf-8")
        for path in (root / "website/src").rglob("*.jsx")
    )
    if version not in readme or version not in website:
        errors.append("public stable Mac release is missing from README or website copy")
    if public["ios"]["minimumDevice"] not in readme:
        errors.append("README minimum iPhone support differs from public-product-facts")
    website_pending = any(phrase in website.lower() for phrase in ("arriving soon", "not public yet", "public distribution is not"))
    if "arriving soon" not in readme.lower() or not website_pending:
        errors.append("public iPhone distribution-pending status is missing from README or website")
    progress = (root / "docs/development-progress.md").read_text(encoding="utf-8")
    if benchmark_baseline_status(root, "macos") and "clean canonical macOS schema-v2 baseline exists" not in progress:
        errors.append("docs/development-progress.md: tracked history has a clean canonical macOS baseline but the checkpoint does not")
    if not benchmark_baseline_status(root, "ios") and "clean canonical iPhone schema-v2 baseline remains pending" not in progress:
        errors.append("docs/development-progress.md: iPhone clean canonical status must remain pending")
    return errors


def _script_help(root: Path, script: str) -> str:
    result = subprocess.run([str(root / script), "--help"], cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10, check=False)
    return result.stdout


def validate_documented_subcommands(root: Path, paths: list[Path]) -> list[str]:
    errors: list[str] = []
    help_text = {script: _script_help(root, script) for script in SCRIPT_HELP_SURFACES if (root / script).is_file()}
    command = re.compile(r"(?:^|\s)(?:\./)?(?P<script>scripts/[A-Za-z0-9_-]+\.sh)\s+(?P<sub>[A-Za-z0-9_-]+)")
    for source in paths:
        for match in command.finditer(source.read_text(encoding="utf-8")):
            script, subcommand = match.group("script"), match.group("sub")
            if script in help_text and subcommand not in help_text[script]:
                errors.append(f"{source.relative_to(root)}: undocumented or retired subcommand {script} {subcommand}")
    return errors


def validate_website_copy(root: Path) -> list[str]:
    errors: list[str] = []
    source_root = root / "website/src"
    for path in sorted(source_root.rglob("*")):
        if not path.is_file() or path.suffix not in {".js", ".jsx", ".json"}:
            continue
        text = path.read_text(encoding="utf-8")
        if "—" in text:
            errors.append(f"{path.relative_to(root)}: visible website source contains a prohibited em dash")
        if re.search(r"(?i)faster than real[ -]?time", text):
            errors.append(f"{path.relative_to(root)}: public copy makes a universal faster-than-realtime claim")
    return errors


def render_index(root: Path) -> str:
    lines = [
        "# Documentation index",
        "",
        "> Generated by `python3 scripts/documentation_contract.py rebuild-index`. Do not edit manually.",
        "",
        "Code, machine-readable contracts, and repository scripts remain higher authority than prose.",
        "",
    ]
    groups = documentation_groups(root)
    historical = set().union(*(
        _expand_group(root, group["paths"]) for group in groups if group["status"] == "historical"
    ))
    for group in groups:
        lines.extend([f"## {group['title']}", "", f"Status: **{group['status']}** · Owner: **{group['owner']}** · Audience: {group['audience']}.", "", f"Authority: {group['authority']}.", "", "Review when: " + "; ".join(group["reviewTriggers"]) + ".", ""])
        group_paths = _expand_group(root, group["paths"])
        if group["status"] == "active":
            group_paths -= historical
        for path in sorted(group_paths):
            if path == root / load_json(root / CONTRACT_PATH)["indexPath"]:
                continue
            relative = path.relative_to(root)
            link = Path("..") / relative
            lines.append(f"- [`{relative.as_posix()}`]({link.as_posix()})")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def validate_index(root: Path) -> list[str]:
    index = root / load_json(root / CONTRACT_PATH)["indexPath"]
    expected = render_index(root)
    if not index.is_file():
        return [f"{index.relative_to(root)}: generated documentation index is missing"]
    if index.read_text(encoding="utf-8") != expected:
        return [f"{index.relative_to(root)}: generated documentation index is stale"]
    return []


def validate_historical_banners(root: Path) -> list[str]:
    errors: list[str] = []
    for path in historical_markdown_paths(root):
        if "audits/archive" not in path.as_posix() and path.name != "backend-optimization-research-report.md":
            continue
        opening = "\n".join(path.read_text(encoding="utf-8").splitlines()[:12])
        if "Historical snapshot" not in opening and "Historical resolution" not in opening:
            errors.append(f"{path.relative_to(root)}: missing opening historical-snapshot notice")
    return errors


def validate(root: Path) -> list[str]:
    paths = active_markdown_paths(root)
    errors: list[str] = []
    errors.extend(validate_relative_links(root, paths))
    errors.extend(validate_script_references(root, paths))
    errors.extend(validate_repository_paths(root, paths))
    errors.extend(validate_build_references(root, paths))
    errors.extend(validate_optional_capabilities(root, paths))
    errors.extend(validate_retired_harness_terms(root, paths))
    errors.extend(validate_documented_subcommands(root, paths))
    errors.extend(validate_facts(root))
    errors.extend(validate_website_copy(root))
    errors.extend(validate_historical_banners(root))
    errors.extend(validate_index(root))
    for source in paths:
        if re.search(r"--ledger(?:-row)?\b", source.read_text(encoding="utf-8")):
            errors.append(f"{source.relative_to(root)}: retired manual benchmark-ledger option returned")
    return sorted(set(errors))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1], help=argparse.SUPPRESS)
    subparsers = parser.add_subparsers(dest="command")
    subparsers.add_parser("validate")
    rebuild = subparsers.add_parser("rebuild-index")
    rebuild.add_argument("--check", action="store_true")
    arguments = parser.parse_args(argv)
    root = arguments.repo_root.resolve()
    if arguments.command == "rebuild-index":
        errors = validate_index(root)
        if arguments.check:
            if errors:
                print("\n".join(errors), file=sys.stderr)
                return 1
            print("Documentation index: PASS")
            return 0
        target = root / load_json(root / CONTRACT_PATH)["indexPath"]
        target.write_text(render_index(root), encoding="utf-8")
        print(f"Rebuilt {target.relative_to(root)}")
        return 0
    errors = validate(root)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Documentation contract: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
