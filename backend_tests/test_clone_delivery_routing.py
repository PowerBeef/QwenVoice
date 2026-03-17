from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest
import uuid


ROOT_DIR = pathlib.Path(__file__).resolve().parents[1]
SERVER_PATH = ROOT_DIR / "Sources/Resources/backend/server.py"


class _FakeModel:
    def generate(self, **kwargs):
        raise AssertionError(f"Unexpected legacy fallback path: {kwargs}")


class _FakeCandidate:
    def __init__(self, audio: object = None):
        self.audio = audio if audio is not None else object()
        self.sample_rate = 24000


class CloneDeliveryRoutingTests(unittest.TestCase):
    def test_clone_prewarm_with_transcript_and_tone_uses_guided_prepared_icl(self) -> None:
        module = self.load_server_module()
        module._current_model = _FakeModel()
        module._normalize_clone_reference = lambda path: path
        module._resolve_clone_transcript = lambda clean_ref_audio, requested: requested
        module._get_or_prepare_clone_context = lambda clean_ref_audio, resolved_ref_text: (object(), True)

        calls: dict[str, dict] = {}

        def fake_prepared(model, text, prepared, instruct=None, **kwargs):
            calls["prepared"] = {
                "model": model,
                "text": text,
                "prepared": prepared,
                "instruct": instruct,
                **kwargs,
            }
            yield object()

        def fake_reference(*args, **kwargs):
            calls["reference"] = kwargs
            yield object()

        module._generate_prepared_icl_fn = fake_prepared
        module._generate_reference_conditioned_fn = fake_reference

        result = module._run_model_prewarm(
            "clone",
            instruct="Angry and frustrated tone",
            ref_audio="/tmp/reference.wav",
            ref_text="Hello there",
        )

        self.assertIn("prepared", calls)
        self.assertNotIn("reference", calls)
        self.assertIn("Angry and frustrated tone", calls["prepared"]["instruct"])
        self.assertTrue(result["prepared_clone_used"])
        self.assertTrue(result["delivery_instruction_applied"])
        self.assertEqual(result["delivery_instruction_strategy"], "guided_prepared_icl")
        self.assertEqual(result["delivery_plan_strength"], "medium")

    def test_clone_prewarm_without_transcript_uses_guided_reference_conditioning(self) -> None:
        module = self.load_server_module()
        module._current_model = _FakeModel()
        module._normalize_clone_reference = lambda path: path
        module._resolve_clone_transcript = lambda clean_ref_audio, requested: None
        module._get_or_prepare_clone_context = lambda clean_ref_audio, resolved_ref_text: (None, None)

        calls: dict[str, dict] = {}

        def fake_prepared(*args, **kwargs):
            calls["prepared"] = kwargs
            yield object()

        def fake_reference(model, text, ref_audio=None, ref_text=None, instruct=None, **kwargs):
            calls["reference"] = {
                "model": model,
                "text": text,
                "ref_audio": ref_audio,
                "ref_text": ref_text,
                "instruct": instruct,
                **kwargs,
            }
            yield object()

        module._generate_prepared_icl_fn = fake_prepared
        module._generate_reference_conditioned_fn = fake_reference

        result = module._run_model_prewarm(
            "clone",
            instruct="Happy and upbeat tone",
            ref_audio="/tmp/reference.wav",
            ref_text=None,
        )

        self.assertNotIn("prepared", calls)
        self.assertIn("reference", calls)
        self.assertEqual(calls["reference"]["ref_audio"], "/tmp/reference.wav")
        self.assertIn("Happy and upbeat tone", calls["reference"]["instruct"])
        self.assertFalse(result["prepared_clone_used"])
        self.assertTrue(result["delivery_instruction_applied"])
        self.assertEqual(result["delivery_instruction_strategy"], "guided_reference_conditioning")
        self.assertEqual(result["delivery_plan_strength"], "medium")

    def test_clone_prewarm_with_neutral_tone_preserves_prepared_fast_path(self) -> None:
        module = self.load_server_module()
        module._current_model = _FakeModel()
        module._normalize_clone_reference = lambda path: path
        module._resolve_clone_transcript = lambda clean_ref_audio, requested: requested
        module._get_or_prepare_clone_context = lambda clean_ref_audio, resolved_ref_text: (object(), False)

        calls: dict[str, dict] = {}

        def fake_prepared(model, text, prepared, instruct=None, **kwargs):
            calls["prepared"] = {
                "model": model,
                "text": text,
                "prepared": prepared,
                "instruct": instruct,
                **kwargs,
            }
            yield object()

        def fake_reference(*args, **kwargs):
            calls["reference"] = kwargs
            yield object()

        module._generate_prepared_icl_fn = fake_prepared
        module._generate_reference_conditioned_fn = fake_reference

        result = module._run_model_prewarm(
            "clone",
            instruct="Normal tone",
            ref_audio="/tmp/reference.wav",
            ref_text="Hello there",
        )

        self.assertIn("prepared", calls)
        self.assertNotIn("reference", calls)
        self.assertIsNone(calls["prepared"]["instruct"])
        self.assertTrue(result["prepared_clone_used"])
        self.assertFalse(result["delivery_instruction_applied"])
        self.assertEqual(result["delivery_instruction_strategy"], "neutral_prepared_icl")

    def test_clone_prewarm_identity_key_distinguishes_neutral_and_guided_requests(self) -> None:
        module = self.load_server_module()

        neutral = module._prewarm_identity_key(
            "pro_clone",
            "clone",
            instruct="Normal tone",
            ref_audio="/tmp/reference.wav",
            ref_text="Hello there",
        )
        guided = module._prewarm_identity_key(
            "pro_clone",
            "clone",
            instruct="Happy and upbeat tone",
            ref_audio="/tmp/reference.wav",
            ref_text="Hello there",
        )

        self.assertNotEqual(neutral, guided)

    def test_guided_clone_selection_retries_with_weaker_strength_when_similarity_is_low(self) -> None:
        module = self.load_server_module()
        strengths = []
        similarities = iter([0.71, 0.83])

        def fake_candidate(**kwargs):
            strengths.append(kwargs["plan"].strength_level)
            return _FakeCandidate(), "guided_prepared_icl", True

        module._generate_guided_clone_candidate = fake_candidate
        module._speaker_similarity_reference_vector = lambda path: object()
        module._speaker_similarity_from_generated_audio = lambda reference, audio: next(similarities)

        selection = module._select_guided_clone_candidate(
            text="Hello there",
            clean_ref_audio="/tmp/reference.wav",
            resolved_ref_text="Hello there",
            prepared_context=object(),
            delivery_profile={
                "preset_id": "angry",
                "intensity": "strong",
                "final_instruction": "Furious and intensely angry, sharp and forceful delivery",
            },
            instruct="Furious and intensely angry, sharp and forceful delivery",
            max_tokens=4096,
        )

        self.assertEqual(strengths, ["strong", "medium"])
        self.assertEqual(selection["plan"].strength_level, "medium")
        self.assertEqual(selection["retry_count"], 1)
        self.assertFalse(selection["delivery_compromised"])

    def test_guided_clone_selection_falls_back_when_all_candidates_fail_hard_floor(self) -> None:
        module = self.load_server_module()
        similarities = iter([0.64, 0.68, 0.69])

        module._generate_guided_clone_candidate = lambda **kwargs: (_FakeCandidate(), "guided_prepared_icl", True)
        module._speaker_similarity_reference_vector = lambda path: object()
        module._speaker_similarity_from_generated_audio = lambda reference, audio: next(similarities)

        selection = module._select_guided_clone_candidate(
            text="Hello there",
            clean_ref_audio="/tmp/reference.wav",
            resolved_ref_text="Hello there",
            prepared_context=object(),
            delivery_profile={
                "preset_id": "angry",
                "intensity": "strong",
                "final_instruction": "Furious and intensely angry, sharp and forceful delivery",
            },
            instruct="Furious and intensely angry, sharp and forceful delivery",
            max_tokens=4096,
        )

        self.assertIsNone(selection["result"])
        self.assertEqual(selection["strategy"], "neutral_fallback_after_similarity_guard")
        self.assertEqual(selection["retry_count"], 2)

    def load_server_module(self):
        module_name = f"qwenvoice_server_clone_delivery_{uuid.uuid4().hex}"
        spec = importlib.util.spec_from_file_location(module_name, SERVER_PATH)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = module
        spec.loader.exec_module(module)
        return module


if __name__ == "__main__":
    unittest.main()
