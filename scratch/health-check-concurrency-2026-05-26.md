# Swift Concurrency Audit — QwenVoice (2026-05-26)

## Summary Counts

| Severity | Count |
|----------|------:|
| **CRITICAL** | 1 |
| **HIGH** | 5 |
| **MEDIUM** | 8 |
| **LOW** | 6 |
| Phase 2 (pattern detection) | 14 |
| Phase 3 (completeness) | 4 |
| Phase 4 (compound) | 2 |

**Focus:** `Sources/QwenVoiceCore`, XPC/extension IPC, engine hosts, streaming `Task.detached`.

**Readiness:** **NEEDS WORK** — engine-core serialization (prewarm gate, model-operation lease) is solid, but IPC coordinators and generation-host defer patterns have correctness gaps that will worsen under Swift 6 `-strict-concurrency=complete`.

---

## Isolation Architecture Map

- **Default strategy:** Per-type isolation. UI/view-models are `@MainActor` + `@Observable`; engine surface is `@MainActor` (`MLXTTSEngine`, `ExtensionBackedTTSEngine`); heavy MLX work lives in `actor NativeEngineRuntime` + `actor MLXModelLoadCoordinator`.
- **Actor boundaries:** `NativeEngineRuntime` (generation/prewarm/load), `ExtensionEngineCoordinator` / `XPCNativeEngineCoordinator` (IPC command serialization), `ServiceActiveGenerationCoordinator` / `ExtensionActiveGenerationCoordinator` (single-flight generation), `NativePreparedCloneConditioningCache`, telemetry/load actors.
- **IPC pattern:** `@Sendable` command envelopes → actor coordinator → `@unchecked Sendable` NSXPC/AppExtension transports → `@MainActor` host `RuntimeContext` wrapping `MLXTTSEngine`.
- **Concurrency entry points:** Mostly unstructured `Task { }` / `Task.detached` (streaming synthesis, waveform extraction, XPC reply handlers). Structured concurrency is rare (`withTaskGroup` only in audio prep queue pattern).
- **Cancellation:** Strong in streaming path (`withTaskCancellationHandler` + explicit `Task.checkCancellation` in `for await`). Weaker in XPC `perform` (no cancellation handler) and engine-host generation `defer` (fire-and-forget finish).
- **Escape hatches:** ~25 `@unchecked Sendable` in engine/IPC layer; `@preconcurrency import MLX*`; 2 `nonisolated(unsafe)` singletons (`DatabaseService.shared`, macOS `Generation.dateFormatter`).

---

## Concurrency Health Score

| Metric | Value |
|--------|-------|
| Isolation coverage | ~85% of UI/engine-facing types have explicit `@MainActor` or `actor` |
| Structured concurrency | ~5% of parallel work (mostly unstructured `Task` / `Task.detached`) |
| Escape hatches | 25 `@unchecked Sendable`, 8 `@preconcurrency import`, 2 `nonisolated(unsafe)` |
| Cancellation coverage | ~60% of stored Tasks have explicit cancel paths; XPC pending requests weak |
| GCD legacy | 10 `DispatchQueue` call sites (memory monitor + UI bridges) |
| **Readiness** | **NEEDS WORK** |

---

## Strengths (Engine Core — Verified OK)

| Area | Verdict |
|------|---------|
| **Prewarm slot gate** (`NativeEngineRuntime.acquirePrewarmSlot` / `releasePrewarmSlot`) | Correct monitor-style serialization across actor reentrancy; used by `ensureWarmStateIfNeeded` and `ensureDesignConditioningWarmStateIfNeeded`. |
| **Model-operation lease** (`MLXTTSEngine.beginUserModelOperation` / `finishModelOperation`) | Serializes generation, batch, load/unload, proactive warm, clone priming; proactive ops skip when lease occupied. |
| **Streaming detached work** (`NativeStreamingSynthesisSession`) | `Task.detached` + `withTaskCancellationHandler` + `Task.checkCancellation` in `for await`; `eventSink` is `@MainActor @Sendable` and awaited per chunk. |
| **Chunk transport fix** | Ordered `AsyncStream` drain in hosts replaces race-prone `objectWillChange` slot sampling. |
| **Connection staleness** | `ExtensionEngineCoordinator` / XPC coordinator ignore replies/events from superseded connection IDs. |
| **UI ObservableObject** | All 22 `ObservableObject` types in `Sources/` carry `@MainActor`. |

---

## Issues by Severity

### CRITICAL/HIGH — IPC: XPC `perform` missing cancellation cleanup

**File:** `Sources/QwenVoiceNative/XPCNativeEngineClient.swift:397-422`  
**Phase:** 3 (Completeness) + 4 (Compound with missing error handling at scale)

**Issue:** `XPCNativeEngineCoordinator.perform` wraps `withCheckedThrowingContinuation` but **does not** use `withTaskCancellationHandler`. When the caller's task is cancelled, the pending entry stays in `pendingRequests` until timeout (if any) or disconnect. Extension path (`ExtensionEngineCoordinator.perform:286-319`) **does** forward cancellation.

**Impact:** Cancelled macOS generations can leave hung continuations, stale pending-request entries, and blocked subsequent commands on the same connection.

**Fix:**

```swift
return try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
        // ... existing pending request setup ...
    }
} onCancel: {
    Task { await self.cancelPendingRequest(id: requestEnvelope.id, command: command) }
}
```

Add `cancelPendingRequest` mirroring `ExtensionEngineCoordinator.cancelPendingRequest`.

**Cross-Auditor Notes:** Overlaps memory auditor (zombie pending state).

---

### HIGH/HIGH — Engine hosts: fire-and-forget generation `finish` in `defer`

**File:** `Sources/QwenVoiceEngineService/EngineServiceHost.swift:262-266,296-300`  
**File:** `Sources/iOSEngineExtension/VocelloEngineExtensionHost.swift:253-257`  
**Phase:** 2 (Stored Task lifecycle) + 4 (Compound with missing cancellation cleanup)

**Issue:** After `generationTask.value` returns, `defer { Task { await activeGenerationCoordinator.finish(id:) } }` clears the single-flight slot **asynchronously**. A fast follow-up `.generate` XPC command can arrive before `finish` runs and hit `register` → "already generating".

**Impact:** Spurious generation rejection under rapid back-to-back submits; brief window where `cancelActiveGeneration` targets a completed generation.

**Fix:** Await finish before returning the reply:

```swift
defer { /* remove fire-and-forget Task */ }
let result = try await generationTask.value
await activeGenerationCoordinator.finish(id: generationID)
return .generationResult(result)
```

Or use synchronous `finish` inside the actor before resuming the XPC reply.

---

### HIGH/HIGH — IPC coordinators: timeout handler may touch actor state without `await`

**File:** `Sources/QwenVoiceNative/XPCNativeEngineClient.swift:405-411`  
**File:** `Sources/QwenVoiceCore/ExtensionEngineCoordinator.swift:300-307`  
**Phase:** 2 (Actor isolation)

**Issue:** Timeout tasks call `self.handleTimeout(for:)` synchronously after `await Task.sleep`. Once the sleep suspends, the unstructured `Task` may resume off the actor executor; mutating `pendingRequests` without `await` is a Swift 6 strict-concurrency violation and potential data race with concurrent `handleReplyData`.

**Impact:** Rare duplicate resume / stale pending-map corruption under timeout+reply race; compiler warnings/errors at `-strict-concurrency=complete`.

**Fix:**

```swift
await self.handleTimeout(for: requestID)
```

---

### HIGH/MEDIUM — `NativeMemoryPressureMonitor.currentLevel` read off-queue

**File:** `Sources/QwenVoiceCore/NativeMemoryPressureMonitor.swift:26,99-101`  
**File:** `Sources/QwenVoiceCore/MLXTTSEngine.swift:188-195` (`adaptiveIdleUnloadDelay`)  
**Phase:** 2 (Thread confinement) + 4 (GCD + actor for same state)

**Issue:** `currentLevel` is mutated on a private `DispatchQueue` but read synchronously from `@MainActor` `MLXTTSEngine` when scheduling idle unload. Comments acknowledge eventual consistency, but there is no memory barrier.

**Impact:** Idle-unload may use a stale pressure band (keep model loaded too long or unload too aggressively). Not a crash, but works against memory policy intent on floor8GBMac.

**Fix:** Expose pressure via `AsyncStream`/`actor` wrapper, or read through `await monitor.currentLevel()` that hops to the monitor queue.

---

### HIGH/MEDIUM — `MLXTTSEngine.stop()` detached cleanup not awaited

**File:** `Sources/QwenVoiceCore/MLXTTSEngine.swift:465-477,508-512`  
**Phase:** 3 (Missing lifecycle cleanup)

**Issue:** `stop()` assigns `stopCleanupTask = Task.detached { await runtime.stop() }` and immediately clears engine state. `initialize()` awaits prior cleanup, but `stop()` itself does not — concurrent `initialize`/`stop` from host session churn can overlap runtime teardown with new setup.

**Impact:** XPC session replacement during tests or reconnect can race runtime unload vs load in the engine service process.

**Fix:** Store cleanup task but expose `async stop()` that awaits it, or await inside `stop()` when called from `@MainActor` host shutdown paths.

---

### HIGH/LOW — `EngineServiceHost` / `VocelloEngineExtensionHost` mixed isolation

**File:** `Sources/QwenVoiceEngineService/EngineServiceHost.swift:71,115-118,417-421`  
**File:** `Sources/iOSEngineExtension/VocelloEngineExtensionHost.swift:68,103-106`  
**Phase:** 3 (Incoherent concurrency strategy)

**Issue:** Host types are `@unchecked Sendable` `NSObject`s using `NSLock` for session tracking while `runtimeContext` is `@MainActor`. XPC entrypoints hop with `Task { @MainActor }`, but session lock + MainActor ordering relies on careful manual sequencing (documented May 2026 session-replacement fix).

**Impact:** Future edits to session lifecycle can reintroduce stale-context cleanup races (historically caused `notInitialized` in tests).

**Fix:** Long-term: isolate session table in an actor; short-term: keep capture-and-identity-check pattern and add comments at every new session mutation site.

---

### MEDIUM/MEDIUM — `@unchecked Sendable` MLX model wrapper (single-owner contract)

**File:** `Sources/QwenVoiceCore/UnsafeSpeechGenerationModel.swift:55-74`  
**Phase:** 2 (Sendable violations) + 3 (Escape hatch)

**Issue:** MLX model instances cross actor boundaries via `@unchecked Sendable`. Safety depends on **model-operation lease** ensuring one mutating operation at a time. Documented, but not compiler-enforced.

**Impact:** A future code path that shares `UnsafeSpeechGenerationModel` across concurrent `Task.detached` streams would data-race inside MLX.

**Fix:** Keep lease gate mandatory; consider wrapping model access in `actor UnsafeSpeechGenerationModelGate` for compile-time enforcement.

---

### MEDIUM/MEDIUM — `PCM16ScratchBuffer` / `NativeStreamingSynthesisSession` `@unchecked Sendable`

**File:** `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift:35,480-516`  
**Phase:** 2 (Sendable) + 3 (Completeness)

**Issue:** Mutable scratch buffer marked `@unchecked Sendable`; safety assumes one detached execution owns it per generation. Correct today because `MLXTTSEngine` model-operation lease blocks concurrent generations.

**Impact:** Pooling/reuse across concurrent sessions would race limiter state.

**Fix:** If pooling is added, guard with actor or serial queue; call `reset()` at lease boundaries (already documented).

---

### MEDIUM/MEDIUM — iOS `AsyncStream` bounded buffer may drop chunk events

**File:** `Sources/QwenVoiceCore/MLXTTSEngine.swift:424-427`  
**Phase:** 3 (Async sequence lifecycle)

**Issue:** iOS uses `.bufferingNewest(64)` for `events`; macOS uses `.unbounded`. Under slow IPC consumer, oldest chunk events can be dropped before the host forwarding task drains them.

**Impact:** Missing preview chunks on physical iPhone under backpressure (final file playback may still succeed).

**Fix:** Align with macOS unbounded policy for chunk transport, or apply backpressure at producer (`yield` suspension) instead of dropping.

---

### MEDIUM/MEDIUM — CPU-heavy detached work without `@concurrent` (Swift 6.2+)

**File:** `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift:114-115,151-152`  
**File:** `Sources/SharedSupport/ViewModels/AudioPlayerViewModel.swift:1484-1485`  
**Phase:** 2 (Missing `@concurrent`)

**Issue:** MLX streaming loop and waveform extraction run in `Task.detached` without `@concurrent`. Acceptable today (intentionally off MainActor), but cooperative pool may starve under load on Swift 6.2 default executor model.

**Fix:** Mark heavy inner functions `@concurrent` when targeting Swift 6.2+, or keep detached with documented rationale.

---

### MEDIUM/LOW — `NativeMemoryPressureMonitor` GCD + `AsyncStream` bridge

**File:** `Sources/QwenVoiceCore/NativeMemoryPressureMonitor.swift:21-104`  
**Phase:** 3 (Legacy bridge)

**Issue:** Deliberate GCD `DispatchSource` + `@unchecked Sendable` class feeding `AsyncStream`. Coexists with `@MainActor` consumer task in `MLXTTSEngine.startMemoryPressureMonitorIfNeeded`.

**Impact:** Low if reads go through stream only; current direct `currentLevel` read is the weak point (see HIGH above).

**Fix:** Make `currentLevel` private; expose async snapshot API.

---

### MEDIUM/LOW — `XPCNativeEngineClient` `@unchecked Sendable` facade

**File:** `Sources/QwenVoiceNative/XPCNativeEngineClient.swift:669-671`  
**Phase:** 2 (Sendable)

**Issue:** Client conforms to `MacTTSEngine` as `@unchecked Sendable`; all mutating state lives in `XPCNativeEngineCoordinator` actor — pattern is sound but relies on discipline.

**Fix:** Remove `@unchecked Sendable` from client if protocol allows; keep on transport boxes only.

---

### MEDIUM/LOW — `prewarm` cancellation uses unstructured `Task` from handler

**File:** `Sources/QwenVoiceCore/NativeEngineRuntime.swift:887-888`  
**Phase:** 2 (Unsafe Task pattern)

**Issue:** `onCancel: { Task { await self.cancelPrewarmWaiter(id:) } }` — fine functionally, but unstructured; under load, many cancelled waiters spawn tasks.

**Fix:** `await cancelPrewarmWaiter` directly if cancellation handler becomes async in future Swift; or batch cancellations.

---

### LOW/LOW — Documented escape hatches (acceptable with contracts)

| File | Note |
|------|------|
| `UnsafeSpeechGenerationModel.swift` | Single-owner MLX wrapper — keep lease gate |
| `NativeCloneSupport.swift:14` | `ResolvedCloneConditioning` — MLX arrays, immutable after resolve |
| `DatabaseService.swift:14-18` | GRDB queue + `@unchecked Sendable` — documented |
| `ExtensionEngineTransport.swift`, XPC transport boxes | IPC callback boxes — required for NSXPC |
| `HuggingFaceDownloader.swift` | URLSession delegate pattern |

---

## Phase 4 Compound Findings

1. **XPC missing cancellation handler + timeout without actor `await`** → hung `.generate` / stale pending map (**CRITICAL** compound).
2. **Fire-and-forget generation `finish` + single-flight coordinator** → spurious "already generating" under rapid IPC (**HIGH** compound).

---

## Recommendations

### Immediate (CRITICAL / HIGH)

1. Add `withTaskCancellationHandler` + `cancelPendingRequest` to `XPCNativeEngineCoordinator.perform` (parity with extension coordinator).
2. Await `activeGenerationCoordinator.finish` in both engine hosts before returning generation replies.
3. Change IPC timeout handlers to `await self.handleTimeout(...)`.
4. Stop reading `NativeMemoryPressureMonitor.currentLevel` directly from MainActor; use stream or actor snapshot.

### Short-term

5. Await `stopCleanupTask` in engine shutdown paths before accepting new sessions.
6. Revisit iOS `.bufferingNewest(64)` on chunk `AsyncStream`.
7. Enable `-strict-concurrency=complete` on `QwenVoiceCore` + `QwenVoiceNative` targets in Debug to surface remaining Sendable/isolation warnings.

### Long-term

8. Consider `actor` wrapper around MLX model access instead of `@unchecked Sendable` + manual lease.
9. Migrate session tables in engine hosts from `NSLock` + `@unchecked Sendable` to a dedicated actor.
10. Adopt `@concurrent` for MLX streaming / waveform CPU paths when upgrading to Swift 6.2 toolchain defaults.

---

## Files Reviewed (Engine Emphasis)

- `Sources/QwenVoiceCore/NativeEngineRuntime.swift`
- `Sources/QwenVoiceCore/MLXTTSEngine.swift`
- `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift`
- `Sources/QwenVoiceCore/UnsafeSpeechGenerationModel.swift`
- `Sources/QwenVoiceCore/ExtensionEngineCoordinator.swift`
- `Sources/QwenVoiceCore/ExtensionBackedTTSEngine.swift`
- `Sources/QwenVoiceCore/NativeMemoryPressureMonitor.swift`
- `Sources/QwenVoiceNative/XPCNativeEngineClient.swift`
- `Sources/QwenVoiceEngineService/EngineServiceHost.swift`
- `Sources/iOSEngineExtension/VocelloEngineExtensionHost.swift`

---

*Generated by concurrency-auditor subagent — 2026-05-26*
