import SwiftUI

enum LayoutConstants {
    static let contentMaxWidth: CGFloat = 940
    static let textEditorMaxHeight: CGFloat = 260
    static let sidebarWidth: CGFloat = 216
    static let canvasPadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 14
    static let compactGap: CGFloat = 10
    static let cardPadding: CGFloat = 10
    static let glassCardPadding: CGFloat = 16
    static let cardRadius: CGFloat = 13
    static let stageRadius: CGFloat = 20
    static let cardBorderWidth: CGFloat = 0.75
    static let controlHeight: CGFloat = 44
}

struct ContentColumnModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: LayoutConstants.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

extension View {
    func contentColumn() -> some View {
        modifier(ContentColumnModifier())
    }
}
