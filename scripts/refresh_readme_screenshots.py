#!/usr/bin/env python3
"""Explain the manual README screenshot workflow for QwenVoice."""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(
        description="README screenshot capture is now a manual Computer Use workflow."
    )
    parser.add_argument(
        "--output-dir",
        default="docs/screenshots",
        help="Directory where curated screenshots should be stored after manual capture.",
    )
    args = parser.parse_args()

    output_dir = Path(args.output_dir).expanduser().resolve()

    print(
        "\n".join(
            [
                "Automated README screenshot capture has been retired.",
                "",
                "Use the local manual workflow instead:",
                "1. Run ./scripts/check_project_inputs.sh",
                "2. Run python3 scripts/harness.py validate",
                "3. Launch QwenVoice on the intended fixture or live data root",
                "4. Use Codex Computer Use to navigate and capture curated screenshots manually",
                f"5. Save approved screenshots under {output_dir}",
                "",
                "Generated images may be used for explanatory mockups, but not as validation evidence.",
            ]
        )
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
