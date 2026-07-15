#!/usr/bin/env python3

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

    def test_security_adrs_exist(self) -> None:
        self.assertEqual(MODULE.validate_docs(), [])


if __name__ == "__main__":
    unittest.main()
