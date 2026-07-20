# Vocello structure, backend depth, and runtime-refactor status report

> Maintainer status report for the active staged convergence program. Confirm against the
> checkout; source, `project.yml`, and `config/runtime-refactor-contract.json` remain higher
> authority. Reviewed with the Phase 5 evidence-path / Phase 6 sidecar / Phase 0 fixture landing.

**Verdict:** Phases **1–4 are source-complete** with focused macOS + physical-iPhone Custom/Design/Clone
acceptance on protected `main`. That is **not** full promotion. Telemetry still ships **schema v8
with a nested partial v9 projection** (now with shipping session/adapter identity digests and a
complete-document sidecar publisher). Sampling v2 ships with an in-tree evidence path (seed
agreement, WAV digests, sub-seed derivation); live fixed-seed promotion pairs remain open.
Load/prewarm still uses the named Legacy SPI. Phase 14 mechanical retirement is explicitly deferred.

## Authority order

1. Code + [`project.yml`](../../project.yml)
2. [`config/runtime-refactor-contract.json`](../../config/runtime-refactor-contract.json)
3. [`docs/decisions/runtime-streaming-quality-convergence.md`](../decisions/runtime-streaming-quality-convergence.md)
4. [`docs/development-progress.md`](../development-progress.md)
5. [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md) §4

## Project structure

| Path | Role |
| --- | --- |
| `Sources/` | First-party Swift: macOS app UI, Core/Backend/Native/XPC, iOS, SharedSupport, CLI |
| `Packages/VocelloQwen3Core/` | Owned Qwen3-TTS + Mimi runtime (XcodeGen alias `MLXAudio`) |
| `Tests/` | Core, XPC integration, macOS/iOS XCUITest, iOS logic (compile-only) |
| `scripts/` | Authoritative build/test/release/contract gates |
| `config/` | Machine-readable contracts |
| `docs/` | Architecture, progress, ADR, reference guides |
| `benchmarks/` | PASS-only privacy-safe history (schema v2 authoritative) |
| `.agents/` | Role playbooks |
| `.cursor/` | Project MCP (`mcp.json`) — not a second policy constitution |

### Shipping generation authority stack

```text
MLXTTSEngine (@MainActor product host)
  → NativeEngineRuntime (load / prewarm / conditioning SPI bridge)
  → UnsafeSpeechGenerationModel (holds VocelloQwen3Engine + opaque loaded model)
  → GenerationOutputAdapter  [lives in NativeStreamingSynthesisSession.swift]
       reserve → claimAudioConsumer → open → drain lossless channel
       → acknowledgeProductFinalization
  → VocelloQwen3Engine (actor: generation mutation lease)
       → VocelloQwen3ClassifiedGenerationSession
       → VocelloQwen3LoadedModel.produce (suspending Qwen producer)
```

macOS: UI/CLI → Native/XPC → EngineService → Core → owned runtime.  
iOS: UI → Core in-process → same owned runtime.

## Phase status (program map)

| Phase | State |
| --- | --- |
| 0 Characterization | Closed — clean controls bound |
| 1 Correctness | Shipping |
| 2 Actor + plans | Actor shipping; plans shadow-only; SPI load bridge remains |
| 3 Classified sessions | Shipping |
| 4 Product adapter + mode cutover | Overall promotion passed (`overallPromotion: passed`) |
| 5 Sampling v2 | Promotion-packaged evidence live |
| 6 Telemetry v9 | Complete sidecar authority with v8 envelope (`telemetry: 9`) |
| 7–13 | Foundations / not started / partial as in the runtime contract |
| 14 Mechanical retirement | Explicitly deferred (`phase14DeferredSurfaces` in the contract) |

## In-progress dual surfaces (do not misread as dual backends)

- Shipping adapter filename still `NativeStreamingSynthesisSession.swift` (Phase 14)
- Package `VocelloQwen3ProductOutputAdapter` vs Core `GenerationOutputAdapter` (only Core ships)
- Combined `VocelloQwen3ModelGenerationSession` — characterization only
- Legacy SPI for load/prewarm/Clone adoption
- Shadow plan mapper — comparison only
- Nested v9-in-v8 plus complete `*.streaming-telemetry-v9.json` sidecars when ready

## Risks

1. JSONL envelope remains v8; do not treat nested transitions alone as history v9 rows.
2. Focused exploratory XCUI is not clean full-matrix promotion.
3. Actor is generation mutation authority, not sole MLX mutator until SPI retires.
4. JSONL remains schema v8; complete v9 sidecars are the history authority for streaming detail.

## Resume order

1. ~~Live fixed-seed pairs~~, ~~nested-v9 producers~~, and ~~macOS + iPhone nested-v9 pilots~~
   landed 2026-07-19/20 (see `docs/development-progress.md`).
2. ~~Live Phase 0 characterization~~ closed 2026-07-20 (`status: closed`,
   `characterizationContract: closed-clean-control-sessions-bound`).
3. ~~Fresh full 29-take matrices~~ landed 2026-07-20
   (`macos-xcui-benchmark-20260720-172920-591696d1`,
   `ios-xcui-benchmark-20260720-174441-16fc128c`).
4. ~~Phase 5 promotion packaging + Phase 6 v9 sidecar authority~~ closed 2026-07-20.
5. ~~`overallPromotion: passed`~~ claimed 2026-07-20. Next: Phase 14 mechanical retirement.

## Implementation landed with this report

| Surface | Path |
| --- | --- |
| Sampling evidence + sub-seed derivation | `Sources/QwenVoiceCore/SamplingEvidence.swift` |
| WAV digest + seed agreement telemetry notes | `NativeStreamingSynthesisSession.swift` |
| Live codec/audio-channel/terminal nested-v9 producers | `NativeStreamingSynthesisSession.swift`, `Qwen3TTS.swift` chunk schedule, `VocelloQwen3AudioChunkEvent` |
| v9 sidecar publication / readiness gate | `GenerationStreamingTelemetryV9Publication.swift` |
| Session/adapter identity digests in bridge | `GenerationStreamingTelemetryV9Bridge.swift` |
| Model-free characterization fixtures | `config/characterization-fixtures.json` |
| Promotion prerequisite gate | `scripts/check_convergence_promotion_gate.py` |
| Phase 14 deferred surface list | `config/runtime-refactor-contract.json` → `phase14DeferredSurfaces` |

## Quick file index

| Need | Start here |
| --- | --- |
| Status | `docs/development-progress.md`, `config/runtime-refactor-contract.json` |
| Product generation | `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift` (`GenerationOutputAdapter`) |
| Actor / session | `Packages/VocelloQwen3Core/Sources/VocelloQwen3Core/Engine.swift`, `ClassifiedGenerationSession.swift` |
| Sampling evidence | `Sources/QwenVoiceCore/SamplingEvidence.swift` |
| Telemetry transition | `GenerationStreamingTelemetryV9*.swift` |
| Gates | `scripts/runtime_security_contract.py`, `scripts/check_convergence_promotion_gate.py`, `scripts/macos_test.sh test` |
