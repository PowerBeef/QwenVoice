#!/usr/bin/env python3

import copy
import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "runtime_security_contract", ROOT / "scripts/runtime_security_contract.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RuntimeSecurityContractTests(unittest.TestCase):
    def test_runtime_debug_registry_covers_production_sources(self) -> None:
        self.assertEqual(MODULE.validate_debug_contract(), [])

    def test_production_affecting_key_must_use_gate_api(self) -> None:
        errors = MODULE.debug_gate_enforcement_errors(
            relative_path="Sources/Example.swift",
            source='let value = environment["QWENVOICE_APP_SUPPORT_DIR"]',
            gated_keys={"QWENVOICE_APP_SUPPORT_DIR"},
            master_gate="QWENVOICE_DEBUG",
        )
        self.assertEqual(len(errors), 1)
        self.assertIn("bypasses RuntimeDebugGate.value", errors[0])

        errors = MODULE.debug_gate_enforcement_errors(
            relative_path="Sources/Example.swift",
            source=(
                'let direct = environment["QWENVOICE_APP_SUPPORT_DIR"]\n'
                'let other = RuntimeDebugGate.value(for: "QWENVOICE_FORCE_MEMORY_CLASS")'
            ),
            gated_keys={"QWENVOICE_APP_SUPPORT_DIR", "QWENVOICE_FORCE_MEMORY_CLASS"},
            master_gate="QWENVOICE_DEBUG",
        )
        self.assertEqual(len(errors), 1)
        self.assertIn("QWENVOICE_APP_SUPPORT_DIR", errors[0])

        self.assertEqual(
            MODULE.debug_gate_enforcement_errors(
                relative_path="Sources/Example.swift",
                source=(
                    'let key = "QWENVOICE_APP_SUPPORT_DIR"\n'
                    "let value = RuntimeDebugGate.value(for: key)"
                ),
                gated_keys={"QWENVOICE_APP_SUPPORT_DIR"},
                master_gate="QWENVOICE_DEBUG",
            ),
            [],
        )

    def test_unchecked_sendable_registry_is_complete(self) -> None:
        self.assertEqual(MODULE.validate_concurrency_contract(), [])

    def test_release_evidence_is_publish_last(self) -> None:
        self.assertEqual(MODULE.validate_release_contract(), [])

    def test_runtime_refactor_contract_is_grounded_for_phase4_shipping(self) -> None:
        self.assertEqual(MODULE.validate_runtime_refactor_contract(), [])

    def test_runtime_refactor_contract_rejects_chunk_and_shadow_drift(self) -> None:
        contract = MODULE.load_json(ROOT / "config/runtime-refactor-contract.json")
        contract["shippingPolicy"] = "run-shadow-generation"
        contract["constrainedTierChunkFrames"]["clone"]["later"] = 7

        errors = MODULE.runtime_refactor_contract_errors(contract)
        self.assertTrue(any("second shadow generation" in error for error in errors))
        self.assertTrue(any("chunk frames drifted" in error for error in errors))

    def test_runtime_refactor_contract_rejects_unverified_or_mixed_shipping_claims(self) -> None:
        contract = MODULE.load_json(ROOT / "config/runtime-refactor-contract.json")
        contract["phaseStatus"]["modeCutover"] = "implemented"
        contract["phaseStatus"]["telemetryV9"] = "shipping"
        contract["phaseStatus"]["engineActor"] = "shipping"
        contract["phase2PublicMutationBoundary"]["status"] = "complete-nonshipping"
        contract["phase2PublicMutationBoundary"]["shippingAuthorityChanged"] = False

        errors = MODULE.runtime_refactor_contract_errors(contract)
        self.assertTrue(any("mode-cutover" in error for error in errors))
        self.assertTrue(any("telemetry v9" in error for error in errors))
        self.assertTrue(any("foundation must ship only through Phase 4" in error for error in errors))
        self.assertTrue(any("shipping-authority change" in error for error in errors))
        self.assertTrue(any("engine actor shipping status" in error for error in errors))

        contract = MODULE.load_json(ROOT / "config/runtime-refactor-contract.json")
        contract["currentShippingAuthorities"]["clone"] = "compatibility-path"
        contract["phase4ProductCutover"]["mixedShippingAuthorityAllowed"] = True
        contract["phase4ProductCutover"]["audioBearingBufferedEventsAllowed"] = True
        contract["phase4ProductCutover"]["physicalIPhoneFocusedAcceptance"] = "pending-device"
        contract["phase4ProductCutover"]["overallPromotion"] = "passed"
        errors = MODULE.runtime_refactor_contract_errors(contract)
        self.assertTrue(any("mixed shipping authority" in error for error in errors))
        self.assertTrue(any("current authorities differ" in error for error in errors))
        self.assertTrue(any("audio-bearing buffered events" in error for error in errors))
        self.assertTrue(any("before all acceptance passes" in error for error in errors))

        contract = MODULE.load_json(ROOT / "config/runtime-refactor-contract.json")
        compatibility = MODULE.load_json(
            ROOT / "Packages/VocelloQwen3Core/COMPATIBILITY.json"
        )
        observed = MODULE.phase2_legacy_spi_product_consumers()
        contract["phase2PublicMutationBoundary"]["legacyShippingSPIConsumers"].pop()
        contract["phase2PublicMutationBoundary"]["cloneHandleLifecycle"][
            "defaultCapacity"
        ] = 2
        drifted_compatibility = copy.deepcopy(compatibility)
        drifted_compatibility["sourceCompatibility"]["stableContracts"].remove(
            "VocelloQwen3CloneHandle"
        )

        errors = MODULE.runtime_refactor_contract_errors(
            contract,
            compatibility=drifted_compatibility,
            observed_spi_consumers=observed,
        )
        self.assertTrue(
            any("SPI consumers differ from COMPATIBILITY" in error for error in errors)
        )
        self.assertTrue(
            any("SPI consumers differ from actual imports" in error for error in errors)
        )
        self.assertTrue(any("clone-handle lifecycle" in error for error in errors))
        self.assertTrue(any("stable contracts" in error for error in errors))

    def test_runtime_refactor_contract_requires_every_numbered_plan_phase(self) -> None:
        for key in (
            "chunkAndPreviewExperiments",
            "runtimeComponentReuse",
            "spokenTextPlanning",
            "longFormV4",
            "boundedAnalyzers",
            "mechanicalRetirement",
        ):
            contract = MODULE.load_json(ROOT / "config/runtime-refactor-contract.json")
            del contract["phaseStatus"][key]
            errors = MODULE.runtime_refactor_contract_errors(contract)
            self.assertTrue(
                any("every convergence phase status" in error for error in errors),
                msg=f"missing {key} was accepted",
            )

    def test_runtime_refactor_contract_rejects_acceptance_only_cutover_claim(self) -> None:
        contract = MODULE.load_json(ROOT / "config/runtime-refactor-contract.json")
        contract["phaseStatus"]["modeCutover"] = "pending-focused-platform-acceptance"

        errors = MODULE.runtime_refactor_contract_errors(contract)
        self.assertTrue(any("mode-cutover" in error for error in errors))

    def test_runtime_refactor_contract_rejects_direct_product_mode_calls(self) -> None:
        contract = MODULE.load_json(ROOT / "config/runtime-refactor-contract.json")
        contract["phase4ProductCutover"]["shippingImplementationSources"].append(
            "Sources/QwenVoiceCore/UnsafeSpeechGenerationModel.swift"
        )

        errors = MODULE.runtime_refactor_contract_errors(contract)
        self.assertTrue(any("invokes direct mode streams" in error for error in errors))

    def test_runtime_refactor_contract_records_overall_promotion_passed(self) -> None:
        contract = MODULE.load_json(ROOT / "config/runtime-refactor-contract.json")
        self.assertEqual(
            contract["reviewCheckpoint"]["promotionEvidence"],
            "overall-promotion-passed-phase0-5-6-closed-canonical-matrices",
        )
        self.assertEqual(
            contract["phase4ProductCutover"]["deterministicVerification"],
            "passed",
        )
        self.assertEqual(
            contract["phase4ProductCutover"]["macosFocusedAcceptance"],
            "passed",
        )
        self.assertEqual(
            contract["phase4ProductCutover"]["physicalIPhoneFocusedAcceptance"],
            "passed",
        )
        self.assertEqual(contract["phase4ProductCutover"]["overallPromotion"], "passed")
        self.assertEqual(
            contract["phaseStatus"]["modeCutover"],
            "implementation-complete-focused-platform-acceptance-passed-"
            "overall-promotion-passed",
        )
        self.assertEqual(MODULE.runtime_refactor_contract_errors(contract), [])

        contract["reviewCheckpoint"]["promotionEvidence"] = (
            "focused-platform-acceptance-passed-overall-promotion-pending"
        )
        errors = MODULE.runtime_refactor_contract_errors(contract)
        self.assertTrue(any("promotion evidence must match" in error for error in errors))

    def test_security_adrs_exist(self) -> None:
        self.assertEqual(MODULE.validate_docs(), [])


if __name__ == "__main__":
    unittest.main()
