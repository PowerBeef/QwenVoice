import SwiftUI

/// Cormorant Garamond is the Vocello brand serif, used for the wordmark and
/// the H1 screen title at the top of each detail pane. macOS does not ship
/// Cormorant in its system font catalog; `Font.custom` silently falls back
/// to the system serif (Charter) when the font isn't installed. Bundling
/// the font as an app resource is a planned follow-up.
enum VocelloTitleStyle {
    /// Sidebar brand-header wordmark size.
    static let wordmarkSize: CGFloat = 23
    /// Detail-pane H1 screen-title size.
    static let h1Size: CGFloat = 32
}

extension Font {
    static func vocelloSerif(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        Font.custom("Cormorant Garamond", size: size).weight(weight)
    }

    static var vocelloWordmark: Font {
        vocelloSerif(VocelloTitleStyle.wordmarkSize, weight: .bold)
    }

    static var vocelloH1: Font {
        vocelloSerif(VocelloTitleStyle.h1Size, weight: .bold)
    }
}

private struct VocelloH1Modifier: ViewModifier {
    @ScaledMetric private var scaledSize: CGFloat = VocelloTitleStyle.h1Size

    func body(content: Content) -> some View {
        content
            .font(.vocelloSerif(scaledSize, weight: .bold))
            .tracking(-0.6)
            .foregroundStyle(AppTheme.textPrimary)
    }
}

private struct VocelloWordmarkModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.vocelloWordmark)
            .tracking(-0.5)
            .foregroundStyle(AppTheme.textPrimary)
    }
}

extension View {
    func vocelloH1() -> some View {
        modifier(VocelloH1Modifier())
    }

    func vocelloWordmark() -> some View {
        modifier(VocelloWordmarkModifier())
    }
}
