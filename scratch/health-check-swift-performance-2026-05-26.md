# Swift Performance Audit — Engine Hot Paths (2026-05-26)

## Summary

Scoped audit of generation/streaming hot paths: `MLXTTSEngine`, `NativeEngineRuntime`, `NativeStreamingSynthesisSession`, `AudioPlayerViewModel`, `TTSEngineStore`, `GenerationChunkBroker`, and vendor `Qwen3TTS` streaming code.

**Verdict: BOTTLENECKED** — the token loop and chunk pipeline are structurally sound (reserveCapacity, asyncEval pipelining, scratch-buffer design), but **per-chunk MainActor delivery** and **multi-stage PCM copies** amplify cost on every streaming chunk. Highest ROI fixes: decouple chunk transport from `@MainActor`, wire the existing `PCM16ScratchBuffer` pool, and eliminate redundant `[Int16]` / `Data` copies in the preview path.

| Severity | Count |
|----------|------:|
| CRITICAL | 3 |
| HIGH | 6 |
| MEDIUM | 6 |
| LOW | 3 |

**Health:** BOTTLENECKED (CRITICAL issues in hot paths)

---

## Performance Hotspot Map

- **Large value types:** `GenerationRequest`, `StreamingAudioChunk` (carries `Data` pcm16LE), `GenerationChunk`, `StreamingExecutionContext` (~15 fields + snapshot dicts). Chunk events copy full preview payloads.
- **Hot loops:** Qwen3TTS token loop (`for _ in 0 ..< effectiveMaxTokens`, ~2551), code-predictor inner loop, `PCM16StreamLimiter.append` per sample, streaming chunk loop (`for try await event in stream`).
- **Actor boundaries:** `NativeEngineRuntime` actor — per-generation prep only (acceptable). **Streaming chunk sink is `@MainActor`** — one hop per chunk from `Task.detached` generation work (not acceptable at scale).
- **Generics / existentials:** `[any KVCache]` in Qwen3 talker/code-predictor (vendor, unavoidable at module boundary). App layer uses `any MacTTSEngine` / `any ModelRegistry` on cold paths only.
- **ARC-heavy:** `[weak self]` in live-buffer completions (one closure + Task per scheduled buffer), `GenerationChunkBroker.publish` Task wrapper, batch progress relay Task hops.

---

## Issues

### CRITICAL — MainActor chunk sink blocks streaming generation thread

| Field | Value |
|-------|-------|
| **File:line** | `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift:1140`, `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift:16`, `Sources/QwenVoiceCore/MLXTTSEngine.swift:971-976` |
| **Description** | Streaming runs in `Task.detached`, but every chunk calls `await eventSink(chunkEvent)` where `eventSink` is `@MainActor`. The MLX producer waits on MainActor scheduling before continuing token generation. Closure also updates `@Published latestEvent` on MainActor. |
| **Impact** | ~100μs–several ms × N chunks; serializes GPU-side throughput behind UI thread load. |
| **Fix** | Yield chunks on a **background-safe transport** (e.g. `AsyncStream.Continuation` / lock-free queue from the detached task). Strip preview for snapshot on a separate MainActor consumer. Reserve `@MainActor eventSink` for `.completed` / errors only, or use `MainActor.assumeIsolated` only where already on main. |

---

### CRITICAL — Per-chunk PCM materialization chain (Float → Int16 → Data → struct)

| Field | Value |
|-------|-------|
| **File:line** | `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift:1071-1096`, `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift:490-504` |
| **Description** | Each `.audio` event: (1) `samples.asArray(Float.self)` GPU→CPU, (2) `convertLimited` returns a **copy** of internal `[Int16]`, (3) `pcm16LittleEndianData(from:)` allocates **`Data`**, (4) `StreamingAudioChunk` + `GenerationChunk` embed payload, (5) same `pcmSamples` copied again into WAV writer via `makePCMBuffer`. |
| **Impact** | ~2× chunk sample bytes in allocations per chunk (typical chunk ~0.5–2 s @ 24 kHz ≈ 24–96 KB Int16, plus Data overhead). Dominates non-MLX time in streaming bench traces. |
| **Fix** | Add `convertLimited(into:)` / return borrowed slice from scratch buffer without copy. Build preview `Data` with `Data(count:)` + `withUnsafeMutableBytes` from same storage, or pass file/chunk-path only when inline PCM disabled. Reuse one `[Int16]` for both preview and `finalWriter.append`. |

---

### CRITICAL — Repetition-penalty Set rebuild every token in Qwen hot loop

| Field | Value |
|-------|-------|
| **File:line** | `third_party_patches/mlx-audio-swift/Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift:2578`, `Qwen3TTS.swift:3511-3512` |
| **Description** | `sampleToken` receives growing `generatedCodebookTokens`. When `repetitionPenalty != 1.0` (default 1.05), each call does `Array(Set(tokens))` over all prior tokens before MLX ops. |
| **Impact** | O(n) Swift work × effectiveMaxTokens (hundreds–thousands); compounds with token-loop latency. |
| **Fix** | Maintain a `Set<Int>` alongside `generatedCodebookTokens` (incremental insert). Or pass penalty only when token count crosses a threshold; use MLX-side penalty for large histories. |

---

### HIGH — PCM16ScratchBuffer pool never wired at factory

| Field | Value |
|-------|-------|
| **File:line** | `Sources/QwenVoiceCore/MLXTTSEngine.swift:1374-1390`, `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift:746-753` |
| **Description** | Pooling API exists (`pcmScratchBuffer` parameter, `reset()` between leases) but `defaultStreamingSessionFactory` never passes a buffer — every generation allocates fresh scratch + limiter state. |
| **Impact** | ~1–2 MB high-water `[Int16]` capacity re-grown per generation; limiter re-init (minor). |
| **Fix** | Hold one `PCM16ScratchBuffer` on `MLXTTSEngine` (or runtime) and pass into `NativeStreamingSynthesisSession` factory; serialize with generation gate so only one lease at a time. |

---

### HIGH — `convertLimited` returns COW copy of scratch storage

| Field | Value |
|-------|-------|
| **File:line** | `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift:490-494` |
| **Description** | `return storage` copies the entire `[Int16]` on every chunk despite scratch buffer being a reusable class instance. |
| **Impact** | One full array copy per chunk on top of preview `Data` allocation. |
| **Fix** | `func convertLimited(_ samples: [Float], into output: inout [Int16]) -> Int` or expose `withLimitedPCM(_ body: (UnsafeBufferPointer<Int16>) -> Void)`. |

---

### HIGH — `activeSuppressTokens` array concatenation per token (pre-EOS window)

| Field | Value |
|-------|-------|
| **File:line** | `third_party_patches/mlx-audio-swift/Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift:2566` |
| **Description** | Until `allowsEOS`, every iteration allocates `suppressTokens + [eosTokenId]` (~1024 Ints + new buffer). |
| **Impact** | O(vocab slice) allocation × minimum-token window (~30+ iterations). |
| **Fix** | Precompute `suppressTokensWithEOS = suppressTokens + [eosTokenId]` once; select pointer/slice without allocating per iteration. |

---

### HIGH — Live playback: Task + MainActor hop per AVAudio buffer completion

| Field | Value |
|-------|-------|
| **File:line** | `Sources/SharedSupport/ViewModels/AudioPlayerViewModel.swift:991-996`, `1032` |
| **Description** | Each `scheduleLiveBuffer` installs a `@Sendable` completion that spawns `Task { @MainActor ... }`. Many chunks ⇒ many Tasks. `liveBufferDurations.removeFirst()` is O(n) per completion. |
| **Impact** | 2× atomic weak loads + Task creation × scheduled buffers; queue bookkeeping scales with chunk count. |
| **Fix** | Use a single serial MainActor handler or coalesce completions (increment atomic counter, drain on main in one Task). Replace `removeFirst()` with index head or circular buffer. |

---

### HIGH — `GenerationChunkBroker.publish` extra MainActor Task (XPC path)

| Field | Value |
|-------|-------|
| **File:line** | `Sources/QwenVoiceNative/GenerationChunkBroker.swift:16-19`, `Sources/QwenVoiceNative/XPCNativeEngineClient.swift:675` |
| **Description** | `nonisolated publish` wraps every event in `Task { @MainActor in shared.subject.send(event) }`. XPC client uses this for chunk delivery — duplicate scheduling vs in-process `AsyncStream`. |
| **Impact** | Extra hop + Combine fan-out per chunk when engine runs out-of-process. |
| **Fix** | Use `MainActor.assumeIsolated` when caller is already main, or a dedicated background `AsyncStream` consumed once on MainActor. Prefer direct `AsyncStream` from XPC decode thread with bounded buffer. |

---

### HIGH — First-codebook `sampleToken` builds MLX suppress array from Swift `[Int]` each step

| Field | Value |
|-------|-------|
| **File:line** | `third_party_patches/mlx-audio-swift/Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift:3504-3507` |
| **Description** | `MLXArray(suppress.map { Int32($0) })` allocates host + device buffers for ~1024 suppressed IDs on every first-codebook sample (every token). |
| **Impact** | Repeated large suppress tensor setup in inner loop. |
| **Fix** | Cache `MLXArray` suppress tensors for `(suppressTokens, eosIncluded)` keys at generation start; reuse in loop. |

---

### MEDIUM — `codeTokens = [nextToken]` reallocated every token step

| Field | Value |
|-------|-------|
| **File:line** | `third_party_patches/mlx-audio-swift/Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift:2593-2637` |
| **Description** | Fresh array + repeated `.append` for code groups each token (~15 groups). |
| **Impact** | Small but fixed allocations × token count. |
| **Fix** | Reuse `var codeTokens: [MLXArray]` with `removeAll(keepingCapacity: true)` and pre-reserve `numCodeGroups`. |

---

### MEDIUM — `PCM16StreamLimiter` scalar per-sample loop

| Field | Value |
|-------|-------|
| **File:line** | `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift:549-597` |
| **Description** | Sample-by-sample limiter with metrics updates; no vectorization. |
| **Impact** | CPU-linear in chunk samples; secondary to MLX but visible on large chunks. |
| **Fix** | vDSP/Accelerate for peak/gain passes where metrics allow batching; or process in SIMD blocks with merged metric sampling. |

---

### MEDIUM — Waveform merge allocates full concatenation

| Field | Value |
|-------|-------|
| **File:line** | `Sources/SharedSupport/ViewModels/AudioPlayerViewModel.swift:1501-1502` |
| **Description** | `let combined = existing + incoming` copies both arrays before downsampling. |
| **Impact** | Runs during streaming waveform updates; extra O(n) copy. |
| **Fix** | Downsample in one pass over both sources without materializing `combined`. |

---

### MEDIUM — `NativeEngineRuntime.prepareGeneration` diagnostic actor hops (cold path)

| Field | Value |
|-------|-------|
| **File:line** | `Sources/QwenVoiceCore/NativeEngineRuntime.swift:332-507` |
| **Description** | Multiple `await recordDiagnosticEvent(...)` during prep when diagnostic sink is set. |
| **Impact** | Adds latency to generation **start**, not per chunk; acceptable unless diagnostics always on. |
| **Fix** | Batch diagnostic records or fire-and-forget to nonisolated writer queue. |

---

### MEDIUM — Batch progress relay hops MainActor per item

| Field | Value |
|-------|-------|
| **File:line** | `Sources/QwenVoiceNative/TTSEngineStore.swift:5-16`, `91-103` |
| **Description** | `BatchProgressRelay.send` wraps each fraction update in `Task { @MainActor }`. |
| **Impact** | Minor for batch (sequential, low frequency); pattern matches chunk-hop smell. |
| **Fix** | `@MainActor` handler invoked directly when `generateBatch` already called from main, or use `AsyncStream` for progress. |

---

### MEDIUM — Non-streaming quality path still uses `samples.map` for PCM (`pcmSamples(from:)`)

| Field | Value |
|-------|-------|
| **File:line** | `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift:271-281`, `826` |
| **Description** | Quality-first final audio uses allocating `.map` instead of scratch limiter path. |
| **Impact** | One-shot full-buffer allocation; OK for batch/non-stream but inconsistent with streaming optimizations. |
| **Fix** | Route through `PCM16ScratchBuffer.convertLimited` for parity. |

---

### LOW — `@MainActor` on entire `MLXTTSEngine`

| Field | Value |
|-------|-------|
| **File:line** | `Sources/QwenVoiceCore/MLXTTSEngine.swift:44` |
| **Description** | Whole engine type is MainActor-isolated; couples UI snapshot updates with engine orchestration. |
| **Impact** | Architectural; mitigated by detached streaming task but event closure still pulls work to main. |
| **Fix** | Split transport/state (`EngineEventBus`) from `@Published` UI snapshot adapter. |

---

### LOW — `diagnosticDetailsString` sorted join on error paths

| Field | Value |
|-------|-------|
| **File:line** | `Sources/QwenVoiceCore/MLXTTSEngine.swift:1394-1401` |
| **Description** | Allocates sorted key strings for diagnostic labels. |
| **Impact** | Cold path only. |
| **Fix** | No action required unless profiling shows otherwise. |

---

### LOW — Vendor `[any KVCache]` witness-table indirection

| Field | Value |
|-------|-------|
| **File:line** | `third_party_patches/mlx-audio-swift/Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSTalker.swift:278-307`, `Qwen3TTSCodePredictor.swift:156-188` |
| **Description** | KV caches stored as existentials; layer loops dispatch through witness tables. |
| **Impact** | Inherent in current MLXAudio abstraction; small vs matmul cost. |
| **Fix** | Upstream generic specialization if MLXAudio exposes concrete cache type; not a local quick win. |

---

## Quick Wins

1. **Decouple chunk delivery from MainActor** — largest latency win for streaming throughput.
2. **Wire `PCM16ScratchBuffer` pool in `defaultStreamingSessionFactory`** — one-line factory change + engine-held instance.
3. **Stop returning `[Int16]` copy from `convertLimited`** — reuse scratch storage for preview + WAV append.

## Recommendations

1. **Immediate:** Fix MainActor-per-chunk sink; collapse PCM copy chain; cache Qwen suppress MLX tensors and precomputed EOS suppress list.
2. **Short-term:** Pool scratch buffer; incremental repetition-penalty set; live playback completion batching + O(1) queue.
3. **Long-term:** Split engine transport from UI snapshot; consider chunk-file-only preview on macOS when IPC copy cost exceeds decode cost.
4. **Verification:** Re-run `scripts/uitest.sh bench-step` on custom/design/clone cold cells; compare `ms_engine_start_to_autoplay`, `rtf`, and Time Profiler "Swift runtime" / allocation instruments on chunk boundaries.

## Cross-Auditor Notes

- MainActor chunk sink overlaps **swiftui-performance-analyzer** (playback) and **concurrency-auditor** (isolation).
- Live-buffer weak/Task pattern overlaps **memory-auditor** if completions retain unexpected state.
- `asyncEval` pipelining in Qwen3TTS (line ~2761) is an existing **good** optimization — preserve when fixing copies.

---

## Performance Health Score

| Metric | Value |
|--------|-------|
| Value type efficiency | 4 large structs in hot path; ~0% use `borrowing`/`consuming` on chunk PCM |
| ARC discipline | Live playback weak+Task per buffer; broker/XPC Task wrappers — partially appropriate |
| Generic specialization | Vendor `[any KVCache]` in token loop; app `any` mostly cold |
| Collection efficiency | Good reserveCapacity in Qwen token loop; missing pool wiring for scratch |
| Actor efficiency | Runtime actor OK per-request; **0% batched** chunk MainActor delivery |
| Hot path cleanliness | Token loop optimized; **chunk egress + PCM copies amplified** |
| **Health** | **BOTTLENECKED** |
