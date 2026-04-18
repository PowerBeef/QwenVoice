# Vendoring and Runtime Packaging

QwenVoice has three maintained runtime stories:

1. **Source builds / development mode**
2. **Packaged release builds**
3. **Native backend source vendoring**

## Tracked Surface Boundaries

Treat tracked surfaces in this repo as four different classes:

- **Repo-owned source**: `Sources/`, `QwenVoiceTests/`, maintained docs, workflows, and repo-local skills
- **Repo-owned vendored source**: `third_party_patches/`, where QwenVoice intentionally carries patched upstream code as maintained source
- **Generated or bundled resources**: `Sources/Resources/ffmpeg/`, most of `Sources/Resources/vendor/`, and similar script-produced payloads
- **Local-only state**: `build/`, `.worktrees/`, `DerivedData/`, app-support data, and other machine-specific outputs

## Development Mode

In a clean source checkout, the app uses the native runtime directly. Normal development builds do not require repo-managed Python setup, backend bootstrap, or compatibility runtime provisioning.

## Release Packaging

`./scripts/release.sh` builds a native-only app bundle. It must not ship:

- `Contents/Resources/backend/`
- `Contents/Resources/python/`
- bundled `Contents/Resources/ffmpeg`

The release pipeline:

- regenerates the Xcode project safely
- builds the app
- strips any leaked backend or Python runtime artifacts from the final `.app`
- removes vendored wheels and compiled Python artifacts from the packaged Resources directory
- verifies the final bundle
- creates the DMG

## Native Backend Source Vendoring

The native backend keeps its Swift MLXAudio stack as a repo-owned local package at:

- `third_party_patches/mlx-audio-swift/`

That tree is maintained source, not a generated runtime artifact.

The native package boundary currently includes:

- the local `MLXAudio` package path in `project.yml`
- remote `MLXSwift` and `SwiftHuggingFace` package entries
- `Package.resolved` pins for the package graph consumed by `QwenVoiceNative`

When the native backend package changes, keep the source tree, `project.yml`, and `Package.resolved` aligned, then regenerate the Xcode project before validating the app build.

`UITestStubMacEngine` remains available for fixture-backed manual desktop-control runs when deterministic app-shell behavior is useful.

## Maintenance Cadence

Review the native vendoring stack:

- after any intentional `mlx-audio-swift`, `MLXSwift`, `SwiftHuggingFace`, or release-packaging update
- before major tagged releases if the native runtime stack changed since the previous tag
- at least quarterly for package pins and release verification flow

Every review should keep these artifacts aligned:

- `third_party_patches/mlx-audio-swift/`
- `project.yml`
- `QwenVoice.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `scripts/verify_release_bundle.sh`
- the signed/notarized GitHub release verification flow

## Current Verification Surface

- `scripts/check_project_inputs.sh`
- `scripts/regenerate_project.sh`
- `python3 scripts/harness.py validate`
- `python3 scripts/harness.py test --layer swift`
- `python3 scripts/harness.py test --layer contract`
- `python3 scripts/harness.py test --layer native`
- `xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build`
- `QWENVOICE_ENABLE_NATIVE_ENGINE_LIVE_TESTS=1 xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice -destination 'platform=macOS' -only-testing:QwenVoiceTests/NativeMLXMacEngineLiveTests test`
- `scripts/verify_release_bundle.sh`
- `.github/workflows/release-dual-ui.yml`

Visual and interaction verification is manual in this checkout. After the cheap source gates are green, use Codex Computer Use instead of any automated XCUI smoke, design, or perf lane.
