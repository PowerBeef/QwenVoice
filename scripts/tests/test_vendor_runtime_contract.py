#!/usr/bin/env python3
from __future__ import annotations

import copy
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("vendor_runtime_contract", ROOT / "scripts/vendor_runtime_contract.py")
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class VendorRuntimeContractTests(unittest.TestCase):
    def test_repository_contract_is_valid(self) -> None:
        self.assertEqual(MODULE.validate(ROOT), [])

    def test_generated_project_and_dependency_automation_use_owned_path(self) -> None:
        self.assertIn(
            "Packages/VocelloQwen3Core",
            (ROOT / "QwenVoice.xcodeproj/project.pbxproj").read_text(encoding="utf-8"),
        )
        self.assertIn(
            'directory: "/Packages/VocelloQwen3Core"',
            (ROOT / ".github/dependabot.yml").read_text(encoding="utf-8"),
        )

    def test_facade_api_baseline_is_canonical_and_hides_raw_runtime_types(self) -> None:
        runtime = ROOT / MODULE.RUNTIME_RELATIVE
        baseline = MODULE.load_json(runtime / MODULE.FACADE_API_BASELINE_NAME)
        self.assertEqual(baseline, MODULE.make_facade_api_baseline(runtime))
        self.assertTrue(baseline["publicDeclarations"])
        self.assertEqual(
            [
                declaration
                for declaration in baseline["publicDeclarations"]
                if MODULE.FORBIDDEN_FACADE_API_TYPES.search(declaration)
            ],
            [],
        )

    def test_facade_type_filter_rejects_third_party_cache_types(self) -> None:
        self.assertIsNotNone(
            MODULE.FORBIDDEN_FACADE_API_TYPES.search(
                "public static func load(cache: HubCache)"
            )
        )
        self.assertIsNone(
            MODULE.FORBIDDEN_FACADE_API_TYPES.search(
                "public static func load(cachePolicy: VocelloQwen3CachePolicy)"
            )
        )

    def test_every_retained_file_has_owned_capability_coverage(self) -> None:
        runtime = ROOT / MODULE.RUNTIME_RELATIVE
        inventory = MODULE.load_json(runtime / MODULE.CURRENT_INVENTORY_NAME)
        contract = MODULE.load_json(runtime / MODULE.CAPABILITIES_NAME)
        patterns = [
            pattern
            for capability in contract["capabilities"]
            for pattern in capability["sourcePatterns"]
        ]
        uncovered = []
        for entry in inventory["entries"]:
            if not MODULE.matches(entry["path"], patterns):
                uncovered.append(entry["path"])
        self.assertEqual(uncovered, [])

    def test_immutable_baseline_and_current_inventory_are_separate(self) -> None:
        runtime = ROOT / MODULE.RUNTIME_RELATIVE
        baseline = MODULE.load_json(runtime / MODULE.BASELINE_NAME)
        inventory = MODULE.load_json(runtime / MODULE.CURRENT_INVENTORY_NAME)
        baseline_paths = {entry["path"] for entry in baseline["entries"]}
        added_paths = {
            entry["path"]
            for entry in inventory["entries"]
            if entry["upstreamStatus"] == "added"
        }
        self.assertTrue(added_paths)
        self.assertTrue(added_paths.isdisjoint(baseline_paths))
        self.assertTrue(all(len(entry["sha256"]) == 64 for entry in baseline["entries"]))
        self.assertEqual(
            inventory,
            MODULE.make_current_inventory(runtime, baseline, "vocello-qwen3-core"),
        )

    def test_changed_or_added_implementation_files_have_semantic_coverage(self) -> None:
        runtime = ROOT / MODULE.RUNTIME_RELATIVE
        inventory = MODULE.load_json(runtime / MODULE.CURRENT_INVENTORY_NAME)
        capabilities = MODULE.load_json(runtime / MODULE.CAPABILITIES_NAME)
        patches = MODULE.load_json(runtime / MODULE.PATCHES_NAME)
        capability_patterns = [
            pattern
            for capability in capabilities["capabilities"]
            for pattern in capability["sourcePatterns"]
        ]
        patch_patterns = [
            pattern
            for patch in patches["patches"]
            for pattern in patch["files"]
        ]
        impacted = [
            entry["path"]
            for entry in inventory["entries"]
            if entry["upstreamStatus"] in {"modified", "added"}
            and MODULE.matches(entry["path"], list(MODULE.IMPLEMENTATION_SCOPE))
        ]
        self.assertTrue(impacted)
        self.assertEqual(
            [path for path in impacted if not MODULE.matches(path, capability_patterns)],
            [],
        )
        self.assertEqual(
            [path for path in impacted if not MODULE.matches(path, patch_patterns)],
            [],
        )
        patches_by_id = {entry["id"]: entry for entry in patches["patches"]}
        unlinked = [
            path
            for path in impacted
            if not any(
                MODULE.matches(path, capability["sourcePatterns"])
                and any(
                    MODULE.matches(path, patches_by_id[patch_id]["files"])
                    for patch_id in capability["upstreamDeltaIDs"]
                )
                for capability in capabilities["capabilities"]
            )
        ]
        self.assertEqual(unlinked, [])

    def test_semantic_delta_entries_have_controlled_live_references(self) -> None:
        runtime = ROOT / MODULE.RUNTIME_RELATIVE
        ledger = MODULE.load_json(runtime / MODULE.PATCHES_NAME)
        states = set(ledger["allowedStates"])
        dispositions = set(ledger["allowedUpstreamDispositions"])
        evidence_classes = set(ledger["allowedEvidenceClasses"])
        for entry in ledger["patches"]:
            self.assertIn(entry["state"], states)
            self.assertIn(entry["upstreamDisposition"], dispositions)
            self.assertIn(entry["evidenceClass"], evidence_classes)
            self.assertTrue(MODULE.expanded(runtime, entry["files"]))
            self.assertTrue(MODULE.expanded(runtime, entry["tests"]))
            self.assertTrue(MODULE.expanded(runtime, entry["documentation"]))
            self.assertTrue(entry["removalCriteria"].strip())

    def test_lineage_digest_pins_immutable_import_inventory(self) -> None:
        runtime = ROOT / MODULE.RUNTIME_RELATIVE
        lineage = MODULE.load_json(runtime / MODULE.LINEAGE_NAME)
        self.assertEqual(
            lineage["baselineInventory"]["sha256"],
            MODULE.sha256(runtime / MODULE.BASELINE_NAME),
        )

    def test_owned_targets_do_not_import_repository_layers(self) -> None:
        runtime = ROOT / MODULE.RUNTIME_RELATIVE
        ownership = MODULE.load_json(runtime / MODULE.OWNERSHIP_NAME)
        forbidden = set(ownership["forbiddenRepositoryImports"])
        for contract in ownership["targets"].values():
            imports = MODULE.swift_imports(runtime / contract["sourceRoot"])
            self.assertEqual(imports & forbidden, set())

    def test_import_scanner_includes_preconcurrency_imports(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Imports.swift").write_text(
                "import Foundation\n@preconcurrency import MLX\n",
                encoding="utf-8",
            )
            self.assertEqual(MODULE.swift_imports(root), {"Foundation", "MLX"})

    def test_owned_target_dependency_inventory_matches_package(self) -> None:
        runtime = ROOT / MODULE.RUNTIME_RELATIVE
        package = (runtime / "Package.swift").read_text(encoding="utf-8")
        blocks = MODULE.package_target_blocks(package)
        ownership = MODULE.load_json(runtime / MODULE.OWNERSHIP_NAME)
        names = set(ownership["targets"])
        for target, contract in ownership["targets"].items():
            actual = {
                candidate
                for candidate in names
                if candidate != target and f'"{candidate}"' in blocks[target]
            }
            self.assertEqual(actual, set(contract["allowedRuntimeTargetDependencies"]))

    def test_baseline_builder_is_deterministic(self) -> None:
        runtime = ROOT / MODULE.RUNTIME_RELATIVE
        lineage = MODULE.load_json(runtime / MODULE.LINEAGE_NAME)
        # Reusing the runtime as a synthetic upstream proves ordering/shape without network access.
        rebuilt = MODULE.make_baseline(
            runtime,
            runtime,
            lineage["origin"]["commit"],
            "vocello-qwen3-core",
        )
        self.assertEqual(
            [entry["path"] for entry in rebuilt["entries"]],
            sorted(entry["path"] for entry in rebuilt["entries"]),
        )
        self.assertTrue(all(len(entry["sha256"]) == 64 for entry in rebuilt["entries"]))

    def test_baseline_rebuild_preserves_the_immutable_path_set(self) -> None:
        runtime = ROOT / MODULE.RUNTIME_RELATIVE
        baseline = MODULE.load_json(runtime / MODULE.BASELINE_NAME)
        paths = [entry["path"] for entry in baseline["entries"]]
        rebuilt = MODULE.make_baseline(
            runtime,
            runtime,
            baseline["upstreamCommit"],
            baseline["componentID"],
            paths,
        )
        self.assertEqual([entry["path"] for entry in rebuilt["entries"]], paths)

    def test_old_benchmark_records_are_not_current_runtime_verification(self) -> None:
        runtime = ROOT / MODULE.RUNTIME_RELATIVE
        contract = MODULE.load_json(runtime / MODULE.CAPABILITIES_NAME)
        records = MODULE.benchmark_records(ROOT)
        benchmark_capabilities = [
            item for item in contract["capabilities"] if item["evidenceClass"] == "benchmark"
        ]
        self.assertTrue(benchmark_capabilities)
        for item in benchmark_capabilities:
            self.assertEqual(item["benchmarkEvidenceStatus"], "diagnostic")
            self.assertFalse(MODULE.capability_benchmark_is_fresh(ROOT, runtime, item, records))

    def test_stale_benchmark_cannot_be_reclassified_as_verified(self) -> None:
        runtime = ROOT / MODULE.RUNTIME_RELATIVE
        contract = MODULE.load_json(runtime / MODULE.CAPABILITIES_NAME)
        records = MODULE.benchmark_records(ROOT)
        capability = copy.deepcopy(
            next(item for item in contract["capabilities"] if item["evidenceClass"] == "benchmark")
        )
        capability["benchmarkEvidenceStatus"] = "verified"
        errors = MODULE.capability_benchmark_evidence_errors(
            ROOT,
            runtime,
            capability,
            records,
            set(contract["allowedBenchmarkEvidenceStatuses"]),
        )
        self.assertTrue(any("must be diagnostic or unverified" in error for error in errors))

    def test_failed_or_unvalidated_benchmark_is_never_fresh_evidence(self) -> None:
        runtime = ROOT / MODULE.RUNTIME_RELATIVE
        record = copy.deepcopy(next(iter(MODULE.benchmark_records(ROOT).values())))
        record["run"]["status"] = "failed"
        record["evidence"]["validatorPassed"] = False
        record["digest"] = MODULE.canonical_record_digest(record)
        self.assertFalse(MODULE.benchmark_record_is_eligible(record))
        self.assertFalse(
            MODULE.benchmark_record_matches_sources(
                ROOT,
                runtime,
                ["Sources/MLXAudioCore/ModelUtils.swift"],
                record,
            )
        )

    def test_dependency_drift_invalidates_runtime_benchmark_evidence(self) -> None:
        runtime = ROOT / MODULE.RUNTIME_RELATIVE
        records = MODULE.benchmark_records(ROOT)
        eligible = [record for record in records.values() if MODULE.benchmark_record_is_eligible(record)]
        self.assertTrue(eligible)
        git_blob = MODULE.git_blob

        def blob_with_dependency_drift(repo_root: Path, commit: str, path: Path) -> bytes | None:
            blob = git_blob(repo_root, commit, path)
            if path.name == "Package.resolved" and blob is not None:
                return blob + b"\n"
            return blob

        with mock.patch.object(MODULE, "git_blob", side_effect=blob_with_dependency_drift):
            self.assertFalse(
                MODULE.benchmark_record_matches_sources(
                    ROOT,
                    runtime,
                    ["Sources/MLXAudioCore/ModelUtils.swift"],
                    eligible[0],
                )
            )

    def test_contract_references_cannot_escape_the_runtime_root(self) -> None:
        runtime = ROOT / MODULE.RUNTIME_RELATIVE
        for reference in ("../README.md", "/tmp/reference", "Sources/../../README.md"):
            self.assertFalse(MODULE.safe_contract_reference(reference))
            self.assertEqual(MODULE.expanded(runtime, [reference]), [])
        self.assertTrue(MODULE.safe_contract_reference("Sources/**/*.swift"))

    def test_patch_state_and_upstream_disposition_combinations_are_controlled(self) -> None:
        self.assertTrue(MODULE.patch_state_disposition_valid("active", "local-only"))
        self.assertTrue(MODULE.patch_state_disposition_valid("shared", "upstreamed"))
        self.assertTrue(MODULE.patch_state_disposition_valid("removed", "obsolete"))
        self.assertFalse(MODULE.patch_state_disposition_valid("active", "obsolete"))
        self.assertFalse(MODULE.patch_state_disposition_valid("removed", "local-only"))
        self.assertFalse(MODULE.patch_state_disposition_valid("unknown", "local-only"))

    def test_immutable_baseline_requires_a_clean_upstream_checkout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary)
            subprocess.run(["git", "init", "-q"], cwd=checkout, check=True)
            tracked = checkout / "Package.swift"
            tracked.write_text("// swift-tools-version: 6.0\n", encoding="utf-8")
            subprocess.run(["git", "add", "Package.swift"], cwd=checkout, check=True)
            subprocess.run(
                [
                    "git",
                    "-c",
                    "user.name=Contract Test",
                    "-c",
                    "user.email=contract@example.invalid",
                    "commit",
                    "-qm",
                    "baseline",
                ],
                cwd=checkout,
                check=True,
            )
            self.assertTrue(MODULE.git_checkout_is_clean(checkout))
            tracked.write_text("// modified\n", encoding="utf-8")
            self.assertFalse(MODULE.git_checkout_is_clean(checkout))
            tracked.write_text("// swift-tools-version: 6.0\n", encoding="utf-8")
            (checkout / "untracked.txt").write_text("untracked\n", encoding="utf-8")
            self.assertFalse(MODULE.git_checkout_is_clean(checkout))

    def test_relocation_records_semantic_changes_instead_of_claiming_byte_parity(self) -> None:
        runtime = ROOT / MODULE.RUNTIME_RELATIVE
        lineage = MODULE.load_json(runtime / MODULE.LINEAGE_NAME)
        relocation = lineage["monorepoRelocation"]
        inventory = MODULE.load_json(runtime / MODULE.RELOCATION_INVENTORY_NAME)
        self.assertEqual(relocation["classification"], "semantic-move-with-modifications-and-additions")
        expected = {"identical": 65, "modified": 11, "added": 12, "removed": 0}
        self.assertEqual(inventory["summary"], expected)
        self.assertEqual(relocation["fileComparison"], inventory["summary"])
        self.assertEqual(
            relocation["inventory"]["sha256"],
            MODULE.sha256(runtime / MODULE.RELOCATION_INVENTORY_NAME),
        )


if __name__ == "__main__":
    unittest.main()
