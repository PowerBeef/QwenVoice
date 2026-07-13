from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "generate_cli_scheme", ROOT / "scripts" / "generate_cli_scheme.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class GenerateCLISchemeTests(unittest.TestCase):
    def fixture(self) -> Path:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        project = root / "QwenVoice.xcodeproj"
        project.mkdir()
        (project / "project.pbxproj").write_text(
            "\t\t0123456789ABCDEF01234567 /* VocelloCLI */ = {\n"
            "\t\t\tisa = PBXNativeTarget;\n"
            "\t\t};\n",
            encoding="utf-8",
        )
        template = root / "config" / "xcode-schemes" / "VocelloCLI.xcscheme.template"
        template.parent.mkdir(parents=True)
        template.write_text(
            "\n".join([MODULE.PLACEHOLDER] * 3) + "\n", encoding="utf-8"
        )
        return root

    def test_render_uses_generated_native_target_identifier(self) -> None:
        output, rendered = MODULE.render(self.fixture())
        self.assertEqual(
            output.name,
            "VocelloCLI.xcscheme",
        )
        self.assertEqual(rendered.count("0123456789ABCDEF01234567"), 3)
        self.assertNotIn(MODULE.PLACEHOLDER, rendered)

    def test_render_rejects_ambiguous_native_target(self) -> None:
        root = self.fixture()
        project = root / "QwenVoice.xcodeproj" / "project.pbxproj"
        project.write_text(project.read_text(encoding="utf-8") * 2, encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            MODULE.render(root)

    def test_render_rejects_template_placeholder_drift(self) -> None:
        root = self.fixture()
        template = root / "config" / "xcode-schemes" / "VocelloCLI.xcscheme.template"
        template.write_text(MODULE.PLACEHOLDER + "\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "exactly three"):
            MODULE.render(root)


if __name__ == "__main__":
    unittest.main()
