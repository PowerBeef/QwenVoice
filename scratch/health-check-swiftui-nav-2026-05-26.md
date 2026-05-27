# SwiftUI Navigation Audit — Vocello (2026-05-26)

**Scope:** `Sources/iOS/App/` (RootView, TabDock, AppModel) + `Sources/Views/` (macOS feature views). Parent shells referenced where routing is owned outside Views (`ContentView`, `QVoiceiOSApp`).

## Executive summary

| Platform | Health | Headline |
|----------|--------|----------|
| **iOS (`App/`)** | **FRAGILE** | Solid centralized routing (`AppModel` + `sheet(item:)` player + custom `TabDock`), but no deep links, no tab/mode persistence, and four path-less `NavigationStack`s recreated on every tab switch. |
| **macOS (`Views/`)** | **SOLID** (within scope) | No stack navigation in Views; `sheet(item:)` is used consistently. Primary chrome is `NavigationSplitView` in `ContentView` with `@AppStorage` sidebar restoration and `AppCommandRouter` menu navigation. |

**Counts:** CRITICAL 2 · HIGH 4 · MEDIUM 4 · LOW 2 · Compound 2

**Immediate actions:** Add `.onOpenURL` + URL types if external entry is required; persist `AppModel.tab` (and optionally `studioMode`); consider a single root `NavigationStack` or per-tab `@SceneStorage` path if nested pushes are added.

---

## Navigation architecture map

1. **iOS root:** `QVoiceiOSRootView` → `RootView` + `@Environment(AppModel)`. Tab selection is `AppModel.tab` (`IOSAppTab`), not `TabView`.
2. **iOS tabs:** `RootView.activeScreen` switches four cases; each wraps its screen in a **new** `NavigationStack { … }` with hidden navigation bar (lines 108–129). No `NavigationPath`, no `.navigationDestination`, no `NavigationLink` in the iOS tree.
3. **iOS modals:** Global `sheet(item: $appModel.playerSheetItem)` and `fullScreenCover` onboarding on `RootView`; edge-to-edge `bottomPanelItem` / `deleteModelSheetItem` overlays (not system sheets). Child sheets (batch, save voice) use local `NavigationStack` inside sheet content only.
4. **iOS cross-tab routing:** `HistoryScreen`, `VoicesScreen`, and library views set `appModel.tab`, `studioMode`, and handoff drafts programmatically — coordinator-style, but not URL/deep-link driven.
5. **macOS Views:** Flat detail content only; **zero** `NavigationStack` / `NavigationLink` under `Sources/Views/`.
6. **macOS chrome (parent):** `ContentView` uses `NavigationSplitView` + `SidebarView` `List(selection:)`; selection persisted via `@AppStorage` (`QwenVoice.LastSelectedSidebarItem`). Keyboard/menu nav via `AppCommandRouter.sidebarSelection`.
7. **macOS modals in Views:** `sheet(item:)` on generation coordinators (`CustomVoiceView`, `VoiceDesignView`, `VoiceCloningView`) and library views (`HistoryView`, `VoicesView`).
8. **Deep links:** No `.onOpenURL`, no `CFBundleURLTypes` / universal links in `project.yml` or app entry (`QVoiceiOSApp`, `QwenVoiceApp`).
9. **State preservation:** macOS sidebar + voice-cloning saved-voice ID persisted; iOS onboarding flag only (`IOSAppDefaults.hasCompletedOnboarding`) — **not** last tab or studio mode.
10. **Tab/stack integration:** Custom `TabDock` is intentional (design-tinted dock); not `TabView` / `.sidebarAdaptable` (iPhone-first; iPad uses same chrome).

---

## Navigation health score

| Metric | iOS (`App/`) | macOS (`Views/` + `ContentView`) |
|--------|----------------|----------------------------------|
| Path coverage | 4 stacks, 0 with `path:` (0%) | 0 stacks in Views; split view = single detail plane |
| Destination coverage | 0 path types; 0 `.navigationDestination` | N/A (no stack pushes) |
| Deep link coverage | 0 handlers; 0 URL schemes | Menu/router only; 0 URL handlers |
| State preservation | Tab/mode: **no**; onboarding: **yes** | Sidebar: **yes** (`@AppStorage`) |
| Deprecated APIs | 0 deprecated `NavigationLink` | 0 in Views |
| Container correctness | `NavigationStack` as chrome wrapper (acceptable today) | Split view appropriate for macOS |
| **Health** | **FRAGILE** | **SOLID** (Views); app lacks URL deep links |

---

## Issues by severity

### CRITICAL — Deep link gaps (app-wide)

**File:** `Sources/iOS/QVoiceiOSApp.swift` (scene), `Sources/QwenVoiceApp.swift` (macOS)  
**Phase:** 2 + 3  
**Issue:** No `.onOpenURL` / `onContinueUserActivity` handlers and no registered URL schemes or universal links in project config.  
**Impact:** Widgets, notifications, marketing links, and Shortcuts cannot open Studio/History/Player or a specific generation.  
**Fix:** Register URL types in `project.yml` / Info.plist; add a small `AppRoute` parser and apply on `AppModel` (iOS) / `AppCommandRouter.navigate` (macOS):

```swift
// iOS — on RootView or WindowGroup
.onOpenURL { url in
    guard let route = AppRoute(url: url) else { return }
    switch route {
    case .tab(let tab): appModel.tab = tab
    case .studio(let mode): appModel.tab = .studio; appModel.studioMode = mode
    case .player(let id): appModel.playerSheetItem = .init(generationID: id)
    }
}
```

**Cross-auditor:** Pairs with **ux-flow-auditor** if deep links land on missing entities (deleted generation).

---

### CRITICAL — Deep links cannot drive stack (compound)

**File:** `Sources/iOS/App/RootView.swift:108-129`  
**Phase:** 4 (Missing NavigationPath + no URL routing)  
**Issue:** Even after adding `.onOpenURL`, there is no `NavigationPath` or typed destinations to push detail screens inside a tab.  
**Impact:** External URLs can only flip tabs/overlays, not restore multi-level in-tab navigation.  
**Fix:** Introduce `@State private var studioPath = NavigationPath()` (per tab or shared router) and `.navigationDestination(for: StudioRoute.self) { … }` before expanding IA beyond single-screen tabs.

---

### HIGH — iOS tab selection not restored after termination

**File:** `Sources/iOS/App/AppModel.swift:52`  
**Phase:** 3 (state restoration gap)  
**Issue:** `tab` defaults to `.studio` every cold launch; unlike macOS `persistedSidebarItem`.  
**Impact:** User working in History or Settings is returned to Studio after app kill.  
**Fix:** Persist in `IOSAppDefaults` or `@SceneStorage("ios.selectedTab")`:

```swift
// AppModel.init or property observer
var tab: IOSAppTab = IOSAppDefaults.lastTab ?? .studio {
    didSet { IOSAppDefaults.lastTab = tab }
}
```

---

### HIGH — Per-tab `NavigationStack` destroyed on tab switch

**File:** `Sources/iOS/App/RootView.swift:103-130`  
**Phase:** 3  
**Issue:** `switch appModel.tab` rebuilds only the active branch; inactive tabs’ stacks are torn down.  
**Impact:** Any future push/pop state inside a tab is lost when switching tabs; today mostly harmless because stacks are flat.  
**Fix:** Keep all four tab roots alive with `.opacity` / `ZStack` + hidden inactive tabs, or hoist one `NavigationStack` above the dock and drive content by `tab`.

---

### HIGH — No scene-level navigation persistence (iOS)

**File:** `Sources/iOS/App/AppModel.swift` (routing section)  
**Phase:** 2 (#7) + 3  
**Issue:** No `@SceneStorage` for `tab`, `studioMode`, or encoded path data.  
**Impact:** System relaunch loses navigation context beyond in-memory `AppModel` (drafts survive only while process lives).  
**Fix:** `@SceneStorage("vocello.tab")` + Codable backup for any future `NavigationPath` blob.

---

### HIGH — macOS: deep link parity vs menu routing

**File:** `Sources/ContentView.swift:280-282`, `Sources/Services/AppCommandRouter.swift:12-14`  
**Phase:** 3 (out of Views scope but affects product)  
**Issue:** `AppCommandRouter.navigate(to:)` covers sidebar screens for menus/shortcuts only; no URL entry point.  
**Impact:** macOS has good **internal** routing; external/universal links still missing.  
**Fix:** `QwenVoiceApp` `.onOpenURL` → parse → `appCommandRouter.navigate(to:)`.

---

### MEDIUM — Path-less `NavigationStack` (future debt)

**File:** `Sources/iOS/App/RootView.swift:108,114,120,126`  
**Phase:** 2 (#1) — **downgraded:** stacks currently wrap flat screens only (no `NavigationLink` in iOS).  
**Issue:** Four stacks omit `path:` binding.  
**Impact:** Blocks programmatic push and deep-link detail routes when IA adds settings sub-pages or library drill-down.  
**Fix:** `NavigationStack(path: $path) { … }.navigationDestination(for: …)`.

---

### MEDIUM — Overlapping modal surfaces (iOS)

**File:** `Sources/iOS/App/RootView.swift:85-97,170-194`  
**Phase:** 3 (modal/stack conflict)  
**Issue:** `playerSheetItem` (system sheet), `bottomPanelItem`, and `deleteModelSheetItem` (custom overlays) are independent; presenting player does not clear `bottomPanelItem` / focus backdrop.  
**Impact:** Possible stacked dimmers or sheet + custom panel confusion.  
**Fix:** Central `presentModal(_:)` on `AppModel` that dismisses other presentation channels first.

---

### MEDIUM — macOS sheets decentralized in Views

**File:** `Sources/Views/Generate/CustomVoiceView.swift:222`, `HistoryView.swift:172`, `VoicesView.swift:66`, etc.  
**Phase:** 2 (#9)  
**Issue:** Each feature owns `sheet(item:)` state locally.  
**Impact:** Hard to open batch/save-voice flows from a single deep-link router.  
**Fix:** Optional root presenter enum on `ContentView` (mirror iOS `AppModel.playerSheetItem`).

---

### MEDIUM — Custom `TabDock` vs `TabView` (iPad)

**File:** `Sources/iOS/App/TabDock.swift:5-7`  
**Phase:** 2 (#6)  
**Issue:** No `.tabViewStyle(.sidebarAdaptable)` — by design for phone dock spec.  
**Impact:** iPad does not get system sidebar-tab morphing; acceptable if intentional.  
**Fix:** Only if iPad IA should match macOS split patterns.

---

### LOW — Cross-tab routing scattered in screen shells

**File:** `Sources/iOS/History/HistoryScreen.swift:27-35`, `Sources/iOS/Voices/VoicesScreen.swift:27-41`  
**Phase:** 2 (#9)  
**Issue:** Tab/mode mutations live in thin screens, not a dedicated `AppRouter`.  
**Impact:** Maintainable today; grows brittle as routes multiply.  
**Fix:** `AppModel.route(to: .studioClone(handoff:))` helpers.

---

### LOW — macOS split visibility not explicit

**File:** `Sources/ContentView.swift:248-265` (parent of `SidebarView`)  
**Phase:** 2 (#10)  
**Issue:** No `@State var columnVisibility: NavigationSplitViewVisibility`.  
**Impact:** Cannot programmatically collapse sidebar for focused flows.  
**Fix:** Bind visibility on `NavigationSplitView` when needed.

---

## Positive patterns (no issue)

| Pattern | Location |
|---------|----------|
| `sheet(item:)` for player | `RootView.swift:88-97` |
| Central presentation state | `AppModel.playerSheetItem`, `bottomPanelItem` |
| macOS sidebar persistence | `ContentView.swift:126-127,395-404` |
| macOS menu navigation | `QwenVoiceApp.swift:63-92` → `AppCommandRouter` |
| Typed sheet configs | `SavedVoiceSheetConfiguration`, coordinator `presentedSheet` |
| No deprecated `NavigationLink(isActive:)` | Verified in scope |

---

## Recommendations

### Immediate (CRITICAL / compound)

1. Decide if URL/universal links are in scope; if yes, add Info.plist URL types and `.onOpenURL` on both platforms.
2. Add `AppRoute` mapping to `AppModel.tab` / `studioMode` / `playerSheetItem` (iOS) and `AppCommandRouter` (macOS).

### Short-term (HIGH)

3. Persist `IOSAppTab` (and optionally `studioMode`) across launches.
4. Document or fix tab-switch stack teardown before adding in-tab navigation.
5. Add mutual exclusion between player sheet and custom bottom overlays.

### Long-term

6. Introduce `NavigationPath` + destinations when adding drill-down screens.
7. Optional centralized sheet router on macOS Views for deep-link parity.
8. Revisit iPad `TabView` vs custom dock if platform parity becomes a goal.

---

## Audit metadata

- **Auditor:** swiftui-nav-auditor (Axiom)
- **Date:** 2026-05-26
- **Files scanned:** 3 (iOS App) + 21 (macOS Views); grep across `Sources/iOS/` for navigation symbols
- **Excluded:** `*Tests*`, `docs/`, `scratch/` (except this output), vendor paths
