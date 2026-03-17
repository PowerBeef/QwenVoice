from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest
import uuid


ROOT_DIR = pathlib.Path(__file__).resolve().parents[1]
PIPELINE_PATH = ROOT_DIR / "Sources/Resources/backend/clone_delivery_pipeline.py"


class CloneDeliveryPipelineTests(unittest.TestCase):
    def test_strong_preset_plan_builds_expressive_instruction_and_ladder(self) -> None:
        module = self.load_pipeline_module()

        plan = module.build_clone_delivery_plan(
            {
                "preset_id": "angry",
                "intensity": "strong",
                "final_instruction": "Furious and intensely angry, sharp and forceful delivery",
            },
            "Hello there",
            has_reference_transcript=True,
        )

        self.assertIsNotNone(plan)
        self.assertEqual(plan.strength_level, "strong")
        self.assertEqual(plan.fallback_ladder, ["strong", "medium", "light"])
        self.assertIn("intense anger", plan.compiled_instruction.lower())
        self.assertEqual(plan.styled_text, "Hello there!")
        self.assertTrue(plan.styled_text_applied)

    def test_custom_tone_defaults_to_medium_strength(self) -> None:
        module = self.load_pipeline_module()

        plan = module.build_clone_delivery_plan(
            {
                "custom_text": "tight, suspicious, almost whispered delivery",
                "final_instruction": "tight, suspicious, almost whispered delivery",
            },
            "We should leave now",
            has_reference_transcript=False,
        )

        self.assertIsNotNone(plan)
        self.assertEqual(plan.strength_level, "medium")
        self.assertEqual(plan.fallback_ladder, ["medium", "light"])
        self.assertIn("requested style", plan.compiled_instruction.lower())
        self.assertEqual(plan.styled_text, "We should leave now.")

    def test_neutral_profile_returns_none(self) -> None:
        module = self.load_pipeline_module()

        plan = module.build_clone_delivery_plan(
            {
                "preset_id": "neutral",
                "final_instruction": "Normal tone",
            },
            "Hello there",
            has_reference_transcript=True,
        )

        self.assertIsNone(plan)

    def test_strength_override_rebuilds_sampling_and_styling(self) -> None:
        module = self.load_pipeline_module()

        strong = module.build_clone_delivery_plan(
            {
                "preset_id": "dramatic",
                "intensity": "strong",
                "final_instruction": "Highly dramatic, theatrical voice with bold pauses and sweeping intensity",
            },
            "This changes everything",
            has_reference_transcript=True,
        )
        light = module.build_clone_delivery_plan(
            {
                "preset_id": "dramatic",
                "intensity": "strong",
                "final_instruction": "Highly dramatic, theatrical voice with bold pauses and sweeping intensity",
            },
            "This changes everything",
            has_reference_transcript=True,
            strength_override="light",
        )

        self.assertIsNotNone(strong)
        self.assertIsNotNone(light)
        self.assertNotEqual(strong.strength_level, light.strength_level)
        self.assertNotEqual(strong.sampling_profile["temperature"], light.sampling_profile["temperature"])

    def load_pipeline_module(self):
        module_name = f"qwenvoice_clone_delivery_pipeline_{uuid.uuid4().hex}"
        spec = importlib.util.spec_from_file_location(module_name, PIPELINE_PATH)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = module
        spec.loader.exec_module(module)
        return module


if __name__ == "__main__":
    unittest.main()
