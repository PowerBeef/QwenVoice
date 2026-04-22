# QwenVoice Current State

This document is the shared factual reference for the current QwenVoice repository state.

## Product Surface

- Repo identity: `QwenVoice`
- Currently shipped public brand: `QwenVoice` (`v1.2.3`)
- Forward rebrand target: `Vocello` — lands with the next macOS release
- Platforms in this repo: macOS and iPhone
- Active public release track: `macOS-first release track`
- Deployment targets: `macOS 26.0+` and `iOS 26.0+`
- Official minimum hardware floor:
  - `Mac mini M1, 8 GB RAM`
  - `iPhone 15 Pro`
- Version source: `project.yml`
- Current version/build: `1.2.3` / `15`

The iPhone app target is Vocello-branded. The next macOS release ships as `Vocello.app` inside `Vocello-macos26.dmg` on a hard `macOS 26.0` minimum — completing the public rebrand on macOS. The supporting framework/service/runtime modules (`QwenVoiceCore`, `QwenVoiceEngineService`, `QwenVoiceEngineSupport`, `QwenVoiceNative`, `QwenVoiceNativeRuntime`) keep their `QwenVoice` names internally for continuity.

## Public Homepage Posture

- `README.md` leads with `QwenVoice` because that is the currently shipped public brand (`v1.2.3`). Its "A Note on What's Changing" section frames `Vocello` as the forward rebrand that lands with the next macOS release.
- The GitHub repo description should stay consistent with the README — do not claim a Vocello-first public posture while the published release is still QwenVoice-branded.
- Public copy should stay aligned with the currently shipped macOS reality and the active `macOS-first release track`.
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
- `Sources/QwenVoiceNativeRuntime/` as a retained compatibility and regression surface rather than the primary macOS runtime-policy owner

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
- The iPhone App Group surface is intentionally limited to the shared app-support subtree rooted by `Sources/iOSSupport/Services/AppPaths.swift` for models, downloads, outputs, voices, and required cache state; no parallel shared-user-defaults channel is maintained.
- The repo’s supported minimum-hardware path is “smooth and reliable on the default path,” not “every optional quality mode is guaranteed on floor hardware.”

## Distribution

macOS:

- supported hosted install path: signed and notarized DMG on GitHub Releases
- intended release asset name: `Vocello-macos26.dmg`
- current public release target: yes

iPhone:

- supported hosted install path: App Store / TestFlight
- current public release target: deferred until the shared core is proven stable on macOS
- GitHub Releases are not the supported iPhone install surface

Source builds remain supported for both platforms.

## Build And Validation Surface

Project and automation source of truth:

- `project.yml`
- `scripts/`
- `.github/workflows/`
- `config/apple-platform-capability-matrix.json`

Active GitHub workflows:

- `Project Inputs`
- `Backend Freeze Gate` for shared-core regression proof, generic macOS/iPhone builds, unsigned macOS release verification, and `.xcresult` artifact upload
- `Vocello macOS Release` as the only signed/public release workflow required for the current milestone
- `Vocello iOS TestFlight` as the maintained but deferred iPhone release workflow

Key local checks:

```sh
./scripts/check_project_inputs.sh
python3 scripts/harness.py validate
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer native
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build
xcodebuild -project QwenVoice.xcodeproj -scheme VocelloiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES build
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
python3 scripts/check_ios_catalog.py
./scripts/release.sh
./scripts/release_ios_testflight.sh
```

`python3 scripts/harness.py test --layer ios` remains maintained, but it is no longer part of the default required path for the current public release milestone. Run it when the change directly touches iPhone app, extension, model-delivery, or memory-policy behavior, or when preparing to re-open the iPhone release track.

`QWENVOICE_ENABLE_NATIVE_ENGINE_LIVE_TESTS=1` still enables the opt-in macOS live smoke test against an installed model.

Visual and interaction verification remains partly manual through local Computer Use passes after the cheap source gates are green.

For deterministic local compile proof, prefer `./scripts/build_foundation_targets.sh` over a shared-DerivedData signed debug build. The deterministic script uses isolated derived-data and `.xcresult` roots so stale hosted-test bundles cannot pollute app codesigning.

The maintained foundation paths now use:

- committed Xcode test plans for source and runtime-oriented suites
- explicit harness package-resolution roots under `build/harness/source-packages/`
- explicit harness derived-data roots under `build/harness/derived-data/`
- explicit `.xcresult` bundles under `build/harness/results/`
- explicit release build roots under `build/foundation/`
- explicit archive/release `.xcresult` bundles under `build/foundation/` for the maintained CI release paths

## Current Documentation Boundaries

- `CLAUDE.md` is the primary repo-operating guide for agents and maintainers.
- `docs/README.md` is the index of the maintained documentation set.
- `docs/reference/current-state.md`, `docs/reference/engineering-status.md`, `docs/reference/backend-freeze-gate.md`, `docs/reference/frontend-backend-contract.md`, and `docs/reference/vendoring-runtime.md` are the maintained reference docs.
- `README.md` is the public GitHub landing page.
- `docs/qwen_tone.md` is a supplemental guidance doc, not a maintained reference doc.
