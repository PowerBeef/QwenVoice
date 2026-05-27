# Memory Leak Audit Results

**Scope:** `Sources/` (167 Swift files, excluding `*Tests.swift`, `*Previews.swift`, `docs/`, `website/`, `third_party_patches/`)  
**Focus:** QwenVoiceCore, TTSEngineStore (macOS + iOS), AudioPlayerViewModel live session, XPC/extension hosts, NativeEngineRuntime  
**Date:** 2026-05-26

## Summary Counts

| Severity | Count |
|----------|------:|
| CRITICAL | 0 |
| HIGH | 2 |
| MEDIUM | 7 |
| LOW | 4 |
| **Total** | **13** |

| Phase | Issues |
|-------|-------:|
| Phase 2 (pattern detection) | 5 |
| Phase 3 (completeness reasoning) | 5 |
| Phase 4 (compound findings) | 3 |

**Health:** NEEDS ATTENTION

---

## Resource Ownership Map

- **MLXTTSEngine / NativeEngineRuntime** — Process-long-lived engine core in XPC/extension hosts. Owns `idleUnloadTask`, `memoryPressureTask`, `stopCleanupTask`, `NativeMemoryPressureMonitor`, clone LRU caches (capacity-bounded), and `primedCloneReferenceKeys` (cleared on hard trim/unload). Cleanup via explicit `stop()` and trim paths; no class `deinit`.
- **EngineServiceHost / VocelloEngineExtensionHost** — Singleton hosts wrapping `RuntimeContext` (MLXTTSEngine + Combine sinks + `eventForwardingTask`). Generation cancellation via `ServiceActiveGenerationCoordinator` / extension equivalent; context replacement cancels prior `eventForwardingTask`.
- **XPCNativeEngineClient / ExtensionEngineCoordinator** — Actor coordinators owning reconnect/fire-and-forget tasks, pending XPC requests with timeout tasks, and batch progress handlers. Disconnect handlers cancel tasks and fail pending continuations.
- **TTSEngineStore (macOS)** — `@MainActor` app-lifetime store; one `AnyCancellable` snapshot subscription (`[weak self]`). Auto-cancelled on dealloc.
- **TTSEngineStore (iOS)** — App-lifetime store with memory guard polling (`activeGenerationMemoryGuardTask`), backend change subscription, and chunk forwarding via `NotificationCenter`. Guard task cancelled in generation `defer`, not in `stop()`.
- **AudioPlayerViewModel** — App-root `@StateObject`; owns repeating playback `Timer`, chunk observer/cancellable, live `AVAudioEngine` graph, bounded `completedLiveSessionIDs` (max 16). `deinit` clears timer/observer but not live audio graph.
- **Intentional singletons (not bugs):** `GenerationChunkBroker.shared`, `EngineServiceHost.shared`, `DatabaseService.shared`, `VocelloEngineHostManager.shared`.

---

## Memory Health Score

| Metric | Value |
|--------|-------|
| Resource ownership coverage | ~18 resource-owning engine/playback classes reviewed; 14 have explicit cleanup paths (~78%) |
| Timer lifecycle | 2 repeating timers, 2 invalidate paths in owning classes (match: yes) |
| Observer lifecycle | 3 observer sites in priority paths, 3 removal/cancellable paths (match: yes) |
| Task lifecycle | 28 stored `Task` properties in `Sources/`; 24 with explicit cancel/stop paths (~86%) |
| Combine subscriptions | 4 `.sink` calls in engine/playback path, 4 with cancellable storage (100%) |
| Unbounded collections | 2 potential accumulation points in engine core (see findings) |
| **Health** | **NEEDS ATTENTION** |

---

## Verification Counts

| Resource | Created | Cleaned up |
|----------|--------:|-----------:|
| Repeating timers | 2 | 2 (invalidate) |
| NotificationCenter observers (priority paths) | 3 | 3 |
| Stored Tasks (engine + playback focus) | 15 | 13 |
| Combine `.sink` (engine path) | 4 | 4 |

---

## Issues by Severity

### HIGH / HIGH — Unbounded macOS generation event stream

**File:** `Sources/QwenVoiceCore/MLXTTSEngine.swift:425-431`  
**Phase:** 3 (Completeness) + 4 (Compound)  
**Issue:** macOS builds use `AsyncStream(bufferingPolicy: .unbounded)` for `engine.events`, while iOS uses `.bufferingNewest(64)`. Streaming generations yield many `.chunk` events that can carry inline `previewAudio` PCM payloads. `EngineServiceHost` / `VocelloEngineExtensionHost` drain this stream in `eventForwardingTask`, but if forwarding falls behind (XPC backpressure, main-thread scheduling, host context swap), events accumulate without bound in the XPC engine process.  
**Impact:** Progressive RSS growth during long streaming sessions on macOS; elevated jetsam/OOM risk on 8 GB tier under sustained chunk throughput.  
**Fix:** Align macOS with iOS bounded policy, or drop/strip inline preview payloads before yielding into the stream on macOS when XPC forwarding is the consumer:

```swift
#if os(iOS)
self.events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { ... }
#else
self.events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { ... } // or .bufferingOldest(64)
#endif
```

**Cross-Auditor Notes:** Compounds with SwiftUI performance if large chunk payloads also reach UI publishers; pairs with `axiom-performance` streaming bench forensics.

---

### HIGH / HIGH — iOS memory guard task survives `stop()`

**File:** `Sources/iOS/TTSEngineStore.swift:131-134, 551-580`  
**Phase:** 3 (Completeness) + 4 (Compound)  
**Issue:** `startActiveGenerationMemoryGuard` launches a 1 Hz polling `Task` during generation, cancelled only via `stopActiveGenerationMemoryGuard` (generation `defer`) or guard restart. `stop()` forwards to `backend.stop()` but does not cancel `activeGenerationMemoryGuardTask`.  
**Impact:** If `stop()` is invoked while a generation is in flight (backgrounding, extension recycle, test teardown), the guard keeps sampling memory snapshots and can trigger critical trim/cancel against a backend that is already stopping — zombie async work and unnecessary memory/CPU churn.  
**Fix:**

```swift
func stop() {
    stopActiveGenerationMemoryGuard(reason: "store_stop")
    backend.stop()
    syncFromBackend()
}
```

**Cross-Auditor Notes:** Overlaps concurrency auditor (Task lifecycle); relevant to iOS extension host restarts.

---

### MEDIUM / MEDIUM — AudioPlayerViewModel `deinit` omits live audio teardown

**File:** `Sources/SharedSupport/ViewModels/AudioPlayerViewModel.swift:310-318, 1099-1159`  
**Phase:** 3 (Completeness)  
**Issue:** `deinit` invalidates the progress timer and removes chunk observers, but does not call `teardownLivePlayback(clearSession: true)` / `stopLivePlayback`. Live `AVAudioEngine`, `AVAudioPlayerNode`, and scheduled buffer completions can outlive intentional session cleanup if the view model is ever deallocated mid-stream.  
**Impact:** Low probability today (`@StateObject` at app root), but retains audio graph resources and completion callbacks until ARC drops nodes; violates symmetric lifecycle for live playback.  
**Fix:**

```swift
deinit {
    MainActor.assumeIsolated {
        teardownLivePlayback(clearSession: true)
        timer?.invalidate()
        if let chunkObserver {
            NotificationCenter.default.removeObserver(chunkObserver)
        }
        chunkCancellable?.cancel()
    }
}
```

---

### MEDIUM / MEDIUM — ExtensionBackedTTSEngine `stop()` uses untracked fire-and-forget invalidate

**File:** `Sources/QwenVoiceCore/ExtensionBackedTTSEngine.swift:100-105`  
**Phase:** 3 (Completeness)  
**Issue:** `stop()` sets lifecycle to `.idle` and spawns an unstructured `Task { await coordinator.invalidate() }` with no stored handle or cancellation. Rapid stop/start can overlap invalidation with new connection setup.  
**Impact:** Overlapping transport lifetimes, transient duplicate event sinks, and harder-to-reason memory/connection state during extension recovery.  
**Fix:** Store a `stopTask`, cancel it on `start()`/`initialize()`, and await prior invalidation before creating a new coordinator connection.

---

### MEDIUM / MEDIUM — Extension host command handler retains host strongly

**File:** `Sources/iOSEngineExtension/VocelloEngineExtensionHost.swift:147-165`  
**Phase:** 2 (Closure capture)  
**Issue:** `perform(_:withReply:)` uses `Task { @MainActor in ... }` without `[weak self]`. Under bursty XPC load, many in-flight command tasks retain the singleton host until completion.  
**Impact:** Extends lifetime of host + `runtimeContext` references during reconnect storms; minor but unnecessary retention on memory-constrained iPhone extension process.  
**Fix:** Match macOS host pattern:

```swift
Task { @MainActor [weak self, payload] in
    guard let self else { return }
    ...
}
```

(`EngineServiceHost.swift:161` already uses `[weak self]`.)

---

### MEDIUM / MEDIUM — `stopCleanupTask` chain lacks cancellation

**File:** `Sources/QwenVoiceCore/MLXTTSEngine.swift:465-477, 508-512`  
**Phase:** 3 (Completeness)  
**Issue:** `stop()` chains `stopCleanupTask` via `Task.detached` awaiting the previous task, but never cancels an in-flight cleanup when `stop()` is called again. `initialize()` awaits completion but rapid stop/stop/initialize can queue multiple detached cleanups touching the same `NativeEngineRuntime`.  
**Impact:** Overlapping `runtime.stop()` / cache clears; transient MLX memory spikes and race-prone warm-state during bench cycles or XPC service restarts.  
**Fix:** Cancel and await the previous `stopCleanupTask` before enqueueing a new one, or serialize stop/initialize through a single actor gate.

---

### MEDIUM / LOW — `primedCloneReferenceKeys` grows until hard trim

**File:** `Sources/QwenVoiceCore/NativeEngineRuntime.swift:145, 608, 1279`  
**Phase:** 3 (Unbounded accumulation)  
**Issue:** Clone prime tracking uses an unbounded `Set<String>` inserted on each successful prime; cleared only on `hardTrim` / `fullUnload` / explicit clone clear — not on soft trim or per-session idle unload.  
**Impact:** Slow metadata growth across many saved-voice prime cycles on macOS tiers that rarely hard-trim; small but lifetime-unbounded in long Debug sessions.  
**Fix:** Cap set size LRU-style, or clear entries when clone conditioning cache evicts matching keys.

---

### MEDIUM / LOW — Batch progress relay spawns uncoalesced MainActor tasks

**File:** `Sources/QwenVoiceNative/TTSEngineStore.swift:5-16, 97-103`  
**Phase:** 2 (Closure capture)  
**Issue:** `BatchProgressRelay.send` fires a new `Task { @MainActor in handler(...) }` per progress tick with no coalescing or `[weak]` relay lifetime control.  
**Impact:** Large batch runs can enqueue hundreds of short-lived tasks; usually benign on macOS but adds avoidable allocation churn during batch generation.  
**Fix:** Hop to MainActor once in the caller, or store a single relay task / use `@MainActor` handler directly from the XPC progress callback path.

---

### MEDIUM / LOW — NativeMemoryPressureMonitor `stop()` races dispatch teardown

**File:** `Sources/QwenVoiceCore/NativeMemoryPressureMonitor.swift:72-80`  
**Phase:** 3 (Partial cleanup)  
**Issue:** `stop()` finishes the `AsyncStream` continuation synchronously while `DispatchSource` cancellation runs asynchronously on a private queue. `MLXTTSEngine.stop()` immediately replaces the monitor instance after `stop()`.  
**Impact:** Brief window where old dispatch source callbacks may still fire on replaced monitor state during engine restart; low severity but inconsistent teardown ordering.  
**Fix:** Synchronously cancel source on the monitor queue (use `queue.sync` for stop path) before `continuation.finish()`.

---

### LOW / LOW — Extension candidate observer subscribers never unregister

**File:** `Sources/iOS/VocelloEngineExtensionPoint.swift:33, 69-80, 110-116`  
**Phase:** 3 (Observer lifecycle mismatch)  
**Issue:** `registerCandidateObserver` appends to `subscribers` dictionary without a matching remove API. Currently called once from static `shared` initialization.  
**Impact:** No production leak today; future duplicate registration would accumulate closures for the lifetime of the monitor provider.  
**Fix:** Return an observation token that removes the subscriber on deinit, or use `AsyncStream` broadcast.

---

### LOW / LOW — IOSReferenceClipRecorder lacks `deinit` timer cleanup

**File:** `Sources/iOS/Overlays/IOSRecordingOverlay.swift:343-350`  
**Phase:** 2 (Timer lifecycle)  
**Issue:** Repeating `meteringTimer` is invalidated on stop paths and delegate callback, but not in `deinit`.  
**Impact:** If the recorder `@StateObject` is destroyed unexpectedly while recording, timer may fire until run loop drops it.  
**Fix:** Add `deinit { meteringTimer?.invalidate() }` on `@MainActor` recorder class.

---

### LOW / LOW — macOS TTSEngineStore has no explicit teardown hook

**File:** `Sources/QwenVoiceNative/TTSEngineStore.swift:33-44`  
**Phase:** 3 (Completeness)  
**Issue:** Snapshot Combine subscription relies on `AnyCancellable` deinit only; no symmetric `stop()` API on the store despite engine lifecycle methods existing on the wrapped engine.  
**Impact:** Benign for app-lifetime ownership; complicates test harness teardown ordering if store/engine lifetimes diverge.  
**Fix:** Add `deinit` or explicit `invalidate()` that nils `snapshotCancellable` and documents store lifetime = engine lifetime.

---

### LOW / LOW — PhotoKit pattern not applicable

**File:** N/A  
**Phase:** 2 (Pattern 6)  
**Issue:** No `PHImageManager` usage under `Sources/`.  
**Impact:** None.  
**Fix:** None required.

---

## Compound Findings (Phase 4)

1. **Unbounded macOS `engine.events` + streaming PCM preview payloads + XPC `eventForwardingTask`** → highest engine-process memory growth risk during streaming autoplay bench cells. Severity: **HIGH**.
2. **iOS `activeGenerationMemoryGuardTask` + `TTSEngineStore.stop()` without guard cancel** → zombie polling that can invoke critical trim on a stopping backend. Severity: **HIGH**.
3. **AudioPlayerViewModel live graph + no `deinit` teardown + stale buffer completion guards** → low-frequency resource retention if ownership model changes away from app-root `@StateObject`. Severity: **MEDIUM**.

---

## Recommendations

### Immediate (HIGH)

1. Bound macOS `MLXTTSEngine.events` buffering (match iOS `.bufferingNewest(64)` or strip inline PCM before yield).
2. Cancel `activeGenerationMemoryGuardTask` in iOS `TTSEngineStore.stop()`.

### Short-term (MEDIUM)

3. Add live playback teardown to `AudioPlayerViewModel.deinit`.
4. Track and serialize `ExtensionBackedTTSEngine` / `MLXTTSEngine` stop/invalidate tasks.
5. Use `[weak self]` in `VocelloEngineExtensionHost.perform`.
6. Cap or pair-evict `primedCloneReferenceKeys` with clone cache LRU.

### Long-term

7. Introduce a shared `EngineLifecycleToken` pattern for all stored Tasks across XPC host, extension host, and app stores (single place to cancel on session end).
8. Add debug-only signpost counters for AsyncStream backlog depth and `modelOperationWaiters.count` to catch regressions during bench runs.

### Instruments verification

- **Allocations + Leaks** on macOS: run a streaming custom-voice cold/warm bench cell; watch XPC `QwenVoiceEngineService` process RSS while `eventForwardingTask` is active.
- **Memory Graph** on iOS device: start generation, call `TTSEngineStore.stop()` mid-flight, verify no surviving `activeGenerationMemoryGuardTask` frames.
- **PointsOfInterest** signposts already emitted by live playback (`Chunk Received`, `Stale Completion Dropped`) — correlate with Memory Graph retain paths for `AVAudioEngine`.

---

## False Positives Reviewed (Not Reported)

- Timer pairs in `AudioPlayerViewModel` and `IOSRecordingOverlay` — both use `[weak self]` and explicit invalidate.
- Combine sinks in engine hosts and stores — stored in `AnyCancellable` / `Set<AnyCancellable>` with `[weak self]`.
- `completedLiveSessionIDs` — bounded to 16 entries with FIFO eviction.
- Clone LRU caches in `NativeCloneSupport` — capacity enforced via policy resolver.
- `WindowChromeConfigurator` static observer maps — stale split views pruned with `removeObserver`.
- `NativeEngineRuntime.prewarmWaiters` — resumed via `releasePrewarmSlot()` / `finishModelOperation()`; cancellation path resumes waiters on operation completion.
- Strong captures in `EngineServiceHost` generation tasks — scoped to active generation with coordinator cancel hook.
