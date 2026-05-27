# Energy Audit — QwenVoice `Sources/` (2026-05-26)

**Scope:** `/Users/patricedery/Coding_Projects/QwenVoice/Sources/` — timers, polling, iOS model delivery + engine lifecycle, continuous animations.  
**Health:** **WASTEFUL** (no CRITICAL idle-drain patterns; several HIGH lifecycle/tolerance gaps on iOS audio + timers)

## Summary

| Severity | Count | Est. idle impact |
|----------|------:|------------------|
| CRITICAL | 0 | — |
| HIGH | 4 | ~2–8%/hr when triggers active |
| MEDIUM | 5 | ~1–5%/hr contextual |
| LOW | 2 | &lt;2%/hr |

**Top actions:** Deactivate `AVAudioSession` when playback/recording ends; add timer tolerance; avoid `setActive(true)` at cold launch; consider `isDiscretionary = true` for background model downloads on cellular unless user is waiting.

**Positives:** No `UIBackgroundModes` / `BGTaskScheduler` / location polling; `scenePhase` background runtime release; model-delivery background completion gated on idle tasks; `CADisplayLink` capped ~30fps with `onDisappear` cleanup; generating `TimelineView` unmounts when leaving Studio tab.

---

## Energy Profile Map

- **Background modes:** None in `Sources/iOS/Info.plist`. Model downloads use `URLSessionConfiguration.background` + `UIApplicationDelegate.handleEventsForBackgroundURLSession` (`IOSModelDeliveryBackgroundEvents.swift`) — appropriate, not timer-polling.
- **Timers:** 2 `Timer.scheduledTimer` sites (recording meter @12.5 Hz, shared `AudioPlayerViewModel` @10 Hz); **0** set `.tolerance`.
- **Display links:** 2 `CADisplayLink` controllers (inline player, player sheet) — 20–60 fps range, preferred 30, invalidated on pause/stop/disappear.
- **Polling:** `TTSEngineStore` 1 Hz `Task.sleep` loop **only** during active generation (memory guard). `NativeTelemetrySampler` 4 Hz only when `QWENVOICE_NATIVE_TELEMETRY_MODE=lightweight` (default off).
- **Location:** None.
- **Network:** User-driven generation + background URLSession for model installs; `waitsForConnectivity = true`; background downloads **non-discretionary**.
- **Engine lifecycle:** `scenePhase` → `releaseRuntime` on background; deferred release when generation active; memory-pressure coordinator defers trim while generating.

---

## Energy Health Score

| Metric | Value |
|--------|-------|
| Timer discipline | 2 timers, **0** with tolerance (**0%**), both repeat while feature active |
| Location lifecycle | N/A |
| Network efficiency | Background model session configured; **non-discretionary**; completion handler completed when idle |
| Animation lifecycle | 2 display links with stop paths; 1 `TimelineView(.animation)` during generating UI only |
| Background modes | 0 plist entries; background URLSession matches delivery code |
| Est. idle drain above baseline | **~2–4%/hr** (chiefly always-active audio session at launch) |
| **Health** | **WASTEFUL** |

---

## Verification Counts

| Category | Created | Tolerance | Stopped on inactive |
|----------|--------:|----------:|---------------------|
| Timers | 2 | 0 | Yes (invalidate / generation end) |
| CADisplayLink | 2 | N/A (30fps preferred) | Yes |
| Location start/stop | 0 / 0 | — | — |
| Background URLSession | 1 | `isDiscretionary=false` | `completeIfPending` when idle |

---

## Issues

### HIGH — Audio session active at app launch

**File:** `Sources/iOS/QVoiceiOSApp.swift:336-340`  
**Phase:** 3 (unnecessary work)  
**Issue:** `configureAudioSession()` in `init()` calls `setActive(true)` before any playback, keeping the audio path awake for the whole session.  
**Impact:** ~2–5%/hr idle penalty; blocks system audio sleep optimizations.  
**Fix:** Set category only at launch; call `setActive(true)` immediately before first play/record and `setActive(false, options: .notifyOthersOnDeactivation)` when all players/recorders are idle.

```swift
// Launch: category only
try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
// Before play:
try session.setActive(true)
// After last player stops:
try session.setActive(false, options: .notifyOthersOnDeactivation)
```

**Cross-auditor:** memory-auditor (long-lived session holding audio graph state)

---

### HIGH — Recording meter timer without tolerance (12.5 Hz)

**File:** `Sources/iOS/Overlays/IOSRecordingOverlay.swift:343-350`  
**Phase:** 2 (timer abuse)  
**Issue:** `Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true)` during clip capture; no `.tolerance`; hops to `MainActor` every tick.  
**Impact:** ~5–10%/hr while overlay open and recording; CPU wake every 80 ms.  
**Fix:**

```swift
let timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { ... }
timer.tolerance = 0.008 // ≥10%
RunLoop.main.add(timer, forMode: .common)
meteringTimer = timer
```

Invalidate remains correct in `stopAndSave` / `stopWithoutSaving` / delegate (lines 316–384).

---

### HIGH — Shared playback timer without tolerance (10 Hz, iOS + macOS)

**File:** `Sources/SharedSupport/ViewModels/AudioPlayerViewModel.swift:1428-1434`  
**Phase:** 2 (timer abuse)  
**Issue:** 100 ms repeating timer for file/live progress; no tolerance. Used on iOS via `QVoiceiOSApp` `@StateObject` and legacy generation/history flows.  
**Impact:** ~3–8%/hr while any `AudioPlayerViewModel` playback is active.  
**Fix:** Set `timer.tolerance = 0.01` (or switch file mode to display-link / `AVAudioPlayer` delegate only).

---

### HIGH — Compound: audio session activated but not deactivated (preview + inline)

**Files:**
- `Sources/iOS/Sheets/IOSVoicePreviewPlayer.swift:56-58, 74-78`
- `Sources/iOS/Studio/IOSStudioInlinePlayerCard.swift:220-222, 260-264`

**Phase:** 4 (compound with launch `setActive(true)`)  
**Issue:** Preview and inline controllers call `setActive(true)` on play/load; `stop()` does not call `setActive(false)`. Player sheet **does** deactivate (`IOSPlayerSheet.swift:595`).  
**Impact:** Session can remain active after brief previews or inline playback (~2–5%/hr until app killed).  
**Fix:** Mirror player sheet: `try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)` in `stop()` / `IOSVoicePreviewPlayer.stop()` when no other audio is playing.

**Cross-auditor:** memory-auditor

---

### MEDIUM — Background model downloads non-discretionary

**File:** `Sources/iOS/IOSModelDeliveryActor.swift:281-286`  
**Phase:** 2 (network) / 3 (user left app mid-download)  
**Issue:** `isDiscretionary = false` and `allowsExpensiveNetworkAccess = true` on background `URLSession` — system may run large HF downloads immediately on cellular when app is backgrounded.  
**Impact:** ~5–15% extra drain on cellular during multi-GB installs (radio high power).  
**Fix:** If UX allows deferral: `backgroundConfig.isDiscretionary = true` when not on Wi‑Fi and user did not foreground-wait; or gate expensive access unless `ProcessInfo.processInfo.isLowPowerModeEnabled == false` and on Wi‑Fi.

---

### MEDIUM — Active-generation memory guard polls every 1 s

**File:** `Sources/iOS/TTSEngineStore.swift:551-574`  
**Phase:** 3 (bounded polling)  
**Issue:** While `hasActiveGeneration`, loop sleeps 1 s and calls `refreshMemoryContext` — not push-driven.  
**Impact:** ~1–3%/hr **only during generation** (acceptable for safety; not idle).  
**Fix:** Optional: tie sampling to extension memory-pressure `AsyncStream` events instead of fixed 1 Hz; keep 1 Hz if simplicity preferred.

---

### MEDIUM — Inline player leaves audio session active after stop

**File:** `Sources/iOS/Studio/IOSStudioInlinePlayerCard.swift:260-264`  
**Phase:** 3  
**Issue:** `stop()` stops player and display link but never deactivates session (contrast `IOSPlayerSheetController.stop()`).  
**Impact:** ~1–3%/hr after inline playback until another subsystem deactivates.  
**Fix:** Same `setActive(false)` as player sheet when stopping.

---

### MEDIUM — Voice preview player leaves session active

**File:** `Sources/iOS/Sheets/IOSVoicePreviewPlayer.swift:74-78`  
**Phase:** 3  
**Issue:** `stop()` clears player only; session stays active after ~2.5 s previews.  
**Impact:** ~1–2%/hr after picker previews.  
**Fix:** Deactivate session in `stop()` and `audioPlayerDidFinishPlaying`.

---

### MEDIUM — Generating waveform uses continuous `TimelineView`

**File:** `Sources/iOS/IOSStudioCanvas.swift:297-303` → `Sources/iOS/IOSDesignSystemPrimitives.swift:210-213`  
**Phase:** 3 (feature-tied)  
**Issue:** `IOSWaveformBars(isAnimating: true)` drives `TimelineView(.animation)` at display refresh while generating bar is visible.  
**Impact:** ~3–8%/hr **only on Studio tab during generation**; stops when user switches tab (Studio unmounts in `RootView.activeScreen`).  
**Fix:** If generation can run long in background of Studio: gate animation with `scenePhase == .active` or replace with lower-rate phase step (e.g. 15 fps explicit).

---

### LOW — Telemetry sampler 4 Hz when enabled

**File:** `Sources/QwenVoiceCore/NativeTelemetrySampler.swift:106-114`  
**Phase:** 2 (periodic work)  
**Issue:** Lightweight telemetry samples memory every 250 ms during synthesis when env enables it.  
**Impact:** &lt;2%/hr during generation only; default **off** (`SemanticTypes.swift:836-837`).  
**Fix:** No change unless enabling telemetry on shipping builds.

---

### LOW — Engine lifecycle toast sleep task

**File:** `Sources/iOS/IOSEngineLifecycleToast.swift:66-72`  
**Phase:** 3  
**Issue:** 4 s one-shot `Task.sleep` per lifecycle state change.  
**Impact:** Negligible (not repeating).  
**Fix:** None required.

---

## Recommendations

1. **Immediate:** Remove launch-time `setActive(true)`; add session deactivation to inline + voice-preview players; add timer tolerance on recording + `AudioPlayerViewModel`.
2. **Short-term:** Review `isDiscretionary` / expensive-network policy for background model delivery; gate generating `TimelineView` on `scenePhase == .active`.
3. **Long-term:** Consider display-link or delegate-driven progress for shared `AudioPlayerViewModel` on iOS to retire 10 Hz timer on mobile.
4. **Verification:** Instruments → Energy Log after fixes; on device, install a model, background app, confirm radio quiescence; record clip and confirm meter timer stops.

---

## False positives ruled out

- `CADisplayLink` in player controllers: stopped on pause/stop/`onDisappear`; frame rate capped.
- Simulator fake install `Task.sleep` loops: `#if`/simulator-gated only.
- `NativeMemoryPressureMonitor`: event-driven `DispatchSource`, not polling.
- Background URLSession completion: `completeBackgroundEventsIfIdle()` waits for `activeInstall == nil` and empty task list (`IOSModelDeliveryActor.swift:842-849`).
- No continuous location, no `BGTaskScheduler`, no network poll intervals in codebase.
