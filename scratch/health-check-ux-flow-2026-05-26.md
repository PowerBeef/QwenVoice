# UX Flow Audit — Vocello iOS (2026-05-26)

**Scope:** `Sources/` with focus on generation cancel, `hasActiveGeneration` cross-mode controls, sheet dismiss traps, History/Voices/Settings empty states, and onboarding dead ends. Primary surface: iOS (`Sources/iOS/`); macOS generation views referenced for parity.

## Executive summary

| Metric | Value |
|--------|-------|
| **CRITICAL** | 2 |
| **HIGH** | 7 |
| **MEDIUM** | 5 |
| **LOW** | 2 |
| **Health** | **BROKEN JOURNEYS** |

Cancel works when the user stays on the originating Studio mode. Leaving Studio (tab switch) or switching Custom / Design / Clone mid-run removes the Cancel control while the engine keeps generating — users can get stuck until the run finishes or they find the original mode again. Cross-mode guards block a second Generate but do not lock the mode rail, setup chips, or tab dock.

Empty states are strongest in History (empty, filtered-empty, error + Retry). Voices and Settings have gaps: misleading “Pull to retry” copy, no saved-voices empty card on the main Voices tab, and a “Save a new voice” CTA that opens Studio without switching to Clone. Onboarding is escapable via the bottom CTA chain, but the Skip control is dead code and post-onboarding install guidance (`IOSFirstRunOnboardingCard`) is never wired.

**Top fixes:** (1) Global in-flight generation chrome with Cancel on every tab, or disable tab/mode switching while `hasActiveGeneration`; (2) drive `studioGenState` from `isGenerationActive`, not coordinator-only; (3) wire Skip + first-run install card; (4) fix Voices save CTA routing and History retry copy.

---

## Journey architecture map

1. **Entry:** `QVoiceiOSApp` → `RootView` + `@Environment(AppModel)`. No deep links, widgets, or notification handlers in iOS sources.
2. **Navigation:** Custom `TabDock` on `AppModel.tab` (Studio / Voices / History / Settings). Each tab is a `NavigationStack` shell with hidden bar.
3. **Studio:** `StudioScreen` → `IOSGenerateContainerView` with `IOSGenerationModeSelector` + `IOSGenerateModeViewport` (only one mode view mounted at a time).
4. **Generation lifecycle:** Per-mode `StudioGenerationCoordinator` on `AppModel` + shared `TTSEngineStore.hasActiveGeneration`. Cancel calls `generationTask?.cancel()` + `ttsEngine.cancelActiveGeneration()` in each mode view.
5. **Modals:** Root `fullScreenCover` onboarding; `sheet(item:)` player; edge-to-edge `bottomPanelItem` / `deleteModelSheetItem` overlays. Per-mode sheets: save voice, batch, recording overlay.
6. **Critical flows audited:** Generate → Cancel; cross-mode/tab during generation; first-run onboarding → Studio without models; History browse; Voices pick / save; Settings model install.

---

## UX journey health score

| Metric | Value |
|--------|-------|
| Critical flow coverage | 5 flows identified, 3 complete start-to-finish (60%) — cancel breaks on navigation |
| State handling | ~8 data-dependent views, ~5 with loading/empty/error (63%) |
| Modal safety | ~10 modal presentations, ~9 with clear dismiss (90%) |
| Entry point validation | 0 external entries implemented |
| Accessibility reach | Gesture-only traps not found; generation cancel unreachable after tab/mode switch |
| **Health** | **BROKEN JOURNEYS** |

---

## Issues (severity · file:line · description · fix)

### CRITICAL

**Cross-mode switch traps in-flight generation (cancel lost)**  
**File:** `Sources/iOS/IOSGenerateFlowViews.swift:127-131`, `Sources/iOS/IOSGenerationSharedViews.swift:22-31`  
**Issue:** `IOSGenerateModeViewport` mounts only the selected mode. Switching Custom → Design while generating unmounts the active view and its Cancel button; `coordinator.isGenerating` and `hasActiveGeneration` stay true.  
**Fix:** Disable `IOSGenerationModeSelector` when `ttsEngine.hasActiveGeneration` (or any coordinator `isGenerating`), **or** hoist generating UI + Cancel to `IOSGenerateContainerView` / `RootView` so it persists across mode changes:

```swift
// IOSGenerateContainerView — pass engine into selector
IOSGenerationModeSelector(
    selectedSection: $selectedSection,
    isLocked: ttsEngine.hasActiveGeneration
        || appModel.customCoordinator.isGenerating
        || appModel.designCoordinator.isGenerating
        || appModel.cloneCoordinator.isGenerating
)
```

---

**Tab switch during generation hides Cancel with no global fallback**  
**File:** `Sources/iOS/App/TabDock.swift:52-56`, `Sources/iOS/IOSGenerationModeViews.swift:382-390`  
**Issue:** Tab dock always switches tabs. Cancel lives only in `IOSStudioCanvas.generatingBar` on Studio. On Voices/History/Settings the user sees no in-flight indicator and cannot cancel.  
**Fix:** Read `TTSEngineStore.hasActiveGeneration` in `TabDock` or `RootView` — disable non-Studio tabs or show a persistent bottom banner with Cancel that calls `ttsEngine.cancelActiveGeneration()` and finishes the active coordinator.

---

### HIGH

**Mode selector not gated on `hasActiveGeneration`**  
**File:** `Sources/iOS/IOSGenerateFlowViews.swift:332-344`  
**Issue:** `IOSCapsuleSelector` has no `.disabled` tied to engine/coordinator state (macOS disables workflow controls via `isDisabled: isGenerationActive` in `CustomVoiceView.swift:285`).  
**Fix:** Add `isLocked` parameter; `.disabled(isLocked)` on segment buttons with accessibility hint “Wait for generation to finish or cancel.”

---

**Setup chips remain tappable during generation**  
**File:** `Sources/iOS/IOSGenerationModeViews.swift:172-198` (Custom; same pattern Design/Clone)  
**Issue:** Voice / Delivery / Language chips call `presentBottomPanel` with no generation guard. User can open pickers mid-run and change inputs that won't apply until next generation.  
**Fix:** `.disabled(isGenerationActive)` on `IOSStudioSetupChip` actions when `isGenerating || ttsEngine.hasActiveGeneration`.

---

**`studioGenState` ignores `hasActiveGeneration`**  
**File:** `Sources/iOS/IOSGenerationModeViews.swift:32-36` (also `:423-427`, `:889-893`)  
**Issue:** Dock state uses `coordinator.isGenerating` only. If coordinator desyncs from engine, UI shows idle Generate while engine is busy.  
**Fix:** `if isGenerationActive { return .generating }` where `isGenerationActive = coordinator.isGenerating || ttsEngine.hasActiveGeneration`.

---

**Onboarding Skip control is dead code**  
**File:** `Sources/iOS/Overlays/IOSOnboardingFlow.swift:19-34` vs `:38-56`  
**Issue:** `topBar` with Skip is defined but never inserted in `body`. `.interactiveDismissDisabled(true)` blocks swipe dismiss; users must tap through 3 CTAs.  
**Fix:** Add `topBar` to the `VStack` in `body` (above `pages`), or remove dead `topBar` if intentional.

---

**Post-onboarding install card never shown**  
**File:** `Sources/iOS/IOSOnboardingCard.swift:1-43` (zero call sites)  
**Issue:** `IOSFirstRunOnboardingCard` (“Open Settings to download…”) is not wired into Studio or Settings after onboarding. New users land on Studio with only per-mode “Install model” CTA.  
**Fix:** Present card in `IOSStudioCanvas` idle state when `!hasAnyInstalledModel` (logic exists in `IOSGenerateContainerView.swift:102-107`).

---

**History error empty state promises pull-to-refresh that doesn't exist**  
**File:** `Sources/iOS/IOSLibraryViews.swift:193-205`  
**Issue:** Copy says “Pull to retry” but `ScrollView` has no `.refreshable`; only the Retry button works.  
**Fix:** Add `.refreshable { reload() }` on the history scroll view, **or** change message to “Tap Retry below.”

---

**Voices “Save a new voice” CTA doesn't open Clone mode**  
**File:** `Sources/iOS/IOSVoicesView.swift:123-129`  
**Issue:** Button only sets `selectedTab = .studio`. Comment admits clone mode should be set at call site; `VoicesScreen` doesn't provide a callback. User lands in last Studio mode (often Custom).  
**Fix:** Add `onSaveNewVoice: () -> Void` to `IOSVoicesView`; in `VoicesScreen` set `appModel.studioMode = .clone` before `appModel.tab = .studio`.

---

**History initial load has no loading affordance**  
**File:** `Sources/iOS/IOSLibraryViews.swift:241-281`  
**Issue:** `reload()` is async on appear; first paint is blank until fetch completes (no `ProgressView`, unlike `IOSSavedVoicesLibrarySection` at `:523-530`).  
**Fix:** Add `@State private var isLoading = true`; show `ProgressView` or skeleton until first reload completes.

---

### MEDIUM

**Voices tab lacks dedicated empty state for zero saved voices**  
**File:** `Sources/iOS/IOSVoicesView.swift:68-76`  
**Issue:** With filter Saved and no saved voices, user sees section heading + dashed CTA only — no `IOSEmptyStateCard` (“No saved voices yet”) like legacy `IOSSavedVoicesLibrarySection` (`IOSLibraryViews.swift:538-544`).  
**Fix:** When `filter != .builtIn && filteredSaved.isEmpty && search.isEmpty`, show `IOSEmptyStateCard` above `saveACallCard`.

---

**Voices tab missing load/error states for saved voices**  
**File:** `Sources/iOS/IOSVoicesView.swift:104-106`  
**Issue:** `ensureLoaded` runs in `.task` but no loading spinner or error surface (legacy library section handles both).  
**Fix:** Mirror `IOSSavedVoicesLibrarySection` loading/error branches using `savedVoicesViewModel.isLoading` / `loadError`.

---

**Onboarding install page over-promises immediate install**  
**File:** `Sources/iOS/Overlays/IOSOnboardingFlow.swift:187-193`  
**Issue:** Page 2 title “Install Custom Voice” implies action here; flow is informational and exits to Studio without opening Settings install sheet.  
**Fix:** Add “Open Settings” secondary action on page 2, or soften copy to “You'll install models in Settings.”

---

**Bottom panel backdrop tap dismisses sheets during unrelated work**  
**File:** `Sources/iOS/App/RootView.swift:174-178`  
**Issue:** Tapping dimmed backdrop calls `dismissBottomPanel()` with no guard for in-flight model download or generation-adjacent pickers.  
**Fix:** Disable backdrop tap while `modelInstaller` reports active install or `hasActiveGeneration`.

---

**Batch sheet Close during run can dismiss before cancel completes**  
**File:** `Sources/iOS/IOSBatchGenerationSheet.swift:39-44`  
**Issue:** Close calls `coordinator.cancel()` then immediate `dismiss()` without awaiting cancel/engine cleanup.  
**Fix:** Disable Close while `coordinator.isProcessing`; await cancel completion before dismiss.

---

### LOW

**Onboarding page 3 has no Skip (by design) but page 0–1 Skip unavailable**  
**File:** `Sources/iOS/Overlays/IOSOnboardingFlow.swift:44-52`  
**Issue:** Skip only renders when `topBar` is shown (it isn't). Low severity because CTAs advance and complete.  
**Fix:** Same as HIGH Skip fix.

---

**Engine lifecycle toast is non-interactive during generation**  
**File:** `Sources/iOS/IOSEngineLifecycleToast.swift:48`  
**Issue:** `.allowsHitTesting(false)` — toast cannot host Cancel or “Return to Studio.”  
**Fix:** Only relevant if adding global generation banner; keep toast informational or merge with generation chrome.

---

## Compound findings

| A | B | Result |
|---|---|--------|
| Mode viewport unmounts active view | No global Cancel | User trapped off-Studio until generation ends — **CRITICAL** |
| `studioGenState` coordinator-only | `hasActiveGeneration` true | Idle UI while engine busy — **HIGH** |
| History “Pull to retry” copy | No `.refreshable` | Broken retry affordance — **HIGH** |
| Onboarding `interactiveDismissDisabled` | Skip not in view hierarchy | Forced 3-step funnel — **HIGH** |

---

## Recommendations

1. **Immediate:** Block or globalize Cancel for `hasActiveGeneration` (tab dock + mode selector + optional root banner). Align `studioGenState` with `isGenerationActive`.
2. **Short-term:** Wire onboarding Skip / first-run install card; fix Voices save CTA; add History loading + honest retry copy; disable setup chips during generation.
3. **Long-term:** Persist “generating mode” on `AppModel` for cross-tab return; add `.refreshable` on History; consider macOS-style `isDisabled` on all cross-mode controls from a single `GenerationActivityState` on `AppModel`.

---

## What's working

- **Cancel on Studio (same mode):** `cancelGeneration()` in all three mode views cancels task + engine + live preview (`IOSGenerationModeViews.swift:382-390` and equivalents).
- **Generate blocked cross-mode:** `canGenerate` checks `!ttsEngine.hasActiveGeneration` (`IOSGenerationModeViews.swift:101`).
- **History empty/error/filtered empty:** `IOSEmptyStateCard` paths at `IOSLibraryViews.swift:193-223`.
- **Recording overlay dismiss:** X button + permission alert Cancel (`IOSRecordingOverlay.swift:66-68`, `:52-54`).
- **Player sheet dismiss:** Chevron down + `onDismiss` (`IOSPlayerSheet.swift:116-118`, `RootView.swift:88-92`).
- **Settings model rows:** Per-row checking/install progress (`IOSSettingsViews.swift:748-762`).
