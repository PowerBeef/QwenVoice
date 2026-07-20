#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts/check_sampling_promotion_evidence.py"
SPEC = importlib.util.spec_from_file_location("check_sampling_promotion_evidence", HELPER)
assert SPEC and SPEC.loader
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class SamplingPromotionEvidenceTests(unittest.TestCase):
    def test_packaged_notes_pass(self) -> None:
        notes = {
            "samplingPromotionPackaged": "true",
            "samplingAlgorithmVersion": "2",
            "samplingPlannedSeed": "42",
            "samplingObservedSeed": "42",
            "samplingSeed": "42",
            "samplingSeedAgreement": "matched",
            "samplingWAVDigest": "ab" * 32,
            "samplingSeedSource": "requested",
        }
        self.assertEqual(CHECK.evaluate_notes(notes, "row"), [])

    def test_incomplete_notes_fail(self) -> None:
        notes = {
            "samplingAlgorithmVersion": "2",
            "samplingPlannedSeed": "42",
            "samplingObservedSeed": "42",
            "samplingWAVDigest": "ab" * 32,
        }
        findings = CHECK.evaluate_notes(notes, "row")
        self.assertTrue(any("samplingPromotionPackaged" in item for item in findings))

    def test_jsonl_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "generations.jsonl"
            row = {
                "generationID": "g1",
                "notes": {
                    "samplingPromotionPackaged": "true",
                    "samplingAlgorithmVersion": "2",
                    "samplingPlannedSeed": "1",
                    "samplingObservedSeed": "1",
                    "samplingSeedAgreement": "matched",
                    "samplingWAVDigest": "cd" * 32,
                    "samplingSeedSource": "generated",
                },
            }
            path.write_text(json.dumps(row) + "\n", encoding="utf-8")
            self.assertEqual(CHECK.evaluate_path(path), [])


if __name__ == "__main__":
    unittest.main()
