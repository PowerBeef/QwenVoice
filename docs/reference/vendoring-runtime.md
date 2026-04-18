# Vendoring and Runtime Packaging

QwenVoice has three maintained vendoring/runtime stories:

1. **Source builds / development mode**
2. **Packaged release builds**
3. **Native backend source vendoring**

## Development Mode

In a clean source checkout, `Sources/Resources/python/` is usually absent. The app then:

- defaults to the native engine for normal app launches
- only uses the retained Python setup flow when `QWENVOICE_APP_ENGINE=python` is selected explicitly for source/debug compatibility
- then finds a local Python 3.11–3.14 install, creates a venv under `~/Library/Application Support/QwenVoice/python/`, installs dependencies from `Sources/Resources/requirements.txt`, and records the requirements hash in `.setup-complete`

## Release Packaging

`./scripts/release.sh` now builds a native-only app bundle. It must not ship:

- `Contents/Resources/backend/`
- `Contents/Resources/python/`
- bundled `Contents/Resources/ffmpeg`

`Sources/Resources/python/` and `Sources/Resources/ffmpeg/` remain repo-side generated assets for source/debug compatibility work, not shipped release-bundle inputs.

The release pipeline also:

- regenerates the Xcode project safely
- builds the app
- strips any leaked backend or Python runtime artifacts from the final `.app`
- removes vendored wheels and compiled Python artifacts from the packaged Resources directory
- verifies the final bundle
- creates the DMG

## Native Backend Source Vendoring

The native backend keeps its Swift MLXAudio stack as a repo-owned local package at:

- `third_party_patches/mlx-audio-swift/`

That tree is maintained source, not a generated runtime artifact. It stays separate from the Python wheel overlay flow in `third_party_patches/mlx-audio/`.

The native package boundary currently includes:

- the local `MLXAudio` package path in `project.yml`
- remote `MLXSwift` and `SwiftHuggingFace` package entries
- `Package.resolved` pins for the package graph consumed by `QwenVoiceNative`

When the native backend package changes, keep the source tree, `project.yml`, and `Package.resolved` aligned, then regenerate the Xcode project before validating the app build.

Normal app launches now default the app-facing engine to `NativeMLXMacEngine`. `QWENVOICE_APP_ENGINE=python` remains the source/debug compatibility path. `UITestStubMacEngine` remains available for manual fixture-backed desktop-control runs when deterministic app-shell behavior is useful.

## Qwen3-TTS Overlay Strategy

The app now installs stock `mlx-audio==0.4.2` and keeps the QwenVoice-specific Qwen3-TTS clone-speedup logic as a standalone backend helper overlay.

Relevant locations:

- `Sources/Resources/backend/mlx_audio_qwen_speed_patch.py`
- `third_party_patches/mlx-audio/`
- `third_party_patches/mlx-audio-swift/`

`scripts/build_mlx_audio_wheel.sh` is now just the source of truth for syncing the backend helper from `third_party_patches/mlx-audio/qwenvoice_speed_patch.py`.

If the GUI app’s `mlx-audio` version changes, the standalone overlay and vendoring notes must be reviewed together.

## Maintenance Cadence

The pinned Python/source-debug compatibility stack is intentionally conservative. Review it on a simple maintainer cadence instead of introducing automated dependency churn:

- after any intentional `mlx-audio`, Python-compatibility, bundled `ffmpeg`, or release-packaging update
- before major tagged releases if the vendored/runtime stack changed since the previous tag
- at least quarterly for the overlay, source/debug runtime expectations, and packaged verification flow

Every review should keep these artifacts aligned:

- `Sources/Resources/requirements.txt`
- `scripts/build_mlx_audio_wheel.sh`
- `third_party_patches/mlx-audio/`
- `third_party_patches/mlx-audio-swift/`
- `Sources/Resources/backend/mlx_audio_qwen_speed_patch.py`
- `project.yml`
- `QwenVoice.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `scripts/verify_release_bundle.sh`
- the signed/notarized GitHub release verification flow

## Current Verification Surface

- `scripts/check_project_inputs.sh`
- `scripts/regenerate_project.sh`
- `python3 scripts/harness.py validate`
- `python3 scripts/harness.py test --layer swift`
- `xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build`
- `QWENVOICE_ENABLE_NATIVE_ENGINE_LIVE_TESTS=1 xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice -destination 'platform=macOS' -only-testing:QwenVoiceTests/NativeMLXMacEngineLiveTests test`
- `scripts/verify_release_bundle.sh`
- `.github/workflows/release-dual-ui.yml`

Visual and interaction verification is manual in this checkout. After the cheap source gates are green, use Codex Computer Use instead of any automated XCUI smoke, design, or perf lane.
