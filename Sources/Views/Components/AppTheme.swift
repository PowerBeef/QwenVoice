import AppKit
import SwiftUI

extension Color {
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        }))
    }
}

enum AppTheme {
    enum UIProfile: String {
        case liquid
        case legacy
    }

    static let uiProfile: UIProfile = {
        #if QW_UI_LIQUID && QW_UI_LEGACY_GLASS
        return .legacy
        #elseif QW_UI_LIQUID
        return .liquid
        #elseif QW_UI_LEGACY_GLASS
        return .legacy
        #else
        return .legacy
        #endif
    }()

    static let accent = Color.accentColor
    static let customVoice = accent
    static let voiceDesign = accent
    static let voiceCloning = accent
    static let history = accent
    static let voices = accent
    static let models = accent
    static let preferences = accent

    static let canvasBackground = Color(nsColor: .windowBackgroundColor)
    static let stageFill = Color(nsColor: .underPageBackgroundColor)
    static let stageStroke = Color(nsColor: .separatorColor)
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let cardStroke = Color(nsColor: .separatorColor)
    static let inlineFill = Color(nsColor: .controlBackgroundColor)
    static let inlineStroke = Color(nsColor: .separatorColor)
    static let railBackground = Color.clear
    static let railStroke = Color.clear
    static let stageGlow = Color.clear

    static var windowTitlebarSeparatorStyle: NSTitlebarSeparatorStyle {
        #if QW_UI_LIQUID
        return .none
        #else
        return .automatic
        #endif
    }
    static var splitDividerStyle: NSSplitView.DividerStyle { .thin }
    static var legacyDividerBlendInset: CGFloat { 0 }
    static var legacyDividerBlendAlpha: CGFloat { 0 }
    static var legacyDividerEdgeAlpha: CGFloat { 0 }

    static func emotionColor(for emotionID: String) -> Color {
        switch emotionID {
        case "neutral":
            return .secondary
        case "happy":
            return .yellow
        case "sad":
            return .blue
        case "angry":
            return .red
        case "fearful":
            return .purple
        case "whisper":
            return .gray
        case "dramatic":
            return .pink
        case "calm":
            return .green
        case "excited":
            return .orange
        default:
            return accent
        }
    }

    static func sidebarColor(for item: SidebarItem) -> Color {
        accent
    }

    static func modeColor(for mode: String) -> Color {
        accent
    }

    static func modeColor(for mode: GenerationMode) -> Color {
        accent
    }

    static let waveformGradient = LinearGradient(
        colors: [accent.opacity(0.45), accent],
        startPoint: .leading,
        endPoint: .trailing
    )

    static func waveformColor(at position: Double) -> Color {
        let progress = max(0, min(1, position))
        return accent.opacity(0.45 + (progress * 0.45))
    }
}

private struct NativeSurfaceStyle: ViewModifier {
    let padding: CGFloat
    let radius: CGFloat
    let fill: Color

    func body(content: Content) -> some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            content
                .padding(padding)
                .glassEffect(in: .rect(cornerRadius: radius))
        } else {
            legacyBody(content: content)
        }
        #else
        legacyBody(content: content)
        #endif
    }

    private func legacyBody(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(AppTheme.cardStroke.opacity(0.18), lineWidth: 0.5)
            )
    }
}

private struct StudioChipStyle: ViewModifier {
    let isSelected: Bool
    let color: Color

    func body(content: Content) -> some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            content
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? color : .primary)
                .glassEffect(isSelected ? .regular.tint(color) : .regular, in: .capsule)
                .appAnimation(.easeInOut(duration: 0.15), value: isSelected)
        } else {
            legacyBody(content: content)
        }
        #else
        legacyBody(content: content)
        #endif
    }

    private func legacyBody(content: Content) -> some View {
        content
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? color.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
            )
            .foregroundStyle(isSelected ? color : .primary)
            .overlay(
                Capsule()
                    .stroke(isSelected ? color.opacity(0.32) : AppTheme.cardStroke.opacity(0.45), lineWidth: 1)
            )
            .appAnimation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

extension View {
    func studioCard(
        padding: CGFloat = LayoutConstants.cardPadding,
        radius: CGFloat = LayoutConstants.cardRadius
    ) -> some View {
        modifier(NativeSurfaceStyle(padding: padding, radius: radius, fill: AppTheme.cardFill))
    }

    func glassCard() -> some View {
        studioCard(padding: LayoutConstants.glassCardPadding, radius: LayoutConstants.cardRadius)
    }

    func stageCard() -> some View {
        modifier(NativeSurfaceStyle(padding: 0, radius: LayoutConstants.stageRadius, fill: AppTheme.stageFill))
    }

    func inlinePanel(padding: CGFloat = 14, radius: CGFloat = 16) -> some View {
        modifier(NativeSurfaceStyle(padding: padding, radius: radius, fill: AppTheme.inlineFill))
    }

    func appAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        self.animation(AppLaunchConfiguration.current.animation(animation), value: value)
    }

    func studioChip(isSelected: Bool, color: Color) -> some View {
        modifier(StudioChipStyle(isSelected: isSelected, color: color))
    }

    func chipStyle(isSelected: Bool, color: Color) -> some View {
        modifier(StudioChipStyle(isSelected: isSelected, color: color))
    }

    func voiceChoiceChip(isSelected: Bool, color: Color) -> some View {
        modifier(StudioChipStyle(isSelected: isSelected, color: color))
    }
}

private struct ToolbarRowStyle: ViewModifier {
    let label: String

    func body(content: Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            content
        }
    }
}

struct SectionHeaderStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

struct GlowingGradientButtonStyle: ButtonStyle {
    let baseColor: Color

    func makeBody(configuration: Configuration) -> some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular.tint(baseColor), in: .rect(cornerRadius: 8))
                .opacity(configuration.isPressed ? 0.75 : 1.0)
                .appAnimation(.easeInOut(duration: 0.15), value: configuration.isPressed)
        } else {
            legacyBody(configuration: configuration)
        }
        #else
        legacyBody(configuration: configuration)
        #endif
    }

    private func legacyBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(baseColor.opacity(configuration.isPressed ? 0.75 : 0.95))
            )
            .appAnimation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct CompactGenerateButtonStyle: ButtonStyle {
    let baseColor: Color

    func makeBody(configuration: Configuration) -> some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            configuration.label
                .foregroundStyle(.white)
                .padding(12)
                .glassEffect(.regular.tint(baseColor), in: .circle)
                .opacity(configuration.isPressed ? 0.75 : 1.0)
                .appAnimation(.easeInOut(duration: 0.15), value: configuration.isPressed)
        } else {
            legacyBody(configuration: configuration)
        }
        #else
        legacyBody(configuration: configuration)
        #endif
    }

    private func legacyBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(12)
            .background(
                Circle()
                    .fill(baseColor.opacity(configuration.isPressed ? 0.75 : 0.95))
            )
            .appAnimation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct AuroraBackground: View {
    var body: some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            Color.clear.ignoresSafeArea()
        } else {
            AppTheme.canvasBackground.ignoresSafeArea()
        }
        #else
        AppTheme.canvasBackground.ignoresSafeArea()
        #endif
    }
}

struct EmptyStateStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.foregroundStyle(.secondary)
    }
}

extension View {
    func toolbarRow(_ label: String) -> some View {
        modifier(ToolbarRowStyle(label: label))
    }

    func sectionHeader() -> some View {
        modifier(SectionHeaderStyle())
    }

    func emptyStateStyle() -> some View {
        modifier(EmptyStateStyle())
    }
}

// MARK: - Studio GroupBox Style (material-based legacy fallback)

struct StudioGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
            configuration.content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.cardStroke.opacity(0.18), lineWidth: 0.5)
        )
    }
}

// MARK: - Liquid Glass Convenience Extensions

#if QW_UI_LIQUID
@available(macOS 26, *)
struct GlassGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
            configuration.content
        }
        .padding(12)
        .glassEffect(in: .rect(cornerRadius: 16))
    }
}
#endif

extension View {
    /// Wraps content in a GlassEffectContainer on liquid builds.
    @ViewBuilder
    func liquidGlassContainer(spacing: CGFloat = 8) -> some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else { self }
        #else
        self
        #endif
    }

    /// Profile-aware background: clear for liquid, specified color for legacy.
    @ViewBuilder
    func profileBackground(_ legacyColor: Color) -> some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            self.background(.clear)
        } else {
            self.background(legacyColor)
        }
        #else
        self.background(legacyColor)
        #endif
    }

    /// Applies profile-aware GroupBox style.
    @ViewBuilder
    func profileGroupBoxStyle() -> some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            self.groupBoxStyle(GlassGroupBoxStyle())
        } else {
            self.groupBoxStyle(StudioGroupBoxStyle())
        }
        #else
        self.groupBoxStyle(.automatic)
        #endif
    }

    /// Profile-aware glass capsule badge background.
    @ViewBuilder
    func glassBadge(tint: Color? = nil) -> some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint), in: .capsule)
            } else {
                self.glassEffect(in: .capsule)
            }
        } else { self }
        #else
        self
        #endif
    }
}
