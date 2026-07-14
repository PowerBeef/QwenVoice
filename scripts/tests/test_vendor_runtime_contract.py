#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("vendor_runtime_contract", ROOT / "scripts/vendor_runtime_contract.py")
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class VendorRuntimeContractTests(unittest.TestCase):
    def test_repository_contract_is_valid(self) -> None:
        self.assertEqual(MODULE.validate(ROOT), [])

    def test_every_changed_retained_file_has_semantic_coverage(self) -> None:
        vendor = ROOT / MODULE.VENDOR_RELATIVE
        baseline = MODULE.load_json(vendor / MODULE.BASELINE_NAME)
        ledger = MODULE.load_json(vendor / MODULE.PATCHES_NAME)
        patterns = [pattern for patch in ledger["patches"] for pattern in patch["files"]]
        changed = []
        for entry in baseline["entries"]:
            path = vendor / entry["path"]
            if entry["upstreamSHA256"] is None or MODULE.sha256(path) != entry["upstreamSHA256"]:
                changed.append(entry["path"])
        self.assertTrue(changed)
        self.assertEqual([path for path in changed if not MODULE.matches(path, patterns)], [])

    def test_baseline_builder_is_deterministic(self) -> None:
        vendor = ROOT / MODULE.VENDOR_RELATIVE
        manifest = MODULE.load_json(vendor / MODULE.MANIFEST_NAME)
        baseline = MODULE.load_json(vendor / MODULE.BASELINE_NAME)
        # Reusing the vendor as a synthetic upstream proves ordering/shape without network access.
        rebuilt = MODULE.make_baseline(vendor, vendor, manifest["importBaseline"]["commit"])
        self.assertEqual([entry["path"] for entry in rebuilt["entries"]], [entry["path"] for entry in baseline["entries"]])


if __name__ == "__main__":
    unittest.main()
