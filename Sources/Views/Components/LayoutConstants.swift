import SwiftUI

enum LayoutConstants {
    static let contentMaxWidth: CGFloat = 1040
    static let generationContentMaxWidth: CGFloat = 1280
    static let textEditorMaxHeight: CGFloat = 360
    static let sidebarWidth: CGFloat = 200
    static let shellPadding: CGFloat = 12
    static let canvasPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 14
    static let generationSectionSpacing: CGFloat = 14
    static let generationShellSpacing: CGFloat = 18
    static let pageHeaderSpacing: CGFloat = 8
    static let compactGap: CGFloat = 8
    static let configurationPanelPadding: CGFloat = 12
    static let configurationRowVerticalPadding: CGFloat = 8
    static let configurationRowSpacing: CGFloat = 8
    static let generationConfigurationPanelPadding: CGFloat = 10
    static let generationConfigurationRowVerticalPadding: CGFloat = 6
    static let generationConfigurationRowSpacing: CGFloat = 6
    // Calibrated to fit the standard Voice Cloning active-reference state
    // without clipping, while avoiding extra slack on the shorter generation screens.
    static let generationConfigurationSlotHeight: CGFloat = 214
    static let configurationLabelWidth: CGFloat = 92
    static let configurationControlMinWidth: CGFloat = 160
    static let workflowPrimaryMinWidth: CGFloat = 620
    static let workflowSecondaryMinWidth: CGFloat = 280
    static let workflowSecondaryIdealWidth: CGFloat = 340
    static let workflowSecondaryMaxWidth: CGFloat = 380
    static let cardPadding: CGFloat = 12
    static let glassCardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 12
    static let stageRadius: CGFloat = 22
    static let cardBorderWidth: CGFloat = 0.75
    static let controlHeight: CGFloat = 41

    // MARK: - Vocello brand-refresh constants
    //
    // Added during the macOS UI ground-up refactor (spec at
    // docs/superpowers/specs/2026-04-24-vocello-macos-redesign-design.md).
    // Lives alongside the legacy constants above so existing call sites stay
    // green; new chrome wires through these instead. Old names are migrated
    // off in later steps of the refactor.

    /// Card radius matching the iOS reference (replaces the legacy 12pt
    /// cardRadius once all callers have been switched).
    static let brandCardRadius: CGFloat = 22
    /// Recessed in-card sub-surface radius (e.g., editor inside a stage card).
    static let brandInlinePanelRadius: CGFloat = 16
    /// Solid editor surface radius (text editors, file drops).
    static let brandEditorRadius: CGFloat = 18
    /// Primary-CTA radius (Generate button).
    static let brandPrimaryCTARadius: CGFloat = 32

    /// Hidden-titlebar glass top bar that holds traffic-light inset +
    /// contextual toolbar items.
    static let topGlassBarHeight: CGFloat = 44
    /// Default-height window-footer player.
    static let footerPlayerHeight: CGFloat = 76
    /// Compact-height footer player below 900pt window height.
    static let footerPlayerCompactHeight: CGFloat = 64
    /// Maximum width of the footer player's center waveform region (caps it
    /// at 4K windows so it doesn't stretch into a thin line).
    static let footerPlayerCenterMaxWidth: CGFloat = 1200

    /// Sidebar brand-header height (V mark + Cormorant wordmark).
    static let sidebarBrandHeaderHeight: CGFloat = 64

    /// Comfortable centered-form column width — used for text editors and
    /// other form-shaped content so they don't stretch at 4K. Grids and
    /// galleries continue to fill available width.
    static let formContentMaxWidth: CGFloat = 720

    // MARK: - Responsive breakpoints

    /// Below this width the sidebar collapses out of view (toolbar toggle).
    static let sidebarHideBreakpoint: CGFloat = 900
    /// Below this width the sidebar uses a compact-rail presentation.
    static let sidebarCompactBreakpoint: CGFloat = 1100
    /// Below this width the sidebar uses its `min` column width.
    static let sidebarIdealBreakpoint: CGFloat = 1400
    /// Below this width the sidebar uses its `ideal` column width;
    /// above it, the `max` column width.
    static let sidebarMaxBreakpoint: CGFloat = 1920
    static let composerDefaultMinHeight: CGFloat = 252
    static let composerEmbeddedMinHeight: CGFloat = 268
    static let composerEmbeddedSpacing: CGFloat = 14
    static let composerEmbeddedEditorInset: CGFloat = 10
    static let composerEmbeddedPlaceholderHorizontalPadding: CGFloat = 12
    static let composerEmbeddedPlaceholderVerticalPadding: CGFloat = 12
    static let generationComposerFooterMinHeight: CGFloat = 84
    static let generationPageTopPadding: CGFloat = 10
    static let generationPageBottomPadding: CGFloat = 14
    static let studioHeaderSpacing: CGFloat = 12
    static let studioInspectorWidth: CGFloat = 348
    static let studioStageMinWidth: CGFloat = 620
    static let studioTransportHeight: CGFloat = 58
}

struct ContentColumnModifier: ViewModifier {
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

extension View {
    func contentColumn(maxWidth: CGFloat = LayoutConstants.contentMaxWidth) -> some View {
        modifier(ContentColumnModifier(maxWidth: maxWidth))
    }
}
