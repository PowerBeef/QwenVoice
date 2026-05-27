# Liquid Glass Adoption Audit — Vocello iOS + macOS Views

**Date:** 2026-05-26  
**Scope:** `Sources/iOS/`, `Sources/Views/` (macOS)  
**Deployment target:** iOS 26.0 / macOS 26.0 (from `project.yml`)

## Summary

Vocello is **partially adopted** for Liquid Glass. iOS has a mature, centralized glass stack (`iosSubtleGlassSurface`, `ThemeGlassSurfaceModifier`) with strong **Reduce Transparency** discipline wired through `RootView` → `iosReduceTransparencyEnabled`. macOS Views adopt glass on cards, sidebar rows, status banners, and CTA button styles behind `#if QW_UI_LIQUID` + `#available(macOS 26, *)`, but **macOS has no Reduce Transparency fallback** for any `.glassEffect()` site — a gap against AGENTS.md / PRODUCT.md requirements.

**Top issues to address:**
1. **HIGH** — Add macOS Reduce Transparency fallbacks for all `.glassEffect()` paths in `AppTheme.swift` and direct call sites.
2. **HIGH** — Remove stacked material + glass in `IOSBottomEdgeSheet` (`.ultraThinMaterial` under `.glassEffect()`).
3. **MEDIUM** — Wire `TabDock` through `iosDockGlass` (helper exists, unused) or document the intentional solid-fill design.
4. **MEDIUM** — Migrate flat `IOSSurfaceCard` / list-adjacent surfaces to `iosSubtleGlassSurface` for consistency.
5. **LOW** — Add `.interactive()` to macOS glass button styles; add `.tint()` to two macOS `.borderedProminent` buttons missing explicit tint.

**Counts:** 3 HIGH · 9 MEDIUM · 5 LOW · 2 informational (positive)

**Health score:** **PARTIAL** — iOS reads as iOS 26-native with accessibility fallbacks; macOS glass is present but incomplete on accessibility and has one glass-on-glass stack.

---

## Liquid Glass Adoption Health Score

| Metric | Value |
|--------|-------|
| Deployment target | iOS 26.0 / macOS 26.0 |
| Legacy effect sites | 1 `.ultraThinMaterial` (iOS bottom sheet); 0 UIBlurEffect/NSVisualEffectView in UI |
| Glass adoption sites | iOS ~6 direct `.glassEffect` + many via `iosSubtleGlassSurface`; macOS ~12 `.glassEffect` |
| Toolbar modernization | iOS 2 toolbars, prominent actions tinted; macOS uses custom chrome (no `.toolbar {}`) |
| Search alignment | Custom `IOSSearchField` + custom `TabDock` (no `.tabRole(.search)`) — intentional IA |
| Variant discipline | All `.regular`; no `.clear` variant used |
| Nesting hygiene | 1 glass-on-glass stack (`IOSBottomEdgeSheet`) |
| Availability gating | iOS: none needed (26-only); macOS: `#available(macOS 26, *)` + `#if QW_UI_LIQUID` |
| Reduce Transparency | iOS: **consistent**; macOS: **absent** |
| **Adoption** | **PARTIAL** |

---

## Visual Treatment Map

- **iOS chrome:** Custom `TabDock` (solid dark fill, not Liquid Glass), studio cards/CTAs/dock sections via `iosSubtleGlassSurface`, bottom sheets via `IOSBottomEdgeSheet`.
- **macOS chrome:** `NativeSurfaceStyle` / `studioCard()` / sidebar row glass behind compile flag; badges and text fields intentionally flat (May 2026 audit).
- **Central modifiers:** `IOSSubtleGlassSurfaceModifier`, `ThemeGlassSurfaceModifier` — both gate glass on `iosReduceTransparencyEnabled`.
- **Dead helpers:** `themeGlassSurface()` (never called), `iosDockGlass()` / `iosSectionGlass()` (defined, unused).
- **No deprecated UIKit/AppKit blur** in production views; `UIVisualEffectView` appears only in preview screenshot tooling.

---

## Findings

### HIGH

| Severity | File:Line | Description | Fix |
|----------|-----------|-------------|-----|
| HIGH | `Sources/Views/Components/AppTheme.swift:262-284` | `NativeSurfaceStyle` applies `.glassEffect()` with no `@Environment(\.accessibilityReduceTransparency)` branch. macOS glass stays active when the user enables Reduce Transparency. | Read `accessibilityReduceTransparency` (or add a macOS env key mirroring iOS). When true, skip `.glassEffect()` / `.glass3DDepth()` and use existing `legacyBody()`. |
| HIGH | `Sources/Views/Sidebar/SidebarView.swift:101-114` | Sidebar selection/hover rows stack fill + stroke + `.glassEffect().interactive()` with no Reduce Transparency fallback. | Gate the `.glassEffect()` / `.glass3DDepth()` pair behind `!accessibilityReduceTransparency`; keep `legacyRowBackground` as fallback. |
| HIGH | `Sources/Views/Components/SidebarStatusView.swift:210-218` | Error/warning status banners use `.glassEffect()` without Reduce Transparency fallback. | Same pattern: solid `statusBackgroundLegacy` when Reduce Transparency is on. |
| HIGH | `Sources/iOS/IOSDesignSystemPrimitives.swift:533-561` | **Glass-on-glass:** `IOSBottomEdgeSheet` paints `.ultraThinMaterial` in `.background`, then applies `.glassEffect()` on the same shape when Reduce Transparency is off. Stacked translucency causes haze. | Remove `.ultraThinMaterial` when glass is active; keep only `IOSBottomSheetChrome.background` solid tint under `.glassEffect()`. Reserve material-free solid fill for Reduce Transparency path (already present at :534-535). |
| HIGH | `Sources/Views/Components/GenerationWorkflowView.swift:277-298` | `StudioSectionCard` / workflow cards apply `.glassEffect()` without Reduce Transparency check (compound with AppTheme gap). | Propagate Reduce Transparency from environment; skip glass + depth overlays when enabled. |

### MEDIUM

| Severity | File:Line | Description | Fix |
|----------|-----------|-------------|-----|
| MEDIUM | `Sources/iOS/App/TabDock.swift:100-129` | Tab dock rail uses opaque `Color` fill + strokes; `iosDockGlass(tint:cornerRadius:)` exists at `IOSShellPrimitives.swift:1270` but is **never called**. Dock is the primary app chrome and does not use Liquid Glass. | Apply `.iosDockGlass(tint: dockTint)` to the rail background (with Reduce Transparency already handled inside `iosSubtleGlassSurface`), or add a comment in `TabDock` documenting the intentional solid-fill match to `chrome.jsx`. |
| MEDIUM | `Sources/iOS/IOSShellPrimitives.swift:393-413` | `IOSSurfaceCard` uses flat `Color.white.opacity(0.04)` fill — no glass. Used by `IOSSavedVoiceCard` and other library surfaces. | Replace background with `.iosSubtleGlassSurface(in: shape, tint: tint, fill: IOSAppTheme.glassSurfaceFill)`. |
| MEDIUM | `Sources/iOS/Sheets/IOSBottomSheets.swift:217,753,951` | Delivery intensity pills, reference-clip rows, and model-install cancel button use `glassSurfaceFillMuted` flat fills without glass. | Use `.iosSubtleGlassSurface` or `Capsule` + glass for visible chrome; keep chips flat if matching macOS May 2026 “quiet chip” policy. |
| MEDIUM | `Sources/iOS/Overlays/IOSOnboardingFlow.swift:267` | Onboarding waveform preview card uses flat `glassSurfaceFillMuted` — inconsistent with studio cards. | Wrap in `.iosSubtleGlassSurface(in: RoundedRectangle(...), tint: tint)`. |
| MEDIUM | `Sources/iOS/Overlays/IOSRecordingOverlay.swift:192` | “Retake” secondary button uses flat muted fill; adjacent primary uses `IOSPrimaryCTAButton` with Reduce Transparency support. | Optional: `.iosSubtleGlassSurface(in: Capsule(), interactive: true)` for visual parity. |
| MEDIUM | `Sources/Views/Library/VoicesView.swift:525-526` | “Replace reference…” uses `.borderedProminent` without `.tint()`. Primary action lacks explicit brand/mode color. | Add `.tint(AppTheme.accent)` (or mode-appropriate tint). |
| MEDIUM | `Sources/Views/Library/SavedVoiceSheet.swift:317-318` | Confirm enroll button uses `.borderedProminent` without `.tint()`. | Add `.tint(AppTheme.accent)`. |
| MEDIUM | `Sources/iOS/Theme/ThemeModifiers.swift:53-69` | `themeGlassSurface()` API is defined but **never referenced** in the codebase; all callers use `iosSubtleGlassSurface`. | Delete duplicate or migrate callers to one canonical modifier to avoid drift. |
| MEDIUM | (completeness) All glass sites | **No Clear variant** (`.glassBackgroundEffect(in: .clear)` / `.regular` vs `.clear` API). Player sheet and mode backdrops use gradients over dark canvas — Regular glass may add unwanted tint over media-heavy areas. | Audit player sheet (`IOSPlayerSheet.swift:82-100`) and mode backdrops; use Clear variant where content sits over tinted gradients/photos. |

### LOW

| Severity | File:Line | Description | Fix |
|----------|-----------|-------------|-----|
| LOW | `Sources/Views/Components/AppTheme.swift:524,558` | `GlowingGradientButtonStyle` / `CompactGenerateButtonStyle` use `.glassEffect()` without `.interactive()`. Press feedback is opacity-only. | Append `.interactive()` to glass configuration: `.glassEffect(.regular.tint(baseColor).interactive(), in: …)`. |
| LOW | `Sources/iOS/IOSGenerationSharedViews.swift:360` | `IOSConditionalGlassEffect` on inline notices omits `.interactive()` (static content — acceptable but inconsistent with interactive surfaces policy). | No change for static notices; add `.interactive()` only if notices become tappable. |
| LOW | `Sources/iOS/IOSDesignSystemPrimitives.swift:862+` | Custom `IOSSearchField` instead of platform `.searchable` / `.tabRole(.search)`. Not wrong for custom TabDock IA, but misses iOS 26 bottom-aligned search tab treatment. | Consider a dedicated search tab with `.tabRole(.search)` in a future IA revision; low priority given design-reference fidelity. |
| LOW | `Sources/iOS/IOSShellPrimitives.swift:1270-1288` | `iosDockGlass` / `iosSectionGlass` helpers unused after R2 selector cleanup. | Remove dead helpers or wire TabDock / section containers to them. |
| LOW | (completeness) macOS | macOS has Reduce Motion via `appAnimation` but no app-level Reduce Transparency toggle (iOS Settings exposes both). | Add macOS Settings toggle + environment key if parity is desired. |

### Informational (positive — no action required)

| Severity | File:Line | Description |
|----------|-----------|-------------|
| INFO | `Sources/iOS/App/RootView.swift:20-52,209-220` | Correctly merges system + app Reduce Transparency into `iosReduceTransparencyEnabled` and gates modal backdrop blur. |
| INFO | `Sources/iOS/IOSShellPrimitives.swift:288-291` | `iosSubtleGlassSurface` skips `.glassEffect()` with documented solid-fill fallback when Reduce Transparency is on. |
| INFO | `Sources/Views/Components/AppTheme.swift:399-461` | Badges and text fields intentionally **avoid** glass per May 2026 “quieter chrome” audit — correct design discipline. |

---

## Recommendations

### Immediate (HIGH)
1. Add `@Environment(\.accessibilityReduceTransparency)` checks to every macOS `.glassEffect()` path — start with `NativeSurfaceStyle`, `SidebarView`, `SidebarStatusView`, `GenerationWorkflowView`, `BatchGenerationSheet`, `VoicesView`, `SavedVoiceSheet`.
2. Fix `IOSBottomEdgeSheet` glass-on-glass by dropping `.ultraThinMaterial` when glass is applied.

### Short-term (MEDIUM)
3. Decide TabDock policy: adopt `iosDockGlass` or document solid-fill as design-spec intentional.
4. Migrate `IOSSurfaceCard` and scattered `glassSurfaceFillMuted` fills to `iosSubtleGlassSurface`.
5. Add explicit `.tint()` to macOS prominent buttons missing it.
6. Consolidate `themeGlassSurface` vs `iosSubtleGlassSurface`.

### Long-term (LOW + completeness)
7. Add `.interactive()` to macOS glass button styles.
8. Evaluate Clear variant for media-adjacent surfaces (player, overlays).
9. Re-run **accessibility-auditor** after macOS Reduce Transparency land — verify text-on-glass contrast ≥ 4.5:1.
10. Visual regression: iOS/macOS with Reduce Transparency on/off, Reduce Motion on/off.

---

## Test Plan

- [ ] Enable **Settings → Accessibility → Display → Reduce Transparency** on iPhone; verify TabDock, sheets, studio cards, CTA, now-playing rail show solid fills (no translucency).
- [ ] Enable in-app **Settings → Reduce Transparency** on iOS; same surfaces as above.
- [ ] Enable **Reduce Transparency** on macOS; verify sidebar selection, studio cards, status banners, batch sheet rows fall back to solid fills.
- [ ] Open Delivery / Voice / Model Install bottom sheets; confirm no double-haze on sheet chrome.
- [ ] Toggle Reduce Motion; confirm dock/tab animations still honor `Theme.Motion` / `appAnimation`.
- [ ] Spot-check contrast on glass cards with VoiceOver + Accessibility Inspector.

---

## Cross-Auditor Notes

- **accessibility-auditor:** Re-check after macOS Reduce Transparency fix; glass can drop text contrast below WCAG 4.5:1.
- **swiftui-performance-analyzer:** Nested glass removed in bottom sheet should slightly reduce compositing cost.
- **liquid-glass (axiom-design):** Clear variant guidance applies to `IOSPlayerSheet` radial backdrop if glass is added there later.
