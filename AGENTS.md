# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## What this repo is

Vocello (formerly QwenVoice) — a local, private text-to-speech macOS app powered by Qwen3-TTS via MLX on Apple Silicon. The macOS scheme is still called `QwenVoice` but the shipped product is `Vocello.app` / `Vocello-macos26.dmg`. An iOS counterpart (`VocelloiOS`) is kept compile-safe but is not a release target for the current milestone.

Targets: macOS 26.0+ and iOS 26.0+, Apple Silicon only, Xcode 26.0. No Python runtime. No bundled model weights — models are downloaded from Hugging Face from Settings → Model Downloads on first run.

## Source of truth (when facts disagree)

Per `CONTRIBUTING.md`, trust in order: `Sources/` → `project.yml` → `scripts/` → `docs/reference/` → other prose. `Sources/Resources/qwenvoice_contract.json` is the canonical schema for speakers, models, variants, HF revisions, and required artifacts.

## Project generation and build

The Xcode project is generated from `project.yml` via XcodeGen. Edit `project.yml` (not `.xcodeproj`) for structural changes, then regenerate.

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
./scripts/release_ios_testflight.sh       # iOS TestFlight build/sign/notarize/upload
./scripts/clean_build_caches.sh           # nuke build caches
./scripts/export_diagnostics.sh           # collect diagnostics bundle
./scripts/verify_packaged_dmg.sh <dmg>    # verify a packaged DMG
./scripts/verify_release_bundle.sh <app>  # verify .app signing/entitlements
```

There is no SwiftFormat / SwiftLint config. There is no lint or typecheck command — the build is the typecheck.

### Build cache

Sha256 fingerprints at `build/.cache/` (`project.yml.sha256`, `Package.resolved.sha256.<context>`) let `build.sh` skip XcodeGen and SwiftPM resolve when their inputs are unchanged. The directory self-heals — delete it (or run `build.sh clean`) to force a cold rebuild. `xcodebuild` output is piped through `xcbeautify` when it's on `PATH` and stdout is a TTY.

### Single-resident build policy

At most one Debug `.app` and one Release `.app` + `.dmg` exist under `build/` at any time. Every successful `build.sh debug` and `build.sh release` (or direct `scripts/release.sh`) prunes the previous build of the same kind, including the intermediate Release `.app` inside `build/foundation/macos-release-derived-data/` and any older-named DMGs. Pruning is automatic with no opt-out; if `Vocello` is running it is quit (SIGTERM, then SIGKILL after a short grace period) before deletion. Failed builds skip pruning so previous artifacts stay intact for inspection.

### Runtime data folders

Release and Debug builds intentionally write to different Application Support folders so that Release behaves like a real end-user first launch while Debug accumulates state across rebuilds:

- Release: `~/Library/Application Support/QwenVoice/` (end-user-equivalent; not used for routine testing)
- Debug: `~/Library/Application Support/QwenVoice-Debug/` (persistent across rebuilds — models, `history.sqlite`, outputs, voices, stream-session caches all live here)

The split is compile-time inside `Sources/Services/AppPaths.swift` via `#if DEBUG`, so it holds regardless of launch method (Finder, Xcode Run, `build.sh run`, lldb). This works because the QwenVoice macOS target's Debug config in `project.yml` includes `DEBUG` in `SWIFT_ACTIVE_COMPILATION_CONDITIONS` — do not remove it without also moving the data-folder logic to a custom flag.

The first Debug launch under this policy renames an existing `QwenVoice/` folder to `QwenVoice-Debug/` automatically (no env-var override set, target folder absent, legacy folder present). The `QWENVOICE_APP_SUPPORT_DIR` env var still overrides the root in either configuration and disables auto-migration when set.

Release builds therefore start with an empty `QwenVoice/` after the first Debug launch — that's intentional. To exercise Release with realistic data, copy/symlink data into `~/Library/Application Support/QwenVoice/` manually or use the env-var override.

### Autonomous UI testing

The Debug build is drivable by a Codex session via the computer-use MCP. Entry point is `scripts/uitest.sh` (subcommands: `prep`, `reset [--include-voices|--full]`, `locate <ax-id>`, `window-locate <ax-id> [image-w image-h]`, `scaled-locate`, `screen-size`, `activate`, `logs`, `db <sql>`, `artifacts-dir`, `smoke-check [<mode>]`, plus the bench-* family: `bench-wait`, `bench-step`, `bench-record`, `bench-summarize`, `bench-compare`, `bench-update-baselines`). The agent's reference for what's clickable and how to verify generation completion lives at `docs/reference/ui-test-surface.md`. Test artifacts land in `build/uitest/<timestamp>/` and are wiped by `scripts/build.sh clean`.

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

## Testing policy — important

This repo intentionally has **no XCTest targets, no automated test harness, and no CI** as of May 2026. Behavioral validation is **manual**: after a clean foundation build, launch `build/Vocello.app` and exercise the affected paths by hand. Do not reintroduce test bundles, QA shell scripts, agent configs, benchmark harnesses, or any GitHub Actions workflow without an explicit maintainer decision — `scripts/check_project_inputs.sh` enforces this with a prohibited-paths list and a regex sweep of the working tree. Inspect that script for the current list rather than quoting names here (its patterns also trip on any file that mentions the banned names verbatim).

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

**Generation flows** (UI side): three coordinators map to the three workflows — `CustomVoiceCoordinator`, `VoiceDesignCoordinator`, `VoiceCloningCoordinator`. Speed (4-bit) vs Quality (8-bit) variant choice lives on the generation screens, not in Settings. iPhone is Speed-only; 8 GB Macs default to Speed, larger Macs default to Quality.

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

### Quality → Speed OOM fallback on floor8GBMac

`MLXTTSEngine.loadModel(id:)` catches load failures on floor8GBMac. If the failed model was a Quality variant AND the error matches OOM heuristics (NSError localizedDescription contains "memory" / "allocate" / "allocation", or NSPOSIXErrorDomain ENOMEM), the engine retries with the Speed sibling derived via the registry. `visibleErrorMessage` surfaces "Switched to Speed (4-bit) — Quality didn't fit in memory." If the fallback ALSO fails, the original error propagates (no cascade).

### Settings → Performance → "Always use Speed (4-bit) models"

Global UserDefaults override at key `QwenVoice.PreferSpeedEverywhere`. When set, `TTSContract.activeModel(...)` short-circuits the per-mode preference and returns the Speed variant for every mode. Default false (preserves existing per-mode behavior). UI in `SettingsView.swift` with `accessibilityIdentifier("settings_preferSpeedEverywhere")`.

### Prewarm signposts for bench traces

Two OSSignposter events in `NativeEngineRuntime` for bench/forensics: `"Native Prewarm Cache Hit"` (fires when `loadCoordinator.isPrewarmed(...)` returns true) and `"Native Design Conditioning Reuse"` (fires on the `reused: true` branch of `ensureDesignConditioningWarmStateIfNeeded`). Future bench-* tooling can count hits vs misses.

### Short-prompt Custom Voice prewarm depth

`NativeEngineRuntime.customPrewarmDepth(for:)` returns `"skip-decoder-bucket"` for `.custom` requests with `text.count <= 30`. The vendor's `Qwen3CustomVoicePrewarmDepth` enum (in `third_party_patches/mlx-audio-swift`) accepts that string and skips the decoder-bucket precompile during prewarm — the decoder compiles on first decode instead. Same output audio, only latency distribution changes. Only fires on tiers where `customPrewarmPolicy: .eager` (mid16GBMac + highMemoryMac); floor8GBMac skips the whole dedicated prewarm anyway.

### Headless-workload env vars

- `QWENVOICE_STREAMING_PREVIEW_DATA=off` (or `skip` / `false` / `0` / `no`) — skips per-chunk `previewAudio.pcm16LE` Data allocation. Default emits. For bench/CI/batch where nobody is listening to live preview.
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
   
   Verification (`build/uitest/20260516-153215`): 10 streaming samples across 3 modes (3 clone cold/warm pairs + 1 custom pair + 1 design pair) — **10/10 engaged streaming, 0 fallbacks**. Pre-fix repro rate on clone/warm back-to-back pairs was ~50 %.
   
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

## Where to find more

- `docs/README.md` — documentation index
- `docs/reference/current-state.md` — current repo facts
- `docs/reference/release-readiness.md` — release signoff gates
- `docs/reference/privacy-storage.md` — local storage and deletion
- `docs/qwen_tone.md` — prompt/tone guidance for voice generation
- `docs/reference/gemini-voice-review.md` — Gemini-backed perceptual review runbook (semi-automated, complements the bench's timing/RMS gates with subjective dimensions)
- `CONTRIBUTING.md` — contributor workflow
