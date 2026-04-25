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
