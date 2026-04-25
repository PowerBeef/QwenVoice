import SwiftUI

struct IOSStudioShellScreen<Accessory: View, Content: View, BottomAccessory: View>: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel

    @Binding var selectedTab: IOSAppTab

    let activeTab: IOSAppTab
    let tint: Color
    let topAccessoryContent: Accessory
    let bottomAccessoryContent: BottomAccessory
    let screenContent: Content
    let showsBottomAccessory: Bool

    @ScaledMetric(relativeTo: .body) private var horizontalPadding = 16
    @ScaledMetric(relativeTo: .body) private var topPadding = 2
    @ScaledMetric(relativeTo: .body) private var contentSpacing = 10
    @ScaledMetric(relativeTo: .body) private var bottomAccessoryTopPadding = 12

    init(
        selectedTab: Binding<IOSAppTab>,
        activeTab: IOSAppTab,
        tint: Color,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder bottomAccessory: () -> BottomAccessory,
        @ViewBuilder content: () -> Content
    ) {
        _selectedTab = selectedTab
        self.activeTab = activeTab
        self.tint = tint
        self.topAccessoryContent = accessory()
        self.bottomAccessoryContent = bottomAccessory()
        self.screenContent = content()
        self.showsBottomAccessory = true
    }

    var body: some View {
        ZStack {
            IOSScreenBackdrop()

            VStack(alignment: .leading, spacing: contentSpacing) {
                IOSStudioShellCanopy(
                    accessory: topAccessoryContent
                )

                screenContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if showsBottomAccessory {
                    bottomAccessoryContent
                        .frame(maxWidth: .infinity)
                        .padding(.top, bottomAccessoryTopPadding)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            IOSStudioRootDock(selectedTab: $selectedTab, tint: tint)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if audioPlayer.isShowingNowPlayingRail {
                IOSGlobalNowPlayingRail()
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(IOSSelectionMotion.miniPlayerSlide, value: audioPlayer.isShowingNowPlayingRail)
        .toolbar(.hidden, for: .navigationBar)
    }
}

extension IOSStudioShellScreen where Accessory == EmptyView {
    init(
        selectedTab: Binding<IOSAppTab>,
        activeTab: IOSAppTab,
        tint: Color,
        @ViewBuilder bottomAccessory: () -> BottomAccessory,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            selectedTab: selectedTab,
            activeTab: activeTab,
            tint: tint,
            accessory: { EmptyView() },
            bottomAccessory: bottomAccessory,
            content: content
        )
    }
}

extension IOSStudioShellScreen where BottomAccessory == EmptyView {
    init(
        selectedTab: Binding<IOSAppTab>,
        activeTab: IOSAppTab,
        tint: Color,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        _selectedTab = selectedTab
        self.activeTab = activeTab
        self.tint = tint
        self.topAccessoryContent = accessory()
        self.bottomAccessoryContent = EmptyView()
        self.screenContent = content()
        self.showsBottomAccessory = false
    }
}

extension IOSStudioShellScreen where Accessory == EmptyView, BottomAccessory == EmptyView {
    init(
        selectedTab: Binding<IOSAppTab>,
        activeTab: IOSAppTab,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) {
        _selectedTab = selectedTab
        self.activeTab = activeTab
        self.tint = tint
        self.topAccessoryContent = EmptyView()
        self.bottomAccessoryContent = EmptyView()
        self.screenContent = content()
        self.showsBottomAccessory = false
    }
}

private struct IOSStudioShellCanopy<Accessory: View>: View {
    let accessory: Accessory

    @ScaledMetric(relativeTo: .body) private var verticalPadding = 0
    @ScaledMetric(relativeTo: .body) private var canopyHeight = 34

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            IOSProductTitleLockup(title: IOSBrandTheme.productName)
                .layoutPriority(1)

            Spacer(minLength: 10)

            accessory
        }
        .padding(.vertical, verticalPadding)
        .frame(minHeight: canopyHeight, maxHeight: canopyHeight, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IOSStudioWorkspaceHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title2.weight(.semibold))
            .foregroundStyle(IOSAppTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct IOSStudioRootDock: View {
    @Binding var selectedTab: IOSAppTab

    let tint: Color

    @ScaledMetric(relativeTo: .body) private var horizontalPadding = 16
    @ScaledMetric(relativeTo: .body) private var topPadding = 8
    @ScaledMetric(relativeTo: .body) private var bottomPadding = 10
    @ScaledMetric(relativeTo: .body) private var dockSpacing = 12
    @ScaledMetric(relativeTo: .body) private var railPadding = 8
    @ScaledMetric(relativeTo: .body) private var railRadius = 30

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(IOSAppTab.allCases) { tab in
                    IOSStudioRootDockButton(
                        tab: tab,
                        isSelected: selectedTab == tab,
                        action: {
                            guard tab != selectedTab else { return }
                            selectedTab = tab
                        }
                    )
                }
            }
            .padding(railPadding)
            .frame(maxWidth: .infinity)
            .iosDockGlass(tint: tint, cornerRadius: railRadius)
            .sensoryFeedback(.selection, trigger: selectedTab)
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
            .padding(.bottom, bottomPadding)
        }
        .background(
            LinearGradient(
                colors: [
                    IOSBrandTheme.canvasBottom.opacity(0),
                    IOSBrandTheme.canvasBottom.opacity(0.88),
                    IOSBrandTheme.canvasBottom
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }
}

private struct IOSStudioRootDockButton: View {
    let tab: IOSAppTab
    let isSelected: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .footnote) private var verticalPadding = 10
    @ScaledMetric(relativeTo: .footnote) private var horizontalPadding = 12

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 15, weight: .semibold))

                Text(tab.title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(
                isSelected
                    ? IOSAppTheme.accentForeground
                    : IOSAppTheme.textSecondary
            )
            .frame(maxWidth: .infinity)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background {
                if isSelected {
                    let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
                    shape
                        .fill(IOSAppTheme.accentFill(tab.tint))
                        .glassEffect(
                            .regular
                                .tint(IOSAppTheme.subtleGlassTint(tab.tint, intensity: 1.0))
                                .interactive(),
                            in: shape
                        )
                        .overlay {
                            shape
                                .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("rootTab_\(tab.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct IOSStudioSectionGroup<Content: View>: View {
    let title: String?
    let tint: Color
    let content: Content

    @ScaledMetric(relativeTo: .body) private var spacing = 10
    @ScaledMetric(relativeTo: .body) private var padding = 14
    @ScaledMetric(relativeTo: .body) private var cornerRadius = 24

    init(
        title: String? = nil,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let title, !title.isEmpty {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(IOSAppTheme.textSecondary.opacity(0.92))
            }

            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .iosSectionGlass(tint: tint, cornerRadius: cornerRadius)
        }
    }
}

private extension IOSAppTab {
    var title: String {
        switch self {
        case .generate:
            return "Generate"
        case .library:
            return "Library"
        case .settings:
            return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .generate:
            return "sparkles"
        case .library:
            return "square.stack.3d.up"
        case .settings:
            return "gearshape"
        }
    }

    var tint: Color {
        switch self {
        case .generate:
            return IOSBrandTheme.accent
        case .library:
            return IOSBrandTheme.library
        case .settings:
            return IOSBrandTheme.settings
        }
    }
}
