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
    static let customVoice = Color.blue
    static let voiceDesign = Color.teal
    static let voiceCloning = Color.indigo
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

    static var windowTitlebarSeparatorStyle: NSTitlebarSeparatorStyle { .automatic }
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
        modeColor(for: item.rawValue)
    }

    static func modeColor(for mode: String) -> Color {
        let normalizedMode = mode.lowercased()

        if normalizedMode.contains("custom") {
            return .blue
        }
        if normalizedMode.contains("design") {
            return .teal
        }
        if normalizedMode.contains("clone") {
            return .indigo
        }
        if normalizedMode.contains("history") {
            return .secondary
        }

        return accent
    }

    static func modeColor(for mode: GenerationMode) -> Color {
        switch mode {
        case .custom:
            return .blue
        case .design:
            return .teal
        case .clone:
            return .indigo
        }
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
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(AppTheme.cardStroke.opacity(0.45), lineWidth: 1)
            )
    }
}

private struct StudioChipStyle: ViewModifier {
    let isSelected: Bool
    let color: Color

    func body(content: Content) -> some View {
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
        AppTheme.canvasBackground
            .ignoresSafeArea()
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
