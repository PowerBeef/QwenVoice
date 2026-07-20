#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts/check_streaming_telemetry_v9_history.py"
SPEC = importlib.util.spec_from_file_location("check_streaming_telemetry_v9_history", HELPER)
assert SPEC and SPEC.loader
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class StreamingTelemetryV9HistoryTests(unittest.TestCase):
    def test_publication_ready_jsonl_with_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "generations.jsonl"
            row = {
                "generationID": "g1",
                "notes": {
                    "streamingTelemetryV9PublicationReady": "true",
                    "streamingTelemetryV9SidecarDigest": "ab" * 32,
                },
                "streamingTelemetryV9": {"schemaVersion": 9},
            }
            path.write_text(json.dumps(row) + "\n", encoding="utf-8")
            self.assertEqual(CHECK.evaluate_generations(path), [])

    def test_complete_sidecar_dir(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            sidecar = directory / "g1.streaming-telemetry-v9.json"
            payload = {"schemaVersion": 9, "generationID": "g1"}
            sidecar.write_text(json.dumps(payload), encoding="utf-8")
            digest = hashlib.sha256(sidecar.read_bytes()).hexdigest()
            self.assertEqual(len(digest), 64)
            self.assertEqual(CHECK.evaluate_sidecar_dir(directory), [])

    def test_empty_sidecar_dir_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            findings = CHECK.evaluate_sidecar_dir(Path(temporary))
            self.assertTrue(any("no complete v9 sidecars" in item for item in findings))


if __name__ == "__main__":
    unittest.main()
