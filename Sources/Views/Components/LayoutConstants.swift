import SwiftUI

enum LayoutConstants {
    static let contentMaxWidth: CGFloat = 960
    static let generationContentMaxWidth: CGFloat = 980
    static let textEditorMaxHeight: CGFloat = 360
    static let sidebarWidth: CGFloat = 200
    static let shellPadding: CGFloat = 12
    static let canvasPadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 12
    static let generationShellSpacing: CGFloat = 14
    static let pageHeaderSpacing: CGFloat = 8
    static let compactGap: CGFloat = 8
    static let configurationPanelPadding: CGFloat = 12
    static let configurationRowVerticalPadding: CGFloat = 8
    static let configurationRowSpacing: CGFloat = 8
    static let configurationLabelWidth: CGFloat = 92
    static let configurationControlMinWidth: CGFloat = 160
    static let workflowPrimaryMinWidth: CGFloat = 360
    static let workflowSecondaryMinWidth: CGFloat = 200
    static let workflowSecondaryIdealWidth: CGFloat = 268
    static let workflowSecondaryMaxWidth: CGFloat = 320
    static let cardPadding: CGFloat = 12
    static let glassCardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 16
    static let stageRadius: CGFloat = 22
    static let cardBorderWidth: CGFloat = 0.75
    static let controlHeight: CGFloat = 41
    static let composerDefaultMinHeight: CGFloat = 252
    static let composerEmbeddedMinHeight: CGFloat = 220
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
