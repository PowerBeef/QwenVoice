# Agent Guide to Vocello (QwenVoice)

This file is written for AI coding agents who need to work in the Vocello repository. It assumes no prior knowledge of the project. When this file disagrees with the code, the code wins — update this file.

## Project overview

**Vocello** (formerly QwenVoice) is a local-first, private text-to-speech application for Apple Silicon Macs and iPhones. It synthesizes speech entirely on-device using Qwen3-TTS models accelerated through the [MLX](https://github.com/ml-explore/mlx) framework. There is no Python runtime, no bundled model weights, and no cloud generation step. Models download on demand from Hugging Face after the app is installed.

The current stable macOS release is **Vocello 2.1.0** (`v2.1.0` tag). The iOS app (`VocelloiOS`) is on-device-capable on `main` but not yet distributed publicly. The repo also ships a headless macOS CLI called `vocello` that drives the same engine.

Key facts:

- **Platforms:** macOS 26.0+ and iOS 26.0+, Apple Silicon only, Xcode 26.0.
- **Languages:** Swift 6 (app and engine), React + Vite (marketing site in `website/`), Python 3 (benchmark/diagnostic scripts).
- **Backend:** MLX via native Swift packages; no Python backend.
- **Models:** Qwen3-TTS 1.7B in Speed (4-bit) and Quality (8-bit) variants; 0.6B is verified but not listed.
- **Distribution:** macOS ships as a signed, notarized, stapled `Vocello-macos26.dmg` via GitHub Releases; iOS is intended for App Store / TestFlight under a separate team namespace.

## Repository layout

```text
QwenVoice.xcodeproj/          # Generated from project.yml — do not edit directly
Sources/                      # All Swift source code, resources, and asset catalogs
Tests/                        # XCUITest bundles for macOS and iOS
scripts/                      # Build, release, validation, and diagnostic scripts
website/                      # Marketing site (React + Vite, deployed by Vercel)
docs/reference/               # Detailed reference docs (CLI, telemetry, iOS testing, etc.)
benchmarks/                   # Committed benchmark summaries and optimization log
third_party_patches/          # Vendored mlx-audio-swift with Vocello-specific patches
config/                       # Platform capability matrix (bundle IDs, entitlements, capabilities)
build/                        # Local build output (gitignored)
project.yml                   # XcodeGen source of truth for the Xcode project
PRODUCT.md                    # Product and brand guidance for the app
```

### `Sources/` module divisions

The Swift code is split into framework and app targets. Their responsibilities are:

| Module | Target type | Purpose |
| --- | --- | --- |
| `QwenVoiceBackendCore` | static framework (iOS + macOS) | Low-level MLX and audio primitives: model loading, synthesis, codecs. |
| `QwenVoiceCore` | static framework (iOS + macOS) | Shared engine semantics: `TTSEngine`, `MLXTTSEngine`, generation modes, audio preparation, telemetry, error types. |
| `QwenVoiceEngineSupport` | static framework (macOS) | Native runtime helpers: memory policy, streaming, telemetry aggregation. |
| `QwenVoiceNative` | static framework (macOS) | macOS app-facing engine proxy/store/client that bridges the XPC service to the UI. |
| `QwenVoiceEngineService` | XPC service (macOS) | Out-of-process engine host (`EngineServiceHost.swift`) for crash isolation and memory containment. |
| `QwenVoice` (app module `QwenVoice`) | macOS app | SwiftUI app surface: `QwenVoiceApp.swift`, `ContentView.swift`, `Views/`, `ViewModels/`, `Models/`, `Services/`. Ships as `Vocello.app`. |
| `VocelloiOS` (app module `QVoiceiOS`) | iOS app | iOS SwiftUI app surface in `Sources/iOS/` with supporting code in `Sources/iOSSupport/`. Engine runs in-process. |
| `SharedSupport` | source folder compiled into both macOS and iOS apps | Dual-platform UI-layer share point: player view model, transcriber, reference-clip recorder, language detector, telemetry timeline helpers. |
| `VocelloCLI` | macOS command-line tool | Headless `vocello` binary linking the engine frameworks in-process. |
| `Models` | source folder compiled into the macOS app | App-level model types for the macOS UI. |

### Resources and contract

- `Sources/Resources/qwenvoice_contract.json` is the canonical schema for speakers, models, variants, Hugging Face revisions, and required artifacts.
- `Sources/Resources/qwenvoice_ios_model_catalog.json` and `Sources/Resources/voice-previews/` are bundled resources for the iOS app.
- `Sources/PrivacyInfo.xcprivacy` is bundled into both apps.
- `Sources/QwenVoiceEmbeddedRuntime.entitlements` is the entitlement file used by the embedded runtime target.

### Source of truth

When facts disagree, trust in this order: `Sources/` → `project.yml` → `scripts/` → `.github/workflows/release.yml` → `AGENTS.md` → other prose. `Sources/Resources/qwenvoice_contract.json` is the canonical schema for speakers, models, variants, Hugging Face revisions, and required artifacts.

### Agent routing

This project is developed with **Kimi Code CLI**. Use the following tools and skills instead of the Axiom subagents referenced in older versions of this guide:

- **Build / Xcode issues:** `mcp__xcodebuildmcp__*` (build, test, launch) and the `swift-mlx` / `swift-mlx-lm` skills. iOS verification is **on-device only** — never use the iOS Simulator or simulator-only MCP tools for Vocello iOS UI work. For environmental setup problems, run the relevant `scripts/*.sh` command and inspect output with `Bash`.
- **Code exploration / architecture:** `Agent` with `subagent_type: "explore"` for read-only audits; `Agent` with `subagent_type: "coder"` for implementation or review tasks.
- **Crash logs / symbolication:** `mcp__axiom__xcsym_*` tools (`xcsym_crash`, `xcsym_resolve`, `xcsym_find_dsym`).
- **Performance / profiling:** `mcp__axiom__xcprof_*` tools (`xcprof_record`, `xcprof_analyze`).
- **Apple framework / iOS 26 / post-cutoff APIs:** `mcp__sosumi__fetchAppleDocumentation` / `searchAppleDocumentation` and the `swift-mlx`/`swift-mlx-lm` skills.
- **Backend / MLX:** `swift-mlx` (array/runtime/memory, custom ops) and `swift-mlx-lm` (generation, streaming, KV-cache, model porting, the vendored `mlx-audio-swift` stack). MLX is the only Qwen3-TTS backend — don't pivot to Core ML.
- **GitHub:** `mcp__github__*` MCPs for issues, PRs, reviews, releases, and remote file search. Fall back to `gh` / `git` via `Bash` only for local-repo operations the MCP cannot do.
- **Hugging Face:** `hf` CLI via `Bash`.
- **Marketing site (`website/`):** `mcp__chrome-devtools__*` for browser verification; `npm --prefix website` via `Bash` for builds.
- **Process guidance:** Use the Superpowers skills (`writing-plans`, `executing-plans`, `finishing-a-development-branch`, `systematic-debugging`, `verification-before-completion`) for multi-step work.

Note: scripted on-device generation validation is driven by `IOSAutorunHarness` and run via `scripts/ios_device.sh bench`; thin XCUITest smoke (`Tests/VocelloiOSUITests/`) is run via `scripts/ios_device.sh ui-test` for UI-flow reachability only. The deprecated screen-mirror/mouse-simulation path has been removed. Interactive UI review on the marketing site is still done via Chrome DevTools.

## Technology stack

- **Swift 6** with strict concurrency-aware patterns; module namespace `QwenVoice` is preserved for the macOS app despite the product rename.
- **SwiftUI** with Liquid Glass (`QW_UI_LIQUID` compilation condition) on supported builds; system materials and accessibility-first design.
- **MLX / mlx-swift 0.30.6** and **mlx-swift-lm 2.30.6** for model inference.
- **mlx-audio-swift** — vendored under `third_party_patches/mlx-audio-swift/` with local patches.
- **SwiftHuggingFace 0.9.0** for model downloads.
- **GRDB.swift 7.10.0** for local SQLite history and saved voices.
- **XcodeGen 2.45.4** (pinned in `.tool-versions`) generates `QwenVoice.xcodeproj` from `project.yml`.
- **Vercel** deploys `website/` (React 18 + Vite).

### Dependency pinning policy

SPM dependencies are pinned to exact versions for backend determinism. `project.yml` pins `mlx-swift`; the vendored `third_party_patches/mlx-audio-swift/Package.swift` pins `mlx-swift-lm`; `Package.resolved` records the resolved versions. Move the `mlx-swift` / `mlx-swift-lm` pair in lockstep — never one alone. Do not float pins without a benchmark-gated review. The known next-step upgrade is `mlx-swift` 0.31.x + `mlx-swift-lm` 2.31.x, which changes the quantization API; treat it as a gated upgrade on a throwaway branch with `vocello bench` + a listening pass.

## Build system

### Project generation

`project.yml` is the source of truth. Never edit `QwenVoice.xcodeproj/project.pbxproj` directly.

```sh
./scripts/regenerate_project.sh    # generate QwenVoice.xcodeproj from project.yml
```

`regenerate_project.sh` backs up and restores `Sources/QwenVoice.entitlements` because XcodeGen overwrites it.

### XcodeGen iOS-resource gotcha

The iOS app target lists `qwenvoice_contract.json`, `qwenvoice_ios_model_catalog.json`, `voice-previews`, and `Assets.xcassets` under its `sources:` block with an explicit `buildPhase: resources` override — **not** under `resources:`. XcodeGen 2.45.4 silently drops them from the `VocelloiOS` Resources phase if listed under `resources:`, so iOS builds compile but crash on first launch with missing bundled resources. macOS uses the `resources:` directory pattern and is unaffected.

### Local development builds

The repo uses a **single shippable config** (`Release`). `build.sh` compiles it with `-Onone` for a fast local loop; `release.sh` compiles the same config optimized for the DMG. There is no `DEBUG` compilation symbol and no Debug-vs-Release behavior fork. Debug capabilities are gated at runtime by `DebugMode.isEnabled`, resolved once at launch from either the `QWENVOICE_DEBUG` env var (`1`/`true`/`on`/`yes`) or a persisted `UserDefaults` flag (`QwenVoice.DebugModeEnabled`) flipped by tapping the version label in Settings 7×. Gesture changes apply on the next launch.

```sh
./scripts/build.sh build            # fast -Onone macOS build, no launch
./scripts/build.sh run              # build and launch Vocello.app
./scripts/build.sh run --telemetry  # build, launch, and stream subsystem logs
./scripts/build.sh cli              # build the headless vocello CLI
./scripts/build.sh cli --help       # build and run the CLI
./scripts/build.sh release          # optimized signed DMG via scripts/release.sh
./scripts/build.sh clean            # rm -rf build/
```

Set `QWENVOICE_DEBUG=1` when launching to use the debug data folder (`~/Library/Application Support/QwenVoice-Debug/`).

### Build layout and storage hygiene

Everything lives under a single `build/` directory (`build/DerivedData`, `build/.cache`, `build/Vocello.app`, `build/Vocello-macos26.dmg`, `build/ios`). `build.sh clean` reclaims everything (~7 GB; next build is a full rebuild). The biggest reclaimable chunk is usually the downloaded model weights in `~/Library/Application Support/QwenVoice-Debug/models/` (both Speed and Quality variants can reach 15 GB+). Reclaim them with `scripts/clean_build_caches.sh` (`--models`, `--aggressive`, or `--all`). Keep the working clone out of iCloud Drive — a synced tree duplicates the large `build/` and vendored `.build` into the cloud.

### Project input validation

Run before any build or commit:

```sh
./scripts/check_project_inputs.sh
```

This validates required surfaces, bans stale references, caps committed benchmark logs, and runs backend contract checks.

### Foundation compile-safety builds

```sh
./scripts/build_foundation_targets.sh macos   # clean macOS framework build
./scripts/build_foundation_targets.sh ios     # iOS compile-safety only
```

These use a separate throwaway DerivedData tree under `build/foundation/` that is removed on exit.

### Release packaging

```sh
./scripts/release.sh --signing-mode developer-id --signing-identity "Developer ID Application: …" --notarize
```

Produces `build/Vocello.app` and `build/Vocello-macos26.dmg`. CI (`.github/workflows/release.yml`) builds, signs, notarizes, staples, and attaches the DMG to a GitHub Release. The CI job also runs an iOS compile-safety check in parallel.

### Website

```sh
npm --prefix website run dev      # dev server
npm --prefix website run build    # production build -> website/dist/
```

## Architecture

- **macOS:** the engine runs **out-of-process** in an XPC service (`QwenVoiceEngineService`). The macOS app communicates with it over XPC. This isolates crashes and allows the service to be retired under memory pressure.
- **iOS:** the engine runs **in-process** (`MLXTTSEngine` via `NativeRuntimeFactory`). The ExtensionKit extension was removed because non-UI extensions are Jetsam-capped independently of the `increased-memory-limit` entitlement.
- **CLI:** `vocello` links the engine frameworks **in-process** and reuses models already installed by the app.

The macOS app generation flows through three coordinators in `Sources/ViewModels/`:

- `CustomVoiceCoordinator`
- `VoiceDesignCoordinator`
- `VoiceCloningCoordinator`

iOS uses its own coordinators in `Sources/iOS/Studio/`: `StudioGenerationCoordinator` and `IOSBatchGenerationCoordinator`.

Engine selection is currently a single option (`AppEngineSelection.native`). `AppEngineSelection.current()` returns `.native` on every platform; the actual platform differences are enforced by the runtime factory and the XPC/in-process split.

### macOS app, iOS app, and CLI folder responsibilities

- `QwenVoiceCore/` — shared engine semantics: `TTSEngine`, `MLXTTSEngine`, `TTSEngineError`, `GenerationMode`, audio prep.
- `QwenVoiceBackendCore/` — low-level MLX + audio primitives (model load, synthesis, codecs).
- `QwenVoiceEngineService/` — macOS XPC service (`EngineServiceHost.swift`) running generation in an isolated process.
- `QwenVoiceNative/` — macOS app-facing engine proxy/store/client (bridges XPC to UI).
- `QwenVoiceEngineSupport/` — native runtime helpers (memory policy, streaming, telemetry).
- `iOS/` — iOS app surface (`@Observable` `AppModel`, 4-tab IA: Studio / Voices / History / Settings).
- `iOSSupport/` — iOS-specific runtime helpers + model wrappers (the iOS counterpart to macOS `Services/` + `QwenVoiceEngineSupport/`). It coordinates through an App Group container and a `UserDefaults` suite.
- `SharedSupport/` — dual-platform UI-layer share point: player view model, transcriber, reference-clip recorder, language detector, telemetry timeline helpers.
- `VocelloCLI/` — headless macOS CLI (`build/vocello`) driving `MLXTTSEngine` in-process via `NativeRuntimeFactory`.

### Critical engine invariants (do not regress)

- **Prewarm reentrancy gate.** `NativeEngineRuntime` serializes prewarm work through `acquirePrewarmSlot()` / `releasePrewarmSlot()`. Never pair a throwing `try? await acquirePrewarmSlot()` with an unconditional `defer { releasePrewarmSlot() }` — on a throw the slot isn't held and the defer releases someone else's slot.
- **Event streams.** macOS `MLXTTSEngine.events` must stay `.unbounded`; iOS uses `.bufferingNewest(64)`.
- **Cancellation ownership.** `MLXTTSEngine` admits one model-mutating operation at a time. iOS cancel is cooperative-only: `MLXTTSEngine` does not conform to `ActiveGenerationCancellable`, so the iOS generate flow must discard the result on `Task.isCancelled` to avoid landing cancelled takes in History. `MLXTTSEngine.generate`'s catch must not rethrow `CancellationError` early — it skips `loadState` reset and strands the engine in `.running`.
- **Per-tier memory.** `NativeMemoryPolicyResolver` picks a policy per `NativeDeviceMemoryClass` (floor8GBMac / mid16GBMac / highMemoryMac / iPhonePro): cache limits, idle-unload windows, clone-cache caps, custom-prewarm policy, and streaming tuning. No hard `Memory.memoryLimit` in production and no Quality→Speed OOM fallback. A debug override exists via `QVOICE_IOS_MLX_MEMORY_LIMIT_MB` for Release-device experimentation only.
- **macOS constrained-tier smoothness.** Idle-unloads stick on floor8GBMac, proactive warms are pressure-gated via `MacWarmupAdmissionPolicy`, and the XPC service can be retired under pressure without error UI.
- **Decoder drift.** The vendored `Qwen3TTSSpeechTokenizer` uses input-side overlap-and-add (`inputContext` buffer). Do not revert to output-side accumulation.
- **XPC event forwarding.** XPC hosts drain `engine.events` on a `Task.detached(.utility)` (off MainActor) so the synchronous XPC encode can't lag the producer; only `lastPublishedEvent` hops to `MainActor`.
- **iOS memory posture.** `NativeStreamingPreviewDataPolicy.current()` defaults to `.emit` on all platforms; set `QWENVOICE_STREAMING_PREVIEW_DATA=off` to restore `.skip`. `Qwen3TTSMemoryCaches.clearAll()` runs on iPhone hard-trim/unload/failure; macOS cache warmth is preserved.

## Development conventions

### Single config and debug mode

- Only the `Release` config exists in `project.yml`.
- `DebugMode.isEnabled` is resolved once at launch from `QWENVOICE_DEBUG` env var or a hidden 7-tap version-label toggle in Settings (persisted to `UserDefaults`).
- `#if DEBUG` blocks are reserved for test/sim scaffolding and compile out of the shipped package.

### Naming and bundle identifiers

- Product display name: **Vocello**.
- macOS app bundle: `com.qwenvoice.app`.
- macOS XPC service: `com.qwenvoice.app.engine-service`.
- macOS/shared frameworks and CLI: `com.qwenvoice.*`.
- iOS app bundle and App Group: `com.patricedery.vocello.*` (maintainer's App Store team namespace).
- Xcode scheme remains `QwenVoice` for the macOS app.
- Swift module names: macOS app `QwenVoice`, iOS app `QVoiceiOS`, frameworks `QwenVoiceCore`, `QwenVoiceBackendCore`, `QwenVoiceNative`, `QwenVoiceEngineSupport`, CLI `VocelloCLI`.

### Accessibility and UI

- `accessibilityIdentifier` values (e.g. `voicesRow_*`, `textInput_*`, `studioChip_*`) are stable surface area and must survive refactors.
- Animations route through `appAnimation` / `AppLaunchConfiguration.performAnimated` to honor Reduce Motion.
- Liquid Glass surfaces fall back to solid fills under Reduce Transparency.
- No color-only signal: mode colors always pair with an icon, label, or position cue.

### Code style

- Follow existing Swift style; there is no formatter or linter configured.
- The build is the typecheck; there is no separate lint/typecheck step.
- Keep minimal changes. Preserve existing module boundaries.
- Vendor patches in `third_party_patches/mlx-audio-swift/` are allowed when the fix belongs below `QwenVoiceCore`; keep them small and preserve upstream style.

### Privacy and content

- Never commit personal identifiers (legal names, emails, home paths, device nicknames, UDIDs, hardcoded team IDs) into user-facing files (`README.md`, `website/`, `docs/`, release notes). Technical bundle IDs (`com.patricedery.vocello`) are acceptable.
- Voice cloning must only be used with voices the user owns or has permission to use.

## Testing instructions

### Static gates (run first)

```sh
./scripts/check_project_inputs.sh
./scripts/build.sh build
./scripts/build_foundation_targets.sh macos && ./scripts/build_foundation_targets.sh ios
```

### macOS UI smoke

```sh
xcodebuild test -project QwenVoice.xcodeproj -scheme QwenVoice \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData
```

The `VocelloMacUITests` target contains a single `VocelloMacSmokeUITests` class with 10 tests covering launch, navigation, composer typing, a real generation, cancel, history, saved voices, settings, enroll, and batch sheets.

### iOS testing

iOS testing is **on-device only**. The iOS Simulator is retired for this project and must not be used for UI testing, verification, screenshots, or snapshots.

**Do not use:**
- `scripts/ios_sim.sh`
- `xcodebuild -destination 'platform=iOS Simulator...'` for iOS UI work
- simulator-only MCP tools such as `mcp__xcodebuildmcp__build_run_sim` / `snapshot_ui` for iOS

The sanctioned paths are:

```sh
scripts/ios_device.sh doctor       # environment + device preflight
scripts/ios_device.sh bench        # build → install → autorun → pull → summarize
scripts/ios_device.sh ui-test      # run VocelloiOSUITests on the device
scripts/ios_device.sh shot         # screenshot the iPhone Mirroring window
```

The headless autorun harness is triggered by `QVOICE_IOS_AUTORUN` and writes telemetry into the App Group container.

### Benchmarks and output quality

```sh
QWENVOICE_DEBUG=1 ./build/vocello bench --modes clone --variants speed --lengths short,medium,long \
  --warm 3 --voice <prepared-voice> --label "release-QA" --ledger
```

`vocello bench` is the deterministic perf/quality driver. The output is joined with telemetry summarizers and can be appended to `benchmarks/HISTORY.md`. The mandatory pre-merge gate is a listening pass over the fixed corpus (`vocello bench --review` or by ear) — audio never ships.

Committed benchmark logs must be compact summaries ≤256 KB; raw `*.jsonl` is gitignored.

### Telemetry

When `TelemetryGate` is on (`QWENVOICE_DEBUG=1` or the debug toggle), each generation writes JSONL under `~/Library/Application Support/QwenVoice-Debug/diagnostics/`:

- `app/generations.jsonl`
- `engine/generations.jsonl`
- `engine-service/generations.jsonl` (macOS)
- `generations-merged.jsonl`

Use `scripts/summarize_generation_telemetry.py` to aggregate results.

## Security considerations

- **App sandbox is disabled** (`com.apple.security.app-sandbox = false` in `Sources/QwenVoice.entitlements`) because MLX requires it.
- Hardened runtime is enabled for release with `allow-unsigned-memory` and `disable-library-validation`.
- Local dev builds auto-sign with the first Apple Development identity so TCC grants (microphone, speech recognition) survive rebuilds. Release builds use Developer ID signing.
- All generation, recording, transcription, and model storage happens locally. On-device transcription uses `requiresOnDeviceRecognition`.
- macOS Speech Recognition requires Siri to be enabled; the app links the user to System Settings when it is not.
- Model downloads come from Hugging Face over HTTPS; the contract pins revisions.
- The iOS app has the `com.apple.developer.kernel.increased-memory-limit` entitlement enabled.

## Deployment

### macOS

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` and run `./scripts/regenerate_project.sh`.
2. Run static gates, automated UI smoke, engine regression net, and listening pass (see `docs/reference/macos-release-qa.md`).
3. Build a signed/notarized DMG locally or via GitHub Release (triggers `.github/workflows/release.yml`).
4. The workflow attaches `Vocello-macos26.dmg` to the release.

### iOS

- On-device generation works; TestFlight / App Store distribution is still deferred.
- A signed IPA lane needs an iOS Distribution certificate and an `archive-ios` CI job.
- Use `scripts/verify_ios_release_archive.sh` for entitlement checks and `scripts/check_ios_catalog.sh` to validate the bundled iOS catalog against the contract.

### Website

- Deployed by Vercel from the `website/` directory.
- See `website/AGENTS.md` for website-specific conventions and `website/PRODUCT.md` for brand copy rules.

## Useful reference documents

Check the relevant reference doc before making changes in a subsystem. If the change invalidates a doc, update the doc in the same PR/commit.

### Core technology references

- `docs/reference/mlx-guide.md` — MLX runtime behavior: lazy evaluation, `eval()`/`asyncEval()`, streams, quantization, memory controls, model loading. Read before changing anything in `QwenVoiceBackendCore/` that touches `MLXArray`, `Memory`, `GPU`, or model loading.
- `docs/reference/qwen3-tts-guide.md` — Talker/code-predictor architecture, model variants, tokenizer profile, generation modes, speakers, languages, special token IDs. Read before changing prompt construction, speaker logic, generation defaults, or the contract.
- `docs/reference/metal-guide.md` — Metal API and performance, MLX's Metal backend, GPU memory/telemetry, profiling tools, iOS Metal constraints. Read before tuning memory policy, adding GPU profiling, or considering custom Metal kernels/DSP.
- `docs/reference/mimi-codec-guide.md` — Mimi/Qwen3-TTS speech tokenizer, RVQ, streaming invariants, decoder drift, codec performance. Read before touching the vendored codec, streaming decode, or audio boundary quality.
- `docs/reference/swift-performance-guide.md` — Swift 6 concurrency, actors, `@MainActor`, allocation/ARC, build settings. Read before broad concurrency or performance refactor in `Sources/`.

### Operational references

- `docs/reference/ios-engine-optimization.md` — iOS memory model, streaming wins, Jetsam/entitlement behavior, thermal constraints.
- `docs/reference/telemetry-and-benchmarking.md` — telemetry schema and benchmark recipes.
- `docs/reference/cli.md` — full `vocello` CLI reference.
- `docs/reference/macos-release-qa.md` — pre-release QA gate sequence.
- `docs/reference/ios-device-testing.md` — on-device iOS build/test driver.
- `docs/reference/privacy-storage.md` — local storage paths and privacy details.
- `docs/reference/macos-permissions.md` — TCC/permission model.
- `docs/reference/mlx-audio-swift-patching.md` — vendored backend patch procedure.

### Product and website

- `PRODUCT.md` — product purpose, users, brand personality, design principles.
- `website/AGENTS.md` — marketing site guidance.
