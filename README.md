## QwenVoice, Home Of Vocello For Mac And iPhone

QwenVoice is the repository and continuity brand. Vocello is the shipped app brand for the merged Apple-platform product line.

This repo now contains one shared Apple-platform codebase for:

- Vocello for Mac
- Vocello for iPhone

Internal module, path, and target names still use `QwenVoice` in several places for repo continuity and lower migration churn.

## Product Direction

The merged architecture is built around:

- `Sources/QwenVoiceCore/` for shared runtime semantics, contract types, model variants, and iOS extension transport
- `Sources/QwenVoiceNative/`, `Sources/QwenVoiceEngineSupport/`, `Sources/QwenVoiceNativeRuntime/`, and `Sources/QwenVoiceEngineService/` for the macOS app-side XPC client, shared IPC, service runtime, and bundled helper
- `Sources/iOS/`, `Sources/iOSSupport/`, and `Sources/iOSEngineExtension/` for the iPhone shell, support layers, and isolated engine extension process
- `third_party_patches/mlx-audio-swift/` as the single vendored MLXAudioSwift boundary

Heavy generation, prewarm, and model-load work stays out of the UI process on both platforms:

- macOS uses the bundled XPC helper
- iPhone uses an ExtensionFoundation-hosted engine extension on iOS 26

## Supported Platforms

| Platform | Minimum OS | Minimum Hardware | Distribution |
|---|---|---|---|
| macOS | `26.0+` | `Mac mini M1, 8 GB RAM` | signed and notarized DMG on GitHub Releases |
| iPhone | `iOS 26.0+` | `iPhone 15 Pro` | App Store / TestFlight |

Source builds remain supported for both platforms.

## Model Variants

Static model metadata lives in [`Sources/Resources/qwenvoice_contract.json`](Sources/Resources/qwenvoice_contract.json).

The shared logical mode families remain:

- Custom Voice
- Voice Design
- Voice Cloning

Install variants now diverge by platform:

- iPhone uses 4-bit `Speed` variants only
- macOS defaults to 4-bit `Speed` on minimum hardware and can also use 8-bit `Quality`

## Current Build And Validation Surface

Fast local gates:

```sh
./scripts/check_project_inputs.sh
python3 scripts/harness.py validate
```

Core source checks:

```sh
./scripts/regenerate_project.sh
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build
xcodebuild -project QwenVoice.xcodeproj -scheme VocelloiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES build
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer native
```

Release-oriented local commands:

```sh
./scripts/release.sh
./scripts/verify_release_bundle.sh build/QwenVoice.app
./scripts/verify_packaged_dmg.sh build/Vocello-macos26.dmg build/release-metadata.txt
python3 scripts/check_ios_catalog.py
./scripts/release_ios_testflight.sh
```

The macOS release asset is Vocello-branded even though the current macOS target graph still keeps `QwenVoice` as its internal target/scheme identity.

## Distribution

macOS:

- GitHub Releases are the supported hosted install path
- the maintained release workflow produces a signed and notarized `Vocello-macos26.dmg`

iPhone:

- App Store / TestFlight are the supported install paths
- GitHub Releases are not the iPhone install surface
- source builds stay available from this repo

StoreKit one-time unlock work is intentionally deferred until after the merge stabilizes.

## Maintained Docs

- [`AGENTS.md`](AGENTS.md) — primary repo operating guide
- [`docs/README.md`](docs/README.md) — documentation index
- [`docs/reference/current-state.md`](docs/reference/current-state.md) — current repo facts
- [`docs/reference/engineering-status.md`](docs/reference/engineering-status.md) — strengths, caveats, and validation posture
- [`docs/reference/vendoring-runtime.md`](docs/reference/vendoring-runtime.md) — vendoring and runtime ownership notes

## Credits

Vocello builds on:

- [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)
- [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift)
- [MLX](https://github.com/ml-explore/mlx)
- [GRDB.swift](https://github.com/groue/GRDB.swift)
