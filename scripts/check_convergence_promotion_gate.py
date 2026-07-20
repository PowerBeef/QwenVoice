#!/usr/bin/env python3
"""Fail closed when overall Phase 4 promotion is claimed before Phase 5/6/0 readiness."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "config/runtime-refactor-contract.json"
CHARACTERIZATION = ROOT / "config/characterization-fixtures.json"

PHASE6_TRANSITION = (
    "partial-transition-projection-embedded-in-v8-"
    "live-producers-landed-history-authority-pending"
)
PHASE6_CLOSED = "complete-sidecar-authority-with-v8-envelope"
PHASE5_CLOSED = "shipping-promotion-packaged-evidence-live"

# Phase 0 statuses advance as live captures land. Do not freeze forever at
# model-free-foundation or promotion will block real characterization updates.
CHARACTERIZATION_STATUSES = frozenset(
    {
        "model-free-foundation",
        "live-captures-partial",
        "live-characterization-active",
        "closed",
    }
)


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def errors() -> list[str]:
    findings: list[str] = []
    contract = load(CONTRACT)
    phases = contract.get("phaseStatus") or {}
    phase4 = contract.get("phase4ProductCutover") or {}
    versions = contract.get("contractVersions") or {}

    if phase4.get("overallPromotion") == "passed":
        sampling = str(phases.get("requestLocalSamplingV2") or "")
        if "pending" in sampling or sampling != PHASE5_CLOSED:
            findings.append(
                "overall Phase 4 promotion cannot pass before Phase 5 live evidence closes"
            )
        if (
            phases.get("telemetryV9") == PHASE6_TRANSITION
            or phases.get("telemetryV9") != PHASE6_CLOSED
            or versions.get("telemetry") != 9
        ):
            findings.append(
                "overall Phase 4 promotion cannot pass while telemetry remains v8/"
                "partial-v9-transition"
            )
        characterization = str(phases.get("characterizationContract") or "")
        if characterization != "closed-clean-control-sessions-bound":
            findings.append(
                "overall Phase 4 promotion cannot pass before Phase 0 characterization closes"
            )

    if not CHARACTERIZATION.is_file():
        findings.append("missing config/characterization-fixtures.json")
        return findings

    fixtures = load(CHARACTERIZATION)
    required_ids = {
        "custom-speed-short-control",
        "design-speed-short-control",
        "clone-speed-short-control",
        "custom-speed-longform-manifest-v3",
    }
    present = {entry.get("id") for entry in fixtures.get("fixtures") or []}
    missing = sorted(required_ids - present)
    if missing:
        findings.append(
            "characterization fixtures missing required ids: " + ", ".join(missing)
        )
    status = fixtures.get("status")
    if status not in CHARACTERIZATION_STATUSES:
        findings.append(
            "characterization fixtures status must be one of: "
            + ", ".join(sorted(CHARACTERIZATION_STATUSES))
            + f" (got {status!r})"
        )
    if phase4.get("overallPromotion") == "passed" and status != "closed":
        findings.append(
            "overall Phase 4 promotion cannot pass before characterization fixtures close"
        )
    return findings


def main() -> int:
    findings = errors()
    if findings:
        for item in findings:
            print(f"error: {item}", file=sys.stderr)
        return 1
    print("Convergence promotion gate: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
