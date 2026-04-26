# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository. It is the primary repo operating guide for coding agents working in QwenVoice.

## Repo Overview

QwenVoice is the repository identity and continuity brand for the merged Vocello Apple-platform product line.

Current product reality:

- the repo stays `QwenVoice`
- the shipped iPhone app is `Vocello`
- the next macOS release ships as `Vocello.app` inside `Vocello-macos26.dmg`; the supporting framework/service/runtime modules (`QwenVoiceCore`, `QwenVoiceEngineService`, `QwenVoiceEngineSupport`, `QwenVoiceNative`, `QwenVoiceNativeRuntime`) keep their `QwenVoice` names internally for continuity
- the current public milestone uses a `macOS-first release track`, with iPhone retained as a compile-safe and deferred release surface

The main working surfaces are:

- `Sources/` for the macOS app shell, shared app models/services/views, and the shipping Mac target
- `Sources/QwenVoiceCore/` for shared Apple-platform runtime semantics, contract types, model variants, and iOS extension transport
- `Sources/QwenVoiceNative/` for the macOS app-facing engine proxy/store/client layer
- `Sources/QwenVoiceEngineSupport/` for shared macOS engine IPC and transport types
- `Sources/QwenVoiceNativeRuntime/` for retained macOS compatibility and regression coverage
- `Sources/QwenVoiceEngineService/` for the bundled macOS XPC helper
- `Sources/iOS/` and `Sources/iOSSupport/` for the iPhone app shell and iPhone-only support layers
- `Sources/SharedSupport/` for cross-platform playback, persistence, and other shared app-layer helpers
- `Sources/iOSEngineExtension/` for the isolated iPhone engine extension target
- `Sources/Resources/qwenvoice_contract.json` for shared model, variant, speaker, output, and required-file metadata
- `scripts/` plus `.github/workflows/` for validation, release packaging, and CI behavior
- `config/apple-platform-capability-matrix.json` for the maintained cross-platform capability, bundle-identity, and entitlement baseline used by release verification

This checkout is a native Apple-platform codebase for macOS and iPhone. Do not reintroduce a repo-owned Python backend, Python setup path, or standalone CLI surface.

## Maintained Docs

The maintained repo docs are:

- `AGENTS.md`
- `README.md`
- `docs/README.md`
- `docs/qwen_tone.md`
- `docs/reference/current-state.md`
- `docs/reference/engineering-status.md`
- `docs/reference/backend-freeze-gate.md`
- `docs/reference/frontend-backend-contract.md`
- `docs/reference/release-readiness.md`
- `docs/reference/live-testing.md`
- `docs/reference/vendoring-runtime.md`
- `docs/reference/mlx-audio-swift-patching.md`

There are no repo-tracked local skills under `.agents/skills/` in this checkout right now. Do not point contributors at removed CLI docs, deleted backend references, or deleted repo-scoped QwenVoice skills.

Public homepage posture:

- `README.md` leads with `QwenVoice` because that is the currently shipped public brand (`v1.2.3`). Its "A Note on What's Changing" section frames `Vocello` as the forward rebrand that lands with the next macOS release.
- The GitHub repo description must stay consistent with the README — do not claim a Vocello-first public posture while the published release is still QwenVoice-branded.
- Leave the GitHub homepage URL blank unless the user explicitly asks to restore or change it.
- Keep public messaging aligned with the currently shipped macOS product reality and the active `macOS-first release track`.
- Do not present iPhone as a current public release surface until the release-track policy changes. The iPhone app is framed publicly as the in-development "Vocello for iPhone" — standalone, 4-bit, open source in this repo, published via the App Store once ready.

Current release-track policy:

- The next public release target is macOS only.
- The next macOS release ships under the `Vocello` brand as `Vocello-macos26.dmg` and requires `macOS 26.0` as the minimum. `macOS 15` was supported only on the already-shipped `QwenVoice v1.2.3` and is retired going forward.
- Do not retroactively edit `QwenVoice v1.2.3` release notes or the shipped-state sections of `README.md` — they must stay accurate to what shipped.
- Keep iPhone green at generic compile level on `main`, but do not treat iPhone release/TestFlight proof as blocking for the current milestone.
- Re-open iPhone release proof only through an explicit milestone change after the shared core is proven stable on macOS.

## Source Of Truth

When repo facts disagree, trust sources in this order:

1. `Sources/`
2. `project.yml`
3. `scripts/` plus `.github/workflows/`
4. `docs/reference/current-state.md`, `docs/reference/engineering-status.md`, and `docs/reference/release-readiness.md`
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
- `config/apple-platform-capability-matrix.json` is the release-verification source of truth for bundle identifiers, expected application groups, opportunistic memory-limit entitlements, and packaged-resource exclusions.
- If `Sources/Resources/ffmpeg/` or `Sources/Resources/vendor/` appear locally, treat them as generated or local-only leftovers, not as maintained tracked checkout surfaces.
- App data under `~/Library/Application Support/QwenVoice/` or a `QWENVOICE_APP_SUPPORT_DIR` override is runtime state, not repo source.
- Watch for accidental `__pycache__`, `.pyc`, `.DS_Store`, and `.profraw` paths when regenerating or reviewing changes.

## Architecture Boundaries

- `Sources/QwenVoiceApp.swift` composes macOS app-global services, owns the separate Settings scene, and initializes the app-facing Mac engine through `AppEngineSelection`.
- `Sources/ContentView.swift` owns the macOS `NavigationSplitView`, toolbar/search chrome, sidebar selection, and persisted generation drafts.
- `Sources/QwenVoiceNative/` is the macOS app-side engine layer: `TTSEngineStore`, `XPCNativeEngineClient`, chunk brokering, and the app-facing `MacTTSEngine` surface live there.
- `Sources/QwenVoiceEngineSupport/` is the shared macOS engine transport boundary used by both the app and the helper.
- `Sources/QwenVoiceEngineService/` now hosts the active macOS shared-core runtime through `QwenVoiceCore`. Treat `Sources/QwenVoiceNativeRuntime/` as a retained compatibility surface rather than the primary live policy owner.
- `Sources/QwenVoiceEngineService/` owns the bundled macOS XPC helper entrypoint and session/host behavior.
- `Sources/QwenVoiceCore/` is the cross-platform engine core and shared semantic boundary. Keep it free of app-process UI assumptions.
- `Sources/iOSEngineExtension/` hosts the isolated iPhone engine process through ExtensionFoundation. Heavy generation and prewarm work belongs there, not in the iPhone UI app process.
- `Sources/iOS/VocelloEngineExtensionPoint.swift` owns monitor-backed iPhone extension discovery and preferred-identity selection, while `Sources/QwenVoiceCore/ExtensionEngineHostManager.swift` owns active transport replacement and teardown.
- `Sources/iOS/` and `Sources/iOSSupport/` own the iPhone SwiftUI shell, model delivery UX, library/history views, and memory-pressure coordination.
- `Sources/SharedSupport/` owns shared playback and generation-persistence surfaces that now serve both the macOS and iPhone apps.
- `Sources/Services/AppPaths.swift` and `Sources/iOSSupport/Services/AppPaths.swift` are the path boundaries for runtime data on each platform.
- The iPhone App Group surface is intentionally file-based and rooted under `Sources/iOSSupport/Services/AppPaths.swift`; keep shared state constrained to the required app-support subtree for models, downloads, outputs, voices, and cache data.
- `Sources/Models/TTSContract.swift`, `Sources/Models/TTSModel.swift`, and the `QwenVoiceCore` semantic types load `Sources/Resources/qwenvoice_contract.json`.
- `Sources/QwenVoiceNativeRuntime/` keeps retained copies of runtime types (notably `NativeStreamingSynthesisSession`) beside the live `Sources/QwenVoiceCore/` implementation. Behavior fixes in shared streaming/session semantics often have to land in both copies until the retained-vs-live split is consolidated.

## Platform And Product Constraints

- Minimum supported OS versions are `macOS 26.0+` and `iOS 26.0+`.
- The official minimum hardware floor is `Mac mini M1, 8 GB RAM` and `iPhone 15 Pro`.
- Process isolation is a product requirement on both platforms. Do not move heavy generation, prewarm, or model-load work back into the UI process.
- `QW_UI_LEGACY_GLASS` and macOS 15 compatibility are retired. Do not restore older dual-profile or dual-OS support.
- iPhone uses 4-bit `Speed` variants only.
- macOS defaults to 4-bit `Speed` on minimum hardware and can also expose 8-bit `Quality` when runtime admission allows it.
- Keep shared styling centralized in `Sources/Views/Components/AppTheme.swift` on macOS and in the iPhone shell primitives/theme layer on iOS.

## Native SwiftUI Discipline

- Keep UI work conservative, native, and stability-led. Prefer standard SwiftUI navigation, forms, lists, toolbars, sheets, controls, and system materials over theme-first redesigns.
- Do not reintroduce the removed desktop-studio shell, generated-reference redesign workflow, oversized hero chrome, inspector layout, full-window footer player, or decorative glass/card systems.
- Treat UI polish as small refinements to the existing app structure. Any broad layout change needs an explicit product decision and must not happen while runtime responsiveness or memory behavior is unstable.
- Keep generation screens responsive under backend activity: avoid speculative mode-switch work, broad environment-object invalidation, and visual effects that rebuild large view subtrees during prewarm or generation.

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
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer native
python3 scripts/harness.py test --layer ios
python3 scripts/harness.py test --layer e2e
QWENVOICE_E2E_STRICT=1 python3 scripts/harness.py test --layer e2e
python3 scripts/harness.py diagnose
python3 scripts/harness.py bench --category latency
python3 scripts/harness.py bench --category load
python3 scripts/harness.py bench --category quality
python3 scripts/harness.py bench --category tts_roundtrip
python3 scripts/check_ios_catalog.py
./scripts/release.sh
./scripts/release.sh --preflight full
./scripts/release_ios_testflight.sh
```

Notes:

- `scripts/harness.py` is the primary local test, diagnostic, and benchmark entrypoint.
- The maintained harness layers are `contract`, `swift`, `native`, `ios`, and `e2e`.
- `e2e` is the macOS XCUITest smoke layer. Hosted CI may soft-skip first-time macOS Accessibility/TCC or foreground-window activation failures; strict local release proof uses `QWENVOICE_E2E_STRICT=1`, where those issues fail instead of becoming skipped passes.
- Benchmarks are opt-in release-investigation lanes, not default PR gates. Use `bench --category latency|load|quality|tts_roundtrip|all` explicitly.
- The harness resolves pinned Swift packages into `build/harness/source-packages/`, uses isolated derived data under `build/harness/derived-data/`, emits `.xcresult` bundles under `build/harness/results/`, and serializes heavy lanes with `build/harness/.lock`.
- `QwenVoice Foundation`, `VocelloiOS Foundation`, and `Vocello UI` are the maintained plan-backed test schemes. The committed plans live under `tests/Plans/`.
- `QW_TEST_SUPPORT` is a Debug/test-only compilation condition for stub engines, UI launch configuration, fault injection, fixture helpers, and opt-in benchmark hooks. Release builds must not depend on that code path.
- During the current `macOS-first release track`, the default required local release-readiness loop is `check_project_inputs`, `harness validate`, `contract`, `swift`, `native`, foundation builds for macOS and iOS, `release.sh`, `verify_release_bundle.sh`, and `verify_packaged_dmg.sh`. Add strict `e2e` on the controlled release machine before public signoff.
- Keep `python3 scripts/harness.py test --layer ios` available, but expect a structured skip on machines without an installed iPhone simulator. Generic iPhone compile proof still comes from `./scripts/build_foundation_targets.sh ios`.
- For deterministic local compile proof, prefer `./scripts/build_foundation_targets.sh` over a shared-DerivedData signed debug build. The script uses isolated build roots and `.xcresult` bundles.
- On this machine, keep validation deliberately low-RAM and serialized: run the cheapest relevant gate first, and never overlap heavy `xcodebuild`, `scripts/harness.py`, release packaging, live app validation, or native smoke processes.
- Do not jump to local packaging or manual Computer Use until `./scripts/check_project_inputs.sh`, `python3 scripts/harness.py validate`, and the smallest relevant source gate are already green.
- If a harness layer fails, inspect the emitted `.xcresult` bundle under `build/harness/results/<layer>/` before changing code. For builds, use `xcrun xcresulttool get build-results --path <path>`; for tests, use `xcrun xcresulttool get test-results summary --path <path>`.
- SourceKit diagnostics like `No such module 'MLX'` / `Cannot find type X in scope` after an edit are index staleness, not real errors. Trust only errors reported by the harness, `xcodebuild`, and `./scripts/build_foundation_targets.sh`.

## Swift Concurrency Gotchas

- `Self` cannot be referenced inside a `static let` initializer on a class (covariant-Self rule). Use the concrete type name (e.g. `EngineServiceHost.logger`) instead of `Self.logger` in static member initializers.
- `Task.detached { ... }` does not inherit cancellation from the parent. If you need cancellation to propagate, wrap the `try await task.value` in `withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }`.
- `AsyncThrowingStream` iterators do not automatically observe the consuming task's cancellation when the producer runs in its own Task. Inside `for try await event in stream { ... }`, add `try Task.checkCancellation()` at the top of the loop body.
- When promoting a helper out of a `@MainActor`-isolated class to module scope, mark the closure parameter `@MainActor` (e.g. `condition: @escaping @MainActor () -> Bool`) and invoke via `await MainActor.run(body: condition)`. Without this, Swift 6 flags call sites that capture actor-isolated state with "Sending risks data race".

## CI And Release Workflows

The active GitHub workflows are:

- `Project Inputs`
- `Apple Platform QA Gate`
- `Vocello macOS Release`
- `Vocello iOS TestFlight`

Release facts:

- macOS GitHub Releases carry the signed and notarized `Vocello-macos26.dmg`.
- iPhone distribution is App Store / TestFlight only. Do not add iPhone install artifacts to GitHub Releases.
- `scripts/release.sh` is the maintained local macOS packaging entrypoint.
- `scripts/release_ios_testflight.sh` is the maintained iPhone archive/export entrypoint.
- `scripts/verify_ios_release_archive.sh` is the maintained structural verifier for the iPhone archive/export artifacts.
- Both release scripts now use explicit derived-data and cloned-package roots under `build/foundation/` so resolve, build, archive, and export are separate phases.
- `Apple Platform QA Gate` now acts as the shared-core regression gate for the current `macOS-first release track`, uploads harness/build `.xcresult` bundles, keeps generic iPhone compile proof, runs soft-skippable hosted UI smoke, and runs the unsigned macOS release-verification path in CI.
- `Vocello macOS Release` is the only signed/public release workflow required for the current milestone.
- `Vocello iOS TestFlight` remains maintained but is deferred from current public release signoff.
- Shipped macOS bundles and notarized DMGs must not contain `Contents/Resources/backend`, `Contents/Resources/python`, or bundled `Contents/Resources/ffmpeg`.

## When Changing X, Also Update Y

- Model registry, speakers, output folders, required model files, or platform-specific install variants:
  update `Sources/Resources/qwenvoice_contract.json` first, then the contract loaders, platform delivery code, and contract-facing docs.
- Adding or renaming source files:
  update `project.yml`, run `./scripts/regenerate_project.sh`, and confirm generated project files did not capture `__pycache__` or `.pyc` paths.
- Shared engine semantics or model-variant resolution:
  review `Sources/QwenVoiceCore/` and iPhone model delivery code together.
- macOS engine/client behavior:
  review `Sources/QwenVoiceNative/`, `Sources/QwenVoiceEngineSupport/`, and `Sources/QwenVoiceNativeRuntime/` together.
- iPhone engine-extension transport or host behavior:
  review `Sources/QwenVoiceCore/Extension*`, `Sources/iOSEngineExtension/`, `Sources/iOS/VocelloEngineExtensionPoint.swift`, and iPhone build coverage together.
- Memory-pressure, prewarm, or low-RAM admission behavior:
  review `Sources/QwenVoiceCore/IOSMemorySnapshot.swift`, `Sources/iOS/TTSEngineStore.swift`, `Sources/iOS/QVoiceiOSApp.swift`, and iPhone settings/status UI together.
- Playback or generation-persistence behavior:
  review `Sources/SharedSupport/` and affected macOS or iPhone feature views together.
- macOS release packaging or notarization behavior:
  keep `scripts/release.sh`, `scripts/create_dmg.sh`, `scripts/verify_release_bundle.sh`, `scripts/verify_packaged_dmg.sh`, `.github/workflows/macos-release.yml`, and release-facing docs aligned.
- iPhone archive/export/TestFlight behavior:
  keep `scripts/check_ios_catalog.py`, `scripts/release_ios_testflight.sh`, `scripts/verify_ios_release_archive.sh`, `.github/workflows/ios-testflight.yml`, and iPhone distribution docs aligned.
- Broad repo facts that users or contributors rely on:
  update `AGENTS.md`, `README.md`, `docs/README.md`, `docs/reference/current-state.md`, `docs/reference/engineering-status.md`, `docs/reference/backend-freeze-gate.md`, `docs/reference/frontend-backend-contract.md`, and `docs/reference/release-readiness.md`.

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
- If you changed release behavior, verify the scripts, workflows, artifact names, `docs/reference/release-readiness.md`, and README/docs all still agree.
- If you changed any public-facing product copy, make sure the README and GitHub repo description still honor the active public homepage posture and current release-track policy.
- For doc-only refreshes, rerun the stale-reference grep and verify referenced commands, workflows, artifact names, and doc links still exist.
- Run the most relevant harness layer plus `python3 scripts/harness.py validate` before calling work complete.
