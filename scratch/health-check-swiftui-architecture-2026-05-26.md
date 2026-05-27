# SwiftUI Architecture Audit — `Sources/iOS/`

**Date:** 2026-05-26  
**Scope:** AppModel `@Observable` vs legacy `ObservableObject`, generation logic in legacy `IOS*` views vs coordinators, logic in view bodies.

## Summary

The iOS layer is mid-migration: **routing, drafts, and generation UI state** live on `@Observable` `AppModel` + `StudioGenerationCoordinator`, but **engine calls, persistence, prefetch, and clone priming** still live inside legacy `IOS*` views (~1,540 lines in `IOSGenerationModeViews.swift` alone). App-level services (`TTSEngineStore`, `AudioPlayerViewModel`, batch/installer view models) remain **`ObservableObject` + `@EnvironmentObject`**, so views mix two state paradigms.

**Health: TANGLED** — no confirmed `@State` source-of-truth bugs, but **3 CRITICAL** async-boundary / untestable-generation issues, **7 HIGH** separation-of-concerns gaps, and a **dead `IOSGeneratePrimaryActionDescriptor` pipeline** still running on every mode switch.

| Severity | Count |
|----------|------:|
| CRITICAL | 3 |
| HIGH | 7 |
| MEDIUM | 6 |
| LOW | 3 |

**Immediate priorities:** (1) move `generate()` / `cancelGeneration()` into a testable coordinator or use-case type per mode, (2) delete or finish migrating `IOSGeneratePrimaryActionDescriptor`, (3) extract prefetch + clone priming out of view bodies.

---

## Architecture Boundary Map

- **Pattern:** Intentional **strangler migration** — new `App/` + `Studio/` shells (`RootView`, `StudioScreen`, tab screens) wrap legacy `IOS*` bodies; comments reference Phases 3–6.
- **View vs model ratio:** ~95 `View` conformances vs **2 `@Observable` models** (`AppModel`, `StudioGenerationCoordinator`) + **8 `ObservableObject` types** (engine store, batch, installer, playback controllers, app deps). Ratio ~10:1 views to observable models; most logic still view-adjacent.
- **State injection:** `@Environment(AppModel.self)` for app routing/drafts/coordinators; `@EnvironmentObject` for engine, audio, models, saved voices. **Dual stack by design, not yet unified.**
- **Generation logic location:** Coordinator holds **UI flags only** (`isGenerating`, `errorMessage`, `lastCompletedOutput`). **`ttsEngine.generate`, `GenerationPersistence`, `Task` lifecycle** remain in `IOSCustomVoiceView`, `IOSVoiceDesignView`, `IOSVoiceCloningView`.
- **Positive reference:** `IOSBatchGenerationCoordinator` owns batch async work correctly; single-generation paths should mirror it.
- **Testability:** Core generation paths require SwiftUI + live engine; no unit-test seam for request assembly or post-generation persistence. `AppModel` imports `SwiftUI` for `AnyView` bottom panels.

---

## Architecture Health Score

| Metric | Value |
|--------|-------|
| View / model ratio | ~95 views, 10 observable models (~9.5:1) |
| Logic separation | ~3 legacy mode views + prefetch view own business logic; coordinators UI-only (~25% clean) |
| Async boundary | 6+ multi-step `Task` blocks in views; batch coordinator delegates correctly (~30% clean) |
| Property wrapper correctness | `@State private var appModel` in root — correct; no non-private `@State` parent-copy bugs found |
| Testability | `AppModel` + navigation enums import SwiftUI; generation untestable without UI (~40% testable) |
| Architecture consistency | **Mixed** — `@Observable` shell + `ObservableObject` services + legacy `IOS*` bodies |
| **Health** | **TANGLED** |

---

## Issues

### CRITICAL

| Severity | File:Line | Description | Fix |
|----------|-----------|-------------|-----|
| CRITICAL | `IOSGenerationModeViews.swift:301-380` | `IOSCustomVoiceView.generate()` builds `GenerationRequest`, runs `Task { await ttsEngine.generate(...) }`, persists via `GenerationPersistence`, and completes the inline player — full business flow in the view. | Add `@MainActor` `StudioCustomGenerationService` (or extend coordinator) with `generate(draft:engine:) async throws -> IOSStudioInlinePlayerItem`. View calls `coordinator.run { try await service.generate(...) }`. |
| CRITICAL | `IOSGenerationModeViews.swift:770-847` | Same pattern in `IOSVoiceDesignView.generate()` including save-sheet side effects. | Same extraction; include enroll/save-voice callbacks as injected closures on the service. |
| CRITICAL | `IOSGenerationModeViews.swift:1295-1394` | `IOSVoiceCloningView.generate()` adds clone priming (`ensureCloneReferencePrimed`) before generate — most complex path, still in view. | Extract `StudioCloneGenerationService` with priming + generate; view only wires draft + coordinator lifecycle. |

### HIGH

| Severity | File:Line | Description | Fix |
|----------|-----------|-------------|-----|
| HIGH | `App/AppModel.swift:3,13-15,130-136` | `AppModel` imports `SwiftUI` and stores `AnyView` closures in `IOSBottomPanelPresentation` — core app state coupled to UI framework. | Replace `AnyView` panel content with a typed `enum PresentedBottomPanel { case voicePicker(...); case delivery(...) }` and let `RootView` switch to concrete sheets. Drop `import SwiftUI` from `AppModel`. |
| HIGH | `IOSGenerateFlowViews.swift:87-89,106-108` + `AppModel.swift:106-108` | `IOSGeneratePrimaryActionDescriptor` bindings + `publishPrimaryAction()` still run (`.task` in each mode view), but `activePrimaryAction` is **never read** — dead bridge from pre-`IOSStudioCanvas` dock. | Remove descriptor properties from `AppModel`, drop `@Binding var primaryAction` from mode views, delete `publishPrimaryAction()` and placeholder init. CTA already flows through `IOSStudioCanvas.onGenerate`. |
| HIGH | `IOSGenerationModeViews.swift:51-61,434-444` (+ clone lacks delivery) | `deliveryChipLabel` and `canGenerate` validation duplicated across Custom/Design/Clone with ~80% overlap. | Extract `StudioGenerationValidation` (or per-mode structs) with `canGenerate(draft:engine:modelManager:)` and `deliveryChipLabel(from:)`. |
| HIGH | `IOSGenerateFlowViews.swift:172-255` | `IOSGeneratePrefetchCoordinator` is a zero-size **View** owning debounced `Task`, signature cache, and `ttsEngine.prefetchInteractiveReadinessIfNeeded` — async business logic in view layer. | Move to `@Observable IOSPrefetchCoordinator` owned by `AppModel` or `TTSEngineStore` extension; trigger from `.onChange` in `StudioScreen` via model methods. |
| HIGH | `IOSGenerationModeViews.swift:1037-1051,1408-1441` | Clone reference priming (`syncCloneReferencePriming`, `.task(id: clonePrimingTaskID)`) lives in `IOSVoiceCloningView` with engine calls in view methods. | Extract `CloneReferencePrimingController` on `AppModel.cloneCoordinator` or dedicated `@Observable` type; view observes phase only. |
| HIGH | `QVoiceiOSApp.swift:9-13,44-49` vs `QVoiceiOSRootView.swift:19-20` | Root uses **`@StateObject`** engine/audio/saved-voices stack **and** **`@State` + `.environment(appModel)`** — two parallel state systems at app entry. | Long-term: migrate `TTSEngineStore` / view models to `@Observable` and inject via `.environment()` consistently; short-term document the split in one `ARCHITECTURE.md` pointer. |
| HIGH | `IOSGenerationModeViews.swift:1-1540` | Three mode views in one file (~660 lines for clone alone) mix validation, sheet presentation, generation, priming, and save-voice flows — god views resist testing and preview isolation. | Split into `CustomVoiceStudioView.swift` + `CustomVoiceGeneration.swift` (etc.) or collapse behind single `StudioBody` once services exist. |

### MEDIUM

| Severity | File:Line | Description | Fix |
|----------|-----------|-------------|-----|
| MEDIUM | `Studio/StudioGenerationCoordinator.swift:37-40,315` | `generationTask` stored as `Task<Void, Never>?` on coordinator but **created and assigned from views** — coordinator doesn't own cancellation policy. | Move `generationTask` creation into coordinator methods: `func runGeneration(_ operation: @Sendable () async -> Void)`. |
| MEDIUM | `IOSBatchGenerationCoordinator.swift:4-5` | Batch path correctly centralizes generation but stays **`ObservableObject`** while studio uses `@Observable` — inconsistent migration surface. | Migrate to `@Observable` + `@Published` removal when batch sheet moves to `@Bindable`. |
| MEDIUM | `Studio/StudioScreen.swift:35-46` | Thin shell still passes **11 bindings** into `IOSGenerateContainerView` instead of reading drafts from `@Environment(AppModel.self)` inside legacy container. | Refactor `IOSGenerateContainerView` to `@Environment(AppModel.self)` only; delete binding plumbing from `StudioScreen`. |
| MEDIUM | `IOSSettingsViews.swift:37-175` | Settings install/delete/cancel call `modelInstaller` directly from private view methods (~900 lines total file). | Extract `SettingsViewModel: @Observable` with `install/cancel/delete`; keep view declarative. |
| MEDIUM | `IOSLibraryViews.swift:264` | History reload uses view-owned `Task` + SQL path — data loading in view layer. | Inject `HistoryRepository` or move load into `@Observable` history store. |
| MEDIUM | `IOSGenerationModeViews.swift:1081-1103` | Batch sheet `requestBuilder` closure assembled inline in `body` modifiers — generation request construction duplicated from `generate()`. | Share `CloneGenerationRequestBuilder.build(line:draft:)` used by both single and batch paths. |

### LOW

| Severity | File:Line | Description | Fix |
|----------|-----------|-------------|-----|
| LOW | `IOSRootNavigationModels.swift:1,28-35` | Navigation enums import `SwiftUI` for `Color` tints. | Acceptable for design tokens; optionally move tints to `Theme.swift` and keep enums Foundation-only. |
| LOW | `IOSBatchGenerationSheet.swift:13` | `@StateObject private var coordinator` for sheet-local coordinator — fine pattern for sheet scope. | When batch coordinator becomes `@Observable`, switch to `@State`. |
| LOW | `Sheets/IOSVoicePreviewPlayer.swift:13` | `ObservableObject` wrapper around `AVAudioPlayer` — appropriate for reference-type player. | No change unless migrating all playback to one `@Observable` player store. |

---

## Compound Findings

| Combination | Severity | Notes |
|-------------|----------|-------|
| Generation logic in views + no unit tests | **CRITICAL** | Request assembly, persistence, and error mapping only reachable via UI or device tests. |
| Partial coordinator extraction + `Task` in views | **HIGH** | Phase 3b moved flags but not operations — developers may assume coordinator owns generation. |
| Dead `primaryAction` pipeline + `.task` publish | **HIGH** | Wasted view updates every `primaryActionToken` change; confusing for future edits. |
| Duplicate validation across 3 modes | **HIGH** | Validation rules can diverge silently (already differs: design requires `voiceDescription`, clone requires reference). |

**Cross-auditor:** Async `Task` in views → concurrency-auditor; formatter/sorting in large views → swiftui-performance-analyzer; tab/handoff routing in `VoicesScreen`/`HistoryScreen` → swiftui-nav-auditor.

---

## Recommendations

### Immediate
1. Extract single-mode `generate()` / `cancelGeneration()` into testable `@MainActor` services; coordinators own task lifecycle.
2. Remove dead `IOSGeneratePrimaryActionDescriptor` path from `AppModel` and mode views.
3. Move `IOSGeneratePrefetchCoordinator` logic off the view type.

### Short-term
4. Unify request builders (`IOSPrefetchRequestFactory` is a good start — promote to shared generation module).
5. Migrate `IOSBatchGenerationCoordinator` to `@Observable`.
6. Reduce `IOSGenerateContainerView` binding surface — environment-only `AppModel`.

### Long-term
7. Collapse legacy `IOS*` bodies behind `StudioBody` / dedicated screen files per AGENTS.md Phase 6.
8. Migrate app-level `ObservableObject` services to `@Observable` for one injection style.
9. Add unit tests for request builders and validation before further UI refactors.

---

## Positive Patterns (keep)

- **`QVoiceiOSRootView`** correctly owns `AppModel` lifetime with `@State` + `.environment(appModel)`.
- **Tab screens** (`VoicesScreen`, `HistoryScreen`, `SettingsScreen`) are thin, AppModel-aware routers — good target shape for Studio.
- **`IOSBatchGenerationCoordinator`** demonstrates the desired async ownership model for generation batches.
- **`IOSPrefetchRequestFactory`** (in `IOSGenerateFlowViews.swift`) already centralizes request assembly for prefetch — extend for live generation.
