import SwiftUI

/// 44pt glass strip across the top of the window that pairs with
/// `WindowChromeConfigurator`'s hidden-titlebar configuration. Provides a
/// glass background that the OS-positioned traffic lights inset cleanly into
/// (left third), with room on the right for contextual toolbar content.
///
/// This view is intentionally minimal — it carries no controls of its own.
/// Per-screen toolbar items continue to live in SwiftUI's `.toolbar` modifier
/// inside `ContentView`; the OS renders them above this glass bar via the
/// `.fullSizeContentView` style mask.
struct TopGlassBar: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: LayoutConstants.topGlassBarHeight)
            .background {
                Rectangle()
                    .fill(AppTheme.railBackground.opacity(colorScheme == .dark ? 0.62 : 0.85))
                    .background(.ultraThinMaterial)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(AppTheme.railStroke.opacity(colorScheme == .dark ? 0.85 : 0.30))
                            .frame(height: 0.5)
                    }
            }
            .ignoresSafeArea(edges: [.top, .horizontal])
            .accessibilityHidden(true)
    }
}
