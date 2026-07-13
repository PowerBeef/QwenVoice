#!/usr/bin/env python3
"""Render the CLI shared scheme without asking XcodeGen to scheme a tool target.

XcodeGen 2.45.4 traps while generating a scheme whose buildable is a `tool`
product. The project itself remains generated from project.yml; this narrowly
renders the one affected shared scheme from a checked-in template after XcodeGen
has assigned the native-target blueprint identifier.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path


PLACEHOLDER = "__VOCELLO_CLI_BLUEPRINT_IDENTIFIER__"
TARGET_PATTERN = re.compile(
    r"^\s*([0-9A-F]{24}) /\* VocelloCLI \*/ = \{\n\s*isa = PBXNativeTarget;",
    re.MULTILINE,
)


def render(root: Path) -> tuple[Path, str]:
    project = root / "QwenVoice.xcodeproj" / "project.pbxproj"
    template = root / "config" / "xcode-schemes" / "VocelloCLI.xcscheme.template"
    output = (
        root
        / "QwenVoice.xcodeproj"
        / "xcshareddata"
        / "xcschemes"
        / "VocelloCLI.xcscheme"
    )
    if not project.is_file():
        raise ValueError(f"missing generated project: {project}")
    if not template.is_file():
        raise ValueError(f"missing CLI scheme template: {template}")

    identifiers = TARGET_PATTERN.findall(project.read_text(encoding="utf-8"))
    if len(identifiers) != 1:
        raise ValueError(
            "expected exactly one PBXNativeTarget named VocelloCLI, "
            f"found {len(identifiers)}"
        )
    template_text = template.read_text(encoding="utf-8")
    if template_text.count(PLACEHOLDER) != 3:
        raise ValueError("CLI scheme template must contain exactly three blueprint placeholders")
    return output, template_text.replace(PLACEHOLDER, identifiers[0])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail when the generated scheme drifts")
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help=argparse.SUPPRESS,
    )
    args = parser.parse_args()

    try:
        output, expected = render(args.root.resolve())
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    if args.check:
        actual = output.read_text(encoding="utf-8") if output.is_file() else ""
        if actual != expected:
            print(
                "error: generated VocelloCLI scheme is missing or stale; "
                "run: python3 scripts/generate_cli_scheme.py",
                file=sys.stderr,
            )
            return 1
        print("VocelloCLI shared scheme: PASS")
        return 0

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f"{output.name}.tmp.{os.getpid()}")
    temporary.write_text(expected, encoding="utf-8")
    os.replace(temporary, output)
    print(f"==> Generated {output.relative_to(args.root.resolve())}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
