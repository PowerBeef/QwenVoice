#!/usr/bin/env python3
"""Validate active Vocello documentation against repository-owned interfaces."""

from __future__ import annotations

import argparse
import glob
import json
import re
import sys
import urllib.parse
from pathlib import Path


HISTORICAL_MARKDOWN = {
    "benchmarks/HISTORY.md",
    "benchmarks/LEGACY_HISTORY.md",
    "docs/reference/backend-optimization-research-report.md",
}

OPTIONAL_CAPABILITY_CLAIMS = {
    "installed GitHub integration": "describe GitHub integration as conditional and keep gh as fallback",
    "Build iOS Apps supplies": "describe the shared XcodeBuildMCP route as conditional",
    "The plugin supplies the one shared XcodeBuildMCP": "describe the shared XcodeBuildMCP route as conditional",
    "impeccable:impeccable": "use the current impeccable skill name",
}

RETIRED_HARNESS = re.compile(
    r"(?i:cursor IDE|\.cursor(?:/|\b)|computer[- ]use|mirroir|peekaboo|mobile-mcp)"
)


def active_markdown_paths(root: Path) -> list[Path]:
    paths: set[Path] = set()
    for relative in (
        "AGENTS.md",
        "README.md",
        "PRODUCT.md",
        "benchmarks/README.md",
        "benchmarks/OPTIMIZATION.md",
        "docs/ARCHITECTURE.md",
        "docs/development-progress.md",
        "docs/qwen_tone.md",
        "website/AGENTS.md",
        "website/DESIGN.md",
        "website/PRODUCT.md",
        "website/README.md",
        "Sources/Resources/voice-previews/README.md",
        "QwenVoice_MLXAudio_Corrected_Report_Series_2026-07-10/README.md",
    ):
        path = root / relative
        if path.is_file():
            paths.add(path)
    paths.update(path for path in (root / ".agents").glob("*.md") if path.is_file())
    paths.update(path for path in (root / "docs/reference").glob("*.md") if path.is_file())
    return sorted(
        path
        for path in paths
        if path.relative_to(root).as_posix() not in HISTORICAL_MARKDOWN
        and "releases" not in path.relative_to(root).parts
    )


def validate_relative_links(root: Path, paths: list[Path]) -> list[str]:
    errors: list[str] = []
    pattern = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
    for source in paths:
        text = source.read_text(encoding="utf-8")
        for raw_target in pattern.findall(text):
            target = raw_target.strip().strip("<>")
            if not target or target.startswith(
                ("#", "http://", "https://", "mailto:", "plugin://")
            ):
                continue
            path_part = urllib.parse.unquote(target.split("#", 1)[0])
            if path_part and not (source.parent / path_part).resolve().exists():
                errors.append(
                    f"{source.relative_to(root)}: missing relative link target {raw_target}"
                )
    return errors


def validate_script_references(root: Path, paths: list[Path]) -> list[str]:
    errors: list[str] = []
    pattern = re.compile(r"(?<![A-Za-z0-9_])(?:\./)?(scripts/[A-Za-z0-9_.*?/-]+\.(?:sh|py))")
    for source in paths:
        text = source.read_text(encoding="utf-8")
        for raw in pattern.findall(text):
            candidate = raw.rstrip(".,;:")
            matches = glob.glob(str(root / candidate)) if any(char in candidate for char in "*?") else []
            if not matches and not (root / candidate).is_file():
                errors.append(
                    f"{source.relative_to(root)}: missing repository script {candidate}"
                )
    return errors


def validate_repository_paths(root: Path, paths: list[Path]) -> list[str]:
    prefixes = ("Sources/", "Tests/", "scripts/", "config/", ".github/", ".agents/", "docs/", "benchmarks/", "website/")
    errors: list[str] = []
    for source in paths:
        text = source.read_text(encoding="utf-8")
        for value in re.findall(r"`([^`\n]+)`", text):
            candidate = value.strip().split()[0].rstrip(".,;:")
            candidate = re.sub(r":\d+(?:-\d+)?$", "", candidate)
            if not candidate.startswith(prefixes) or any(
                marker in candidate for marker in ("<", ">", "{", "}", "$")
            ):
                continue
            matches = glob.glob(str(root / candidate)) if "*" in candidate else []
            if not matches and (root / candidate).exists():
                matches = [str(root / candidate)]
            if not matches and candidate.startswith("Sources/"):
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
            errors.append(
                f"{source.relative_to(root)}:{line}: retired harness term {match.group(0)!r}"
            )
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
    manifest = json.loads((root / "config/build-output-policy.json").read_text(encoding="utf-8"))
    allowed = _allowed_build_paths(manifest)
    owned_roots = {entry["path"].rstrip("/") for entry in manifest["entries"]}
    owned_roots.update(link["path"].rstrip("/") for link in manifest.get("publicLinks", []))
    pattern = re.compile(r"(?P<path>build/[A-Za-z0-9_.{}<>/,-]+)")
    errors: list[str] = []
    for source in paths:
        text = source.read_text(encoding="utf-8")
        regions = [(match.group(1), match.start(1)) for match in re.finditer(r"`([^`\n]+)`", text)]
        regions.extend(
            (match.group(1), match.start(1))
            for match in re.finditer(r"```[^\n]*\n(.*?)```", text, re.DOTALL)
        )
        for region, offset in regions:
            for match in pattern.finditer(region):
                candidate = match.group("path").rstrip("/.,;:")
                static = re.split(r"[<{]", candidate, maxsplit=1)[0].rstrip("/")
                if static in allowed or any(
                    candidate == owned or candidate.startswith(owned + "/")
                    for owned in owned_roots
                ):
                    continue
                line = text.count("\n", 0, offset + match.start("path")) + 1
                errors.append(
                    f"{source.relative_to(root)}:{line}: unowned documented build path {candidate}"
                )
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


def validate_current_status(root: Path) -> list[str]:
    errors: list[str] = []
    progress = (root / "docs/development-progress.md").read_text(encoding="utf-8")
    for required in ("exploratory", "clean canonical schema-v2 comparison baselines"):
        if required not in progress:
            errors.append(f"docs/development-progress.md: missing current status marker {required!r}")
    if "first native schema-v2 canonical records" in progress:
        errors.append("docs/development-progress.md: exploratory evidence is presented as a first canonical record")

    language = (root / "docs/reference/language-bench.md").read_text(encoding="utf-8")
    if "### Historical validation snapshot" not in language:
        errors.append("docs/reference/language-bench.md: dated validation table is not marked historical")
    if "### Validated (2026-07-06)" in language:
        errors.append("docs/reference/language-bench.md: July 6 snapshot is presented as current acceptance")

    optimization = (root / "benchmarks/OPTIMIZATION.md").read_text(encoding="utf-8")
    if "**standing status**" in optimization:
        errors.append("benchmarks/OPTIMIZATION.md: dated ledger is presented as current standing status")

    project_map = (root / "docs/project-map.html").read_text(encoding="utf-8")
    dates = set(re.findall(r"reviewed(?:\s+|\"\s*:\s*\")(?P<date>20\d{2}-\d{2}-\d{2})", project_map))
    if len(dates) != 1:
        errors.append(f"docs/project-map.html: review markers disagree: {sorted(dates)}")
    return errors


def validate_historical_banners(root: Path) -> list[str]:
    paths = sorted((root / "QwenVoice_MLXAudio_Corrected_Report_Series_2026-07-10").glob("*.md"))
    paths.append(root / "docs/reference/backend-optimization-research-report.md")
    errors = []
    for path in paths:
        if not path.is_file():
            continue
        opening = "\n".join(path.read_text(encoding="utf-8").splitlines()[:10])
        if "Historical snapshot" not in opening:
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
    errors.extend(validate_current_status(root))
    errors.extend(validate_historical_banners(root))
    for source in paths:
        text = source.read_text(encoding="utf-8")
        if re.search(r"--ledger(?:-row)?\b", text):
            errors.append(f"{source.relative_to(root)}: retired manual benchmark-ledger option returned")
    return sorted(set(errors))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1])
    arguments = parser.parse_args(argv)
    root = arguments.repo_root.resolve()
    errors = validate(root)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Documentation contract: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
