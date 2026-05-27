# P0 Engine Gate Verification (2026-05-26)

Manual trace of AGENTS.md non-regression invariants.

| # | Invariant | Status | Evidence |
|---|-----------|--------|----------|
| 1 | **Prewarm slot** serializes all `prewarm*` paths | **PASS** | `ensureWarmStateIfNeeded` (L760–761) and `ensureDesignConditioningWarmStateIfNeeded` (L1109–1110) call `acquirePrewarmSlot()` / `defer { releasePrewarmSlot() }` before `model.prewarmCustomVoice`, `prewarmVoiceDesign`, `prewarmVoiceClone`. All 4 `await model.prewarm*` sites in NativeEngineRuntime.swift are inside gated functions. |
| 2 | **Model-operation lease** gates generation/load/prewarm | **PASS** | MLXTTSEngine: `beginUserModelOperation` for `.generation`, `.batchGeneration`, `.explicitLoad`, `.explicitUnload`; `beginProactiveModelOperation` for `.proactiveLoad`, `.proactivePrewarm`, `.clonePriming`. Waiters queue when generation active. |
| 3 | **Host single-generation** coordinators | **PASS** | `ServiceActiveGenerationCoordinator` actor in EngineServiceHost.swift; `ExtensionActiveGenerationCoordinator` in VocelloEngineExtensionHost.swift. Both hold one active generation with registered cancel closure. |
| 4 | **Ordered chunk transport** (no slot-sampling regression) | **PASS** | MLXTTSEngine exposes `events: AsyncStream` with `eventStreamContinuation.yield` before `@Published latestEvent` (L972–976). EngineServiceHost drains `for await event in engine.events` (L391–398). Comments explicitly reject chunk-only latestEvent sampling. GenerationChunkBroker receives full event stream via XPC publish path. |
| 5 | **Streaming cancellation** propagates to vendor | **PASS** | NativeStreamingSynthesisSession uses `Task.detached` + `withTaskCancellationHandler` (L146–154) and `Task.checkCancellation()` in chunk loop (L1061). Vendor Qwen3TTS.swift and Generation.swift use `continuation.onTermination` to cancel producer tasks; token loops call `Task.checkCancellation()`. |
| 6 | **Decoder chunk invariance** (`inputContext`) | **PASS** | Qwen3TTSSpeechTokenizer.swift DecoderBlockUpsample retains `inputContext` buffer with input-side overlap (L546–614). Documented fix for chunk-size LSB drift. No upstream-style output-side-only overlap revert detected. |
| 7 | **Live playback session ID** stale-completion guard | **PASS** | AudioPlayerViewModel captures `scheduleSessionID` at schedule time; `handleLiveBufferPlaybackCompletion` rejects mismatched IDs with `Stale Completion Dropped` signpost (L1019–1020). `teardownLivePlayback(clearSession:)` nils engine references (Race A fix documented in AGENTS.md). |

## Notes / watch items (not P0 failures)

- **latestEvent still exists** on MLXTTSEngine, ExtensionBackedTTSEngine, iOS TTSEngineStore for snapshot/UI bindings — intentional dual path; chunk delivery for macOS production uses AsyncStream + broker. iOS extension host comments mirror macOS suppression of duplicate snapshot publishes on chunk-only updates.
- **IOSSimulatorTTSEngine** uses latestEvent only — acceptable for stub path.
- **Re-verification**: Any new `await` into MLX inside NativeEngineRuntime without prewarm slot should be flagged in code review.

## Overall P0 gate verdict: **ALL PASS**

No regressions detected against documented crash-history gates.
