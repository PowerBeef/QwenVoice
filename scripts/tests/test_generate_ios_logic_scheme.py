from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "generate_ios_logic_scheme", ROOT / "scripts/generate_ios_logic_scheme.py"
)
assert SPEC and SPEC.loader
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


class IOSLogicSchemeGeneratorTests(unittest.TestCase):
    def test_renderer_binds_generated_target_identifier(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project = root / "QwenVoice.xcodeproj"
            project.mkdir(parents=True)
            identifier = "A" * 24
            (project / "project.pbxproj").write_text(
                f"\t\t{identifier} /* VocelloiOSLogicTests */ = {{\n\t\t\tisa = PBXNativeTarget;\n",
                encoding="utf-8",
            )
            template = root / "config/xcode-schemes/VocelloiOSLogic.xcscheme.template"
            template.parent.mkdir(parents=True)
            template.write_text(
                f"{GENERATOR.PLACEHOLDER}\n{GENERATOR.PLACEHOLDER}\n",
                encoding="utf-8",
            )

            output, rendered = GENERATOR.render(root)
            self.assertEqual(output.name, "VocelloiOSLogic.xcscheme")
            self.assertNotIn(GENERATOR.PLACEHOLDER, rendered)
            self.assertEqual(rendered.count(identifier), 2)


if __name__ == "__main__":
    unittest.main()
