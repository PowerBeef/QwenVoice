# QwenVoice Current State

This document is the shared factual reference for the current QwenVoice repository state.

## Product Surface

- Repo identity: `QwenVoice`
- Shipped product brand: `Vocello`
- Platforms in this repo: macOS and iPhone
- Deployment targets: `macOS 26.0+` and `iOS 26.0+`
- Official minimum hardware floor:
  - `Mac mini M1, 8 GB RAM`
  - `iPhone 15 Pro`
- Version source: `project.yml`
- Current version/build: `1.2.3` / `15`

The iPhone app target is already Vocello-branded. The macOS target graph still keeps several internal `QwenVoice` names for continuity, while the intended hosted macOS release asset is `Vocello-macos26.dmg`.

## Architecture

This repo now carries one Apple-platform codebase with a shared engine core and platform-specific isolated hosts.

Shared engine core:

- `Sources/QwenVoiceCore/` for semantic types, contract-backed model descriptors, platform-specific artifact resolution, low-RAM iPhone policy, and engine-extension IPC

macOS runtime split:

- `Sources/` for the macOS app shell, views, services, and app-owned state
- `Sources/QwenVoiceNative/` for the macOS app-facing engine proxy/store/client layer
- `Sources/QwenVoiceEngineSupport/` for shared macOS engine IPC and transport types
- `Sources/QwenVoiceNativeRuntime/` for service-only native execution and MLX runtime ownership
- `Sources/QwenVoiceEngineService/` for the bundled XPC helper embedded into the Mac app

iPhone runtime split:

- `Sources/iOS/` for the SwiftUI app shell and UI-owned orchestration
- `Sources/iOSSupport/` for shared iPhone support services, paths, model delivery, and persistence layers
- `Sources/iOSEngineExtension/` for the isolated engine-extension process hosted through ExtensionFoundation

Vendored native backend boundary:

- `third_party_patches/mlx-audio-swift/`

Heavy generation, prewarm, and model-load work stays out of the UI process on both platforms:

- macOS uses the bundled XPC helper
- iPhone uses the engine extension process

## Models, Variants, And Contract Ownership

Static TTS contract data lives in `Sources/Resources/qwenvoice_contract.json`.

That manifest is the source of truth for:

- model registry
- model variants per platform
- default speaker
- grouped speakers
- output subfolders
- required model files
- Hugging Face repos

The shared logical mode families remain:

- `custom`
- `design`
- `clone`

Platform-specific install policy:

- iPhone resolves to 4-bit `Speed` variants only
- macOS resolves to 8-bit `Quality` by default when available, while minimum-hardware guidance recommends 4-bit `Speed`

## Memory And Isolation Posture

- iPhone memory policy lives in `Sources/QwenVoiceCore/IOSMemorySnapshot.swift` and the iPhone `TTSEngineStore` / app shell layers.
- The shared memory bands are `healthy`, `guarded`, and `critical`.
- iPhone shell code reacts to memory and thermal pressure and can trim or unload proactively.
- The repo’s supported minimum-hardware path is “smooth and reliable on the default path,” not “every optional quality mode is guaranteed on floor hardware.”

## Distribution

macOS:

- supported hosted install path: signed and notarized DMG on GitHub Releases
- intended release asset name: `Vocello-macos26.dmg`

iPhone:

- supported hosted install path: App Store / TestFlight
- GitHub Releases are not the supported iPhone install surface

Source builds remain supported for both platforms.

## Build And Validation Surface

Project and automation source of truth:

- `project.yml`
- `scripts/`
- `.github/workflows/`

Active GitHub workflows:

- `Project Inputs`
- `Apple Platform Validation`
- `Vocello macOS Release`
- `Vocello iOS TestFlight`

Key local checks:

```sh
./scripts/check_project_inputs.sh
python3 scripts/harness.py validate
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer native
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build
xcodebuild -project QwenVoice.xcodeproj -scheme VocelloiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES build
python3 scripts/check_ios_catalog.py
./scripts/release.sh
./scripts/release_ios_testflight.sh
```

`QWENVOICE_ENABLE_NATIVE_ENGINE_LIVE_TESTS=1` still enables the opt-in macOS live smoke test against an installed model.

Visual and interaction verification remains partly manual through local Computer Use passes after the cheap source gates are green.

## Current Documentation Boundaries

- `AGENTS.md` is the primary repo-operating guide for agents and maintainers.
- `docs/README.md` is the index of the maintained documentation set.
- `docs/reference/current-state.md`, `docs/reference/engineering-status.md`, and `docs/reference/vendoring-runtime.md` are the maintained reference docs.
- `README.md` is the public GitHub landing page.
- `docs/qwen_tone.md` is a supplemental guidance doc, not a maintained reference doc.
