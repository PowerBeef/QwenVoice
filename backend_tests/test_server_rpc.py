from __future__ import annotations

import json
import pathlib
import tempfile
import unittest

from harness import BackendServerHarness, ROOT_DIR


class ServerRPCTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = BackendServerHarness()
        self.harness.start()
        self.temp_dir = tempfile.TemporaryDirectory()
        self.app_support_dir = pathlib.Path(self.temp_dir.name)

    def tearDown(self) -> None:
        self.harness.stop()
        self.temp_dir.cleanup()

    def test_ping(self) -> None:
        response = self.harness.send_request("ping")
        self.assertEqual(response["result"]["status"], "ok")

    def test_init_creates_app_support_paths(self) -> None:
        response = self.harness.send_request(
            "init",
            {"app_support_dir": str(self.app_support_dir)},
        )

        self.assertEqual(response["result"]["status"], "ok")
        self.assertTrue((self.app_support_dir / "models").exists())
        self.assertTrue((self.app_support_dir / "outputs").exists())
        self.assertTrue((self.app_support_dir / "voices").exists())

    def test_get_speakers_reflects_shared_contract(self) -> None:
        contract = load_contract()

        response = self.harness.send_request("get_speakers")

        self.assertEqual(response["result"], contract["speakers"])

    def test_get_model_info_reflects_shared_contract(self) -> None:
        contract = load_contract()

        response = self.harness.send_request("get_model_info")

        self.assertEqual(len(response["result"]), len(contract["models"]))
        first_actual = response["result"][0]
        first_expected = contract["models"][0]
        self.assertEqual(first_actual["id"], first_expected["id"])
        self.assertEqual(first_actual["mode"], first_expected["mode"])
        self.assertEqual(first_actual["tier"], first_expected["tier"])
        self.assertEqual(first_actual["output_subfolder"], first_expected["outputSubfolder"])
        self.assertIn("downloaded", first_actual)
        self.assertIn("size_bytes", first_actual)

    def test_list_voices_reads_seeded_voice_fixture(self) -> None:
        voices_dir = self.app_support_dir / "voices"
        voices_dir.mkdir(parents=True)
        (voices_dir / "fixture_voice.wav").write_bytes(b"")
        (voices_dir / "fixture_voice.txt").write_text("fixture transcript", encoding="utf-8")
        self.harness.send_request("init", {"app_support_dir": str(self.app_support_dir)})

        response = self.harness.send_request("list_voices")

        self.assertEqual(len(response["result"]), 1)
        self.assertEqual(response["result"][0]["name"], "fixture_voice")
        self.assertTrue(response["result"][0]["has_transcript"])

    def test_malformed_json_returns_parse_error(self) -> None:
        response = self.harness.send_raw("{not json")

        self.assertEqual(response["error"]["code"], -32700)
        self.assertIn("Parse error", response["error"]["message"])

    def test_unknown_method_returns_method_not_found(self) -> None:
        response = self.harness.send_request("missing_method")

        self.assertEqual(response["error"]["code"], -32601)
        self.assertIn("Method not found", response["error"]["message"])

    def test_generate_without_loaded_model_returns_error(self) -> None:
        response = self.harness.send_request(
            "generate",
            {
                "mode": "design",
                "text": "Hello from tests",
                "instruct": "A calm narrator",
            },
        )

        self.assertEqual(response["error"]["code"], -32000)
        self.assertEqual(response["error"]["message"], "No model loaded. Call load_model first.")


def load_contract() -> dict:
    contract_path = ROOT_DIR / "Sources/Resources/qwenvoice_contract.json"
    return json.loads(contract_path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
