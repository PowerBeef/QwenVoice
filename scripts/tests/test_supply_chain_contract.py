from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "supply_chain_contract.py"
SPEC = importlib.util.spec_from_file_location("supply_chain_contract", SCRIPT)
assert SPEC and SPEC.loader
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class SupplyChainContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        for relative in (
            ".github/workflows", ".github/ISSUE_TEMPLATE", "config", "scripts", "website"
        ):
            (self.root / relative).mkdir(parents=True, exist_ok=True)
        self.sha = "a" * 40
        (self.root / "config/toolchain.json").write_text(json.dumps({
            "schemaVersion": 1,
            "native": {}, "release": {}, "website": {},
            "actions": {"actions/checkout": {"version": "v4", "sha": self.sha}},
        }), encoding="utf-8")
        workflow = """on:\n  push:\n    tags: ['v*']\nsteps:\n  - name: Verify release tag and source identity\n    uses: actions/checkout@%s # v4\n  - name: Generate and validate release evidence\n  - name: Attest verified DMG provenance\n  - name: Create or reuse draft GitHub Release\n  - name: Reset draft Release assets\n    run: gh release view \"$RELEASE_TAG\" --json assets && gh release delete-asset \"$RELEASE_TAG\" stale --yes\n  - name: Upload verified assets to draft Release\n  - name: Verify downloaded Release assets\n    run: echo \"unexpected or missing draft Release assets\"\n  - name: Run process-bound iOS release readiness\n    run: python3 scripts/required_step_ledger.py run --step platform-readiness -- bash -euo pipefail -c 'scripts/macos_test.sh gate && ./scripts/build_foundation_targets.sh ios'\n  - name: Archive VocelloiOS\n  - name: Export App Store IPA\n  - name: Verify exported IPA identity and signing contract\n    run: python3 scripts/required_step_ledger.py run --step ipa-verification -- python3 scripts/verify_ios_release_artifacts.py --output ios-release-artifact-verification.json\n  - name: Generate and validate iOS release evidence\n  - name: Publish verified GitHub Release\n""" % self.sha
        (self.root / ".github/workflows/release.yml").write_text(workflow, encoding="utf-8")
        security = """name: Security
on:
  pull_request:
  push:
    branches: [main]
  schedule:
    - cron: '23 8 * * 2'
  workflow_dispatch:
jobs:
  swift-dependency-submission:
    if: github.event_name == 'push' || github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@%s
      - run: python3 scripts/swift_dependency_snapshot.py > "$RUNNER_TEMP/swift-dependency-snapshot.json"
      - run: gh api repos/example/project/dependency-graph/snapshots --input "$RUNNER_TEMP/swift-dependency-snapshot.json"
  npm-advisory-audit:
    if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'
    permissions:
      contents: read
    steps:
      - run: npm --prefix website audit --package-lock-only --audit-level=high
""" % self.sha
        (self.root / ".github/workflows/security.yml").write_text(security, encoding="utf-8")
        (self.root / ".github/dependabot.yml").write_text(
            '\n'.join(f'package-ecosystem: "{value}"' for value in ("github-actions", "npm", "swift")),
            encoding="utf-8",
        )
        (self.root / "website/package.json").write_text(json.dumps({
            "scripts": {key: "true" for key in ("lint", "test", "build", "check")}
        }), encoding="utf-8")
        for relative in (
            "SECURITY.md", ".github/CODEOWNERS", ".github/ISSUE_TEMPLATE/bug_report.yml",
            ".github/ISSUE_TEMPLATE/feature_request.yml", ".github/ISSUE_TEMPLATE/config.yml",
            "scripts/release_evidence.py", "scripts/release_sbom.py",
            "scripts/swift_dependency_snapshot.py",
            "scripts/verify_ios_release_artifacts.py",
        ):
            contents = "fixture\n"
            if relative == "scripts/swift_dependency_snapshot.py":
                contents = "\n".join((
                    "QwenVoice.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
                    "Packages/VocelloQwen3Core/Package.resolved",
                ))
            (self.root / relative).write_text(contents, encoding="utf-8")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_valid_fixture_passes(self) -> None:
        self.assertEqual(module.validate(self.root), [])

    def test_mutable_action_ref_fails(self) -> None:
        path = self.root / ".github/workflows/release.yml"
        path.write_text(path.read_text().replace(self.sha, "v4"), encoding="utf-8")
        self.assertTrue(any("full SHA" in value for value in module.validate(self.root)))

    def test_published_release_trigger_fails(self) -> None:
        path = self.root / ".github/workflows/release.yml"
        path.write_text(path.read_text() + "\nrelease:\n  types: [published]\n", encoding="utf-8")
        self.assertTrue(any("must not trigger" in value for value in module.validate(self.root)))

    def test_publish_before_remote_verification_fails(self) -> None:
        path = self.root / ".github/workflows/release.yml"
        text = path.read_text()
        text = text.replace("  - name: Publish verified GitHub Release\n", "")
        text = text.replace(
            "  - name: Verify downloaded Release assets\n",
            "  - name: Publish verified GitHub Release\n"
            "  - name: Verify downloaded Release assets\n",
        )
        path.write_text(text, encoding="utf-8")
        self.assertTrue(any("ordering" in value for value in module.validate(self.root)))

    def test_draft_asset_set_must_be_reset_and_checked_exactly(self) -> None:
        path = self.root / ".github/workflows/release.yml"
        text = path.read_text(encoding="utf-8")
        path.write_text(text.replace("gh release delete-asset", "echo skip-delete"), encoding="utf-8")
        self.assertTrue(any("exact draft asset set" in value for value in module.validate(self.root)))

    def test_ios_export_must_be_verified_before_evidence(self) -> None:
        path = self.root / ".github/workflows/release.yml"
        text = path.read_text(encoding="utf-8")
        path.write_text(
            text.replace("scripts/verify_ios_release_artifacts.py", "scripts/skip_ios_verification.py"),
            encoding="utf-8",
        )
        self.assertTrue(any("artifact-verification binding" in value for value in module.validate(self.root)))

    def test_ios_readiness_must_be_process_bound_before_archive(self) -> None:
        path = self.root / ".github/workflows/release.yml"
        text = path.read_text(encoding="utf-8")
        path.write_text(
            text.replace("--step platform-readiness", "--step unbound-readiness"),
            encoding="utf-8",
        )
        self.assertTrue(any("readiness binding" in value for value in module.validate(self.root)))

    def test_release_tool_validation_is_isolated_from_native_tools(self) -> None:
        path = self.root / "config/toolchain.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        manifest["native"] = {
            "compiler": {
                "version": "native-expected",
                "versionCommand": [sys.executable, "-c", "print('native-observed')"],
            }
        }
        manifest["release"] = {
            "gh": {
                "version": "2.95.0",
                "versionCommand": [sys.executable, "-c", "print('gh 2.95.0')"],
            }
        }
        path.write_text(json.dumps(manifest), encoding="utf-8")

        self.assertEqual(module.validate(self.root, "release"), [])
        self.assertTrue(any("compiler" in value for value in module.validate(self.root, "all")))

    def test_swift_dependency_submission_cannot_run_on_pull_requests(self) -> None:
        path = self.root / ".github/workflows/security.yml"
        text = path.read_text(encoding="utf-8")
        path.write_text(
            text.replace(
                "if: github.event_name == 'push' || github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'",
                "if: github.event_name != 'schedule'",
                1,
            ),
            encoding="utf-8",
        )
        self.assertTrue(any("submission must run only" in value for value in module.validate(self.root)))

    def test_swift_dependency_submission_push_is_limited_to_main(self) -> None:
        path = self.root / ".github/workflows/security.yml"
        text = path.read_text(encoding="utf-8")
        path.write_text(text.replace("    branches: [main]", "    branches: [develop]", 1), encoding="utf-8")
        self.assertTrue(any("push trigger must remain limited" in value for value in module.validate(self.root)))

    def test_swift_dependency_submission_has_only_required_permission(self) -> None:
        path = self.root / ".github/workflows/security.yml"
        text = path.read_text(encoding="utf-8")
        path.write_text(text.replace("      contents: write", "      contents: write\n      actions: write", 1), encoding="utf-8")
        self.assertTrue(any("only contents:write" in value for value in module.validate(self.root)))

    def test_npm_advisory_audit_cannot_run_on_ordinary_push(self) -> None:
        path = self.root / ".github/workflows/security.yml"
        text = path.read_text(encoding="utf-8")
        path.write_text(
            text.replace(
                "if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'",
                "if: github.event_name != 'pull_request'",
                1,
            ),
            encoding="utf-8",
        )
        self.assertTrue(any("audit must run only" in value for value in module.validate(self.root)))

    def test_swift_dependency_snapshot_must_cover_both_tracked_locks(self) -> None:
        path = self.root / "scripts/swift_dependency_snapshot.py"
        path.write_text("Packages/VocelloQwen3Core/Package.resolved\n", encoding="utf-8")
        self.assertTrue(any("QwenVoice.xcodeproj" in value for value in module.validate(self.root)))


if __name__ == "__main__":
    unittest.main()
