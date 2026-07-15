#!/usr/bin/env python3
"""Static regression checks for the repository build-output routing contract."""

from __future__ import annotations

import json
from pathlib import Path
import re
import shlex
import unittest


ROOT = Path(__file__).resolve().parents[2]


class BuildRoutingContractTests(unittest.TestCase):
    def text(self, relative: str) -> str:
        return (ROOT / relative).read_text(encoding="utf-8")

    def assert_tokens(self, relative: str, *tokens: str) -> None:
        text = self.text(relative)
        missing = [token for token in tokens if token not in text]
        self.assertFalse(missing, f"{relative} is missing {missing}")

    def test_local_xcode_lanes_use_policy_paths_pinned_packages_and_explicit_identity(self) -> None:
        common = (
            "-derivedDataPath",
            "-clonedSourcePackagesDirPath",
            "-disableAutomaticPackageResolution",
            "-onlyUsePackageVersionsFromResolvedFile",
        )
        for relative in (
            "scripts/build.sh",
            "scripts/build_foundation_targets.sh",
            "scripts/macos_test.sh",
            "scripts/ios_device.sh",
            "scripts/ui_test.sh",
            "scripts/release.sh",
        ):
            with self.subTest(relative=relative):
                self.assert_tokens(relative, *common)
                self.assert_tokens(relative, "configuration", "ARCHS=arm64")

    def test_cli_uses_generated_scheme_and_canonical_derived_data(self) -> None:
        build = self.text("scripts/build.sh")
        start = build.index("build_cli() {")
        end = build.index("\ncmd_cli() {", start)
        body = build[start:end]
        for token in (
            'python3 "$ROOT_DIR/scripts/generate_cli_scheme.py"',
            '-scheme "$CLI_TARGET"',
            '-derivedDataPath "$DERIVED_DATA"',
            '-clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR"',
        ):
            source = self.text("scripts/lib/build_cache.sh") if token.startswith("python3") else body
            self.assertIn(token, source)
        self.assertNotIn('-target "$CLI_TARGET"', body)
        self.assertNotIn("SYMROOT=", body)
        self.assertNotIn("OBJROOT=", body)
        self.assertTrue(
            (ROOT / "QwenVoice.xcodeproj/xcshareddata/xcschemes/VocelloCLI.xcscheme").is_file()
        )

    def test_macos_lanes_are_arm64_only(self) -> None:
        for relative in (
            "scripts/build.sh",
            "scripts/build_foundation_targets.sh",
            "scripts/macos_test.sh",
            "scripts/ui_test.sh",
            "scripts/release.sh",
        ):
            with self.subTest(relative=relative):
                self.assert_tokens(relative, "ONLY_ACTIVE_ARCH=YES", "ARCHS=arm64")
        self.assert_tokens(
            "scripts/lib/build_cache.sh",
            "assert_macos_bundle_arm64_only",
            "assert_macho_arm64_only",
        )

    def test_owned_swiftpm_commands_always_have_an_explicit_scratch_path(self) -> None:
        errors: list[str] = []
        for path in (ROOT / "scripts").rglob("*.sh"):
            if "tests" in path.parts:
                continue
            text = path.read_text(encoding="utf-8")
            for match in re.finditer(r"\bswift\s+(?:build|test)\b", text):
                window = text[match.start() : match.start() + 500]
                if "--scratch-path" not in window:
                    line = text.count("\n", 0, match.start()) + 1
                    errors.append(f"{path.relative_to(ROOT)}:{line}")
        self.assertFalse(errors, "SwiftPM commands lack --scratch-path: " + ", ".join(errors))
        self.assert_tokens(
            "scripts/lib/build_cache.sh",
            "ensure_swiftpm_scratch_location",
            ".qvoice-scratch-location-v1",
            "swift package --package-path",
        )
        self.assert_tokens(
            "scripts/macos_test.sh",
            'ensure_swiftpm_scratch_location "$runtime_package" "$QVOICE_SWIFTPM_RUNTIME_CACHE"',
        )

    def test_owned_runtime_uses_a_tracked_lock_in_xcode_lockstep(self) -> None:
        runtime_lock = ROOT / "Packages/VocelloQwen3Core/Package.resolved"
        xcode_lock = ROOT / "QwenVoice.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        self.assertTrue(runtime_lock.is_file(), "owned runtime Package.resolved must be tracked")

        def pins(path: Path) -> dict[str, dict[str, str]]:
            payload = json.loads(path.read_text(encoding="utf-8"))
            return {pin["identity"]: pin["state"] for pin in payload["pins"]}

        runtime_pins = pins(runtime_lock)
        xcode_pins = pins(xcode_lock)
        self.assertTrue(runtime_pins.keys() <= xcode_pins.keys())
        for identity, state in runtime_pins.items():
            with self.subTest(identity=identity):
                self.assertEqual(state, xcode_pins[identity])

        macos = self.text("scripts/macos_test.sh")
        self.assertGreaterEqual(macos.count("--force-resolved-versions"), 3)

    def test_ci_build_and_archive_commands_are_explicit_and_pinned(self) -> None:
        for relative in (".github/workflows/ci.yml", ".github/workflows/release.yml"):
            text = self.text(relative)
            for match in re.finditer(r"xcodebuild\s+(?:build|archive)\b", text):
                window = text[match.start() : match.start() + 1200]
                for token in (
                    "-derivedDataPath",
                    "-clonedSourcePackagesDirPath",
                    "-disableAutomaticPackageResolution",
                    "-onlyUsePackageVersionsFromResolvedFile",
                    "ARCHS=arm64",
                    "ONLY_ACTIVE_ARCH=YES",
                ):
                    self.assertIn(token, window, f"{relative} command lacks {token}")

    def test_local_package_resolution_is_platform_aware_and_pinned(self) -> None:
        resolver = self.text("scripts/lib/build_cache.sh")
        for token in (
            'local scheme="${4:-}"',
            'local configuration="${5:-}"',
            'local destination="${6:-}"',
            '-scheme "$scheme"',
            '-configuration "$configuration"',
            '-destination "$destination"',
            '-derivedDataPath "$derived_data"',
            '-clonedSourcePackagesDirPath "$source_packages"',
            "-disableAutomaticPackageResolution",
            "-onlyUsePackageVersionsFromResolvedFile",
            "swiftpm-resolution-$resolution_key.json",
            'rm -f "$BUILD_CACHE_DIR/swiftpm-resolution.json"',
            '"scheme": sys.argv[7]',
            '"configuration": sys.argv[8]',
            '"destination": sys.argv[9]',
        ):
            self.assertIn(token, resolver)

        calls: dict[str, list[tuple[str, str, str]]] = {}
        for path in (ROOT / "scripts").rglob("*.sh"):
            if "tests" in path.parts or path.name == "build_cache.sh":
                continue
            text = re.sub(r"\\\n\s*", " ", path.read_text(encoding="utf-8"))
            for line in text.splitlines():
                command = line.strip()
                if not command.startswith("ensure_spm_resolved "):
                    continue
                command = command.split("||", 1)[0].strip()
                tokens = shlex.split(command)
                self.assertEqual(
                    len(tokens), 7,
                    f"{path.relative_to(ROOT)} must pass context, scheme, configuration, and destination",
                )
                calls.setdefault(tokens[3], []).append(tuple(tokens[4:7]))

        expected = {
            "dev": [("QwenVoice", "Release", "$DESTINATION")] * 2,
            "foundation-macos": [("QwenVoice", "Release", "platform=macOS,arch=arm64")],
            "foundation-ios": [("VocelloiOS", "Release", "generic/platform=iOS")],
            "release": [("$SCHEME", "$CONFIGURATION", "platform=macOS,arch=arm64")],
            "macos-test": [("QwenVoice", "Release", "platform=macOS,arch=arm64")],
            "ios-device": [("VocelloiOS", "Release", "generic/platform=iOS")],
            "ios-device-logic": [("VocelloiOSLogic", "Release", "id=$dev")],
            "ui-macos": [("VocelloMacUI", "Release", "platform=macOS,arch=arm64")],
            "ui-ios": [("VocelloiOSUI", "Release", "generic/platform=iOS")],
        }
        self.assertEqual(calls, expected)

    def test_ci_package_resolvers_are_destination_explicit_and_pinned(self) -> None:
        required = (
            "-project QwenVoice.xcodeproj",
            "-scheme VocelloiOS",
            "-configuration Release",
            "-destination 'generic/platform=iOS'",
            "-derivedDataPath build/scratch/derived-data/ci/",
            "-clonedSourcePackagesDirPath build/cache/xcode/source-packages",
            "-disableAutomaticPackageResolution",
            "-onlyUsePackageVersionsFromResolvedFile",
        )
        for relative in (".github/workflows/ci.yml", ".github/workflows/release.yml"):
            text = self.text(relative)
            matches = list(re.finditer(r"xcodebuild\s+-resolvePackageDependencies\b", text))
            self.assertEqual(len(matches), 1, f"{relative} must own one explicit package resolve")
            start = matches[0].start()
            end = text.find("\n\n", start)
            window = text[start : len(text) if end == -1 else end]
            for token in required:
                self.assertIn(token, window, f"{relative} resolver lacks {token}")

    def test_mcp_profiles_have_managed_scratch_derived_data(self) -> None:
        text = self.text(".xcodebuildmcp/config.yaml")
        self.assertEqual(text.count("derivedDataPath:"), 2)
        self.assertIn("build/scratch/derived-data/xcodebuildmcp/macos", text)
        self.assertIn("build/scratch/derived-data/xcodebuildmcp/ios-device", text)

    def test_symbol_retention_is_current_product_only_and_uuid_validated(self) -> None:
        cache = self.text("scripts/lib/build_cache.sh")
        self.assertIn("validate_dsym_uuid", cache)
        self.assertIn("preserve_ios_dsym", cache)
        self.assertIn("Vocello.app.dSYM", cache)
        self.assertIn("QwenVoiceEngineService.xpc.dSYM", cache)
        ios = self.text("scripts/ios_device.sh")
        self.assertIn("validate_dsym_identity", ios)
        self.assertIn("QVOICE_SYMBOLS_IOS", ios)
        self.assertIn(
            'local binary="$1" dsym="$2"\n  local dwarf="$dsym/Contents/Resources/DWARF/Vocello"',
            ios,
        )
        policy = self.text("scripts/build_output_policy.py")
        self.assertIn("_symbol_identity_violations", policy)

    def test_benchmark_take_identity_uses_platform_appropriate_temporary_storage(self) -> None:
        context = self.text("Sources/QwenVoiceCore/BenchRunContext.swift")
        self.assertIn("#if os(iOS)", context)
        self.assertIn("FileManager.default.temporaryDirectory", context)
        self.assertIn(
            'URL(fileURLWithPath: "/tmp/vocello-bench-current-take.json"',
            context,
        )
        self.assertIn("try data.write(to: currentTakeFileURL, options: .atomic)", context)
        self.assertIn("currentTakeFileNotes() == payload", context)

        runner = self.text("Sources/iOS/IOSDeviceDiagnosticsRunner.swift")
        self.assertIn("try BenchRunContext.writeCurrentTakeFile", runner)
        self.assertIn("defer { BenchRunContext.clearCurrentTakeFile() }", runner)
        self.assertNotIn(
            'URL(fileURLWithPath: "/tmp/vocello-bench-current-take.json")',
            runner,
        )

    def test_ios_profile_rebuilds_before_install_and_source_snapshot(self) -> None:
        ios = self.text("scripts/ios_device.sh")
        start = ios.index("cmd_profile() {")
        end = ios.index("\n# memory", start)
        profile = ios[start:end]
        build_index = profile.index("\n  cmd_build\n")
        install_index = profile.index("\n  cmd_install >/dev/null\n")
        snapshot_index = profile.index("\n  capture_benchmark_source \"$artifacts\"\n")
        late_xctrace_index = profile.rindex('xctrace_dev="$(resolve_xctrace_device "$dev")"')
        launch_index = profile.index("xcrun devicectl device process launch")
        self.assertLess(build_index, install_index)
        self.assertLess(install_index, snapshot_index)
        self.assertLess(snapshot_index, late_xctrace_index)
        self.assertLess(late_xctrace_index, launch_index)
        self.assertEqual(profile.count('xctrace_dev="$(resolve_xctrace_device "$dev")"'), 2)

    def test_ui_lifecycle_metadata_is_atomic_and_failure_aware(self) -> None:
        text = self.text("scripts/ui_test.sh")
        for token in (
            "write_run_metadata running",
            "write_run_metadata failed",
            "write_run_metadata passed",
            "os.replace(temporary, path)",
        ):
            self.assertIn(token, text)

    def test_owned_runtime_never_owns_a_generated_dot_build(self) -> None:
        self.assertFalse(
            (ROOT / "Packages" / "VocelloQwen3Core" / ".build").exists(),
            "migrate the owned runtime SwiftPM cache to build/cache/swiftpm/mlx-audio-runtime",
        )

    def test_only_classified_top_level_build_roots_remain(self) -> None:
        build = ROOT / "build"
        if not build.exists():
            return
        allowed = {
            ".DS_Store",  # Finder metadata, not a build-output root.
            "cache",
            "scratch",
            "artifacts",
            "dist",
            "Vocello.app",
            "vocello",
        }
        unknown = sorted(path.name for path in build.iterdir() if path.name not in allowed)
        self.assertEqual(unknown, [], f"unclassified build roots remain: {unknown}")


if __name__ == "__main__":
    unittest.main()
