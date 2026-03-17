from __future__ import annotations

import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest import mock


ROOT_DIR = pathlib.Path(__file__).resolve().parents[1]
SCRIPT_PATH = ROOT_DIR / "scripts" / "evaluate_clone_tone.py"


class EvaluateCloneToneTests(unittest.TestCase):
    def test_build_scenarios_creates_expected_eight_guided_comparisons(self) -> None:
        module = self.load_script_module()

        scenarios = module.build_scenarios(
            transcripted_ref_audio=pathlib.Path("/tmp/transcripted.wav"),
            transcripted_ref_text="Reference transcript",
            no_transcript_ref_audio=pathlib.Path("/tmp/no_transcript.wav"),
        )

        self.assertEqual(len(scenarios), 8)
        self.assertEqual(
            {scenario.path_kind for scenario in scenarios},
            {"transcripted", "no_transcript"},
        )
        self.assertIn("transcripted_angry_strong", {scenario.scenario_id for scenario in scenarios})
        self.assertIn("no_transcript_custom_brisk", {scenario.scenario_id for scenario in scenarios})

    def test_extract_json_payload_handles_wrapped_cli_json(self) -> None:
        module = self.load_script_module()

        raw_output = json.dumps(
            {
                "response": json.dumps(
                    {
                        "scenario_id": "transcripted_angry_strong",
                        "path_kind": "transcripted",
                        "requested_tone": "angry / strong",
                        "relative_contrast": "stronger",
                        "target_match": "clear",
                        "speaker_consistency": "preserved",
                        "confidence": "high",
                        "pass": True,
                        "notes": "Clear contrast.",
                    }
                )
            }
        )

        evaluation = module.parse_gemini_evaluation(raw_output)

        self.assertEqual(evaluation.relative_contrast, "stronger")
        self.assertTrue(evaluation.passed)

    def test_parse_auth_check_handles_wrapped_cli_json(self) -> None:
        module = self.load_script_module()

        raw_output = json.dumps(
            {
                "session_id": "abc123",
                "response": '{"ok":true}',
            }
        )

        payload = module.parse_auth_check(raw_output)

        self.assertEqual(payload, {"ok": True})

    def test_extract_json_payload_handles_markdown_fenced_json(self) -> None:
        module = self.load_script_module()

        raw_output = """```json
{
  "scenario_id": "no_transcript_happy_normal",
  "path_kind": "no_transcript",
  "requested_tone": "happy / normal",
  "relative_contrast": "slightly_stronger",
  "target_match": "partial",
  "speaker_consistency": "preserved",
  "confidence": "medium",
  "pass": true,
  "notes": "A modest but real change."
}
```"""

        evaluation = module.parse_gemini_evaluation(raw_output)

        self.assertEqual(evaluation.path_kind, "no_transcript")
        self.assertEqual(evaluation.target_match, "partial")

    def test_summarize_results_applies_threshold_and_speaker_guard(self) -> None:
        module = self.load_script_module()

        results = []
        for index in range(8):
            results.append(
                {
                    "scenario_id": f"scenario_{index}",
                    "path_kind": "transcripted",
                    "requested_tone": "happy / normal",
                    "relative_contrast": "stronger",
                    "target_match": "clear",
                    "speaker_consistency": "preserved",
                    "confidence": "high",
                    "pass": index < 6,
                }
            )

        summary = module.summarize_results(results)
        self.assertTrue(summary["overall_pass"])

        results[-1]["speaker_consistency"] = "changed"
        summary = module.summarize_results(results)
        self.assertFalse(summary["overall_pass"])

    def test_write_summary_markdown_includes_key_headers(self) -> None:
        module = self.load_script_module()

        summary = {
            "scenario_count": 8,
            "pass_count": 6,
            "fail_count": 2,
            "speaker_changed": False,
            "overall_pass": True,
        }
        rows = [
            {
                "scenario_id": "transcripted_angry_strong",
                "path_kind": "transcripted",
                "requested_tone": "angry / strong",
                "relative_contrast": "stronger",
                "target_match": "clear",
                "speaker_consistency": "preserved",
                "confidence": "high",
                "pass": True,
            }
        ]
        judge_backend = {
            "binary_path": "/opt/homebrew/bin/gemini",
            "homebrew_path_injected": True,
            "model_fallback_order": ["gemini-3.1-pro-preview", "gemini-2.5-pro", "gemini-2.5-flash"],
            "auth_check_model_used": "gemini-2.5-flash",
        }

        markdown = module.write_summary_markdown(summary, rows, judge_backend)

        self.assertIn("# Voice Cloning Tone Evaluation", markdown)
        self.assertIn("## Judge Backend", markdown)
        self.assertIn("| Scenario | Path | Tone |", markdown)
        self.assertIn("transcripted_angry_strong", markdown)
        self.assertIn("/opt/homebrew/bin/gemini", markdown)

    def test_write_json_writes_pretty_json(self) -> None:
        module = self.load_script_module()
        with tempfile.TemporaryDirectory() as temp_dir:
            output_path = pathlib.Path(temp_dir) / "summary.json"
            module.write_json(output_path, {"ok": True, "count": 2})

            content = output_path.read_text(encoding="utf-8")
            self.assertIn('"ok": true', content)
            self.assertTrue(content.endswith("\n"))

    def test_resolve_gemini_binary_requires_homebrew_node(self) -> None:
        module = self.load_script_module()
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = pathlib.Path(temp_dir)
            fake_bin_dir = temp_root / "bin"
            fake_bin_dir.mkdir()
            fake_gemini = fake_bin_dir / "gemini"
            fake_gemini.write_text("#!/bin/sh\n", encoding="utf-8")
            fake_gemini.chmod(0o755)

            with mock.patch.object(module, "HOMEBREW_BIN_DIR", fake_bin_dir), mock.patch.object(
                module, "HOMEBREW_NODE_PATH", fake_bin_dir / "node"
            ):
                with self.assertRaises(module.InfrastructureFailure) as context:
                    module.resolve_gemini_binary(str(fake_gemini))

            self.assertIn("requires", str(context.exception))

    def test_build_gemini_env_prepends_homebrew_bin(self) -> None:
        module = self.load_script_module()
        with tempfile.TemporaryDirectory() as temp_dir:
            fake_homebrew = pathlib.Path(temp_dir)
            with mock.patch.object(module, "HOMEBREW_BIN_DIR", fake_homebrew):
                with mock.patch.dict(module.os.environ, {"PATH": "/usr/bin:/bin"}, clear=True):
                    env = module.build_gemini_env()

        self.assertEqual(env["PATH"], f"{fake_homebrew}:/usr/bin:/bin")
        self.assertEqual(env["NO_COLOR"], "1")
        self.assertEqual(env["CI"], "1")

    def test_evaluate_with_gemini_falls_back_on_capacity_error(self) -> None:
        module = self.load_script_module()
        success_payload = json.dumps(
            {
                "scenario_id": "transcripted_angry_strong",
                "path_kind": "transcripted",
                "requested_tone": "angry / strong",
                "relative_contrast": "stronger",
                "target_match": "clear",
                "speaker_consistency": "preserved",
                "confidence": "high",
                "pass": True,
                "notes": "Clear contrast.",
            }
        )

        with tempfile.TemporaryDirectory() as temp_dir:
            scenario_dir = pathlib.Path(temp_dir)
            with mock.patch.object(module.subprocess, "run") as run_mock:
                run_mock.side_effect = [
                    subprocess.CompletedProcess(
                        args=["gemini"],
                        returncode=1,
                        stdout="",
                        stderr="429 MODEL_CAPACITY_EXHAUSTED",
                    ),
                    subprocess.CompletedProcess(
                        args=["gemini"],
                        returncode=0,
                        stdout=success_payload,
                        stderr="",
                    ),
                ]

                evaluation, _raw_output, metadata = module.evaluate_with_gemini(
                    gemini_binary="/opt/homebrew/bin/gemini",
                    gemini_model="gemini-3.1-pro-preview",
                    scenario_dir=scenario_dir,
                )

        self.assertEqual(evaluation.relative_contrast, "stronger")
        self.assertEqual(metadata["gemini_model_used"], "gemini-2.5-pro")
        self.assertEqual(metadata["gemini_attempt_count"], 2)
        self.assertEqual(len(metadata["gemini_attempts"]), 2)

    def test_evaluate_with_gemini_stops_on_non_capacity_failure(self) -> None:
        module = self.load_script_module()
        with tempfile.TemporaryDirectory() as temp_dir:
            scenario_dir = pathlib.Path(temp_dir)
            with mock.patch.object(module.subprocess, "run") as run_mock:
                run_mock.return_value = subprocess.CompletedProcess(
                    args=["gemini"],
                    returncode=1,
                    stdout="",
                    stderr="authentication failed",
                )

                with self.assertRaises(module.GeminiCLIInfrastructureFailure) as context:
                    module.evaluate_with_gemini(
                        gemini_binary="/opt/homebrew/bin/gemini",
                        gemini_model="gemini-3.1-pro-preview",
                        scenario_dir=scenario_dir,
                    )

        self.assertIn("authentication failed", str(context.exception))
        self.assertEqual(len(context.exception.attempts), 1)
        self.assertEqual(context.exception.attempts[0]["model"], "gemini-3.1-pro-preview")

    def test_build_judge_backend_summary_reports_scenario_models(self) -> None:
        module = self.load_script_module()

        summary = module.build_judge_backend_summary(
            gemini_binary="/opt/homebrew/bin/gemini",
            primary_model="gemini-3.1-pro-preview",
            auth_metadata={"gemini_model_used": "gemini-3.1-pro-preview", "gemini_attempt_count": 1},
            results=[
                {"scenario_id": "transcripted_angry_strong", "gemini_model_used": "gemini-3.1-pro-preview"},
                {"scenario_id": "no_transcript_happy_normal", "gemini_model_used": "gemini-2.5-flash"},
            ],
        )

        self.assertEqual(summary["binary_path"], "/opt/homebrew/bin/gemini")
        self.assertTrue(summary["homebrew_path_injected"])
        self.assertEqual(
            summary["model_fallback_order"],
            ["gemini-3.1-pro-preview", "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite"],
        )
        self.assertEqual(summary["scenario_models"]["no_transcript_happy_normal"], "gemini-2.5-flash")

    def load_script_module(self):
        module_name = f"qwenvoice_evaluate_clone_tone_{uuid.uuid4().hex}"
        spec = importlib.util.spec_from_file_location(module_name, SCRIPT_PATH)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = module
        spec.loader.exec_module(module)
        return module


if __name__ == "__main__":
    unittest.main()
