# Vocello macOS UI — Ground-Up Refactor (Design Spec)

## Context

The macOS app last received a major UI pass in commit `f55fc04` ("Implement Vocello Liquid Glass redesign"). Since then, a separate iOS reference design has matured (`/Users/patricedery/Downloads/Vocello/`) that defines the canonical Vocello brand language: V monogram, Cormorant Garamond wordmark, dark-canvas glass with warm hairlines, per-mode tints (Custom champagne / Design lavender / Clone peach / Library silver-gold / Settings silver), and a coherent component vocabulary (capsule segmented, animated waveform, mini player, voice orb, status chip).

The intent is to rebuild the macOS app around that brand language with a desktop-native layout — NOT a phone tab bar scaled up. The app must look intentional and uncramped at every supported window size, from 720p displays to 4K, and respect macOS Display scale settings.

The intended outcome is one unified refactor that lands on `main` as a coherent diff, replacing the chrome and per-screen visual treatment in a single coordinated change.

## Decisions Locked (from brainstorming)

1. **Theme intent**: macOS inherits iOS brand identity (V mark, Cormorant wordmark, dark canvas, glass surfaces, per-mode tints) and component primitives (waveform, mini player, status chip, capsule segmented, voice orb). Layout is desktop-native, not iOS-ported.
2. **Scope**: Single unified spec, full refactor in one go.
3. **Scaling constraint**: Must look excellent from 720p to 4K, across all macOS Display scale settings.
4. **Top-level navigation**: `NavigationSplitView` with a flat 4-row sidebar — **Home / Generate / Library / Settings**. Generate's three modes (Custom / Design / Clone) collapse from sidebar children into a top capsule **segmented control inside the Generate detail**. Library and Settings sub-tabs become in-pane segmented controls similarly.
5. **Home screen**: New landing screen above Generate (greeting, recent takes, three mode launchers, runtime/memory status). Default initial selection.
6. **Persistent player**: **Window-footer, full-width** glass strip across the bottom of the entire window (under sidebar + detail). Always visible across all four sections. Apple-Music / Spotify positioning, with iOS theming (per-mode tint, animated waveform, glass blur).
7. **Wide-window behavior**: **Hybrid by content type** — text editors and forms cap at ~720pt centered, grids fill width with auto-flowing columns, player footer is always full-bleed.
8. **Color modes**: **Dark only** for this refactor. Light mode is explicitly out of scope.
9. **Window chrome**: **Hidden titlebar**, content extends to top edge. Traffic lights inset into a glass top bar. Vocello wordmark anchors the top of the sidebar; screen title anchors the top of the detail pane.
10. **Type identity**: Cormorant Garamond serif for the wordmark and the H1 screen title at the top of each detail pane. Body text and controls remain SF Pro.
11. **Window sizing**: Min `1100×720`. Sidebar collapses to 64pt icon-only rail under 1100pt width. Below 900pt the sidebar can be hidden via toolbar toggle. Above 1400pt, sidebar expands to fully labeled state. Player footer is always full-width.
12. **Motion**: Restrained — animated waveform when playing, smooth segmented/tab transitions (180–240ms), gentle hover lift on cards, animated voice orb on Home. No ambient drift, no parallax. `Reduce Motion` accessibility setting honored throughout.

## Visual Token System

All tokens move into a new `Sources/Views/Components/VocelloTokens.swift` (or extend `AppTheme` in place — see Implementation Order below). Values mirror `Sources/iOS/IOSShellPrimitives.swift IOSBrandTheme` exactly so iOS and macOS share one brand truth.

### Mode tints (the visual spine)

| Token | Hex | Used for |
|---|---|---|
| `accent` (Custom) | `#EDCC8A` champagne gold | Custom Voice mode, primary CTA when in Custom |
| `design` | `#BFABDB` lavender | Voice Design mode |
| `clone` | `#DBA887` peach clay | Voice Cloning mode |
| `library` | `#BFBCB5` silver-gold | Library section chrome (History + Voices) |
| `settings` | `#ADB5C2` silver | Settings section chrome (Models + Preferences) |
| `purple` | `#BAA8D6` | V mark gradient back |
| `lavender` | `#DED1ED` | V mark gradient front |
| `healthy` / `guarded` / `critical` | `#8CB38C` / `#D9B373` / `#D98080` | Status chip dot |

### Surfaces

| Token | Value | Used for |
|---|---|---|
| `canvas` | `#0A0B0D` | Window background base |
| `deepNav` | `#0F1115` | Beneath canvas in vignettes |
| `surface` | `rgba(36,38,46, 0.86)` | Glass card fill |
| `surfaceMuted` | `rgba(46,48,56, 0.74)` | Recessed/secondary glass |
| `inputFill` | `#1C1E26` | Solid editor surfaces (text editors, file drops) |
| `tabBar` | `rgba(20,22,28, 0.93)` | Window-footer player chrome, top glass bar |
| `surfaceStroke` | `rgba(247,235,209, 0.10)` | Universal warm 0.5pt hairline |
| `inputStroke` | `rgba(245,235,209, 0.12)` | Editor surface strokes |

### Material recipes

- **Glass card**: `surface` fill + `0.5pt surfaceStroke` border + `glassEffect(.regular)` + `glass3DDepth(intensity: 1.0)`. Radius **22pt**.
- **Inline panel** (in-card sub-surface): `surfaceMuted` fill + same stroke. Radius **16pt**.
- **Mode-tinted glass card**: same recipe, with `cardGlassTint` env set to the mode color → tint resolves via `surfaceGlassTint(color, scheme)` (~14% alpha) and stroke via `accentStroke(color, scheme)` (~34% alpha).
- **Footer/chrome glass**: `tabBar` fill + stronger blur (`saturate 180%`).
- **Editor input**: `inputFill` solid + `inputStroke` 0.5pt. Radius **18pt**.

### Type

| Role | Font | Size | Weight |
|---|---|---|---|
| Wordmark | Cormorant Garamond | 23pt | 700 |
| H1 screen title | Cormorant Garamond | 32pt | 700, tracking -0.6 |
| H2 section heading | SF Pro Display | 17pt | 600 |
| Body | SF Pro Text | 14pt | 400/500 |
| Caption / metadata | SF Pro Text | 12pt | 500 |
| Label (uppercase) | SF Pro Text | 11pt | 600, tracking +1.4, uppercased |
| Button label | SF Pro Text | 14–16pt | 600/700, tracking -0.1 |

The H1 serif size scales via `@ScaledMetric` so it honors macOS accessibility text scaling without breaking layout. All other text is `Font` literals (no `@ScaledMetric`) — chrome stays predictable; if a user picks a larger Display scale, the OS handles pt→px scaling at the rendering layer.

### Radii / spacing

`radii = { input 18, card 22, inlinePanel 16, capsule 999, primaryCTA 32 }`. `spacing = { 4, 8, 12, 16, 22, 32 }` (8pt base). These get exposed as `LayoutConstants` extensions so existing constants stay backwards-compatible during the transition.

### Motion

| Animation | Duration | Curve |
|---|---|---|
| Segmented active swap | 200ms | `easeInOut` |
| Sidebar selection / hover | 140ms | `easeOut` |
| Card hover lift | 160ms | `easeOut` |
| Footer player tint change | 240ms | `easeInOut` |
| Waveform bar animation | 0.5–0.7s | spline `0.4 0 0.6 1` |
| Voice orb conic rotation | 14s linear | infinite |

All animations gated through `AppLaunchConfiguration.current.animation(...)` (existing `.appAnimation` extension), which already respects `Reduce Motion` and the test-mode flag.

## Layout Shell

### Window

- `NSWindow` style: `.hiddenTitleBar` + `.fullSizeContentView` + `titlebarAppearsTransparent = true`. Configured via existing `WindowChromeConfigurator`.
- Background: `VocelloStudioBackground` gradient (existing) re-tinted to true dark canvas (#0A0B0D → #06070A vertical) plus warm/lavender bloom radials at top-right and bottom-left (matching the iOS device frame).
- Min size: `1100×720`. Saved size restored from `NSWindow` defaults.

### Top glass bar (over sidebar + detail)

- Height: `44pt`. Glass material (tabBar fill + 24pt blur saturate 180%).
- Left third: traffic lights inset (system-positioned, no overlay needed).
- Center/right: optional contextual toolbar items (existing `MainWindowToolbar` content moves here — search field for History, "Add Voice Sample" for Voices, sort menu).

### Sidebar

- New flat structure (replaces current 3-section nested):
  ```
  Home
  Generate
  Library
  Settings
  ```
- `SidebarItem` enum collapses from 6 cases to 4. The current `customVoice / voiceDesign / voiceCloning / history / voices / models` cases survive as **child** enums (e.g., `GenerateMode.{custom,design,clone}`, `LibraryTab.{history,voices}`, `SettingsTab.{models,preferences}`) used inside each detail pane.
- Brand header at the top: V mark + Cormorant "Vocello" + small "AI-TTS" mark — replaces current `SidebarBrandHeader`. Lives in `safeAreaInset(.top)` so it stays anchored.
- Row treatment: 22pt radius pills, mode-tint when selected (per-row tint resolved via `AppTheme.sidebarColor(for:)`), 1pt warm stroke on selected, glass effect with `interactive()` on hover.
- Width: `navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)` at full state. Below 1100pt window width the sidebar binds to `.compact` (icon-only 64pt rail) via `navigationSplitViewVisibility`. Below 900pt the sidebar can be hidden via toolbar toggle.
- No more sidebar-footer player or sidebar-footer status — both move to the global window footer.
- Sidebar-footer status chip (memory/healthy) becomes a subtle bottom-of-sidebar pill, ~32pt tall, matching the iOS `VHeader` chip pattern.

### Detail pane

- One persistent shell that hosts the active screen.
- Each screen owns its own H1 (Cormorant 32pt) at the top, plus the in-pane segmented control for sub-sections.
- Content scrolls vertically inside the detail; the footer player is OUTSIDE the scroll region.
- Forms/editors get `.contentColumn(maxWidth: 720)` (centered with breathing room). Grids use `.frame(maxWidth: .infinity)` with adaptive `LazyVGrid(columns: [.adaptive(minimum: 220, maximum: 320)])`.

### Window-footer player

- New file: `Sources/Views/Components/WindowFooterPlayer.swift`.
- Full window width, fixed height **76pt** at default scale (becomes 64pt below 900pt window height).
- Material: glass `tabBar` fill + 24pt blur, top hairline only (no bottom — sits on window edge).
- Three regions:
  - **Left** (240pt fixed): play/pause disc (44pt circle, mode-tinted gradient when ready), then take title + subtitle (mode label · duration · sample rate). Truncates with ellipsis at narrow widths.
  - **Center** (flex): scrubable animated waveform. At 720p widths, ~400pt wide; at 4K, expands to fill but caps at 1200pt centered. Mode-tinted; played/unplayed split.
  - **Right** (180pt fixed): Take number badge, Download button, Ellipsis (more actions).
- States: idle (no audio yet — muted, "Latest take will appear here"), generating (orbit spinner), ready, playing.
- Replaces both `SidebarPlayerView` and the current `SidebarFooterRegion`. `AudioPlayerViewModel` continues to drive it.

## Responsive Scaling Strategy

### Breakpoints

| Window width | Behavior |
|---|---|
| `< 900pt` | Sidebar hidden by default (toggle in toolbar). Detail uses full window width. Footer player drops to 64pt height with compact layout (waveform shrinks, badges hidden). |
| `900–1099pt` | Sidebar in icon-only `.compact` mode (64pt rail). Labels appear on hover/tooltip. |
| `1100–1399pt` | Sidebar full but at `min: 240`. Detail forms cap at 720pt centered. Grids use 2-3 columns. |
| `1400–1919pt` | Sidebar at `ideal: 280`. Forms still cap at 720pt. Grids 3-4 columns. |
| `≥ 1920pt` | Sidebar at `max: 320`. Forms cap at 720pt with extra side padding. Grids 4-6 columns. Footer player center waveform caps at 1200pt centered. |

### Display scale settings

- macOS Display scale ("Larger Text", "Default", "More Space") changes the rendering scale at the OS level. All point-based values automatically follow.
- The H1 serif uses `@ScaledMetric` so it additionally respects accessibility text size.
- All grids use `LazyVGrid(columns: [GridItem(.adaptive(minimum: X))])` so column count adjusts naturally to scale + window width.
- Min window size (1100×720) is chosen so even at "Larger Text" scale on a 1280×800 panel, the app remains usable (the OS quantizes 1280 → ~1024pt at largest scale, which still clears our 900pt fallback breakpoint).

### Scrolling

- Detail pane scrolls vertically (each screen is its own `ScrollView`).
- Sidebar scrolls vertically when content exceeds height (rare with 4 items).
- Footer player NEVER scrolls — it's a fixed window inset.
- No horizontal scrolling anywhere.

## Per-Screen Designs

### Home (NEW)

`Sources/Views/Home/HomeView.swift`. Mirrors `lib/screen-home.jsx` but desktop-laid-out.

- H1: "Good <time-of-day>" + Cormorant gradient line: "What should we voice today?" (champagne→lavender→peach gradient).
- **Hero card** (full-width within content cap of 1040pt): voice orb (animated conic gradient, 96pt) + tagline + a script-prompt input that on click navigates to Generate with focus in the editor.
- **Three mode launchers** (3-column grid, each card 240–320pt wide, mode-tinted): Choose Voice (Custom) / Describe Voice (Design) / Use Reference (Clone). Click navigates to Generate and pre-selects the mode segment.
- **Recent takes** card (full-width up to 1040pt cap): list of last 5 takes (title, mode chip, duration, when, mini waveform). "See all" link routes to Library/History.
- **Runtime status pill** at the bottom: model name, memory loaded, hardware identifier. Matches the iOS `VHeader` chip palette but laid out horizontally for the wider canvas.

### Generate

`Sources/Views/Generate/GenerateView.swift` (NEW host) — replaces direct routing to `CustomVoiceView` / `VoiceDesignView` / `VoiceCloningView`.

- Top: H1 "Generate" (Cormorant) + capsule segmented control (Custom / Design / Clone), each segment tinted with its mode color when active.
- Body: switches between three sub-views based on segment. Each sub-view keeps its current responsibility (drafts, generation runner, etc.) but receives a refreshed visual treatment via the new tokens.
- Forms cap at 720pt centered. Voice/emotion picker grids use adaptive columns.
- The current per-screen "Generate" CTA button becomes redundant — the bottom strip below the editor still has a primary CTA, but a duplicate "Create" is also pinned in the footer player while in idle state (matching iOS embedded CTA pattern). Pressing either triggers generation; the footer CTA is hidden once the take is ready.
- Existing files affected: `CustomVoiceView.swift`, `VoiceDesignView.swift`, `VoiceCloningView.swift` keep their inner content but lose their own H1/title chrome (now owned by `GenerateView`).

### Library

`Sources/Views/Library/LibraryView.swift` (NEW host).

- Top: H1 "Library" (Cormorant) + capsule segmented (History / Voices), tinted with `library` silver-gold.
- Body: switches between `HistoryView` and `VoicesView`. Both remain in their existing files but lose the per-screen H1.
- History: list of takes (already present), now styled with new card recipe. Search field and sort menu live in the top glass bar (already wired via `MainWindowToolbar`).
- Voices: grid layout (`adaptive(minimum: 240)`) of saved voice cards, each with the voice's tint chip. "Add Voice Sample" button stays in the top glass bar.

### Settings

`Sources/Views/Settings/SettingsView.swift` (NEW host).

- Top: H1 "Settings" (Cormorant) + capsule segmented (Models / Preferences), tinted with `settings` silver.
- Body: switches between `ModelsView` and `PreferencesView`.
- This **replaces** the current pattern where `Models` is a sidebar item and `Preferences` is a separate `Settings` scene opened via `Cmd+,`. The system Settings scene at `QwenVoiceApp.swift:settingsScene` either:
  - **Option A (preferred)**: keeps the system Settings scene in place but routes `Cmd+,` to the in-app Settings sidebar item via `appCommandRouter.sidebarSelection.send(.settings)`. The system scene becomes a thin wrapper that just opens the main window on Settings.
  - **Option B**: deletes the system Settings scene; `Cmd+,` selects the Settings sidebar item directly.
  - Decision deferred to implementation; either is consistent with the spec.

## Files to Create / Modify

### New files

- `Sources/Views/Home/HomeView.swift`
- `Sources/Views/Home/VoiceOrb.swift`
- `Sources/Views/Home/RecentTakesCard.swift`
- `Sources/Views/Generate/GenerateView.swift` (host)
- `Sources/Views/Library/LibraryView.swift` (host)
- `Sources/Views/Settings/SettingsView.swift` (host)
- `Sources/Views/Components/WindowFooterPlayer.swift`
- `Sources/Views/Components/VocelloSegmentedControl.swift`
- `Sources/Views/Components/VocelloStatusChip.swift`
- `Sources/Views/Components/VocelloVMark.swift` (Swift port of the SVG monogram)
- `Sources/Views/Components/CormorantTitle.swift` (font helper + H1 modifier)
- `Sources/Views/Sidebar/TopGlassBar.swift` (the 44pt glass bar across the top, holding traffic-light inset + contextual toolbar)

### Heavily modified

- `Sources/Views/Components/AppTheme.swift` — port iOS exact hex values; add the new tokens listed above; keep existing modifiers but retire the duplicated `vocelloGold/Lavender/Terracotta` aliases now that mode tokens are canonical.
- `Sources/Views/Components/LayoutConstants.swift` — refresh radii (22 / 18 / 16), spacing scale, footer-player heights, breakpoint constants.
- `Sources/Views/Sidebar/SidebarView.swift` — flatten `SidebarItem` from 6 cases to 4 (`home`, `generate`, `library`, `settings`); replace nested-section structure; remove `SidebarFooterRegion` (moves to global footer); add new brand header.
- `Sources/ContentView.swift` — top-level layout becomes `VStack { TopGlassBar; NavigationSplitView { Sidebar } detail { Detail }; WindowFooterPlayer }` (or equivalent overlay topology). Sidebar selection state becomes a 4-value enum; per-screen sub-state (mode, library tab, settings tab) persists per-screen.
- `Sources/QwenVoiceApp.swift` — register `WindowChromeConfigurator` to apply hidden titlebar + full-size content; route `Cmd+,` per the Settings decision above.
- `Sources/Views/Generate/CustomVoiceView.swift`, `VoiceDesignView.swift`, `VoiceCloningView.swift` — remove top-level page chrome (H1, mode tint backdrop) which now belongs to `GenerateView`. Internal forms keep their existing structure but adopt the new card recipe via `.studioCard(...)` (already aliased; tokens behind it change).
- `Sources/Views/Library/HistoryView.swift`, `VoicesView.swift` — remove top-level page chrome.
- `Sources/Views/Settings/ModelsView.swift`, `PreferencesView.swift` — remove top-level page chrome.
- `Sources/Views/Components/SidebarPlayerView.swift` — DELETE (replaced by `WindowFooterPlayer`).
- `Sources/Views/Components/SidebarStatusView.swift` — RELOCATE its memory/healthy chip to a sidebar-bottom pill; the engine-error inline messaging moves into the footer player's left region as an overlay banner.
- `Sources/Views/Components/WindowChromeConfigurator.swift` — set `titleVisibility = .hidden`, `titlebarAppearsTransparent = true`, `styleMask.insert(.fullSizeContentView)`, `isMovableByWindowBackground = true`, `minSize = NSSize(1100, 720)`.

### Untouched (functional code stays as-is)

- `Sources/Services/*`, `Sources/Models/*`, all generation runners, audio service, database, MLX integration — none of this is visual.
- `Sources/QwenVoiceCore`, engine service, native runtime — engine layer is unchanged.
- `Sources/iOS/*` — out of scope. iOS keeps its existing shell.
- `Sources/Views/Components/GenerationWorkflowView.swift`, `WaveformView.swift`, `TextInputView.swift`, `EmotionPickerView.swift`, `ContinuousVoiceDescriptionField.swift`, `BatchGenerationSheet.swift`, `FlowLayout.swift` — internal generation UI, kept but re-skinned via the token swap (no structural changes needed).

## Implementation Order Within the Unified Refactor

Even though this lands as one coherent diff, the work proceeds in this order to keep each interim build green:

1. **Token foundation** — port iOS exact hex values into `AppTheme.swift`; add new constants to `LayoutConstants.swift`; create `CormorantTitle.swift` font helper. Build still passes; existing screens slightly recolor.
2. **New shared components** — `VocelloVMark`, `VocelloSegmentedControl`, `VocelloStatusChip`, `WindowFooterPlayer`, `TopGlassBar`. Built against tokens from step 1, not yet wired into the shell.
3. **Window chrome** — update `WindowChromeConfigurator` for hidden titlebar, set min size, configure the top glass bar. Sidebar still has its old 6-row structure at this point; build passes.
4. **Sidebar flatten** — collapse `SidebarItem` to 4 cases. Each renamed item routes to a new host (`HomeView`, `GenerateView`, `LibraryView`, `SettingsView`). Hosts initially just embed the existing per-screen views with no segmented control. Test plans (`tests/Plans/*.xctestplan`) updated to use the new accessibility identifiers (`screen_home`, `screen_generate`, `screen_library`, `screen_settings` plus per-tab IDs like `generate_tab_custom`).
5. **Per-host segmented controls** — add the in-pane segmented control to `GenerateView`, `LibraryView`, `SettingsView`. Existing per-mode H1 chrome removed from inner views.
6. **Footer player wired in** — `WindowFooterPlayer` becomes the top-level view inset; `SidebarFooterRegion` and `SidebarPlayerView` deleted; sidebar bottom shows only the new compact status pill.
7. **Home screen built** — `HomeView`, `VoiceOrb`, `RecentTakesCard`. Recent takes pulls from existing history database via `HistoryView`'s data source.
8. **Visual QA pass** — manual sweep at 1100×720, 1440×900, 1920×1200, 2560×1440, 3840×2160; at each macOS Display scale setting on a 1440×900 panel; with `Reduce Motion` on.

## Verification

### Code gates (must pass before claiming done)

```bash
./scripts/check_project_inputs.sh
python3 scripts/harness.py validate
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios            # iPhone target must stay compile-green
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer e2e
```

### Visual QA matrix (manual, on the controlled Mac)

For each of these window sizes — `1100×720`, `1440×900`, `1920×1200`, `2560×1440`, `3840×2160` — verify:
- Sidebar sits at the expected breakpoint state (full / icon-only / hidden).
- Top glass bar renders without gaps next to the traffic lights.
- Forms (Generate text editor, Voice Cloning script) cap at 720pt and look centered, not cramped.
- Library voices grid shows the expected adaptive column count (3 at 1440, 4 at 1920, 5–6 at 2560+).
- Footer player center waveform caps at 1200pt at 4K, fills width below.
- H1 serif renders without truncation at all widths.

For each macOS Display scale on a 1440×900 panel — `Larger Text`, `Default`, `More Space` — verify:
- App opens to a usable size (≥ 1100pt effective width after scaling).
- No clipping in sidebar rows, segmented controls, footer player.
- Text remains legible (no sub-11pt rendered text).

For accessibility — with `Reduce Motion` on:
- Voice orb conic rotation is replaced by a static gradient.
- Waveform animation collapses to a static played/unplayed split.
- Segmented active swap is instant (no slide).

### Test-plan changes

- `tests/Plans/QwenVoiceSource.xctestplan` and `QwenVoiceRuntime.xctestplan` — accept renamed accessibility identifiers (`screen_home`, `screen_generate`, etc.). Update XCUITest path expectations.
- `tests/Plans/VocelloUISmoke.xctestplan` — exercise the new sidebar 4-row navigation + at least one segmented control change inside Generate.

### Rollback

- Single `git revert` of the merged commit returns the app to the current Liquid Glass shell. Token swap is mechanical so a forward-fix is preferred over revert if a regression surfaces.

## Files Critical to Read Before Implementing

- `Sources/Views/Components/AppTheme.swift` (token surface area; existing helpers must keep working)
- `Sources/Views/Sidebar/SidebarView.swift` + `Sources/ContentView.swift` (current shell topology)
- `Sources/Views/Components/LayoutConstants.swift` (sizing primitives)
- `Sources/Views/Components/WindowChromeConfigurator.swift` (window styling entry point)
- `Sources/iOS/IOSShellPrimitives.swift` (`IOSBrandTheme` — canonical token source)
- `Sources/QwenVoiceApp.swift` (settings-scene wiring decision)
- `tests/Plans/*.xctestplan` (accessibility identifiers under test)
- Reference: `/Users/patricedery/Downloads/Vocello/lib/{vocello-tokens,vocello-chrome,screen-home,screen-generate,screen-library-settings,vocello-icons}.jsx` (canonical visual source)
