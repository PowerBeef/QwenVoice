#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
HELPER = REPO_ROOT / "scripts/documentation_contract.py"
SPEC = importlib.util.spec_from_file_location("documentation_contract", HELPER)
assert SPEC and SPEC.loader
DOCUMENTATION = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = DOCUMENTATION
SPEC.loader.exec_module(DOCUMENTATION)


class DocumentationContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "config").mkdir(parents=True)
        (self.root / "config/build-output-policy.json").write_text(
            json.dumps(
                {
                    "entries": [
                        {"path": "build/cache/xcode/macos"},
                        {"path": "build/artifacts/macos"},
                        {"path": "build/dist/macos"},
                    ],
                    "publicLinks": [
                        {"path": "build/Vocello.app"},
                        {"path": "build/vocello"},
                    ],
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write(self, relative: str, text: str) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def test_active_inventory_includes_nested_guidance_and_excludes_history(self) -> None:
        active = self.write("website/AGENTS.md", "# Current\n")
        release = self.write("docs/releases/v2.0.0.md", "retired harness instructions\n")
        legacy = self.write("benchmarks/LEGACY_HISTORY.md", "retired harness instructions\n")
        paths = DOCUMENTATION.active_markdown_paths(self.root)
        self.assertIn(active, paths)
        self.assertNotIn(release, paths)
        self.assertNotIn(legacy, paths)

    def test_missing_link_and_script_are_rejected(self) -> None:
        source = self.write(
            "README.md",
            "[missing](docs/missing.md) and `scripts/missing_tool.sh`\n",
        )
        self.assertTrue(DOCUMENTATION.validate_relative_links(self.root, [source]))
        self.assertTrue(DOCUMENTATION.validate_script_references(self.root, [source]))
        self.write("docs/missing.md", "# Found\n")
        self.write("scripts/missing_tool.sh", "#!/bin/sh\n")
        self.assertEqual(DOCUMENTATION.validate_relative_links(self.root, [source]), [])
        self.assertEqual(DOCUMENTATION.validate_script_references(self.root, [source]), [])

    def test_stale_inline_repository_path_is_rejected(self) -> None:
        source = self.write("README.md", "Use `config/missing-contract.json`.\n")
        self.assertTrue(DOCUMENTATION.validate_repository_paths(self.root, [source]))
        self.write("config/missing-contract.json", "{}\n")
        self.assertEqual(DOCUMENTATION.validate_repository_paths(self.root, [source]), [])

    def test_only_manifest_owned_build_paths_are_documented(self) -> None:
        source = self.write(
            "README.md",
            "Valid `build/artifacts/macos/run` and `build/Vocello.app`; "
            "invalid `build/random-derived-data/run`.\n",
        )
        errors = DOCUMENTATION.validate_build_references(self.root, [source])
        self.assertEqual(len(errors), 1)
        self.assertIn("build/random-derived-data/run", errors[0])

    def test_transient_plugin_installation_cannot_be_claimed(self) -> None:
        source = self.write(
            "AGENTS.md",
            "Use the installed GitHub integration. OpenAI Build iOS Apps supplies the server.\n",
        )
        errors = DOCUMENTATION.validate_optional_capabilities(self.root, [source])
        self.assertEqual(len(errors), 2)
        source.write_text(
            "Use GitHub when callable, otherwise gh. Use one shared server when available.\n",
            encoding="utf-8",
        )
        self.assertEqual(DOCUMENTATION.validate_optional_capabilities(self.root, [source]), [])

    def test_local_markdown_heading_anchor_is_validated(self) -> None:
        target = self.write("docs/guide.md", "# Guide\n\n## Exact heading\n")
        source = self.write("README.md", "[good](docs/guide.md#exact-heading)\n")
        self.assertEqual(DOCUMENTATION.validate_relative_links(self.root, [source]), [])
        source.write_text("[bad](docs/guide.md#missing-heading)\n", encoding="utf-8")
        self.assertTrue(DOCUMENTATION.validate_relative_links(self.root, [source]))
        self.assertIn("exact-heading", DOCUMENTATION.headings(target))

    def test_project_inventory_parser_counts_only_top_level_entries(self) -> None:
        project = "targets:\n  One:\n    type: app\n  Two:\n    type: framework\nschemes:\n  Main:\n    build:\n"
        self.assertEqual(DOCUMENTATION._top_level_names(project, "targets"), ["One", "Two"])
        self.assertEqual(DOCUMENTATION._top_level_names(project, "schemes"), ["Main"])

    def test_clean_canonical_status_is_derived_from_history(self) -> None:
        self.write(
            "benchmarks/runs/ui-generation/mac.json",
            json.dumps(
                {
                    "schemaVersion": 2,
                    "run": {"platform": "macos", "classification": "canonical", "status": "passedWithWarnings"},
                    "source": {"dirty": False},
                }
            ),
        )
        self.assertTrue(DOCUMENTATION.benchmark_baseline_status(self.root, "macos"))
        self.assertFalse(DOCUMENTATION.benchmark_baseline_status(self.root, "ios"))

    def test_visible_website_copy_rejects_universal_performance_and_em_dash(self) -> None:
        source = self.write("website/src/Hero.jsx", 'const copy = "Faster than realtime — everywhere";\n')
        errors = DOCUMENTATION.validate_website_copy(self.root)
        self.assertEqual(len(errors), 2)
        source.write_text('const copy = "Responsive native generation";\n', encoding="utf-8")
        self.assertEqual(DOCUMENTATION.validate_website_copy(self.root), [])

    def test_historical_snapshot_may_retain_retired_terminology(self) -> None:
        active = self.write("README.md", "Computer Use is an old harness.\n")
        self.assertTrue(DOCUMENTATION.validate_retired_harness_terms(self.root, [active]))
        report = self.write(
            "docs/reference/backend-optimization-research-report.md",
            "# Report\n\n> **Historical snapshot.**\n\nComputer Use and an old harness.\n",
        )
        self.assertNotIn(report, DOCUMENTATION.active_markdown_paths(self.root))
        self.assertEqual(
            DOCUMENTATION.validate_retired_harness_terms(
                self.root, DOCUMENTATION.active_markdown_paths(self.root)
            ),
            DOCUMENTATION.validate_retired_harness_terms(self.root, [active]),
        )
        self.assertEqual(DOCUMENTATION.validate_historical_banners(self.root), [])


if __name__ == "__main__":
    unittest.main()
