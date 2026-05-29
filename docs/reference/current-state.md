# QwenVoice Current State

This document is the shared factual reference for the current QwenVoice repository state.

## Product Surface

- Repo identity: `QwenVoice`
- Currently shipped public stable brand: `Vocello` (`v2.0.0`)
- Legacy fallback brand: `QwenVoice` (`v1.2.3`) — macOS 15 only
- Platforms in this repo: macOS and iPhone
- Active public release track: `macOS-first release track`
- Deployment targets: `macOS 26.0+` and `iOS 26.0+`
- Official minimum hardware floor:
  - `Mac mini M1, 8 GB RAM`
  - `iPhone 15 Pro`
- Version source: `project.yml`
- Current workspace version/build on `main`: `2.0.0` / `16`
- Shipped public stable version/build: `2.0.0` / `16`
- Legacy macOS 15 fallback version/build: `1.2.3` / `15`

The iPhone app target is Vocello-branded. The public macOS release ships as `Vocello.app` inside `Vocello-macos26.dmg` on a hard `macOS 26.0` minimum, signed with an Apple Developer ID certificate and Apple-notarized. The supporting framework/service/runtime modules (`QwenVoiceCore`, `QwenVoiceEngineService`, `QwenVoiceEngineSupport`, `QwenVoiceNative`) keep their `QwenVoice` names internally for continuity.

## Public Homepage Posture

- `README.md` leads with `Vocello 2.0.0` (stable) for macOS 26+ users, while keeping `QwenVoice v1.2.3` as the legacy fallback for macOS 15.
- The GitHub repo description should stay consistent with the README: Vocello is the current public macOS 26+ release, and QwenVoice v1.2.3 is the legacy macOS 15 fallback.
- Public copy should stay aligned with the currently shipped macOS reality and the active `macOS-first release track`.
- The withdrawn `2.0.0` RC1 GitHub release must not be linked or advertised; the public Vocello link is `v2.0.0`.
- Do not present iPhone as a current public release surface until the release-track policy changes. The public framing for iPhone is the in-development "Vocello for iPhone" — standalone, 4-bit, open source in this repo, published via the App Store once ready.
- The GitHub homepage URL should stay blank unless the repo owner explicitly asks to set it again.

## Architecture

This repo now carries one Apple-platform codebase with a shared engine core and platform-specific isolated hosts.

Shared engine core:

- `Sources/QwenVoiceCore/` for the repo-owned semantic source of truth, contract-backed model descriptors, shared lifecycle/capability primitives, platform-specific artifact resolution, low-RAM iPhone policy, and engine-extension IPC

macOS runtime split:

- `Sources/` for the macOS app shell, views, services, and app-owned state
- `Sources/QwenVoiceNative/` for the macOS app-facing engine proxy/store/client layer
- `Sources/QwenVoiceEngineSupport/` for shared macOS engine IPC, transport types, and trust policy
- `Sources/QwenVoiceEngineService/` for the bundled XPC helper embedded into the Mac app and the active shared-core runtime host

iPhone runtime split:

- `Sources/iOS/` for the SwiftUI app shell and UI-owned orchestration
- `Sources/iOSSupport/` for iPhone-only support services, paths, and model-delivery layers
- `Sources/SharedSupport/` for cross-platform playback state, generation persistence, and other shared app-layer helpers
- `Sources/iOSEngineExtension/` for the isolated engine-extension process hosted through ExtensionFoundation

iPhone host ownership:

- `Sources/iOS/VocelloEngineExtensionPoint.swift` owns monitor-backed extension discovery and preferred-identity selection
- `Sources/QwenVoiceCore/ExtensionEngineHostManager.swift` owns active transport replacement, invalidation, and teardown for the iPhone host/runtime boundary

Vendored native backend boundary:

- `third_party_patches/mlx-audio-swift/`

Heavy generation, prewarm, and model-load work stays out of the UI process on both platforms:

- macOS uses the bundled XPC helper, which now hosts `MLXTTSEngine` from `QwenVoiceCore`
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
- Hugging Face repos and immutable revisions

The shared logical mode families remain:

- `custom`
- `design`
- `clone`

Platform-specific install policy:

- macOS exposes both `Speed / 4-bit` and `Quality / 8-bit` variants for Custom Voice, Voice Design, and Voice Cloning.
- 8 GB/floor Macs default to and recommend `Speed / 4-bit`; mid/high-memory Macs default to and recommend `Quality / 8-bit`.
- Mac users may select either installed macOS variant per generation mode. Status, downloads, repair/delete actions, install metadata, and progress are keyed by variant-specific IDs such as `pro_custom_speed` and `pro_custom_quality`.
- Installed Speed and Quality folders can coexist under the macOS app-support `models/` subtree.
- Legacy base IDs such as `pro_custom`, `pro_design`, and `pro_clone` remain compatibility aliases to the hardware-recommended variant.
- iPhone resolves to and downloads `Speed / 4-bit` variants only.

## Memory And Isolation Posture

- iPhone memory policy lives in `Sources/QwenVoiceCore/IOSMemorySnapshot.swift` and the iPhone `TTSEngineStore` / app shell layers.
- The shared memory bands are `healthy`, `guarded`, and `critical`.
- iPhone shell code reacts to memory and thermal pressure and can trim or unload proactively.
- On-device MLX generation on iPhone is **blocked at the product level** until Apple approves `com.apple.developer.kernel.increased-memory-limit` for the app and engine extension; the repo blocks model admission when extension headroom is low rather than risking Jetsam. Maintainer docs: [`ios-shipping.md`](ios-shipping.md).
- The iPhone App Group surface is intentionally limited to the shared app-support subtree rooted by `Sources/iOSSupport/Services/AppPaths.swift` for models, downloads, outputs, voices, and required cache state; no parallel shared-user-defaults channel is maintained.
- macOS active model-quality selection is stored as normal app preference state per generation mode; model files themselves remain folder-based under app support.
- The repo’s supported minimum-hardware path is “smooth and reliable on the default path,” not “every optional quality mode is guaranteed on floor hardware.”

## Distribution

macOS:

- supported hosted install path: signed and notarized DMG on GitHub Releases
- intended release asset name: `Vocello-macos26.dmg`
- current public release target: yes

iPhone:

- supported hosted install path: App Store / TestFlight
- current public release target: deferred until entitlement, TestFlight, and minimum-device proof are recorded
- GitHub Releases are not the supported iPhone install surface

Source builds remain supported for both platforms.

## Build And Validation Surface

Project and automation source of truth:

- `project.yml`
- `scripts/`
- `config/apple-platform-capability-matrix.json`

The only maintained GitHub workflow is `.github/workflows/release.yml`: macOS DMG packaging plus iOS compile-safety, with no tests, smoke, benchmarks, or signed iOS IPA. XCTest targets and the legacy Python/CI benchmark harnesses were retired in May 2026; the agent-driven macOS UI-driving / bench harness and the iPhone device-deploy / proof / TestFlight tooling were removed in a later cleanup. Build, packaging, signing, and notarization are driven locally on Mac mini M2 via the `scripts/` tooling; iPhone is compile-safe only. Behavioral verification is manual local app acceptance — build and launch the app and exercise the affected paths by hand. Debug macOS checks use `./scripts/build.sh run` against the persistent `QwenVoice-Debug` store. Release macOS checks use `build/Release/Vocello.app` after `./scripts/release.sh`; that repo-local app gets a fresh release-id-specific app-support folder and preferences suite.

Key local checks:

```sh
./scripts/check_project_inputs.sh
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build
xcodebuild -project QwenVoice.xcodeproj -scheme VocelloiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES build
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
./scripts/check_ios_catalog.sh
./scripts/release.sh
```

For deterministic local compile proof, prefer `./scripts/build_foundation_targets.sh` over a shared-DerivedData signed debug build. The deterministic script uses isolated derived-data and `.xcresult` roots so stale build artifacts cannot pollute app codesigning.

The maintained local build layout now uses only two top-level folders under `build/`:

- `build/Debug/` for development builds, Debug DerivedData, foundation compile-proof output, diagnostics, and agent smoke/bench artifacts.
- `build/Release/` for macOS GitHub release artifacts, release DerivedData, release logs/metadata, source packages, `.xcresult` bundles, and iOS TestFlight archive/export output.

## Current Documentation Boundaries

- `docs/README.md` is the index of the maintained documentation set.
- `docs/reference/current-state.md`, `docs/reference/engineering-status.md`, `docs/reference/backend-freeze-gate.md`, `docs/reference/frontend-backend-contract.md`, and `docs/reference/vendoring-runtime.md` are the maintained reference docs.
- `docs/reference/privacy-storage.md` records local storage, deletion paths, and voice-cloning consent posture.
- `README.md` is the public GitHub landing page.
- `docs/qwen_tone.md` is a supplemental guidance doc, not a maintained reference doc.
