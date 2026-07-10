#!/usr/bin/env python3
"""Regenerate docs/reference/ui-test-surface.md — the accessibilityIdentifier catalog.

Scans Sources/**/*.swift for accessibilityIdentifier declarations and writes a
platform-grouped markdown catalog. Successor to the 611-line hand-written catalog
deleted at 6d1cca4; generated so it cannot drift from the code again.

usage: python3 scripts/generate_ui_test_surface.py [--check]
  --check   exit 1 if the committed doc is stale (for gates/CI)
"""

import collections
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOC = ROOT / "docs" / "reference" / "ui-test-surface.md"
PAT = re.compile(r'accessibilityIdentifier(?:\(|\s*=\s*|:\s*)"([^"]+)"')

def classify(files: set[str]) -> str:
    is_ios = any("/iOS/" in f or "/iOSSupport/" in f for f in files)
    is_shared = any("/SharedSupport/" in f for f in files)
    is_mac = any(
        ("/Views/" in f or "/ViewModels/" in f or "/Services/" in f) and "/iOS" not in f
        for f in files
    )
    if is_shared or (is_ios and is_mac):
        return "shared"
    return "ios" if is_ios else "macos"

def collect() -> dict[str, list[tuple[str, list[str]]]]:
    by_id: dict[str, set[str]] = collections.defaultdict(set)
    for f in sorted((ROOT / "Sources").rglob("*.swift")):
        rel = str(f.relative_to(ROOT))
        for m in PAT.finditer(f.read_text(errors="ignore")):
            by_id[m.group(1)].add(rel)
    groups: dict[str, list[tuple[str, list[str]]]] = {"macos": [], "ios": [], "shared": []}
    for ident, files in sorted(by_id.items()):
        groups[classify({f"/{p}" for p in files})].append((ident, sorted(files)))
    return groups

def render(groups: dict[str, list[tuple[str, list[str]]]]) -> str:
    lines = [
        "# UI test surface — accessibilityIdentifier catalog",
        "",
        "**GENERATED — do not edit by hand.** Regenerate after UI changes:",
        "",
        "```sh",
        "python3 scripts/generate_ui_test_surface.py",
        "```",
        "",
        "These identifiers are **stable test surface area** (AGENTS.md Hard rules) and must survive",
        "refactors. They are the semantic reference for what to look for on screen — used by",
        "the macOS Computer Use scenarios, iOS XCUITest/mirroir routes, and review runbooks.",
        "Dynamic ids show their Swift interpolation pattern (e.g. `voicesRow_\\(id)`).",
        "",
    ]
    titles = {
        "macos": "macOS (Vocello.app)",
        "ios": "iOS (VocelloiOS)",
        "shared": "Shared (both platforms)",
    }
    for key in ("macos", "ios", "shared"):
        entries = groups[key]
        lines += [f"## {titles[key]} — {len(entries)} identifiers", ""]
        lines += ["| Identifier | Declared in |", "|---|---|"]
        for ident, files in entries:
            shown = ", ".join(f"`{Path(f).name}`" for f in files)
            lines.append(f"| `{ident}` | {shown} |")
        lines.append("")
    lines += [
        "## Conventions",
        "",
        "- `screen_*` — screen presence markers (leaf elements; never shadow children).",
        "- `sidebar_*` / `rootTab_*` — primary navigation (macOS sidebar / iOS tab dock).",
        "- `textInput_*` — script composer surfaces; `textInput_textEditor` is the main editor.",
        "- `generateSection_*` / `studioChip_*` — iOS Studio mode segments and setup chips.",
        "- `voicesRow_*`, `iosModel*` — dynamic per-item ids (interpolated).",
        "- `*_readiness` markers carry `ready=true/false` in their value for wait-loops.",
        "- macOS scenarios inspect real screen/control state; hidden `mainWindow_*` test markers are prohibited.",
        "",
    ]
    return "\n".join(lines)

def main() -> int:
    content = render(collect())
    if "--check" in sys.argv:
        if not DOC.exists() or DOC.read_text() != content:
            print(f"stale: {DOC} — regenerate with scripts/generate_ui_test_surface.py", file=sys.stderr)
            return 1
        print("ui-test-surface.md is up to date")
        return 0
    DOC.write_text(content)
    print(f"wrote {DOC}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
