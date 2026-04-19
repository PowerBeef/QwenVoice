# AGENTS.md

This is the primary repo operating guide for coding agents working in QwenVoice.

## Repo Overview

QwenVoice is the repository identity and continuity brand for the merged Vocello Apple-platform product line.

Current product reality:

- the repo stays `QwenVoice`
- the shipped iPhone app is `Vocello`
- macOS release assets are Vocello-branded, while several internal macOS targets, modules, and paths still keep `QwenVoice` names for continuity

The main working surfaces are:

- `Sources/` for the macOS app shell, shared app models/services/views, and the shipping Mac target
- `Sources/QwenVoiceCore/` for shared Apple-platform runtime semantics, contract types, model variants, and iOS extension transport
- `Sources/QwenVoiceNative/` for the macOS app-facing engine proxy/store/client layer
- `Sources/QwenVoiceEngineSupport/` for shared macOS engine IPC and transport types
- `Sources/QwenVoiceNativeRuntime/` for macOS service-only native execution
- `Sources/QwenVoiceEngineService/` for the bundled macOS XPC helper
- `Sources/iOS/` and `Sources/iOSSupport/` for the iPhone app shell and support layers
- `Sources/iOSEngineExtension/` for the isolated iPhone engine extension target
- `Sources/Resources/qwenvoice_contract.json` for shared model, variant, speaker, output, and required-file metadata
- `scripts/` plus `.github/workflows/` for validation, release packaging, and CI behavior

This checkout is native-only. Do not reintroduce a repo-owned Python backend, Python setup path, or standalone CLI surface.

## Maintained Docs

The maintained repo docs are:

- `AGENTS.md`
- `README.md`
- `docs/README.md`
- `docs/reference/current-state.md`
- `docs/reference/engineering-status.md`
- `docs/reference/vendoring-runtime.md`

Do not point contributors at removed CLI docs, deleted backend references, or deleted repo-scoped QwenVoice skills.

## Source Of Truth

When repo facts disagree, trust sources in this order:

1. `Sources/`
2. `project.yml`
3. `scripts/` plus `.github/workflows/`
4. `docs/reference/current-state.md` and `docs/reference/engineering-status.md`
5. other prose docs

`Sources/Resources/qwenvoice_contract.json` is the source of truth for shared model, speaker, and platform-variant metadata.

## Git Workflow Default

- Work directly on `main` by default.
- Do not create branches or worktrees unless the user explicitly asks for one.
- Do not let generic tool, plugin, or skill defaults override this repo-specific rule.

## Safe Edit Boundaries

- `project.yml` drives `QwenVoice.xcodeproj`. Prefer editing `project.yml` and regenerating the project over hand-editing generated project files.
- The macOS app target intentionally excludes `Sources/QwenVoiceEngineService/`, `Sources/QwenVoiceEngineSupport/`, and `Sources/QwenVoiceNativeRuntime/` as ordinary app sources while embedding the XPC service target through `project.yml`. Keep that split intact.
- The iPhone app target and the iPhone engine-extension target both depend on `QwenVoiceCore`. Keep engine execution isolated from the iPhone UI process.
- `third_party_patches/mlx-audio-swift/` is the repo-owned native backend source boundary for MLXAudioSwift. Keep its package manifest and pins aligned with `project.yml` and `Package.resolved`.
- If `Sources/Resources/ffmpeg/` or `Sources/Resources/vendor/` appear locally, treat them as generated or local-only leftovers, not as maintained tracked checkout surfaces.
- App data under `~/Library/Application Support/QwenVoice/` or a `QWENVOICE_APP_SUPPORT_DIR` override is runtime state, not repo source.
- Watch for accidental `__pycache__`, `.pyc`, `.DS_Store`, and `.profraw` paths when regenerating or reviewing changes.

## Architecture Boundaries

- `Sources/QwenVoiceApp.swift` composes macOS app-global services, owns the separate Settings scene, and initializes the app-facing Mac engine through `AppEngineSelection`.
- `Sources/ContentView.swift` owns the macOS `NavigationSplitView`, toolbar/search chrome, sidebar selection, and persisted generation drafts.
- `Sources/QwenVoiceNative/` is the macOS app-side engine layer: `TTSEngineStore`, `XPCNativeEngineClient`, chunk brokering, and the app-facing `MacTTSEngine` surface live there.
- `Sources/QwenVoiceEngineSupport/` is the shared macOS engine transport boundary used by both the app and the helper.
- `Sources/QwenVoiceNativeRuntime/` is the macOS service-only runtime boundary. Keep model load, prewarm, generation, cancellation, and clone preparation ownership there instead of in the app process.
- `Sources/QwenVoiceEngineService/` owns the bundled macOS XPC helper entrypoint and session/host behavior.
- `Sources/QwenVoiceCore/` is the cross-platform engine core and shared semantic boundary. Keep it free of app-process UI assumptions.
- `Sources/iOSEngineExtension/` hosts the isolated iPhone engine process through ExtensionFoundation. Heavy generation and prewarm work belongs there, not in the iPhone UI app process.
- `Sources/iOS/` and `Sources/iOSSupport/` own the iPhone SwiftUI shell, model delivery UX, playback UI, library/history views, and memory-pressure coordination.
- `Sources/Services/AppPaths.swift` and `Sources/iOSSupport/Services/AppPaths.swift` are the path boundaries for runtime data on each platform.
- `Sources/Models/TTSContract.swift`, `Sources/Models/TTSModel.swift`, and the `QwenVoiceCore` semantic types load `Sources/Resources/qwenvoice_contract.json`.

## Platform And Product Constraints

- Minimum supported OS versions are `macOS 26.0+` and `iOS 26.0+`.
- The official minimum hardware floor is `Mac mini M1, 8 GB RAM` and `iPhone 15 Pro`.
- Process isolation is a product requirement on both platforms. Do not move heavy generation, prewarm, or model-load work back into the UI process.
- `QW_UI_LEGACY_GLASS` and macOS 15 compatibility are retired. Do not restore older dual-profile or dual-OS support.
- iPhone uses 4-bit `Speed` variants only.
- macOS defaults to 4-bit `Speed` on minimum hardware and can also expose 8-bit `Quality` when runtime admission allows it.
- Keep shared styling centralized in `Sources/Views/Components/AppTheme.swift` on macOS and in the iPhone shell primitives/theme layer on iOS.

## Required Workflows

Start with repo truth first:

- Search with `rg`, inspect source, manifests, scripts, and workflows before assuming docs are current.
- Prefer repo scripts, `python3 scripts/harness.py`, and `xcodebuild` over improvised one-off workflows.

Fast gates:

```bash
./scripts/check_project_inputs.sh
python3 scripts/harness.py validate
```

Core local commands:

```bash
./scripts/regenerate_project.sh
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build
xcodebuild -project QwenVoice.xcodeproj -scheme VocelloiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES build
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer native
python3 scripts/harness.py test --layer audio --artifact-dir <dir>
python3 scripts/harness.py diagnose
python3 scripts/harness.py bench --category latency
python3 scripts/harness.py bench --category load
python3 scripts/harness.py bench --category quality
python3 scripts/harness.py bench --category tts_roundtrip
python3 scripts/check_ios_catalog.py
./scripts/release.sh
./scripts/release_ios_testflight.sh
QWENVOICE_ENABLE_NATIVE_ENGINE_LIVE_TESTS=1 xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice -destination 'platform=macOS' -only-testing:QwenVoiceTests/NativeMLXMacEngineLiveTests test
```

Notes:

- `scripts/harness.py` remains the primary local test, diagnostic, and benchmark entrypoint.
- The maintained harness layers are `swift`, `contract`, `native`, and `audio`.
- On this machine, keep validation deliberately low-RAM and serialized: run the cheapest relevant gate first, and never overlap heavy `xcodebuild`, `scripts/harness.py`, release packaging, live app validation, or native smoke processes.
- Do not jump to live native smoke, local packaging, or manual Computer Use until `./scripts/check_project_inputs.sh`, `python3 scripts/harness.py validate`, and the smallest relevant source gate are already green.

## CI And Release Workflows

The active GitHub workflows are:

- `Project Inputs`
- `Apple Platform Validation`
- `Vocello macOS Release`
- `Vocello iOS TestFlight`

Release facts:

- macOS GitHub Releases carry the signed and notarized `Vocello-macos26.dmg`.
- iPhone distribution is App Store / TestFlight only. Do not add iPhone install artifacts to GitHub Releases.
- `scripts/release.sh` is the maintained local macOS packaging entrypoint.
- `scripts/release_ios_testflight.sh` is the maintained iPhone archive/export entrypoint.
- Shipped macOS bundles and notarized DMGs must not contain `Contents/Resources/backend`, `Contents/Resources/python`, or bundled `Contents/Resources/ffmpeg`.

## When Changing X, Also Update Y

- Model registry, speakers, output folders, required model files, or platform-specific install variants:
  update `Sources/Resources/qwenvoice_contract.json` first, then the contract loaders, platform delivery code, and contract-facing docs/tests.
- Adding or renaming source files:
  update `project.yml`, run `./scripts/regenerate_project.sh`, and confirm generated project files did not capture `__pycache__` or `.pyc` paths.
- Shared engine semantics or model-variant resolution:
  review `Sources/QwenVoiceCore/`, iPhone model delivery code, and affected tests together.
- macOS engine/client behavior:
  review `Sources/QwenVoiceNative/`, `Sources/QwenVoiceEngineSupport/`, `Sources/QwenVoiceNativeRuntime/`, and the affected tests together.
- iPhone engine-extension transport or host behavior:
  review `Sources/QwenVoiceCore/Extension*`, `Sources/iOSEngineExtension/`, `Sources/iOS/VocelloEngineExtensionPoint.swift`, and iPhone build/test coverage together.
- Memory-pressure, prewarm, or low-RAM admission behavior:
  review `Sources/QwenVoiceCore/IOSMemorySnapshot.swift`, `Sources/iOS/TTSEngineStore.swift`, `Sources/iOS/QVoiceiOSApp.swift`, and iPhone settings/status UI together.
- macOS release packaging or notarization behavior:
  keep `scripts/release.sh`, `scripts/create_dmg.sh`, `scripts/verify_release_bundle.sh`, `scripts/verify_packaged_dmg.sh`, `.github/workflows/macos-release.yml`, and release-facing docs aligned.
- iPhone archive/export/TestFlight behavior:
  keep `scripts/check_ios_catalog.py`, `scripts/release_ios_testflight.sh`, `.github/workflows/ios-testflight.yml`, and iPhone distribution docs aligned.
- Broad repo facts that users or contributors rely on:
  update `AGENTS.md`, `README.md`, `docs/README.md`, `docs/reference/current-state.md`, and `docs/reference/engineering-status.md`.

## Operational Safety

- Avoid running multiple `QwenVoice` or `Vocello` app instances at once while debugging model loads, clone prep, playback, XPC behavior, or engine-extension behavior.
- Prefer killing an old instance before launching a new build.
- Never overlap heavy `xcodebuild`, `scripts/harness.py`, release packaging, live app validation, or native smoke processes on this machine.
- Never run more than one heavy model load, generation, or benchmark at a time.
- Use Computer Use only after heavy automation is finished; never keep desktop interaction active while memory-heavy build or validation work is still running.

## Before Finishing

- Prefer manifest-backed data over duplicated constants.
- Keep accessibility identifiers stable when UI control types change.
- If you changed engine architecture or runtime ownership, verify `AGENTS.md` and `docs/reference/current-state.md` still describe the same app/service/runtime split.
- If you changed release behavior, verify the scripts, workflows, artifact names, and README/docs all still agree.
- For doc-only refreshes, rerun the stale-reference grep and verify referenced commands, workflows, artifact names, and doc links still exist.
- Run the most relevant harness layer plus `python3 scripts/harness.py validate` before calling work complete.
