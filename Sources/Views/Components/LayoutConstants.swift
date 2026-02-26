import SwiftUI

enum LayoutConstants {
    static let contentMaxWidth: CGFloat = 700
    static let textEditorMaxHeight: CGFloat = 300
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
