# Engine Core Deep Dive (2026-05-26)

## 2b. Memory policy parity

| Policy dimension | floor8GBMac | mid16GBMac | highMemoryMac | iPhonePro |
|----------------|-------------|------------|---------------|-----------|
| Cache limit | 256 MB | 512 MB | 1 GB | 128 MB (+ debug overrides) |
| clearCacheAfterGeneration | yes (non-batch) | no | no | yes |
| unloadAfterIdleSeconds | 120 (adaptive ↓ under pressure) | 600 | nil | 30 |
| clone cache cap | 1 | 8 | 16 | 1 |
| customPrewarmPolicy (host) | skipDedicatedCustomPrewarm | eager | eager | skipDedicatedCustomPrewarm (extension) |
| Streaming interval floor | 0.8s | 0.4s | 0.4s | 0.8s |

**Parity notes:**
- macOS 8 GB and iOS extension both skip dedicated Custom Voice prewarm — aligned.
- iOS adds **aggregate admission** in `TTSEngineStore` (app + extension footprints, critical/guarded bands) — macOS XPC store does not mirror this; macOS relies on process isolation + tier policy in core only.
- iOS hard-trim clears `Qwen3TTSMemoryCaches.clearAll()`; macOS preserves more cache warmth intentionally.
- Quality→Speed OOM fallback: **macOS floor8GBMac only**, user-visible message at MLXTTSEngine L580.

## 2c. Vendor patch inventory

**Upstream seed:** mlx-audio-swift v0.1.2 @ `fcbd04d`

**Production-critical deltas (do not rebase without re-proof):**

| Delta | Location | Class |
|-------|----------|-------|
| Decoder chunk invariance (`inputContext`) | Qwen3TTSSpeechTokenizer.swift | Correctness |
| Qwen3 TTS families + clone prompts | Qwen3TTS/*.swift | Feature |
| Chunked + full-result generation APIs | Qwen3TTS.swift, Generation.swift | Feature |
| Stream producer cancellation | Qwen3TTS.swift onTermination | Correctness |
| maxTokens as failure | Vendor + QwenVoiceCore | Quality |
| Prepared local model-directory loading | Qwen3 load path | Integration |

**Integration boundary:** App targets import `QwenVoiceBackendCore`; `QwenVoiceCore` imports MLX/MLXAudio directly (expected — core sits below app, above vendor).

**Drift risk:** MLX Swift 0.30.6 vs 0.31.3; MLX LM 2.30.6 vs 3.31.3 — defer controlled vendor refresh per foundation-projects-audit.md.

## 2d. IPC and streaming traces

### macOS path

```
CustomVoiceCoordinator.makeGenerationRequest (shouldStream: true)
  → TTSEngineStore.generate (QwenVoiceNative)
  → XPCNativeEngineClient
  → EngineServiceHost (ServiceActiveGenerationCoordinator)
  → MLXTTSEngine.generate → beginUserModelOperation(.generation)
  → NativeEngineRuntime.prepareGeneration (prewarm slot, load, clone conditioning)
  → NativeStreamingSynthesisSession.run (Task.detached + cancellation handler)
  → eventStreamContinuation.yield → engine.events AsyncStream
  → EngineServiceHost eventForwardingTask → XPC publish(.generationChunk)
  → GenerationChunkBroker.publish → AudioPlayerViewModel live session
  → GenerationPersistence → history.sqlite + final WAV
```

**Env vars:** `QWENVOICE_STREAMING_PREVIEW_DATA` (default emit on macOS), `QWENVOICE_STREAMING_OUTPUT_POLICY` (default pcm_preview).

### iOS path

```
IOSGenerationModeViews (legacy) → generate Task
  → TTSEngineStore (iOS) — aggregate memory admission
  → ExtensionBackedTTSEngine
  → ExtensionEngineCoordinator → VocelloEngineExtensionHost
  → same MLXTTSEngine / NativeStreamingSynthesisSession stack
  → latestEvent + optional Debug event sink (physical device: final-file playback default)
  → IOSStudioInlinePlayerCard / IOSPlayerSheet
```

**Physical iOS defaults:** inline PCM skipped unless `QWENVOICE_STREAMING_PREVIEW_DATA=on`; chunk files need `QWENVOICE_STREAMING_OUTPUT_POLICY=file` + event sink.

## 2e. Parallel implementation drift

| Concern | Behavioral divergence | Risk |
|---------|----------------------|------|
| TTSEngineStore | iOS: extension lifecycle, aggregate memory guard, chunk via NotificationCenter path; macOS: XPC snapshot subscription, GenerationChunkBroker | Medium — intentional platform differences |
| DatabaseService | macOS v4 index migration; iOS missing v4 | HIGH — perf + future drift |
| TTSContract | macOS full variant catalog; iOS bundled catalog JSON, Speed-only | Intentional product policy |
| Streaming preview | macOS inline PCM default; iOS device skips | Intentional memory policy |
| Generation UX | macOS coordinators own flow; iOS logic in legacy views | HIGH — maintenance, cancel UX gaps |

## 2f. Validation posture

- **CI:** release.yml only — no behavioral tests
- **Local proof:** scripts/uitest.sh smoke (6) + bench (24 cells, benchmark-baselines.json)
- **Recommendation:** Re-bench affected cells after changes to NativeStreamingSynthesisSession eventSink, MLXTTSEngine events buffering, or memory unload timing
