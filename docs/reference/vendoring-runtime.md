# Vendoring And Runtime Notes

QwenVoice now has three maintained runtime stories:

1. shared Apple-platform engine semantics in `QwenVoiceCore`
2. macOS execution through the bundled XPC helper
3. iPhone execution through the isolated engine extension process

## Tracked Surface Boundaries

Treat tracked surfaces in this repo as five classes:

- **Repo-owned source**: `Sources/`, maintained docs, and active scripts under `scripts/`
- **Product assets**: `Sources/Assets.xcassets/` and public docs images under `docs/`
- **Historical records**: `docs/releases/`
- **Repo-owned vendored source**: `third_party_patches/`, where QwenVoice intentionally carries patched upstream code as maintained source

Local-only state includes `build/`, `.worktrees/`, `DerivedData/`, app-support data, generated screenshot diffs, Finder metadata, Python caches, coverage artifacts, and any temporary `Sources/Resources/ffmpeg/` or `Sources/Resources/vendor/` leftovers that appear during local experiments.

## Shared Engine Core

`Sources/QwenVoiceCore/` is the shared engine boundary for:

- semantic request/result types
- platform-specific model variant resolution
- iPhone memory-pressure policy types
- engine-extension transport and IPC
- shared runtime helpers that do not belong to a specific UI process

Keep `QwenVoiceCore` free of UI-process assumptions so it can be hosted by both:

- the macOS XPC helper
- the iPhone engine extension

## Native Backend Source Vendoring

The shared MLX runtime stack still uses one repo-owned vendored package at:

- `third_party_patches/mlx-audio-swift/`

That tree remains maintained source, not a generated runtime artifact.

The native package boundary currently includes:

- the local `MLXAudio` package path in `project.yml`
- remote `MLXSwift` and `SwiftHuggingFace` package entries
- `Package.resolved` pins for the package graph consumed by the macOS, iPhone, and shared-core targets

When the native backend package changes, keep the source tree, `project.yml`, and `Package.resolved` aligned, then regenerate the Xcode project before validating the build.

## Packaging And Verification Surfaces

Maintained local packaging entrypoints:

- `scripts/release.sh` for the macOS signed/notarized DMG pipeline
- `scripts/create_dmg.sh`
- `scripts/verify_release_bundle.sh`
- `scripts/verify_packaged_dmg.sh`
- `scripts/check_ios_catalog.py`
- `scripts/release_ios_testflight.sh`

Maintained CI/release workflow surfaces:

- `.github/workflows/project-inputs.yml`
- `.github/workflows/apple-platform-validation.yml`
- `.github/workflows/macos-release.yml`
- `.github/workflows/ios-testflight.yml`

## Current Verification Surface

- `scripts/check_project_inputs.sh`
- `scripts/regenerate_project.sh`
- `./scripts/build_foundation_targets.sh macos`
- `./scripts/build_foundation_targets.sh ios`
- `xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build`
- `xcodebuild -project QwenVoice.xcodeproj -scheme VocelloiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES build`
- `python3 scripts/check_ios_catalog.py`
- `./scripts/release.sh`
- `./scripts/release_ios_testflight.sh`

Visual and interaction verification still includes manual local passes after project-input checks and builds are green.
