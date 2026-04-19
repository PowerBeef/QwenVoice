# Vendoring and Runtime Notes

QwenVoice has two maintained runtime stories:

1. **Source builds / development mode**
2. **Native backend source vendoring**

## Tracked Surface Boundaries

Treat tracked surfaces in this repo as four different classes:

- **Repo-owned source**: `Sources/`, `QwenVoiceTests/`, maintained docs, and local harness scripts
- **Repo-owned vendored source**: `third_party_patches/`, where QwenVoice intentionally carries patched upstream code as maintained source
- **Generated or bundled resources**: `Sources/Resources/ffmpeg/`, most of `Sources/Resources/vendor/`, and similar script-produced payloads
- **Local-only state**: `build/`, `.worktrees/`, `DerivedData/`, app-support data, and other machine-specific outputs

## Development Mode

In a clean source checkout, the app uses the native runtime through the bundled XPC helper and the app-side proxy/store layer. Normal development builds do not require repo-managed Python setup, backend bootstrap, compatibility runtime provisioning, or release-packaging automation.

## Native Backend Source Vendoring

The native backend keeps its Swift MLXAudio stack as a repo-owned local package at:

- `third_party_patches/mlx-audio-swift/`

That tree is maintained source, not a generated runtime artifact.

The native package boundary currently includes:

- the local `MLXAudio` package path in `project.yml`
- remote `MLXSwift` and `SwiftHuggingFace` package entries
- `Package.resolved` pins for the package graph consumed by the app and runtime targets

When the native backend package changes, keep the source tree, `project.yml`, and `Package.resolved` aligned, then regenerate the Xcode project before validating the app build.

`UITestStubMacEngine` remains available for fixture-backed manual desktop-control runs when deterministic app-shell behavior is useful.

## Maintenance Cadence

Review the native vendoring stack:

- after any intentional `mlx-audio-swift`, `MLXSwift`, or `SwiftHuggingFace` update
- after any change to the app/runtime/XPC boundary that affects the consumed package graph
- at least quarterly for package pins and runtime compatibility assumptions

Every review should keep these artifacts aligned:

- `third_party_patches/mlx-audio-swift/`
- `project.yml`
- `QwenVoice.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- maintained docs that describe runtime ownership or vendoring boundaries

## Current Verification Surface

- `scripts/check_project_inputs.sh`
- `scripts/regenerate_project.sh`
- `python3 scripts/harness.py validate`
- `python3 scripts/harness.py test --layer swift`
- `python3 scripts/harness.py test --layer contract`
- `python3 scripts/harness.py test --layer native`
- `xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build`
- `QWENVOICE_ENABLE_NATIVE_ENGINE_LIVE_TESTS=1 xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice -destination 'platform=macOS' -only-testing:QwenVoiceTests/NativeMLXMacEngineLiveTests test`

Visual and interaction verification is manual in this checkout. After the cheap source gates are green, use Codex Computer Use instead of any automated XCUI smoke, design, perf, or packaged-release lane.
