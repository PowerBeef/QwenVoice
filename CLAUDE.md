# CLAUDE.md

Single source of truth for working in this repo with Claude Code. If something here disagrees with the code, the code wins — fix this file.

## What this repo is

**Vocello** (formerly QwenVoice) — a local, private text-to-speech **macOS** app running Qwen3-TTS via **MLX** on Apple Silicon. The macOS Xcode scheme is still `QwenVoice`; the shipped product is `Vocello.app` / `Vocello-macos26.dmg`. The iOS app (`VocelloiOS`) is **compile-safe only** on `main` — on-device generation and TestFlight are deferred pending Apple's increased-memory entitlement, and iPhone proof is **not** a public-release blocker. The marketing site lives in `website/` (React + Vite, deployed by Vercel from that subdir; it has its own `website/CLAUDE.md`).

Targets: macOS 26+ and iOS 26+, Apple Silicon only, Xcode 26. No Python runtime, no bundled model weights — models download from Hugging Face on first run (Settings → Model Downloads).

## Quick start

```sh
./scripts/build.sh run                       # fast -Onone build → launch Vocello.app
./scripts/build.sh build                      # fast -Onone build, no launch (alias: debug)
./scripts/build.sh release                    # → scripts/release.sh (optimized signed/notarized DMG)
./scripts/build.sh clean                      # rm -rf build/
QWENVOICE_DEBUG=1 ./scripts/build.sh run      # launch with the runtime debug toggle ON
./scripts/build_foundation_targets.sh macos   # clean macOS foundation build
./scripts/build_foundation_targets.sh ios     # iOS compile-safety only
./scripts/check_project_inputs.sh             # static validator — run before any build
npm --prefix website run build                # marketing site production build
```

First-time setup: `brew install xcodegen` (required), optionally `brew install xcbeautify` (prettier build output). There is no lint/format/typecheck step — **the build is the typecheck**.

## Source of truth

When facts disagree, trust in order: `Sources/` → `project.yml` → `scripts/` → `.github/workflows/release.yml` → this file → other prose. `Sources/Resources/qwenvoice_contract.json` is the canonical schema for speakers, models, variants, Hugging Face revisions, and required artifacts.

## Agent routing (Claude Code)

Before any iOS/Swift response, check whether an **Axiom skill** applies (environment/build → architecture → implementation). Use Axiom **subagents** via the `Agent` tool (`subagent_type`) for audits.

**Launch the relevant subagent before deep work, then address or explicitly defer findings:**

| Symptom / scope | `subagent_type` | Pair with skill |
|---|---|---|
| BUILD FAILED / Xcode env | `axiom:build-fixer` | `axiom:axiom-build` |
| Crash log (`.ips`, MetricKit) | `axiom:crash-analyzer` | (`xcsym` tool) |
| Engine async / actors / gates | `axiom:concurrency-auditor` | `axiom:axiom-concurrency` |
| Memory / streaming / MLX cache | `axiom:memory-auditor` (+ `axiom:swift-performance-analyzer`) | `axiom:axiom-performance` |
| GRDB / migrations | `axiom:database-schema-auditor` | `axiom:axiom-data` |
| Release / entitlements / privacy | `axiom:security-privacy-scanner` | `axiom:axiom-security` |
| SwiftUI work / perf / layout / nav | `axiom:swiftui-*-auditor` | `axiom:axiom-swiftui` |
| Full project audit | `axiom:health-check` | |

- **Backend/MLX:** `mlx-swift` (array/runtime/memory, custom ops) and `mlx-swift-lm` (generation, streaming, KV-cache, model porting, the vendored `mlx-audio-swift` stack). MLX is the only Qwen3-TTS backend — don't pivot to Core ML.
- **Apple framework / iOS 26 / post-cutoff APIs:** `axiom:axiom-apple-docs` skill + `sosumi` MCP; Xcode for-LLM guides live under `/Applications/Xcode.app/...AdditionalDocumentation/`.
- **GitHub:** `gh` CLI via Bash + `/review`. **Hugging Face:** `hf` CLI via Bash. Branch before committing if on `main`; commit/push only when asked.
- Don't auto-invoke unrelated skills (`deep-research`, `anthropic-skills:*`, `design:*`, `productivity:*`, `engineering:*`, `claude-api`). For website work use `context7` for library docs, `impeccable:impeccable` for UI/UX, `chrome-devtools` for browser verification.

## Build & project generation

The Xcode project is generated from `project.yml` via XcodeGen — edit `project.yml` (not `.xcodeproj`), then `./scripts/regenerate_project.sh`. `build.sh` skips regen / SPM resolve when their input fingerprints (under `build/.cache/`) are unchanged.

**Single config — no `DEBUG` symbol.** There is one shippable Xcode config (`Release`); `project.yml` declares only `configs: { Release: release }`. `build.sh` builds it **`-Onone`** for a fast local loop; `release.sh` builds the same config **optimized** for the DMG. So dev and shipped binaries run **identical code paths** — there is no `DEBUG` compilation symbol and no Debug-vs-Release behavior fork. Debug capabilities (telemetry, probing) are gated at **runtime** by `DebugMode`, not compiled out. (`#if DEBUG` blocks that remain are pure test/sim scaffolding and intentionally compile out of the shipped package.)

**Debug mode (runtime toggle).** `Sources/Services/DebugMode.swift` resolves `DebugMode.isEnabled` once at launch from either the `QWENVOICE_DEBUG` env var (`1`/`true`/`on`/`yes` — dev + scripts) or a persisted `UserDefaults` flag (`QwenVoice.DebugModeEnabled`) flipped by tapping the version label in Settings **7×**. Gesture changes apply on the next launch (it gates the data folder, resolved early).

**XcodeGen iOS-resource gotcha (do not break).** The iOS app target lists `qwenvoice_contract.json`, `qwenvoice_ios_model_catalog.json`, `voice-previews`, and `Assets.xcassets` under its `sources:` block with an explicit `buildPhase: resources` override — **not** under `resources:`. XcodeGen 2.45.4 silently drops them from the `VocelloiOS` Resources phase if listed under `resources:`, so iOS builds compile but crash on first launch with missing bundled resources. (macOS uses the `resources:` directory pattern and is unaffected.) Landed in `287c969`.

**Build layout.** Everything lives directly under a single `build/` (`build/DerivedData`, `build/.cache`, `build/Vocello.app`, `build/Vocello-macos26.dmg`, `build/foundation/`) — `build.sh` and `release.sh` share it. **Single-resident policy:** one `build/Vocello.app` + one `build/Vocello-macos26.dmg` + one active `build/DerivedData` tree at a time; pruning is automatic (a running `Vocello` is quit first; the legacy `build/Debug` + `build/Release` split is cleaned on sight). The `build_foundation_targets.sh` compile-safety builds use their own DerivedData under `build/foundation/`; they **remove it on exit** (trap), and a normal `build.sh` build also prunes a stale foundation tree — so no second 1–2 GB build tree ever lingers. Failed builds skip artifact pruning so they survive for inspection. `build.sh clean` (`rm -rf build/`) reclaims everything (~7 GB; next build is a one-time full rebuild).

**Storage hygiene (disk-tight systems).** The biggest reclaimable chunk is usually NOT the build: running the app in debug mode downloads model weights into `~/Library/Application Support/QwenVoice-Debug/models/`, which accumulates **both** Speed (4-bit) and Quality (8-bit) variants and can reach 15 GB+. It's regenerable (re-downloads from Hugging Face). Prefer verifying changes via builds + reading the existing `diagnostics/*/generations.jsonl` telemetry over repeated debug app launches; only launch in debug mode when needed, and clear `QwenVoice-Debug/models` when storage is tight (the real `QwenVoice/models` is the shipped app's and should be left alone). The diagnostics JSONL itself is **size-capped + auto-pruned** (oldest-first) by `GenerationTelemetryJSONLSink` (default ~8 MB/log; verbose `samples-*.jsonl` sidecars kept newest-48 / ≤64 MB; `QWENVOICE_DIAGNOSTICS_MAX_MB` scales the per-log cap), so benchmark logs can't blow out disk — no manual clear needed for logs (models remain the big reclaimable chunk).

**Runtime data folder.** One folder, selected in `Sources/Services/AppPaths.swift`: `~/Library/Application Support/QwenVoice/` normally, or `QwenVoice-Debug/` when `DebugMode.isEnabled` (so dev work never touches real data). `QWENVOICE_APP_SUPPORT_DIR` overrides the root. `AppDefaults` mirrors this (a `…app.debug` prefs suite when the toggle is on). (Note: there is intentionally **no** models-dir-only override — the prepared-cache overlay lives inside each model dir, so pointing a debug run at the real models dir rebuilds it in place and mutates real model data; copy the package into `QwenVoice-Debug/models/` instead.)

## Architecture

Two-platform Swift codebase with an out-of-process engine per platform.

- `QwenVoiceCore/` — shared engine semantics: `TTSEngine`, `MLXTTSEngine`, `TTSEngineError`, `GenerationMode`, audio prep.
- `QwenVoiceBackendCore/` — low-level MLX + audio primitives (model load, synthesis, codecs).
- `QwenVoiceEngineService/` — **macOS XPC service** (`EngineServiceHost.swift`) running generation in an isolated process.
- `QwenVoiceNative/` — macOS app-facing engine proxy/store/client (bridges XPC to UI).
- `QwenVoiceEngineSupport/` — native runtime helpers (memory policy, streaming, telemetry).
- `iOSEngineExtension/` — **iOS ExtensionKit extension** (`VocelloEngineExtension`) running heavy generation off the UI process.
- `iOS/` + `iOSSupport/` — iOS app surface (`@Observable` `AppModel`, 4-tab IA: Studio / Voices / History / Settings; design tokens are intentionally locked to the macOS values).
- Top-level macOS app: `QwenVoiceApp.swift`, `ContentView.swift`, `Views/`, `ViewModels/`, `Models/`, `Services/`.

`AppEngineSelection.current()` picks the engine per platform (macOS XPC client / iOS extension-backed). UI generation flows through three coordinators — `CustomVoiceCoordinator`, `VoiceDesignCoordinator`, `VoiceCloningCoordinator` (iOS adds `IOSBatchGenerationCoordinator`). Active Qwen3 variants: **Speed** (1.7B 4-bit) and **Quality** (1.7B 8-bit); 0.6B is verified but intentionally not listed. 8 GB Macs default to Speed, larger Macs to Quality; iPhone is Speed-only.

## Critical engine invariants (do not regress)

- **Prewarm reentrancy gate.** `NativeEngineRuntime` is an actor, but actors don't prevent reentrancy across suspension points. `ensureWarmStateIfNeeded` / `ensureDesignConditioningWarmStateIfNeeded` serialize through `acquirePrewarmSlot()` / `releasePrewarmSlot()` (`prewarmInFlight` + waiter continuations). Two prewarms racing into MLX KV-cache slice updates trips a C++ assertion and crashes the engine. **Anti-pattern:** never pair `try? await acquirePrewarmSlot()` with an unconditional `defer { releasePrewarmSlot() }` — on a throw the slot isn't held and the defer releases someone else's slot. Use `do { try await acquirePrewarmSlot() } catch { return }` then `defer`.
- **macOS `MLXTTSEngine.events` must stay `.unbounded`.** It's the streaming-preview chunk-delivery path and must not drop `.chunk` events. iOS stays bounded (`.bufferingNewest(64)`) for extension memory safety. Capping macOS (tried in `d93612c`) dropped chunks → latency/quality regressions. If backpressure ever matters, count it in `native-events.jsonl`, don't drop at the producer.
- **Generation ownership & cancellation.** `MLXTTSEngine` owns admission for all model-mutating work via a model-operation gate (one mutator at a time). Proactive warm ops defer when busy; user generation rejects cleanly when another is active. macOS/iOS stores expose `hasActiveGeneration`; XPC + extension hosts reject concurrent generation. Streaming chunks carry a UUID `generationID` (numeric `requestID` is logs-only). Vendored Qwen producers cancel their `Task` on stream termination and check cancellation in token/decode loops.
- **Per-tier memory.** `NativeMemoryPolicyResolver` picks a policy per `NativeDeviceMemoryClass` (floor8GBMac / mid16GBMac / highMemoryMac / iPhonePro): cache limits, idle-unload windows, clone-cache caps, custom-prewarm policy, and streaming tuning (`clearMLXCacheOnStreamChunkEmit` / `mlxTokenMemoryClearCadence`, pushed to the backend via `Qwen3StreamingMemoryTuning`). **No hard `Memory.memoryLimit`** on any tier — a 6 GB (floor) and 5 GB (iPhone) cap were tried and reverted in `b77c08e` (spurious OOM downgrades). floor8GBMac also: `clearCacheAfterGeneration` + adaptive idle-unload (120 s → 30 s softTrim → 10 s hardTrim). There is **no Quality→Speed OOM fallback** — picking Quality (8-bit) always loads the 8-bit model and surfaces the real error if it can't fit (no silent downgrade), on every tier. `NativeMemoryPressureMonitor` maps kernel pressure → `trimMemory(level:)`.
- **Decoder drift (do not reintroduce).** Streaming and batch invoke the same `streamingStep` decoder at very different chunk sizes; `DecoderBlockUpsample.step()`'s output-side overlap-and-add once produced LSB drift at chunk boundaries. Fixed in `4fab110` (input-side `inputContext` buffer + `callAsFunction([context, x])` + discard leading samples — each sample is a slice of one conv op regardless of chunk size). Don't revert it.
- **Event forwarding.** XPC hosts drain `engine.events` on a `Task.detached(.utility)` (off MainActor) so the synchronous XPC encode can't lag the producer; only `lastPublishedEvent` hops to MainActor (via `LatestEventCoalescer`, a lock-guarded coalescing slot — no per-chunk MainActor task spawning).
- **iOS memory posture.** Admission blocking is **records-only** (`guardModelAdmission` → `model_admission_observed`) while measuring extension Jetsam without the entitlement. iOS generation is streaming-first; physical devices omit inline `previewAudio.pcm16LE` unless `QWENVOICE_STREAMING_PREVIEW_DATA=on`. `Qwen3TTSMemoryCaches.clearAll()` runs on iPhone hard-trim/unload/failure; macOS cache warmth is preserved.
- **Entitlements.** App sandbox is **disabled** (`com.apple.security.app-sandbox = false` in `Sources/QwenVoice.entitlements`) — required for MLX. Hardened runtime on with allow-unsigned-memory + disable-library-validation.

## Testing

Benchmarking + output-quality checks are **first-class**: committed benchmark/QC **scripts, baselines, and summaries are allowed** (keep committed `benchmarks/` logs ≤256 KB each, no raw `*.jsonl` — guard-enforced; raw diagnostics JSONL stays gitignored + auto-pruned). There is **no automated UI-driving or smoke-test harness** (the XCUITest bundle stays retired). Track performance over time via `benchmarks/HISTORY.md` (one ledger row per run; append with `summarize_generation_telemetry.py --ledger-row --label "…" >> benchmarks/HISTORY.md`) + dated `--label` snapshots — compared with `git diff`, never an auto-compared baseline gate. Behavioral validation is **manual or agent-driven**: `./scripts/build.sh run`, then exercise the app by hand **or drive it live via the native `computer-use` MCP** (Cowork/Claude Code) — see [`docs/reference/ui-driving.md`](docs/reference/ui-driving.md). **UI-driven tests/reviews/benchmarks MUST use the `computer-use` MCP** (load the toolkit with one `ToolSearch` query `computer-use`, `max_results: 30`; `mcp__computer-use__request_access` for `Vocello` → full tier; then `screenshot` + `left_click`/`type`/`key`). **Do NOT drive the Vocello UI with AppleScript / System Events** — the SwiftUI accessibility tree is virtualized (lazily materialized, inconsistent between calls; e.g. the `textInput_textEditor` `AXTextArea` only appears after a real focus-click, and `AXPress` on the scroll area does not focus the inner editor), so AppleScript UI scripting is unreliable and is the wrong tool here. Run all shell work (builds, JSONL inspection) through the Bash tool, never computer-use. The only automated gate is build/compile-safety (`./scripts/build.sh build`, `./scripts/build_foundation_targets.sh ios`). Benchmark latency is captured via Instruments (`xctrace … os-signpost`) or the runtime-gated per-generation telemetry — **not** the unified `log` (it does not surface the engine's `OSSignposter` signposts). When `TelemetryGate` is on (`QWENVOICE_DEBUG=1`, or the 7-tap DebugMode flag relayed to the engine process over the `initialize` IPC handshake), each layer appends one JSON line keyed by the shared `generationID` under `…/QwenVoice[-Debug]/diagnostics/`: `app/generations.jsonl` (submit→firstChunk→firstAudible→completed + rescued memory `summary`), `engine-service/generations.jsonl` (XPC transport: forwarded count, gaps, forwarding span), `engine/generations.jsonl` (backend memory `summary`), all joined into `generations-merged.jsonl` (the intended benchmark source). `TelemetryGate`/`GenerationTelemetryRecord`/`GenerationTelemetryJSONLSink` live in `QwenVoiceCore`; `AppGenerationTimeline` in `SharedSupport`; `GenerationTelemetryMerger` in `Sources/Services` (macOS). The engine row also carries the full MLX decode breakdown (`timingsMS`, re-read from the model after the decode loop), derived KPIs (`derivedMetrics`: `audioSecondsPerWallSecond` = realtime factor, `tokensPerSecond`), per-stage MLX GPU memory (`mlxMemoryByStage`), a per-chunk decode timeline (`chunkTimeline`), and a populated `stageMarks` timeline (a per-generation `NativeTelemetryRecorder` is created in `prepareGeneration`, sharing the sampler's start clock). The sampler cadence is device-tiered (high-mem Mac 100ms / 16GB 250ms / 8GB+iPhone 500ms); `QWENVOICE_NATIVE_TELEMETRY_MODE=verbose` additionally writes a raw per-sample sidecar. The legacy `native-events.jsonl` still carries chunk-gap/encode-drop events. For a repeatable cross-mode benchmark, launch with `QWENVOICE_SUPPRESS_WARMUP=1` (accurate cold-start; Custom/Design only — Voice Cloning is warm-by-design) and aggregate with `python3 scripts/summarize_generation_telemetry.py` (prints RTF/tokens/TTFC/decode + RAM `physFoot`/RSS/peak-GPU, a per-stage GPU-growth block, and `trims`/`pressure` from `memory_trim`/`memory_pressure` stage marks). To measure **memory pressure on a high-memory dev Mac**, also launch with `QWENVOICE_FORCE_MEMORY_CLASS=floor_8gb_mac` (`NativeDeviceClassGate`; propagated to the engine over the `initialize` handshake since env doesn't cross) to run the constrained-tier paths + start the pressure monitor, then induce real pressure with `sudo memory_pressure -l warn` mid-generation; each engine row stamps `notes.deviceClass` so forced runs are self-evident. **Output-quality regression guard:** every engine row carries a reference-free `audioQC` verdict (pass/warn/fail + flags: nonfinite/clipping/clicks/dropout/near_silent — extends `PCM16StreamLimiter`, surfaced as the summarizer `QC` column). This is the objective tripwire — the **mandatory pre-merge human/agent listening pass over the fixed corpus is the real perceptual gate** (see telemetry doc "Guarding output quality"). Full reference: [`docs/reference/telemetry-and-benchmarking.md`](docs/reference/telemetry-and-benchmarking.md). Don't reintroduce the retired **test bundle / UI-driving harness / device + TestFlight tooling** or extra GitHub workflows without an explicit maintainer decision — `scripts/check_project_inputs.sh` still guards those (and caps committed `benchmarks/` logs: ≤256 KB, no raw `*.jsonl`). **Benchmark + output-quality scripts, baselines, and docs are permitted** (no longer guard-banned).

## Release & iPhone status

macOS-first. Signoff = green build + `scripts/release.sh` package (sign/notarize/staple → `build/Vocello-macos26.dmg`) + manual smoke of the packaged `build/Vocello.app`. CI is a single workflow (`.github/workflows/release.yml`): `package` (macOS DMG) + `compile-ios` (iOS compile-safety only) — no tests, benches, or signed IPA.

iPhone is compile-safe only; on-device generation, memory proof, and TestFlight are deferred pending Apple's `com.apple.developer.kernel.increased-memory-limit` entitlement for `com.patricedery.vocello` + `com.patricedery.vocello.engine-extension`. The copy-ready Apple request packet is [`docs/reference/ios-increased-memory-entitlement-request.md`](docs/reference/ios-increased-memory-entitlement-request.md). (The previous on-device deploy/proof tooling was removed and would need re-establishing when iPhone work resumes.)

## SPM dependencies (pinned in `project.yml`)

- `MLXSwift` 0.30.6 (`github.com/ml-explore/mlx-swift`)
- `MLXAudio` — **vendored** at `third_party_patches/mlx-audio-swift/` (Vocello-specific patches)
- `SwiftHuggingFace` 0.9.0 (model downloads)
- `GRDB` 7.10.0 (local SQLite — history, saved voices, model metadata)

## Conventions

- Vendor edits inside `third_party_patches/mlx-audio-swift/` are allowed for backend correctness/memory/streaming/perf when the fix belongs below `QwenVoiceCore`. Keep them small, preserve upstream style, and follow the validation gates in [`docs/reference/mlx-audio-swift-patching.md`](docs/reference/mlx-audio-swift-patching.md). Treat an upstream rebase as a separate task.
- `accessibilityIdentifier` values (e.g. `voicesRow_*`, `textInput_*`) are stable surface area — keep them through refactors.
- Animations route through `appAnimation` / `AppLaunchConfiguration.performAnimated` (honor Reduced Motion); Liquid Glass surfaces fall back to solid fills under Reduce Transparency. Both non-negotiable.
- Don't reintroduce a Python backend, a standalone CLI, or bundled model weights. Keep macOS artifacts named `Vocello.app` / `Vocello-macos26.dmg`.
- **Maintainer privacy:** never commit personal identifiers into user-facing files (this file, `README.md`, `website/`, `docs/`, release notes, script defaults) — no legal names, personal emails, home paths (`/Users/<name>/…`), device nicknames, UDIDs, or hardcoded Apple team IDs. Bundle IDs (`com.patricedery.vocello`) and generic "Developer ID" / "notarized" wording are fine. Scan before committing.

## Where to find more

- [`docs/reference/privacy-storage.md`](docs/reference/privacy-storage.md) — local model/output/history/voice storage, App Group, and deletion paths.
- [`docs/reference/ios-increased-memory-entitlement-request.md`](docs/reference/ios-increased-memory-entitlement-request.md) — Apple increased-memory entitlement request packet.
- [`docs/reference/mlx-audio-swift-patching.md`](docs/reference/mlx-audio-swift-patching.md) — vendored backend patch procedure + validation gates.
- [`docs/reference/telemetry-and-benchmarking.md`](docs/reference/telemetry-and-benchmarking.md) — full telemetry reference: probes across all three layers, the per-generation record schema, MLX decode timings + KPIs, efficiency/tiering, and how to run+read a benchmark.
- [`docs/reference/ui-driving.md`](docs/reference/ui-driving.md) — driving UI tests/reviews/benchmarks via computer-use (macOS) + iPhone Mirroring (iOS).
- `docs/qwen_tone.md` — prompt/tone guidance for voice generation.
- `design_references/` — Vocello design system + iOS prototype (read before touching chrome/tints).
- `website/CLAUDE.md` — marketing-site guidance (React + Vite).
