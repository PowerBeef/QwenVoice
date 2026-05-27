# SwiftUI Layout Audit — `Sources/iOS/` (2026-05-26)

## Summary

| Severity | Count |
|----------|------:|
| CRITICAL | 0 |
| HIGH | 4 |
| MEDIUM | 7 |
| LOW | 4 |

**Health: RIGID** — Studio composer flex (`IOSFlexibleTextEditor`) is sound; no deprecated `UIScreen`/`UIDevice` APIs; GeometryReader usage is mostly disciplined. Main risks are **hardcoded dock/chrome reservations** (`tabDockReservation` 97, Settings 90+118) that can drift from `TabDock` and may stack with `RootView` `safeAreaInset`, **no size-class or iPad multitasking adaptation**, and **fixed 22pt composer typography** that does not track Dynamic Type.

**Focus areas:** `IOSFlexibleTextEditor` is correctly implemented for `flex: 1`. `tabDockReservation` 97 matches the React reference but is a manual workaround for `NavigationStack` not inheriting bottom inset; keep it in sync with `TabDock` or replace with measured layout. AGENTS.md still mentions `.padding(.bottom, 130)`; current code uses **97** only. No numeric width/height breakpoint comparisons (`width > 400`) were found.

---

## Layout Strategy Map

- **Approach:** Fixed design-token layout (pt constants from `design_references/Vocello iOS/`), flexible Studio composer via `layoutPriority` + `maxHeight: .infinity`, not size-class-driven.
- **GeometryReader:** 7 usages across 5 files; waveforms/scrubbers/backdrops constrained with `.frame(height:)`; `RootView` overlays use full-screen GR as root (acceptable).
- **Modern adaptivity:** `ViewThatFits` ×1 (clone setup card); no `horizontalSizeClass`, `AnyLayout`, `onGeometryChange`, or `containerRelativeFrame`.
- **Fixed dimensions:** Many sub-300pt frames; one **300pt** onboarding width; dock/chrome constants **97 / 64 / 135 / 90 / 118**.
- **Deprecated APIs:** None in `Sources/iOS/`.
- **Multitasking / iPad:** No explicit Split View or Stage Manager handling; iPhone-first chrome.

---

## Layout Health Score

| Metric | Value |
|--------|-------|
| Adaptivity coverage | Size class: **no**; ViewThatFits: **1**; AnyLayout: **0** |
| GeometryReader discipline | **7** total; **5** with explicit height/frame in HStack/VStack; **2** full-screen overlay/background |
| Fixed dimension risk | **1** frame ≥300pt; **6** hardcoded chrome constants (97, 64, 135, 90, 118, 44) |
| Deprecated API usage | **0** |
| Identity safety | Conditional stacks use `@ViewBuilder` switches on **dock state**, not VStack↔HStack swaps; clone setup uses **ViewThatFits** (safe) |
| Device coverage | Smallest width: not guarded; multitasking: **not addressed** |
| **Health** | **RIGID** |

---

## Issues

### HIGH — Hardcoded `tabDockReservation` (97) vs live `TabDock` + `safeAreaInset`

| Field | Detail |
|-------|--------|
| **File** | `Sources/iOS/IOSStudioCanvas.swift:5`, `Sources/iOS/IOSStudioCanvas.swift:105-110` |
| **Description** | Studio canvas applies `.padding(.bottom, 97)` because comments state `NavigationStack` does not propagate `RootView`'s `safeAreaInset` for `TabDock`. `TabDock` height is assembled from nested padding (rail 6+6, bottom 24, button ~52pt) and is not defined in one shared constant—**97 can drift** if dock chrome changes. If inset propagation improves on a future OS, this could **double-reserve** bottom space (inset + 97). |
| **Fix** | Extract `TabDock` preferred height into a shared `enum TabDockMetrics { static let contentHeight: CGFloat = … }` used by both `TabDock` and `IOSStudioCanvasLayout.tabDockReservation`. Prefer `safeAreaPadding(.bottom, …)` / `GeometryReader` + `PreferenceKey` on the dock when `NavigationStack` inheritance is confirmed; remove manual padding when redundant. |

---

### HIGH — Settings bottom clearance triple-stack (90 + 118 + global dock inset)

| Field | Detail |
|-------|--------|
| **File** | `Sources/iOS/IOSSettingsViews.swift:137-144` |
| **Description** | Scroll content uses `.padding(.bottom, 90)` **and** `.safeAreaInset(edge: .bottom) { Color.clear.frame(height: 118) }` while `RootView` already inserts `TabDock` via `safeAreaInset`. Total bottom reservation can exceed dock height (~97pt), leaving a large dead zone or inconsistent scroll end on smaller phones / landscape. |
| **Fix** | Rely on a single mechanism: either parent `TabDock` inset only, or one measured spacer. Remove redundant 90+118 pair; use `scrollContentBackground` + `contentMargins` (iOS 17+) or one `safeAreaInset` tied to shared dock metrics. |

---

### HIGH — No horizontal/vertical size class or iPad layout adaptation

| Field | Detail |
|-------|--------|
| **File** | `Sources/iOS/` (project-wide; e.g. `StudioScreen.swift`, `RootView.swift`, `IOSStudioCanvas.swift`) |
| **Description** | Zero `horizontalSizeClass` / `verticalSizeClass` / `ViewThatFits` beyond one clone-setup card. Studio, Voices, History, Settings use full-width phone layouts inside `NavigationStack` with no regular-width column, readable width cap, or Split View testing. |
| **Fix** | Add `@Environment(\.horizontalSizeClass)` at `RootView` or screen shells; use `ViewThatFits`, `NavigationSplitView` (iPad), or `frame(maxWidth: 640)` centered column for regular width. Verify Studio composer + dock in iPad Slide Over (~320–400pt width). |

---

### HIGH — Studio vertical budget: stacked fixed chrome + 97pt dock pad

| Field | Detail |
|-------|--------|
| **File** | `Sources/iOS/IOSStudioCanvas.swift:4-8,115-120`; `Sources/iOS/IOSGenerateFlowViews.swift:78,126-131` |
| **Description** | Mode selector rail (44pt + padding), setup chips, dock area (64 idle / **135 complete**), dock bottom pad 8, plus **97** tab reservation compete with `composerPad` `maxHeight: .infinity`. On short heights (landscape, Dynamic Type, Display Zoom), CTA/inline player can crowd the composer despite `IOSFlexibleTextEditor`. |
| **Fix** | Derive minimum composer height with `ViewThatFits` or `LayoutPriority` tweak; consider shrinking `completeDockAreaHeight` on compact height via `verticalSizeClass` or `onGeometryChange`. Measure on iPhone SE landscape + largest content size. |

---

### MEDIUM — `IOSFlexibleTextEditor`: fixed 22pt font, no Dynamic Type parity

| Field | Detail |
|-------|--------|
| **File** | `Sources/iOS/IOSStudioCanvas.swift:143-159`; `Sources/iOS/Studio/IOSFlexibleTextEditor.swift:22-49` |
| **Description** | Editor uses `UIFont.systemFont(ofSize: 22, weight: .medium)` while placeholder `Text` uses `.font(.system(size: 22, …))`. `IOSMultilineTextView` elsewhere uses `.preferredFont(forTextStyle: .body)`. Large content sizes will not scale the Studio script field; placeholder and `UITextView` can misalign. |
| **Fix** | Use `UIFontMetrics(forTextStyle: .title3).scaledFont(for: UIFont.systemFont(ofSize: 22, weight: .medium))` (or shared metrics token) and matching SwiftUI `Font` on placeholder; pass scaled metrics from `IOSStudioCanvas`. |

---

### MEDIUM — `IOSMultilineTextView` still uses fixed `.frame(height:)` (legacy editors)

| Field | Detail |
|-------|--------|
| **File** | `Sources/iOS/IOSGenerationSharedViews.swift:206-214`; `Sources/iOS/IOSGenerationInputControls.swift:81-92`; `Sources/iOS/IOSGenerationSetupCards.swift:255` |
| **Description** | Non-Studio prompts use `IOSMultilineTextView` with `@ScaledMetric` or fixed `editorHeight` / `inlineEditorHeight`—not the flexible intrinsic-height pattern. Acceptable for cards/sheets, but inconsistent with Studio flex model. |
| **Fix** | Document intentional split, or adopt `IOSFlexibleTextEditor` where expansion inside a parent `VStack` is required. |

---

### MEDIUM — Onboarding card fixed width 300pt

| Field | Detail |
|-------|--------|
| **File** | `Sources/iOS/Overlays/IOSOnboardingFlow.swift:218` |
| **Description** | `.frame(width: 300, alignment: .leading)` risks clipping in iPad Split View (~320pt) and tight landscape on small phones when margins apply. |
| **Fix** | `.frame(maxWidth: 300)` with horizontal padding, or `containerRelativeFrame(.horizontal, count: 12, span: 10, spacing: 8)`. |

---

### MEDIUM — `IOSWaveformBars` GeometryReader inside `HStack` (nested manual sizing)

| Field | Detail |
|-------|--------|
| **File** | `Sources/iOS/IOSDesignSystemPrimitives.swift:219-239` |
| **Description** | Every waveform instantiates a `GeometryReader` + `ForEach(0..<barCount)`. Call sites constrain height (36/96pt), so not CRITICAL, but bar layout uses `geo.size.width/height` multipliers—pattern repeats on hot paths (Studio generating bar, player, inline card). |
| **Fix** | Long-term: `Canvas` or precomputed bar layout; short-term: keep height constraints at all call sites (already done). |

---

### MEDIUM — Percentage-based gradient radii (soft breakpoints)

| Field | Detail |
|-------|--------|
| **File** | `Sources/iOS/IOSDesignSystemPrimitives.swift:87`; `Sources/iOS/Sheets/IOSPlayerSheet.swift:84` |
| **Description** | `max(proxy.size.width * 0.72, proxy.size.height * 0.52)` scales with container—acceptable for backgrounds, not device breakpoints. |
| **Fix** | None required unless gradients look wrong in extreme aspect ratios; optional clamp via `ViewThatFits`. |

---

### MEDIUM — Documentation drift: AGENTS cites 130pt bottom pad; code uses 97

| Field | Detail |
|-------|--------|
| **File** | `AGENTS.md` (repo root) vs `Sources/iOS/IOSStudioCanvas.swift:5,110` |
| **Description** | Maintainer docs reference `.padding(.bottom, 130)` for canvas/dock clearance; implementation uses `tabDockReservation = 97` aligned to React `app.css`. Agents auditing layout may apply the wrong threshold. |
| **Fix** | Update `AGENTS.md` to 97 + pointer to `IOSStudioCanvasLayout` / `TabDock` metrics. |

---

### LOW — `IOSFlexibleTextEditor` focus sync via `DispatchQueue.main.async`

| Field | Detail |
|-------|--------|
| **File** | `Sources/iOS/Studio/IOSFlexibleTextEditor.swift:68-72` |
| **Description** | `becomeFirstResponder` / `resignFirstResponder` dispatched async from `updateUIView` can race rapid focus binding changes (flicker or stale keyboard). Layout-neutral but affects composer UX. |
| **Fix** | Use `UIView.performWithoutAnimation` or compare binding in `textViewDidBeginEditing` only; avoid async if already on main run loop during `updateUIView`. |

---

### LOW — `RootView` `GeometryReader` overlays (delete/bottom panels)

| Field | Detail |
|-------|--------|
| **File** | `Sources/iOS/App/RootView.swift:140-164`, `172-186` |
| **Description** | Full-screen `GeometryReader` for bottom-aligned sheets—correct pattern (no stack sibling collapse). Uses `proxy.safeAreaInsets.bottom` for edge-to-edge sheets. |
| **Fix** | No change; keep as reference for safe-area-aware overlays. |

---

### LOW — `ViewThatFits` only on clone reference row

| Field | Detail |
|-------|--------|
| **File** | `Sources/iOS/IOSGenerationSetupCards.swift:215-224` |
| **Description** | Good identity-safe horizontal/vertical fallback; rest of app does not use content-driven adaptation. |
| **Fix** | Reuse pattern for setup chip rows or delivery controls if they wrap on narrow widths. |

---

### LOW — `IOSCapsuleSelector` non-lazy `HStack` + `ForEach` (3 items)

| Field | Detail |
|-------|--------|
| **File** | `Sources/iOS/IOSGenerateFlowViews.swift:367-396` |
| **Description** | Three mode segments—below lazy threshold per auditor false-positive rules. |
| **Fix** | None. |

---

## Phase 4 — Compound notes

| Combination | Severity | Note |
|-------------|----------|------|
| `tabDockReservation` 97 + `completeDockAreaHeight` 135 | HIGH | Largest Studio bottom stack; test inline player + keyboard open. |
| Settings 90 + 118 + `TabDock` inset | HIGH | Excess scroll padding. |
| Fixed 22pt composer + Dynamic Type | MEDIUM | Overlaps accessibility-auditor (text clipping). |
| No size class + iPad deployment | HIGH | UX-flow risk on iPad multitasking. |

---

## Recommendations

1. **Immediate:** Unify dock height constant between `TabDock` and `IOSStudioCanvasLayout`; audit Settings scroll bottom (remove duplicate 90+118 if `TabDock` inset is active).
2. **Short-term:** Dynamic Type for Studio composer; verify Studio on SE landscape and iPad Split View; update AGENTS.md 130→97.
3. **Long-term:** Size-class-aware shell; reduce hardcoded dock/complete heights on compact vertical size.
4. **Test matrix:** iPhone SE (320pt wide), iPhone 15 Pro Max landscape, iPad Split View ~50% width, largest Dynamic Type.

---

## Files scanned

51 Swift files under `Sources/iOS/` (excludes `*Tests.swift`, `*Previews.swift`, `scratch/`, `docs/` per auditor rules).

**GeometryReader inventory:** `IOSDesignSystemPrimitives.swift` (×2), `RootView.swift` (×2), `IOSGenerationSharedViews.swift` (×1), `IOSStudioInlinePlayerCard.swift` (×1), `IOSPlayerSheet.swift` (×2).
