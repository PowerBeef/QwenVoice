#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts/check_convergence_promotion_gate.py"
SPEC = importlib.util.spec_from_file_location("check_convergence_promotion_gate", HELPER)
assert SPEC and SPEC.loader
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class ConvergencePromotionGateTests(unittest.TestCase):
    def test_current_checkout_passes(self) -> None:
        self.assertEqual(GATE.errors(), [])

    def test_rejects_premature_overall_promotion(self) -> None:
        contract = json.loads((ROOT / "config/runtime-refactor-contract.json").read_text(encoding="utf-8"))
        contract["phase4ProductCutover"]["overallPromotion"] = "passed"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "config").mkdir()
            contract_path = root / "config/runtime-refactor-contract.json"
            fixtures_path = root / "config/characterization-fixtures.json"
            contract_path.write_text(json.dumps(contract), encoding="utf-8")
            fixtures_path.write_text(
                (ROOT / "config/characterization-fixtures.json").read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            original_contract = GATE.CONTRACT
            original_fixtures = GATE.CHARACTERIZATION
            try:
                GATE.CONTRACT = contract_path
                GATE.CHARACTERIZATION = fixtures_path
                errors = GATE.errors()
            finally:
                GATE.CONTRACT = original_contract
                GATE.CHARACTERIZATION = original_fixtures
        self.assertTrue(any("Phase 5" in item for item in errors))
        self.assertTrue(any("telemetry" in item for item in errors))
        # Phase 0 is closed in the current checkout; it must not keep blocking
        # once characterizationContract no longer says pending/partial.
        self.assertFalse(any("Phase 0" in item for item in errors))

    def test_rejects_promotion_while_characterization_pending(self) -> None:
        contract = json.loads((ROOT / "config/runtime-refactor-contract.json").read_text(encoding="utf-8"))
        contract["phase4ProductCutover"]["overallPromotion"] = "passed"
        contract["phaseStatus"]["characterizationContract"] = (
            "partial-model-free-fixtures-present-exact-mode-token-pcm-and-clean-controls-pending"
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "config").mkdir()
            contract_path = root / "config/runtime-refactor-contract.json"
            fixtures_path = root / "config/characterization-fixtures.json"
            contract_path.write_text(json.dumps(contract), encoding="utf-8")
            fixtures_path.write_text(
                (ROOT / "config/characterization-fixtures.json").read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            original_contract = GATE.CONTRACT
            original_fixtures = GATE.CHARACTERIZATION
            try:
                GATE.CONTRACT = contract_path
                GATE.CHARACTERIZATION = fixtures_path
                errors = GATE.errors()
            finally:
                GATE.CONTRACT = original_contract
                GATE.CHARACTERIZATION = original_fixtures
        self.assertTrue(any("Phase 0" in item for item in errors))

    def test_allows_live_characterization_status_progress(self) -> None:
        fixtures = json.loads(
            (ROOT / "config/characterization-fixtures.json").read_text(encoding="utf-8")
        )
        fixtures["status"] = "live-characterization-active"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "config").mkdir()
            contract_path = root / "config/runtime-refactor-contract.json"
            fixtures_path = root / "config/characterization-fixtures.json"
            contract_path.write_text(
                (ROOT / "config/runtime-refactor-contract.json").read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            fixtures_path.write_text(json.dumps(fixtures), encoding="utf-8")
            original_contract = GATE.CONTRACT
            original_fixtures = GATE.CHARACTERIZATION
            try:
                GATE.CONTRACT = contract_path
                GATE.CHARACTERIZATION = fixtures_path
                errors = GATE.errors()
            finally:
                GATE.CONTRACT = original_contract
                GATE.CHARACTERIZATION = original_fixtures
        self.assertEqual(errors, [])

    def test_rejects_unknown_characterization_status(self) -> None:
        fixtures = json.loads(
            (ROOT / "config/characterization-fixtures.json").read_text(encoding="utf-8")
        )
        fixtures["status"] = "not-a-real-status"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "config").mkdir()
            contract_path = root / "config/runtime-refactor-contract.json"
            fixtures_path = root / "config/characterization-fixtures.json"
            contract_path.write_text(
                (ROOT / "config/runtime-refactor-contract.json").read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            fixtures_path.write_text(json.dumps(fixtures), encoding="utf-8")
            original_contract = GATE.CONTRACT
            original_fixtures = GATE.CHARACTERIZATION
            try:
                GATE.CONTRACT = contract_path
                GATE.CHARACTERIZATION = fixtures_path
                errors = GATE.errors()
            finally:
                GATE.CONTRACT = original_contract
                GATE.CHARACTERIZATION = original_fixtures
        self.assertTrue(any("characterization fixtures status" in item for item in errors))


if __name__ == "__main__":
    unittest.main()
