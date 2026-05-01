# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Companion Docs

- `AGENTS.md` is the full repo operating guide (Codex-authored, but authoritative for Claude too). Treat this file as the fast index; fall back to `AGENTS.md` for detail.
- `README.md` covers product surface, supported platforms, and the basic build flow.
- `CONTRIBUTING.md` covers contributor flow.
- `docs/reference/current-state.md`, `docs/reference/engineering-status.md`, and `docs/reference/release-readiness.md` are the maintained engineering references.

## Source Of Truth

When repo facts disagree, trust in this order:

1. `Sources/`
2. `project.yml`
3. `scripts/` plus `.github/workflows/`
4. `docs/reference/current-state.md`, `engineering-status.md`, `release-readiness.md`
5. other prose docs

`Sources/Resources/qwenvoice_contract.json` is the source of truth for shared model, speaker, variant, output, and required-file metadata.

## Common Commands

Always start with the cheap gates:

```sh
./scripts/check_project_inputs.sh
python3 scripts/harness.py validate
```

Project regen (after editing `project.yml`):

```sh
./scripts/regenerate_project.sh
```

Builds:

```sh
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build
xcodebuild -project QwenVoice.xcodeproj -scheme VocelloiOS \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES build
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
```

Tests (the harness is the single entrypoint; pick the layer you need — there is no "single test" knob below the layer):

```sh
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer native
python3 scripts/harness.py test --layer ios     # structurally skips when no iOS simulator is installed
python3 scripts/harness.py test --layer e2e
QWENVOICE_E2E_STRICT=1 python3 scripts/harness.py test --layer e2e   # release-signoff strict mode
python3 scripts/harness.py diagnose
```

Benchmarks are opt-in, never default gates:

```sh
python3 scripts/harness.py bench --category latency|load|quality|tts_roundtrip --runs 3
```

Local rescue and release:

```sh
./scripts/rescue_gate.sh --fast        # docs / static cleanup
./scripts/rescue_gate.sh                # full lane; gates on swap, override via QW_RESCUE_SWAP_LIMIT_MB
./scripts/release.sh --preflight full
./scripts/verify_release_bundle.sh build/Vocello.app
./scripts/verify_packaged_dmg.sh build/Vocello-macos26.dmg build/release-metadata.txt
```

Harness artifacts: `build/harness/{derived-data,results,source-packages,artifacts}`. On failure, inspect the `.xcresult` bundle:

```sh
xcrun xcresulttool get build-results  --path build/harness/results/<layer>/...
xcrun xcresulttool get test-results summary --path build/harness/results/<layer>/...
```

SourceKit diagnostics like `No such module 'MLX'` or `Cannot find type X in scope` after an edit are index staleness. Trust only `xcodebuild`, `scripts/harness.py`, and `./scripts/build_foundation_targets.sh`.

## Architecture

The repo identity stays `QwenVoice`; the shipping macOS bundle is `Vocello.app` (its Swift `PRODUCT_MODULE_NAME` is kept as `QwenVoice` so sibling modules still resolve). The iPhone app is `Vocello` for iPhone, currently deferred from public release.

**macOS process split**

- App process: `Sources/QwenVoiceApp.swift` composes app-global services and runs `AppEngineSelection`; `Sources/ContentView.swift` owns the `NavigationSplitView` chrome and persisted drafts.
- App-side engine layer: `Sources/QwenVoiceNative/` — `TTSEngineStore`, `XPCNativeEngineClient`, chunk brokering, `MacTTSEngine`.
- Transport boundary: `Sources/QwenVoiceEngineSupport/`.
- Out-of-process helper: `Sources/QwenVoiceEngineService/` (XPC service, hosts the active shared-core runtime through `QwenVoiceCore`).

**iPhone process split**

- App shell: `Sources/iOS/` + `Sources/iOSSupport/` (SwiftUI, model delivery UX, library/history, memory-pressure coordination).
- Engine extension: `Sources/iOSEngineExtension/` runs heavy generation/prewarm out of the UI process via ExtensionKit. Discovery: `Sources/iOS/VocelloEngineExtensionPoint.swift`. Active transport replacement / teardown: `Sources/QwenVoiceCore/ExtensionEngineHostManager.swift`.

**Cross-platform core**

- `Sources/QwenVoiceCore/` owns shared engine semantics, contract types, model-variant resolution, and ExtensionKit transport. Keep it free of app-process UI assumptions.
- `Sources/SharedSupport/` owns shared playback and generation-persistence surfaces consumed by both shells.
- `Sources/Services/AppPaths.swift` (macOS) and `Sources/iOSSupport/Services/AppPaths.swift` (iPhone) are the runtime-data path boundaries. Default macOS data root: `~/Library/Application Support/QwenVoice/{models,outputs,voices,history.sqlite}` (override via `QWENVOICE_APP_SUPPORT_DIR`).

**Retained-vs-live runtime split**

`Sources/QwenVoiceNativeRuntime/` keeps duplicate copies of runtime types (notably `NativeStreamingSynthesisSession`) alongside the live `Sources/QwenVoiceCore/` implementations. Behavior fixes in shared streaming/session semantics often need to land in **both** copies until the split is consolidated.

**Manifests**

- `Sources/Resources/qwenvoice_contract.json` is loaded by `Sources/Models/TTSContract.swift`, `Sources/Models/TTSModel.swift`, and the `QwenVoiceCore` semantic types.
- `config/apple-platform-capability-matrix.json` is the release-verification baseline for bundle ids, app groups, opportunistic memory-limit entitlements, and packaged-resource exclusions.

**Vendored backend**

`third_party_patches/mlx-audio-swift/` is the repo-owned MLXAudioSwift source. Keep its package manifest pinned with `project.yml` and `Package.resolved`.

## Repo-Specific Rules

These override generic agent defaults — read them before editing.

- **No repo-owned Python backend, Python setup path, or standalone CLI.** Do not reintroduce one.
- **Git default**: work on the user-designated branch (currently `claude/init-project-7ZdXV`). Do not create extra branches or worktrees unless the user asks.
- **Edit `project.yml`, never the generated `*.xcodeproj` files directly.** Run `./scripts/regenerate_project.sh` after structural changes. Watch outputs for accidental `__pycache__`, `.pyc`, `.DS_Store`, or `.profraw` paths.
- The macOS app target intentionally **excludes** `QwenVoiceEngineService/`, `QwenVoiceEngineSupport/`, `QwenVoiceNativeRuntime/`, `iOS*/`, `Resources/ffmpeg/`, and `Resources/vendor/` from its `Sources` glob; the XPC service is embedded as a separate target. Keep that split intact.
- **Process isolation is a product requirement** on both platforms. Do not move heavy generation, prewarm, or model-load work back into the UI process.
- **Platform floors**: macOS 26.0+ and iOS 26.0+; Apple Silicon; Mac mini M1 8 GB / iPhone 15 Pro minimums. iPhone uses 4-bit Speed only; macOS defaults to 4-bit Speed and may expose 8-bit Quality where admission allows. `macOS 15` and `QW_UI_LEGACY_GLASS` are retired — do not restore.
- **`QW_TEST_SUPPORT`** is a Debug/test-only Swift compilation condition (stub engines, fault injection, fixtures, opt-in benchmark hooks). Release builds must not depend on it.
- **Native SwiftUI discipline**: prefer standard SwiftUI primitives plus `Sources/Views/Components/AppTheme.swift` (macOS) or the iPhone shell theme. Do not reintroduce the removed desktop-studio shell, generated-reference redesign, hero chrome, inspector layout, or full-window footer player.
- **Operational safety on this 8 GB dev machine**: never overlap heavy `xcodebuild`, `scripts/harness.py`, release packaging, live app validation, or benchmark processes. Kill old `QwenVoice`/`Vocello` instances before launching a new build.

## Swift Concurrency Gotchas

- `Self` cannot be referenced inside a `static let` initializer on a class — use the concrete type name (e.g. `EngineServiceHost.logger`) instead of `Self.logger`.
- `Task.detached { ... }` does not inherit cancellation. If cancellation must propagate, wrap `try await task.value` in `withTaskCancellationHandler { ... } onCancel: { task.cancel() }`.
- `AsyncThrowingStream` consumers do not automatically observe the consuming task's cancellation when the producer runs in its own `Task`. Add `try Task.checkCancellation()` at the top of `for try await` loop bodies.
- When promoting a helper out of a `@MainActor`-isolated class to module scope, mark the closure parameter `@MainActor` (e.g. `condition: @escaping @MainActor () -> Bool`) and invoke via `await MainActor.run(body: condition)`. Without this, Swift 6 flags call sites as "Sending risks data race".

## When Changing X, Also Update Y

- Model registry / speakers / output folders / required model files / install variants → `Sources/Resources/qwenvoice_contract.json` first, then contract loaders and contract-facing docs.
- Adding or renaming source files → `project.yml`, then `./scripts/regenerate_project.sh`.
- Shared engine semantics or model-variant resolution → review `Sources/QwenVoiceCore/` and iPhone model delivery together; mirror retained runtime copies in `Sources/QwenVoiceNativeRuntime/` when applicable.
- macOS engine/client behavior → review `QwenVoiceNative/`, `QwenVoiceEngineSupport/`, and `QwenVoiceNativeRuntime/` together.
- iPhone engine extension transport / host → review `QwenVoiceCore/Extension*`, `iOSEngineExtension/`, and `iOS/VocelloEngineExtensionPoint.swift` together.
- Memory pressure / prewarm / low-RAM admission → `QwenVoiceCore/IOSMemorySnapshot.swift`, `iOS/TTSEngineStore.swift`, `iOS/QVoiceiOSApp.swift`, plus iPhone settings/status UI.
- Playback or generation persistence → `Sources/SharedSupport/` and the affected feature views.
- macOS release packaging / notarization → `scripts/release.sh`, `scripts/create_dmg.sh`, `scripts/verify_release_bundle.sh`, `scripts/verify_packaged_dmg.sh`, `.github/workflows/macos-release.yml`, and release-facing docs.
- iPhone TestFlight → `scripts/check_ios_catalog.py`, `scripts/release_ios_testflight.sh`, `scripts/verify_ios_release_archive.sh`, `.github/workflows/ios-testflight.yml`.

## Before Finishing

- Prefer manifest-backed data over duplicated constants.
- Keep accessibility identifiers stable when UI control types change.
- Re-run `./scripts/check_project_inputs.sh` and `python3 scripts/harness.py validate` plus the most relevant harness layer before declaring work complete.
- If you changed engine architecture, runtime ownership, or release behavior, verify that `AGENTS.md` and `docs/reference/current-state.md` still describe the same split.
