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
        self.assertIn("mlx_audio_version", first_actual)
        self.assertIn("supports_streaming", first_actual)
        self.assertIn("supports_prepared_clone", first_actual)
        self.assertIn("supports_clone_streaming", first_actual)
        self.assertIn("supports_batch", first_actual)

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

    def test_load_model_reports_capabilities_for_installed_custom_model(self) -> None:
        if not model_is_installed("pro_custom"):
            self.skipTest("Custom Voice model is not installed locally")

        response = self.harness.send_request("load_model", {"model_id": "pro_custom"})

        self.assertTrue(response["result"]["success"])
        self.assertEqual(response["result"]["model_id"], "pro_custom")
        self.assertEqual(response["result"]["mlx_audio_version"], "0.4.0.post1")
        self.assertTrue(response["result"]["supports_streaming"])
        self.assertTrue(response["result"]["supports_batch"])
        self.assertFalse(response["result"]["supports_prepared_clone"])
        self.assertFalse(response["result"]["supports_clone_streaming"])

    def test_streaming_generate_emits_chunk_notifications_and_metrics_for_custom_model(self) -> None:
        if not model_is_installed("pro_custom"):
            self.skipTest("Custom Voice model is not installed locally")

        self.harness.send_request("load_model", {"model_id": "pro_custom"})

        output_path = self.app_support_dir / "outputs" / "custom_stream.wav"
        output_path.parent.mkdir(parents=True, exist_ok=True)

        response, notifications = self.harness.send_request_collect_notifications(
            "generate",
            {
                "mode": "custom",
                "text": "Streaming backend test.",
                "voice": load_contract()["defaultSpeaker"],
                "instruct": "Normal tone",
                "speed": 1.0,
                "stream": True,
                "streaming_interval": 0.32,
                "output_path": str(output_path),
            },
        )

        chunk_notifications = [
            message
            for message in notifications
            if message.get("method") == "generation_chunk"
        ]
        self.assertTrue(chunk_notifications, "Expected generation_chunk notifications")
        first_chunk = chunk_notifications[0]["params"]
        self.assertIn("chunk_duration_seconds", first_chunk)
        self.assertIn("cumulative_duration_seconds", first_chunk)
        self.assertIn("stream_session_dir", first_chunk)
        self.assertTrue(output_path.exists())

        metrics = response["result"]["metrics"]
        self.assertTrue(metrics["streaming_used"])
        self.assertIn("first_chunk_ms", metrics)
        self.assertIn("processing_time_seconds", metrics)
        self.assertIn("peak_memory_usage", metrics)
        self.assertEqual(response["result"]["stream_session_dir"], first_chunk["stream_session_dir"])


def load_contract() -> dict:
    contract_path = ROOT_DIR / "Sources/Resources/qwenvoice_contract.json"
    return json.loads(contract_path.read_text(encoding="utf-8"))


def model_is_installed(model_id: str) -> bool:
    contract = load_contract()
    model = next(item for item in contract["models"] if item["id"] == model_id)
    model_dir = pathlib.Path.home() / "Library/Application Support/QwenVoice/models" / model["folder"]
    return model_dir.exists()


if __name__ == "__main__":
    unittest.main()
