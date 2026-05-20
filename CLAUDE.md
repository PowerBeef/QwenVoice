# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Vocello (formerly QwenVoice) — a local, private text-to-speech macOS app powered by Qwen3-TTS via MLX on Apple Silicon. The macOS scheme is still called `QwenVoice` but the shipped product is `Vocello.app` / `Vocello-macos26.dmg`. An iOS counterpart (`VocelloiOS`) is kept compile-safe but is not a release target for the current milestone.

Targets: macOS 26.0+ and iOS 26.0+, Apple Silicon only, Xcode 26.0. No Python runtime. No bundled model weights — models are downloaded from Hugging Face from Settings → Model Downloads on first run.

## Source of truth (when facts disagree)

Per `CONTRIBUTING.md`, trust in order: `Sources/` → `project.yml` → `scripts/` → `docs/reference/` → other prose. `Sources/Resources/qwenvoice_contract.json` is the canonical schema for speakers, models, variants, HF revisions, and required artifacts.

## Project generation and build

The Xcode project is generated from `project.yml` via XcodeGen. Edit `project.yml` (not `.xcodeproj`) for structural changes, then regenerate.

**XcodeGen iOS resource gotcha.** The iOS app target lists `Sources/Resources/qwenvoice_contract.json` and `Sources/Assets.xcassets` under its `sources:` block with an explicit `buildPhase: resources` override, not under `resources:`. XcodeGen 2.45.4 silently drops these files from the `VocelloiOS` Resources phase when they're listed under `resources:` directly — iOS builds compile but crash on first launch with `Fatal error: Could not locate bundled qwenvoice_contract.json`. The macOS target is unaffected because it uses the directory pattern (`- path: Sources/Resources` under `resources:`). Workaround landed in Track 0 of commit `287c969` (May 2026); leave the sources-block placement in place when editing `project.yml`.

Preferred entrypoint for day-to-day work — wraps the steps below and skips regen / SPM resolve when their inputs are unchanged:

```sh
./scripts/build.sh debug                  # fast incremental Debug build, no launch
./scripts/build.sh run                    # Debug build → launch Vocello.app
./scripts/build.sh run --logs             # also: --telemetry, --verify, --debug (lldb)
./scripts/build.sh release [args...]      # delegates to scripts/release.sh
./scripts/build.sh clean                  # rm -rf build/
```

Lower-level scripts (still supported, used by `build.sh` internally):

```sh
./scripts/regenerate_project.sh           # rebuild QwenVoice.xcodeproj from project.yml
./scripts/check_project_inputs.sh         # static validator — run before any build
./scripts/build_foundation_targets.sh macos   # macOS foundation build (always clean)
./scripts/build_foundation_targets.sh ios     # iOS compile-safety build (always clean)
./scripts/build_foundation_targets.sh all     # both
./scripts/build_and_run.sh                # legacy debug build → install → launch
./scripts/release.sh                      # macOS release packaging (ad-hoc signed DMG by default)
./scripts/check_ios_catalog.sh            # iOS catalog/static sanity check
./scripts/release_ios_testflight.sh       # iOS TestFlight build/sign/notarize/upload
./scripts/clean_build_caches.sh           # nuke build caches
./scripts/export_diagnostics.sh           # collect diagnostics bundle
./scripts/verify_ios_release_archive.sh <archive>  # verify iOS release archive
./scripts/verify_packaged_dmg.sh <dmg>    # verify a packaged DMG
./scripts/verify_release_bundle.sh <app>  # verify .app signing/entitlements
```

There is no SwiftFormat / SwiftLint config. There is no lint or typecheck command — the build is the typecheck.

### Build layout and cache

Only two maintained top-level folders belong under `build/`: `build/Debug/` and `build/Release/`. Debug is the default development/testing/debugging area; Release is the GitHub-release packaging area. Do not add new sibling folders under `build/`.

Sha256 fingerprints under `build/Debug/.cache/` and `build/Release/.cache/` (`project.yml.sha256`, `Package.resolved.sha256.<context>`) let `build.sh` skip XcodeGen and SwiftPM resolve when their inputs are unchanged. These directories self-heal — delete `build/` (or run `build.sh clean`) to force a cold rebuild. `xcodebuild` output is piped through `xcbeautify` when it's on `PATH` and stdout is a TTY.

### Single-resident build policy

At most one published Debug `.app` and one published Release `.app` + `.dmg` exist under `build/` at any time: `build/Debug/Vocello.app`, `build/Release/Vocello.app`, and `build/Release/Vocello-macos26.dmg`. Xcode incremental products stay nested under the owning folder's `DerivedData/`; UI/benchmark artifacts live under `build/Debug/uitest/`; release logs, metadata, source packages, result bundles, and package outputs live under `build/Release/`. Pruning is automatic with no opt-out; if `Vocello` is running it is quit (SIGTERM, then SIGKILL after a short grace period) before deletion. Failed builds skip pruning so previous artifacts stay intact for inspection.

### Runtime data folders

Debug and local Release builds intentionally write to different Application Support folders so Debug keeps day-to-day development state while each repo-local Release package starts clean:

- Debug: `~/Library/Application Support/QwenVoice-Debug/` (persistent across rebuilds — models, `history.sqlite`, outputs, voices, stream-session caches all live here)
- Repo-local Release: `~/Library/Application Support/QwenVoice-Release-Local/<release-data-id>/` (fresh per successful `scripts/release.sh` packaging)
- Installed/public Release: `~/Library/Application Support/QwenVoice/` (normal end-user storage once copied outside repo-local `build/Release/`)

Debug selection is compile-time inside `Sources/Services/AppPaths.swift` via `#if DEBUG`. Repo-local Release selection is runtime-gated by the signed `QwenVoiceLocalReleaseDataID` Info.plist value and the bundle path ending in `build/Release/Vocello.app`; copying the app elsewhere makes it use the installed/public Release store. This works because the QwenVoice macOS target's Debug config in `project.yml` includes `DEBUG` in `SWIFT_ACTIVE_COMPILATION_CONDITIONS` — do not remove it without also moving the data-folder logic to a custom flag.

The first Debug launch under this policy renames an existing `QwenVoice/` folder to `QwenVoice-Debug/` automatically (no env-var override set, target folder absent, legacy folder present). The `QWENVOICE_APP_SUPPORT_DIR` env var still overrides the root in either configuration and disables auto-migration when set.

Local Release defaults are isolated too: `AppDefaults` uses a release-id-specific preferences suite for repo-local Release apps, while Debug and installed/public Release use normal app preferences. To exercise Release with realistic data, copy/symlink data into the local release folder or use the env-var override.

### Autonomous UI testing

The Debug build is drivable by a Claude Code session via the computer-use MCP. Entry point is `scripts/uitest.sh` (subcommands: `prep`, `reset [--include-voices|--full]`, `locate <ax-id>`, `window-locate <ax-id> [image-w image-h]`, `scaled-locate`, `screen-size`, `activate`, `logs`, `db <sql>`, `artifacts-dir`, `smoke-check [<mode>]`, plus the bench-* family: `bench-wait`, `bench-step`, `bench-record`, `bench-summarize`, `bench-compare`, `bench-update-baselines`). The agent's reference for what's clickable and how to verify generation completion lives at `docs/reference/ui-test-surface.md`. Test artifacts land in `build/Debug/uitest/<timestamp>/` and are wiped by `scripts/build.sh clean`.

Smoke runbooks (one per generation mode):

- `docs/reference/smoke-custom-voice.md`
- `docs/reference/smoke-voice-design.md`
- `docs/reference/smoke-voice-cloning.md` (requires the `UITestRef` saved-voice fixture — see bootstrap below)

Smoke runbooks for non-generation surfaces:

- `docs/reference/smoke-settings.md` — Settings screen renders + Custom Voice model packages show "Ready"
- `docs/reference/smoke-history.md` — History list renders + search filters + row plays
- `docs/reference/smoke-saved-voices.md` — Saved Voices lists the `UITestRef` fixture + row plays

Saved-voice fixture bootstrap (one-time, autonomous):

- `docs/reference/bootstrap-saved-voice.md` — generates `voices/UITestRef.wav` via Voice Design → Save to Saved Voices, no file picker needed

Benchmark runbooks share the bench-* harness (`bench-wait`, `bench-step <mode> <variant> <coldwarm> <bucket>` as the one-shot per-sample wrapper, `bench-record` for the raw record-only call, `bench-summarize`, `bench-compare`, `bench-update-baselines`):

- `docs/reference/bench-custom-voice.md`
- `docs/reference/bench-voice-design.md`
- `docs/reference/bench-voice-cloning.md`

Committed baselines live at `docs/reference/benchmark-baselines.json` (schema v3, regression-ready, 24 cells × n=3 on Apple M2 — full coverage of the 3 modes × 2 variants × cold/medium + warm/{short,medium,long} matrix as of May 2026). Every cell carries `ms_engine_start_to_final`, `ms_engine_start_to_autoplay`, `audio_duration_s`, `rtf`, `audio_rms_dbfs`, `audio_peak_dbfs`, `peak_rss_mb` (combined Vocello + XPC), and the `peak_rss_mb_app` / `peak_rss_mb_xpc` split. `bench-compare` flags drift on `ms_engine_start_to_final` and `rtf` at ±15 %; depth metrics are recorded in the baseline for forensic comparison but not gated on directly.

**Reading bench-compare flags — `ms` and `rtf` as paired signals.** The two gates flag independently but are not independent metrics. When `ms_engine_start_to_final` flags but `rtf` stays within ±15 %, the latency change is driven by LM output-length variance (same input prompt occasionally produces a longer/shorter take), not engine throughput regression — inspect `audio_duration_s` in the per-sample JSONL for outliers. The `rtf` metric (audio-seconds per generation-second) normalizes out output-length and is the correct gate for engine throughput. The ±15 % gate on raw `ms` is conservative for catching obvious regressions but is noisy at n=3; for a "confirmed regression" verdict, prefer `rtf` and require n≥10 samples. See `docs/reference/ui-test-surface.md` § "Reading the bench-compare output" for the full reading rules and a May 18 worked example.

### iOS Simulator UI testing

Real MLX generation can't run in the iOS Simulator (no Apple Neural Engine, no real bytes on disk), but every iPhone UI surface is reviewable end-to-end through a stubbed engine and a Simulator-only fake-install path. Quick start:

```sh
xcodebuild -project QwenVoice.xcodeproj -scheme VocelloiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/Debug/foundation/local-builds/ios-simulator-derived-data \
  -configuration Debug build
xcrun simctl boot "iPhone 17 Pro"
xcrun simctl install booted build/Debug/foundation/local-builds/ios-simulator-derived-data/Build/Products/Debug-iphonesimulator/Vocello.app
xcrun simctl launch booted com.qvoice.ios
```

`IOSAppBootstrap.makeBackend` swaps in `IOSSimulatorTTSEngine` (stub) + `IOSSimulatorFakeStatusProvider` (decorates `LocalModelStatusProvider` with a process-wide `IOSSimulatorFakeInstallRegistry`) when running on Simulator. Tapping Download / Delete on a model row in Settings drives a fake ~4.2 s download flow via `simulatorFakeInstall` / `simulatorFakeDelete`; the registry persists the installed state across `modelManager.refresh()` calls, so the Generate tab's onboarding card hides as expected after a fake install. All Simulator paths are gated on `IOSSimulatorRuntimeSupport.isSimulator`; real-hardware behavior is unchanged.

Full runbook at `docs/reference/ios-simulator-testing.md` (covers Reduce Motion / Reduce Transparency toggle review, side-by-side macOS chrome comparison, and known limitations).

## Testing policy — important

This repo keeps CI **scoped to release packaging only** as of May 2026 — no XCTest targets, no automated bench/smoke/perceptual runs on CI, no legacy Python/CI benchmark harnesses. The sole workflow at `.github/workflows/release.yml` has two parallel jobs on `release.published` (and on manual `workflow_dispatch`): `package` (macOS DMG sign + notarize + staple via `scripts/release.sh`, attached to the GitHub Release) and `compile-ios` (iOS compile-safety only, no signing, no tests, runs `scripts/build_foundation_targets.sh ios`). `compile-ios` failures do not block the macOS DMG; the iOS signed-IPA path requires the entitlement approval + iOS Distribution cert + provisioning profile that don't exist as of v2.0.0 (see [`docs/reference/release-readiness.md`](docs/reference/release-readiness.md) § "iPhone Shipping Plan"). Behavioral validation is local-only and two-track: manual app acceptance plus the maintained Claude Code–driven `scripts/uitest.sh` smoke/bench harness above. For Debug behavior, use `./scripts/build.sh run` or `scripts/uitest.sh prep` (Debug app path: `build/Debug/Vocello.app`). For release signoff, launch `build/Release/Vocello.app` only after `./scripts/release.sh` has produced the Release bundle.

Do not reintroduce test bundles, QA shell scripts, agent configs, additional GitHub Actions workflows beyond `release.yml`, or a parallel benchmark harness without an explicit maintainer decision. `scripts/check_project_inputs.sh` enforces the retired surfaces with a prohibited-paths list and a regex sweep of the working tree. Inspect that script for the current list rather than quoting names here (its patterns also trip on any file that mentions the banned names verbatim).

Recent commits that establish this stance: *"Retire all CI workflows; reset to local-only operation"*, *"Remove test harness and agent config"*, *"Scope CI to building and packaging validations only"*.

## Architecture

Two-platform Swift codebase with an out-of-process engine on each platform.

**Core modules (under `Sources/`):**

- `QwenVoiceCore/` — shared engine semantics: `TTSEngine` protocol, `MLXTTSEngine`, `TTSEngineError` (renamed from `MLXTTSEngineError`; a back-compat typealias remains), `GenerationMode`, lifecycle types, audio preparation.
- `QwenVoiceBackendCore/` — low-level MLX + audio primitives (model loading, synthesis, codecs).
- `QwenVoiceEngineService/` — **macOS XPC service** that runs TTS generation in an isolated process (`EngineServiceHost.swift`). The macOS app talks to it via `QwenVoiceNative`.
- `QwenVoiceNative/` — macOS app-facing engine proxy / store / client layer; bridges the XPC service to UI.
- `QwenVoiceEngineSupport/` — native runtime helpers (memory policy, streaming, telemetry).
- `iOSEngineExtension/` — **iOS ExtensionKit extension** (`VocelloEngineExtension`) that runs heavy generation outside the iPhone UI process.
- `iOS/` + `iOSSupport/` — iOS app surface.
- Main macOS app sources at the top level of `Sources/`: `QwenVoiceApp.swift` (entry), `ContentView.swift`, `Views/`, `ViewModels/`, `Models/`, `Services/`, `SharedSupport/`.

**Engine routing:** `AppEngineSelection.current()` picks the engine per platform — XPC client on macOS, extension-backed engine on iOS.

**Generation flows** (UI side): three coordinators map to the three workflows — `CustomVoiceCoordinator`, `VoiceDesignCoordinator`, `VoiceCloningCoordinator`. Speed (4-bit) vs Quality (8-bit) variant choice lives on the generation screens, not in Settings. iPhone is Speed-only; 8 GB Macs default to Speed, larger Macs default to Quality. iOS exposes an additional 3-segment intensity picker (`Subtle / Normal / Strong`) below the delivery preset selector when a non-neutral preset is chosen; `DeliveryInputState.selectedIntensity` carries the value through to `EmotionPreset.preset(preset, intensity:)`. iOS Voice Cloning also exposes a "Generate batch…" affordance backed by `IOSBatchGenerationCoordinator` (sequential single-call loop, distinct from the macOS `BatchGenerationRunner`) and `IOSBatchGenerationSheet`.

**iOS design tokens align to macOS** (May 2026, commit `287c969`). `IOSAppTheme.subtleGlassTint` is 14% opacity (matches macOS `surfaceGlassTint` dark); `accentStroke` is 34%; `accentWash` is 20%. Neutral palette is warm-tinted (`textSecondary` ~`#C5BFAE`, `textTertiary` ~`#7E7868`) rather than cool blue-gray. Card corner radii unify at 16 pt; chips and badges are flat (no glass) per the macOS May 2026 chip audit. Brand wordmark uses SF Rounded semibold, mirroring `Sources/Views/Sidebar/SidebarView.swift`. When changing iOS colors, check the macOS values first — these are intentionally locked together.

**iOS Claude Design redesign** (May 2026, commits `51d8dce` through `68fda10`). The iOS app moved to a 4-tab IA (**Studio / Voices / History / Settings**) sourced from `design_references/Vocello iOS/` (React + CSS prototype) and `design_references/Vocello Design System/`. Key files introduced:

- `Sources/iOS/IOSDesignSystemPrimitives.swift` — shared building blocks: `IOSCornerRadius` (8 chip / 10 input / 16 card / 22 stage), `IOSDesignMotion` (220/360/420 ms ease-out curves, cubic-bezier 0.22, 1, 0.36, 1), `IOSModeBackdrop` (radial mode-tinted wash), `IOSWaveformBars` (deterministic seed-based bars used by History thumbnails + Player sheet), `IOSVoiceAvatar` (hue-by-id gradient circle), `IOSBottomSheet` (drag-to-dismiss chrome with grabber + title), `IOSStudioSetupChip`, `IOSFilterChipRow`, `IOSSearchField`, `IOSPrimaryCTAButton`.
- `Sources/iOS/IOSOnboardingFlow.swift` — first-launch 3-step welcome (Welcome, Install hint, You're set). Gated by `IOSAppDefaults.hasCompletedOnboarding`.
- `Sources/iOS/IOSPlayerSheet.swift` + `IOSWordTimingPlanner.swift` — full-screen Player sheet with 38-bar waveform scrubber and karaoke transcript that follows playback under linear word-timing (engine doesn't emit per-token timestamps; transcript split evenly across audio duration).
- `Sources/iOS/IOSBottomSheets.swift` — five sheets in one file: `IOSDeliveryPickerSheet` (preset grid + intensity + optional custom-tone escape), `IOSVoicePickerSheet`, `IOSReferenceClipSheet`, `IOSModelInstallSheet`, `IOSDeleteModelSheet`.
- `Sources/iOS/IOSRecordingOverlay.swift` — clone-reference capture via `AVAudioRecorder` at 24 kHz mono Int16 PCM, live amplitude meter, 10-20 s validation gate. Wired into Voice Cloning's "Record reference clip…" button. Requires `NSMicrophoneUsageDescription` in `Sources/iOS/Info.plist`.
- `Sources/iOS/IOSVoicesView.swift` — unified Voices tab combining built-in speakers (`TTSContract.allSpeakerDescriptors`) with saved voices (`SavedVoicesViewModel`). Tapping a built-in speaker presets `customVoiceDraft.selectedSpeaker` and jumps to Studio Custom; tapping a saved voice stages `PendingVoiceCloningHandoff` and jumps to Studio Clone.

The Studio screen still uses the legacy per-mode views (`IOSCustomVoiceView` / `IOSVoiceDesignView` / `IOSVoiceCloningView`) inside the mode-segmented control. The delivery picker inside those views now opens `IOSDeliveryPickerSheet` instead of a system Menu. The full setup-chip + inline-player completion pattern from the design prototype is not yet wired into the per-mode views; lifting the per-mode setup into the new chip layout is a follow-up track.

`Sources/iOSSupport/Services/IOSAppDefaults.swift` owns iOS user-defaults keys (`hasCompletedOnboarding`, `autoplayCompletions`).

**Entitlements:** App sandbox is **disabled** (`com.apple.security.app-sandbox = false` in `Sources/QwenVoice.entitlements`) — required for MLX. Hardened runtime is on with allow-unsigned-memory and disable-library-validation flags.

## Performance + memory adaptation (May 2026)

Non-obvious runtime behavior added across the May 2026 Phase 1+2+3 rollout. Future agents modifying engine code should know about these.

### Per-tier memory policy

`NativeMemoryPolicyResolver` picks a policy per `NativeDeviceMemoryClass` (floor8GBMac, mid16GBMac, highMemoryMac, iPhonePro). Key tier-specific behaviors:

- **floor8GBMac**: `clearCacheAfterGeneration: true`, `unloadAfterIdleSeconds: 120` (adaptive — see below), clone cache capacity = 1, `customPrewarmPolicy: .skipDedicatedCustomPrewarm` (`EngineServiceHost.swift` sets this conditionally). Custom Voice doesn't run a dedicated prewarm — the work moves into the first generation proper.
- **mid16GBMac / highMemoryMac**: `customPrewarmPolicy: .eager`, longer idle windows, larger clone caches.
- **iPhonePro**: tightest tier — cache 128 MB, unload after 30 s, clone cache = 1.

### macOS runtime memory-pressure monitor

`Sources/QwenVoiceCore/NativeMemoryPressureMonitor.swift` wraps `DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical])` on macOS. `MLXTTSEngine.initialize(...)` starts it on floor8GBMac and mid16GBMac. Kernel pressure events map to `NativeMemoryTrimLevel` and route to `runtime.trimMemory(level:reason:)` — softTrim clears MLX cache + clone soft-trim; hardTrim clears all warm state. iOS has its own host-side monitor (`IOSShellPrimitives.swift`) — don't add a second on iOS.

### Adaptive idle-unload on floor8GBMac

`MLXTTSEngine.adaptiveIdleUnloadDelay(...)` consults `memoryPressureMonitor.currentLevel` and shortens the 120 s default to 30 s under softTrim or 10 s under hardTrim. mid16GBMac and higher keep their baseline. The model reloads on the next generation (~500–700 ms cost) but peak RSS stays bounded.

### Prewarm reentrancy gate (CRITICAL)

`NativeEngineRuntime` is a Swift actor, but actors don't prevent reentrancy across suspension points. Both `ensureWarmStateIfNeeded` (Custom + Design + Clone path) and `ensureDesignConditioningWarmStateIfNeeded` call `try await model.prewarm*(...)`, which releases actor exclusivity while MLX work runs. Without protection, two callers (typically `prefetchInteractiveReadinessIfNeeded` + `prepareGeneration` racing on launch) reach MLX's KV cache slice updates concurrently and trip an assertion (crashed the engine in May 2026 — see `~/Library/Logs/DiagnosticReports/QwenVoiceEngineService-2026-05-15-162429.ips`).

The fix is a monitor-style gate: `prewarmInFlight: Bool` + `prewarmWaiters: [CheckedContinuation<Void, Never>]` with `acquirePrewarmSlot()` / `releasePrewarmSlot()` helpers. Both ensure* methods call `await acquirePrewarmSlot()` first and `defer { releasePrewarmSlot() }`. **Do not remove the gate or restructure the prewarm path without preserving this serialization.**

### Generation ownership and cancellation (CRITICAL)

`MLXTTSEngine` owns admission for model-mutating work. Generation, batch generation, explicit load/unload, proactive warmup/prefetch, and clone priming must go through its model-operation gate so only one operation mutates model/runtime state at a time. Proactive warm operations skip/defer when the lease is occupied; user-triggered generation rejects cleanly when another generation is active.

The macOS and iOS app-facing stores expose `hasActiveGeneration`, and generation UIs must use that shared state to disable cross-mode controls and show cancellation. The macOS XPC host and iOS extension host reject concurrent generation instead of replacing active handles. Streaming chunks carry a UUID `generationID`; numeric `requestID` remains useful for logs/signposts but must not be the sole playback-session identity across service/runtime restarts. Vendored Qwen streaming producers must cancel their producer `Task` from `AsyncThrowingStream` termination and check cancellation inside token/decode loops so orphaned consumers cannot leave MLX generation running.

### Quality → Speed OOM fallback on floor8GBMac

`MLXTTSEngine.loadModel(id:)` catches load failures on floor8GBMac. If the failed model was a Quality variant AND the error matches OOM heuristics (NSError localizedDescription contains "memory" / "allocate" / "allocation", or NSPOSIXErrorDomain ENOMEM), the engine retries with the Speed sibling derived via the registry. `visibleErrorMessage` surfaces "Switched to Speed (4-bit) — Quality didn't fit in memory." If the fallback ALSO fails, the original error propagates (no cascade).

### Settings → Performance → "Always use Speed (4-bit) models"

Global UserDefaults override at key `QwenVoice.PreferSpeedEverywhere`. When set, `TTSContract.activeModel(...)` short-circuits the per-mode preference and returns the Speed variant for every mode. Default false (preserves existing per-mode behavior). UI in `SettingsView.swift` with `accessibilityIdentifier("settings_preferSpeedEverywhere")`.

### Prewarm signposts for bench traces

Two OSSignposter events in `NativeEngineRuntime` for bench/forensics: `"Native Prewarm Cache Hit"` (fires when `loadCoordinator.isPrewarmed(...)` returns true) and `"Native Design Conditioning Reuse"` (fires on the `reused: true` branch of `ensureDesignConditioningWarmStateIfNeeded`). Future bench-* tooling can count hits vs misses.

### Short-prompt Custom Voice prewarm depth

`NativeEngineRuntime.customPrewarmDepth(for:)` returns `"skip-decoder-bucket"` for `.custom` requests with `text.count <= 30`. The vendor's `Qwen3CustomVoicePrewarmDepth` enum (in `third_party_patches/mlx-audio-swift`) accepts that string and skips the decoder-bucket precompile during prewarm — the decoder compiles on first decode instead. Same output audio, only latency distribution changes. Only fires on tiers where `customPrewarmPolicy: .eager` (mid16GBMac + highMemoryMac); floor8GBMac skips the whole dedicated prewarm anyway.

### Headless-workload env vars

- `QWENVOICE_STREAMING_PREVIEW_DATA=off` (or `skip` / `false` / `0` / `no`) — skips per-chunk `previewAudio.pcm16LE` Data allocation. Default emits. For headless bench/batch work where nobody is listening to live preview.
- `QWENVOICE_STREAMING_OUTPUT_POLICY=file` — adds per-chunk file artifacts alongside the PCM preview. Default `pcm_preview` (PCM preview only, no per-chunk files).

## Known traps

### Streaming preview enabled production-wide (as of `f6aa8e3`); batch generation stays quality-first

`shouldStream: true` at all 8 user-facing call sites (3 macOS coordinators + 5 iOS counterparts). `BatchGenerationRunner` stays `shouldStream: false` by design — batch is quality-first regardless. The user hears the first audio chunk within ~3-6 seconds of pressing generate on cold cells, vs ~8-15 seconds for the materialize-then-play flow that preceded it.

**Bench-measured perceived-speed gain** (Phase 3 cycle, against `fa94cc7` baselines):

| Cell | Baseline ms_autoplay | Phase 3 ms_autoplay | Gain |
|---|---:|---:|---:|
| custom/cold/medium | 9 893 ms | 5 509 ms | **+4.4 s (+44 %)** |
| design/cold/medium | 7 830 ms | 3 068 ms | **+4.8 s (+61 %)** |
| design/warm/medium | 7 166 ms | 4 083 ms | **+3.1 s (+43 %)** |
| clone/cold/medium (n=3) | 14 036 ms | 5 765 ms | **+8.3 s (+59 %)** |
| clone/warm/medium | 15 090 ms | 5 483 ms | **+9.6 s (+64 %)** |
| custom/warm/medium | 8 044 ms | 11 106 ms | **−3.1 s (−38 %)** ⚠ |

Mean gain across all 6 cells: **+4.5 s** saved on time-to-first-sound.

**History.** A first May 2026 enable attempt was bench-rejected: 6/6 cells exceeded ±0.1 dB on `audio_rms_dbfs` and `audio_peak_dbfs` vs the `fa94cc7` baselines, three cells > ±1 dB peak deviation. Investigation falsified the early "model-side sampling/RNG divergence" hypothesis and identified the real cause: both paths invoke the same `streamingStep` decoder but with very different chunk sizes (300 tokens for `streamingDecode` vs ~12 tokens for streaming). `DecoderBlockUpsample.step()`'s output-side overlap-and-add accumulator was producing LSB drift at every chunk boundary that amplified through `SnakeBeta` and downstream blocks. **The decoder fix landed in `4fab110`** (input-side `inputContext` buffer + `callAsFunction([context, x])` + discard leading samples — each emitted sample is now a slice of one conv operation, matching batch-mode float parenthesisation regardless of chunk size). `CausalConv1d.step()` was audited and left unchanged; its `streamBuffer` already implements the equivalent pattern for stride=1.

**Phase 3 verification gap closed in `f6aa8e3`.** `prepareStreamingPreview` is defined but never called from production — the streaming-autoplay flow relies on the auto-init path in `AudioPlayerViewModel.startLiveSession`, which is invoked from `handleGenerationChunk` when the first streaming chunk arrives with a new session ID. That path set `liveAutoplayEnabled` but forgot to set `pendingAutoplaySignpost`, so `consumeAutoplaySignpostIfNeeded()` was a no-op and the "Autoplay Start" OSSignposter event never fired despite actual playback starting. `f6aa8e3` adds `pendingAutoplaySignpost = autoPlay` in `startLiveSession` so the signpost mirrors the live engine's actual play() call. The bench parser in `scripts/uitest.sh` was also updated (`6b7c5e2`) to capture "Autoplay Start" when it fires BEFORE "Final File Ready" — required because streaming autoplay fires during generation, not after.

**Ruled out** by the investigation (do not re-litigate): `PCM16StreamLimiter` math (sequential, state-pure, no lookahead — `NativeStreamingSynthesisSession.swift:506`); LM token sampling (deterministic given seed); the transformer KV-cache (offset correctly tracked, normalization is over feature axis).

**Phase 4 follow-up investigation (post-`6c2ea52`):**

1. **Warm-after-cold streaming engagement race — fully fixed in `6c2ea52` + `be4dbcf`.** Two distinct races were stacked:
   - **Race A (engine retention, fixed in `6c2ea52`)**: `teardownLivePlayback(clearSession: true)` left `liveEngine` and `livePlayerNode` references non-nil after `.reset()`ing the engine. The next session's `appendLiveChunk` skipped `configureLiveEngine` (guard `if liveEngine == nil || livePlayerNode == nil` was false), and `attemptLivePlay`'s `liveEngine.start()` threw — silently swallowed. Fix: nil out the references in the clearSession block. Closed custom/warm and design/warm.
   - **Race B (stale buffer completions, fixed in `be4dbcf`)**: AVAudioEngine's per-buffer completion callback hops to MainActor via `Task { @MainActor in ... }`. Cold's late-firing tasks landed AFTER warm's `startLiveSession` had reset `liveScheduledCount = 0` and `liveQueuedAudioSeconds = 0`, then decremented warm's freshly-incremented counters and removed warm's entries from `liveBufferDurations`. `shouldStartLivePlayback`'s Policy 2 then could never trigger for warm. The `guard playbackMode == .live` was too coarse (warm IS .live). Fix: capture `liveSessionID` at `scheduleLiveBuffer` time and reject completions in `handleLiveBufferPlaybackCompletion` whose sessionID doesn't match the current `liveSessionID`.
   
   Verification (`build/Debug/uitest/20260516-153215`): 10 streaming samples across 3 modes (3 clone cold/warm pairs + 1 custom pair + 1 design pair) — **10/10 engaged streaming, 0 fallbacks**. Pre-fix repro rate on clone/warm back-to-back pairs was ~50 %.
   
   Production signposts at every streaming state transition (`Chunk Received`, `Chunk Decoded`, `Live Session Start`, `Live Engine Play`, `Session Completed Recorded`, `Switch To File Playback`, `Should Start Reject Autoplay`, `Should Start Reject Buffer`, `Stale Completion Dropped`) — together they reconstruct the streaming state machine's complete trace in `log show --signpost`; useful for any future regression triage.

2. **Cold-cell audio loudness shift — falsified as a regression.** The Phase 3 observation of +1-3 dB louder RMS on cold cells was based on too-small samples (n=1 for custom/design, n=3 for clone). Phase 4 re-bench with the fix in place showed the deviation goes BOTH ways (-1.56 to +2.81 dB across cells in the same run, with the same generation parameters). The previous "AVAudioFile applies gain" hypothesis was wrong: the streaming WAV writer's `IncrementalPCM16WAVFileWriter` and the non-streaming `AtomicPCM16WAVWriter` both write the same Int16 samples; the per-cell deviation is dominated by LM sampling variance run-to-run. The `fa94cc7` baseline's n=3 samples just happened to lie at one end of that variance distribution. To re-promote the baseline accurately would need n=10+ per cell. Not a regression; no action needed.

**If a future change needs to bench-validate against `fa94cc7` again,** the recipe is the same as Phase 3: 6 minimal cells (custom/design/clone × cold/warm × medium prompt × Speed variant) via `scripts/uitest.sh bench-step`. Pass criteria: ms_engine_start_to_autoplay should drop substantially on cold cells (>40 % gain expected); audio RMS/peak within baseline natural variance (using the per-cell `min..max` range, NOT ±0.1 dB of mean — that's stricter than the n=3 baseline's own spread).

## SPM dependencies (pinned in `project.yml`)

- `MLXSwift` 0.30.6 (`https://github.com/ml-explore/mlx-swift.git`)
- `MLXAudio` — **vendored locally** at `third_party_patches/mlx-audio-swift/` (Vocello-specific patches; do not replace with the upstream package without porting patches)
- `SwiftHuggingFace` 0.9.0 (model downloads)
- `GRDB` 7.10.0 (local SQLite — history, saved voices, model metadata)

## Conventions to preserve

- `accessibilityIdentifier` values in UI (e.g., `voicesRow_*`, `voicesEnroll_*`) are stable surface area — keep them when refactoring views.
- Animations route through `appAnimation` / `AppLaunchConfiguration.performAnimated` so Reduced Motion is honored; Liquid Glass surfaces must fall back to solid fills when Reduce Transparency is on. Both are non-negotiable per `PRODUCT.md`.
- Do not propose reintroducing a Python backend, a standalone CLI, or bundled model weights.
- Keep macOS release artifacts named `Vocello.app` and `Vocello-macos26.dmg`.
- Do not use `/ultraplan` on this project. Claude Code runs here inside the Claude.app desktop helper, which injects `ANTHROPIC_BASE_URL` pointing at its internal proxy — the cloud-teleport route `/ultraplan` requires (POST `/v1/sessions` against `api.anthropic.com` with OAuth subscription auth) doesn't work through that proxy, and `ANTHROPIC_API_KEY` shows up empty-but-set in the env, which trips the auth precedence. Use local plan mode (`Shift+Tab`) instead; it produces the same plan-quality without the cloud handshake.
- **Drive SwiftUI Picker menus by keyboard, not fixed click coordinates.** SwiftUI `Picker` menus open anchored to the **currently-selected item**, not to a fixed top position, so a fixed-coordinate click on a menu row only works on the first selection of a session — subsequent picks land on the wrong row as the menu shifts. This is the bug that mislabeled 45 of 53 cells in the May 2026 emotion matrix run. Reliable pattern: `left_click` the picker to open the menu, then `mcp__computer-use__key(text: "down")` (or `"up"`) N times from the currently-selected index to the target, then `key(text: "return")` to confirm. Track current selection in shell state to compute N. Full pattern lives in [`docs/reference/ui-test-surface.md`](docs/reference/ui-test-surface.md) under "Driving SwiftUI Picker menus"; keep that doc in sync if `scripts/uitest.sh` or any bench/smoke runbook adds a new picker-driver path.

## Where to find more

- `docs/README.md` — documentation index
- `docs/reference/current-state.md` — current repo facts
- `docs/reference/release-readiness.md` — release signoff gates + iOS shipping plan
- `docs/reference/ios-simulator-testing.md` — iOS Simulator UI review + Simulator-only fake install/delete dev affordance
- `docs/reference/privacy-storage.md` — local storage and deletion
- `docs/qwen_tone.md` — prompt/tone guidance for voice generation
- `docs/reference/antigravity-voice-review.md` — Antigravity-CLI-backed perceptual review runbook (semi-automated, complements the bench's timing/RMS gates with subjective dimensions). The legacy `gemini-voice-review.md` is a redirect stub after Google retired Gemini CLI in favor of Antigravity CLI (2026-05-19).
- `CONTRIBUTING.md` — contributor workflow
