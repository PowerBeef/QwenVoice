# SwiftUI Performance Audit — 2026-05-26

**Scope:** `Sources/iOS/` (51 Swift files) and `Sources/Views/` macOS (21 Swift files).  
**Priority note:** UI-layer findings below are **secondary** to engine/XPC/MLX performance work in this repo; treat them as polish and scroll/jank hardening, not release blockers unless user-visible jank is confirmed on device.

## Executive summary

- **Health: JANKY** — no synchronous file I/O or formatter creation in view bodies; history/macOS lists are mostly well structured.
- **Top risks:** (1) `IOSWaveformBars` uses `GeometryReader` + per-bar `ForEach` inside **history list cells**; (2) several iOS screens use **`ScrollView` + `VStack` + `ForEach`** instead of lazy stacks for voice lists; (3) **Player karaoke** rebuilds a full `AttributedString` on every `CADisplayLink` tick (~30 Hz).
- **macOS:** Generally stronger — `HistoryView` precomputes row data, `List` is native-lazy, `WaveformView` uses `Canvas`. Minor gaps: batch status `ScrollView`/`VStack`, broad `EnvironmentObject` on generation views.
- **Counts:** CRITICAL 1 (compound) · HIGH 6 · MEDIUM 7 · LOW 4

---

## Performance context map

| Area | Scrolling | Cell / body cost | Update drivers |
|------|-----------|------------------|----------------|
| iOS History (`IOSLibraryViews`) | `LazyVStack` in `ScrollView` | Each row: `IOSWaveformBars` (14 bars, `GeometryReader`, static) | Search debounce 150 ms; DB reload |
| iOS Voices (`IOSVoicesView`) | `ScrollView` + **`VStack`** `ForEach` | Built-in + saved rows; sort/filter on every body read | `search`, `filter`, `SavedVoicesViewModel` |
| iOS Voice picker sheet | `ScrollView` + **`VStack`** `ForEach` | Filtered speakers + preview player | Search, filter chips |
| iOS Studio inline player | Fixed chrome | 38-bar waveform + `GeometryReader`; `CADisplayLink` ~30 Hz | `IOSInlinePlaybackController` |
| iOS Player sheet | Transcript `ScrollView` | 42-bar waveform; karaoke `AttributedString` rebuild | `CADisplayLink` 20–60 Hz (preferred 30) |
| iOS Settings | `ScrollView` + `VStack` | ~few model rows | `ModelManager` / installer state |
| macOS History | `List` | Lightweight rows (no waveform) | Debounced search; prebuilt `HistoryListItem` |
| macOS Voices | `List` | `VoiceRow` | `SavedVoicesViewModel` |
| macOS Sidebar player | Static | `Canvas` waveform; **`PlaybackProgress`** isolated | 100 ms timer |
| macOS Generate pages | `PageScaffold` `GeometryReader` + `ScrollView` | Heavy forms, not list cells | Coordinators, engine env objects |

High-frequency sources: `CADisplayLink` (iOS player/inline), `IOSReferenceClipRecorder` metering timer (12.5 Hz), `AudioPlayerViewModel` progress timer (10 Hz, macOS-isolated), `TTSEngineStore` `@Published` (chunk events deliberately not fan-out).

---

## Performance health score

| Metric | Value |
|--------|-------|
| View body purity | ~72 iOS + ~52 macOS `body` sites scanned; **0** confirmed sync file I/O or formatter alloc in `body` |
| Scrolling cell safety | 2/4 long-list iOS contexts use lazy containers (History, Batch); Voices + voice picker do not |
| Lazy container usage | macOS library lists: **100%** `List`; iOS long lists: **~50%** lazy |
| Collection efficiency | Filter/sort in computed properties (Voices, History iOS); macOS history filter off-body via `recomputeFilteredItems` |
| Observable efficiency | iOS: `@Observable` `AppModel` + many legacy `ObservableObject`; macOS Views: **0** `@Observable`, coordinators `StateObject` |
| **Health** | **JANKY** |

---

## Issues (severity · file:line · description · fix)

### CRITICAL

| Severity | File:Line | Description | Fix |
|----------|-----------|-------------|-----|
| CRITICAL (compound) | `Sources/iOS/IOSLibraryViews.swift:395-401` + `Sources/iOS/IOSDesignSystemPrimitives.swift:219-238` | History **lazy row** embeds `IOSWaveformBars`: `GeometryReader` + `ForEach(0..<barCount)` per visible row. Fast scroll = double layout pass × visible rows. | Replace thumbnail with static `Canvas`/SF Symbol, or cache bar heights in `Generation` metadata; keep `GeometryReader` only in player chrome. |

### HIGH

| Severity | File:Line | Description | Fix |
|----------|-----------|-------------|-----|
| HIGH | `Sources/iOS/Sheets/IOSPlayerSheet.swift:503-523` | `IOSPlayerKaraokeText` rebuilds full `AttributedString` over all spans every `currentTime` tick (~30 Hz via `CADisplayLink`). Long transcripts = main-thread churn. | Track `activeIndex` in controller; update only changed span attributes, or use `Text` + per-word views with `.id(activeIndex)`. Throttle karaoke updates to 10–15 Hz. |
| HIGH | `Sources/iOS/IOSVoicesView.swift:54-86` | `ScrollView` + **`VStack`** + `ForEach` for saved + built-in voices (unbounded saved count). All rows materialized when scrolled. | Use `LazyVStack` (or `List` + sections). Precompute `filteredBuiltIn` / `filteredSaved` only when `search`/`filter` change (`@State` cache). |
| HIGH | `Sources/iOS/Sheets/IOSBottomSheets.swift:399-407` | Voice picker: `ScrollView` + **`VStack`** + `ForEach(filtered)` over full speaker catalog. | `LazyVStack` with stable `id: \.id`; consider sectioned `List` in sheet. |
| HIGH | `Sources/iOS/IOSDesignSystemPrimitives.swift:209-216` | `IOSWaveformBars` with `isAnimating: true` uses `TimelineView(.animation)` → continuous body refresh. Used in recording overlay (`IOSRecordingOverlay.swift:122-128`). | Drive animation from recorder amplitude via `@State` + single `Canvas` draw; respect Reduce Motion (already partially gated). |
| HIGH | `Sources/iOS/Sheets/IOSPlayerSheet.swift:630-646` | `IOSPlayerSheetController` publishes `currentTime` every display link frame → whole sheet (waveform, scrubber, transcript) invalidates. | Split progress into a small `@Observable` scrub state; use `Canvas` for scrubber fill; isolate karaoke subview with equatable wrapper. |
| HIGH | `Sources/iOS/Studio/IOSStudioInlinePlayerCard.swift:89-103,283-294` | Inline player: `GeometryReader` + 38-bar `IOSWaveformBars` + `CADisplayLink` progress updates. | Same as player sheet: `Canvas` waveform; throttle `currentTime` publishes; `isAnimating: false` already — avoid expanding bar count in hot path. |
| HIGH (cross-auditor: energy) | `Sources/iOS/IOSVoicesView.swift:19-20` + `Sources/iOS/IOSGenerationModeViews.swift:6-8,395-398,862-865` | `TTSEngineStore` / `SavedVoicesViewModel` as `@EnvironmentObject` on large views. Engine readiness/events can invalidate entire Studio/Voices subtrees. | Prefer `@Environment(AppModel)` + narrow bindings; inject engine only into generate controls. Chunk fan-out already suppressed in `TTSEngineStore.swift:379-384` — extend pattern to other `@Published` fields. |

### MEDIUM

| Severity | File:Line | Description | Fix |
|----------|-----------|-------------|-----|
| MEDIUM | `Sources/iOS/IOSSettingsViews.swift:71-87` | Settings models: `ScrollView` + `VStack` + `ForEach(TTSModel.all)` (small N today, not lazy). | `LazyVStack` if model count grows; current N is low — acceptable if catalog stays <10. |
| MEDIUM | `Sources/iOS/IOSVoicesView.swift:26-46` | `builtIn` / `saved` re-sort and re-filter on every `body` evaluation when parent invalidates. | Cache sorted arrays; recompute filtered lists in `.onChange(of: search)` / `.onChange(of: filter)`. |
| MEDIUM | `Sources/iOS/Sheets/IOSBottomSheets.swift:369-382` | `filtered` computed property scans all speakers on each body pass during search. | Debounce search (match History 150 ms); store filtered array in `@State`. |
| MEDIUM | `Sources/Views/Components/BatchGenerationSheet.swift:358-366` | Batch status: `ScrollView` + `VStack` + `ForEach(items)` (non-lazy). Large batches allocate all rows. | `LazyVStack` inside `ScrollView`; cap visible height (already `maxHeight: 220`). |
| MEDIUM | `Sources/Views/Components/GenerationWorkflowView.swift:62-69` | `PageScaffold` wraps content in `GeometryReader` + `ScrollView` (extra layout pass on every generate page). | Acceptable for static pages; use fixed min-height only when `fillsViewportHeight` is true. |
| MEDIUM | `Sources/Views/Library/HistoryView.swift:279-294` | `recomputeFilteredItems()` filters/sorts full array (good: not in `body`), but triggered from debounced search — OK. | Already debounced; ensure sort work stays off main for 1k+ rows (background filter). |
| MEDIUM | `Sources/iOS/QVoiceiOSApp.swift:9-13` + multiple views | Legacy `ObservableObject` / `@EnvironmentObject` / `@StateObject` vs `@Observable` `AppModel`. Whole-object invalidation. | Migrate `TTSEngineStore`, playback controllers, batch coordinator to `@Observable` per `AppModel.swift` guidance. |
| MEDIUM (cross-auditor: memory) | `Sources/iOS/Overlays/IOSRecordingOverlay.swift:345-346` | Metering `Timer` at 0.08 s; cleaned on disappear/stop — OK. | Verify `stopWithoutSaving` always invalidates timer (already at 316, 330, 344, 383). |

### LOW

| Severity | File:Line | Description | Fix |
|----------|-----------|-------------|-----|
| LOW | `Sources/Views/Generate/CustomVoiceView.swift:123` | `@StateObject` coordinator (`ObservableObject`). | Migrate to `@Observable` + `@State` when touching generate stack. |
| LOW | `Sources/Views/Components/EmotionPickerView.swift:51` | `first(where:)` in `Binding` setter (not per-frame). | Optional: preset ID → index map. |
| LOW | `Sources/iOS/IOSGenerationSetupCards.swift:103-105` | `ForEach(TTSModel.allSpeakers)` inside menu `Picker` (small N). | No change unless speaker count grows large. |
| LOW | `Sources/Views/Components/SidebarPlayerView.swift:54-62` | `GeometryReader` around waveform (single instance, not scrolling). | Pattern is fine; `PlaybackProgress` isolation is exemplary (`AudioPlayerViewModel.swift:85-103`). |

---

## False positives ruled out

- `HistoryView.swift:37` `DateFormatter()` — inside `HistoryListItem.init`, not view `body`.
- `BatchGenerationSheet.swift:78` `String(contentsOf:)` — file-drop callback, not `body`.
- `IOSGenerationModeViews.swift:1515` transcript read — import handler, not `body`.
- `IOSRecordingOverlay.swift:373` `ISO8601DateFormatter()` — `makeOutputURL()` on recorder, not overlay `body`.
- macOS `WaveformView` — `Canvas` rendering (good pattern).
- iOS History / macOS Voices — native lazy containers (`LazyVStack` / `List`).

---

## Recommendations

### Immediate (scrolling / perceived jank)

1. Remove or simplify `IOSWaveformBars` in `IOSHistoryItemCard` (CRITICAL compound).
2. Convert `IOSVoicesView` and voice picker sheet to `LazyVStack`.
3. Throttle or incremental-update `IOSPlayerKaraokeText` during playback.

### Short-term

4. Refactor `IOSWaveformBars` animated path off `TimelineView` where amplitude is externally driven (recording, rail).
5. Narrow `TTSEngineStore` observation on Studio/Voices (environment injection scope).
6. macOS batch sheet: lazy stack for item list.

### Long-term / verification

7. Continue `@Observable` migration for iOS engine/playback coordinators.
8. Profile with Instruments **SwiftUI** template after changes: History fast-scroll, Voices search, Player sheet scrub + karaoke.
9. Physical iPhone check for Studio inline player + History scroll (Simulator stub engine won’t stress MLX, but UI layout cost still applies).

---

## Phase accounting

| Phase | Issues |
|-------|--------|
| Phase 2 (anti-pattern detection) | 12 |
| Phase 3 (context-dependent) | 5 |
| Phase 4 (compound) | 1 |

**Cross-auditor:** Timer cleanup → memory-auditor; `TTSEngineStore` fan-out → concurrency/energy; animated waveforms → energy-auditor.
