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
    }

    static let uiProfile: UIProfile = {
        #if QW_UI_LIQUID
        return .liquid
        #else
        return .liquid
        #endif
    }()

    static let accent = Color.accentColor
    static let inlinePreviewProgressTint = Color(
        light: Color(red: 0.30, green: 0.53, blue: 0.88),
        dark: Color(red: 0.43, green: 0.65, blue: 0.97)
    )
    static let statusProgressTint = Color(
        light: Color(red: 0.34, green: 0.56, blue: 0.91),
        dark: Color(red: 0.47, green: 0.68, blue: 0.98)
    )
    static let smokedGlassTint = Color(
        light: Color(red: 0.84, green: 0.90, blue: 0.98).opacity(0.60),
        dark: Color(white: 0.15, opacity: 0.6)
    )
    static let customVoice = accent
    static let voiceDesign = accent
    static let voiceCloning = accent
    static let history = accent
    static let voices = accent
    static let models = accent
    static let preferences = accent

    static let canvasBackground = Color(
        light: Color(red: 0.960, green: 0.968, blue: 0.982),
        dark: Color(red: 0.086, green: 0.094, blue: 0.118)
    )
    static let stageFill = Color(
        light: Color(red: 0.946, green: 0.954, blue: 0.973),
        dark: Color(red: 0.110, green: 0.118, blue: 0.150)
    )
    static let stageStroke = Color(
        light: Color(red: 0.772, green: 0.804, blue: 0.868).opacity(0.66),
        dark: Color.white.opacity(0.10)
    )
    static let cardFill = Color(
        light: Color(red: 0.978, green: 0.983, blue: 0.993),
        dark: Color(red: 0.125, green: 0.132, blue: 0.164)
    )
    static let cardStroke = Color(
        light: Color(red: 0.744, green: 0.776, blue: 0.844).opacity(0.64),
        dark: Color.white.opacity(0.11)
    )
    static let inlineFill = Color(
        light: Color(red: 0.966, green: 0.972, blue: 0.986),
        dark: Color(red: 0.145, green: 0.153, blue: 0.188)
    )
    static let inlineStroke = Color(
        light: Color(red: 0.736, green: 0.768, blue: 0.838).opacity(0.60),
        dark: Color.white.opacity(0.09)
    )
    static let fieldFill = Color(
        light: Color(red: 0.984, green: 0.988, blue: 0.996),
        dark: Color(red: 0.165, green: 0.172, blue: 0.214)
    )
    static let fieldStroke = Color(
        light: Color(red: 0.724, green: 0.756, blue: 0.828).opacity(0.58),
        dark: Color.white.opacity(0.10)
    )
    static let railBackground = Color(
        light: Color(red: 0.968, green: 0.974, blue: 0.986),
        dark: Color(red: 0.090, green: 0.098, blue: 0.122)
    )
    static let railStroke = Color(
        light: Color(red: 0.780, green: 0.810, blue: 0.872).opacity(0.42),
        dark: Color.white.opacity(0.08)
    )
    static let stageGlow = Color(
        light: Color.white.opacity(0.65),
        dark: Color.white.opacity(0.05)
    )
    static let sidebarSelectionFill = Color(
        light: Color(red: 0.918, green: 0.944, blue: 0.988),
        dark: Color.white.opacity(0.05)
    )
    static let sidebarSelectionStroke = Color(
        light: Color(red: 0.336, green: 0.540, blue: 0.918).opacity(0.24),
        dark: accent.opacity(0.26)
    )
    static let sidebarHoverFill = Color(
        light: Color(red: 0.952, green: 0.962, blue: 0.984),
        dark: Color.white.opacity(0.03)
    )
    static let sidebarHoverStroke = Color(
        light: Color(red: 0.708, green: 0.748, blue: 0.844).opacity(0.24),
        dark: Color.white.opacity(0.08)
    )

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

    static func accentWash(_ color: Color, for colorScheme: ColorScheme) -> Color {
        color.opacity(colorScheme == .dark ? 0.20 : 0.09)
    }

    static func accentGlassTint(_ color: Color, for colorScheme: ColorScheme) -> Color {
        color.opacity(colorScheme == .dark ? 0.88 : 0.18)
    }

    static func accentStroke(_ color: Color, for colorScheme: ColorScheme) -> Color {
        color.opacity(colorScheme == .dark ? 0.34 : 0.28)
    }

    static func surfaceStrokeOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.16 : 0.48
    }

    static func surfaceStrokeWidth(for colorScheme: ColorScheme) -> CGFloat {
        colorScheme == .dark ? 0.75 : 1
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
    @Environment(\.colorScheme) private var colorScheme

    let padding: CGFloat
    let radius: CGFloat
    let fill: Color

    func body(content: Content) -> some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            content
                .padding(padding)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(fill)
                        .overlay(
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(
                                    AppTheme.cardStroke.opacity(AppTheme.surfaceStrokeOpacity(for: colorScheme)),
                                    lineWidth: AppTheme.surfaceStrokeWidth(for: colorScheme)
                                )
                        )
                )
                .glassEffect(.regular.tint(AppTheme.smokedGlassTint), in: .rect(cornerRadius: radius))
                .glass3DDepth(radius: radius)
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
                    .stroke(
                        AppTheme.cardStroke.opacity(colorScheme == .dark ? 0.20 : AppTheme.surfaceStrokeOpacity(for: colorScheme)),
                        lineWidth: colorScheme == .dark ? 0.5 : 1
                    )
            )
    }
}

private struct StudioChipStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

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
                .background(
                    Capsule()
                        .fill(isSelected ? AppTheme.accentWash(color, for: colorScheme) : AppTheme.inlineFill)
                        .overlay(
                            Capsule()
                                .stroke(
                                    isSelected
                                        ? AppTheme.accentStroke(color, for: colorScheme)
                                        : AppTheme.cardStroke.opacity(colorScheme == .dark ? 0.18 : 0.40),
                                    lineWidth: isSelected ? (colorScheme == .dark ? 1 : 0.9) : AppTheme.surfaceStrokeWidth(for: colorScheme)
                                )
                        )
                )
                .glassEffect(
                    isSelected
                        ? .regular.tint(AppTheme.accentGlassTint(color, for: colorScheme))
                        : .regular.tint(AppTheme.smokedGlassTint),
                    in: .capsule
                )
                .glass3DDepth(radius: 999, intensity: isSelected ? 0.8 : 0.45)
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

private struct GlassBadgeStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let tint: Color?

    func body(content: Content) -> some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            content
                .background(
                    Capsule()
                        .fill(AppTheme.inlineFill)
                        .overlay(
                            Capsule()
                                .stroke(
                                    AppTheme.inlineStroke.opacity(colorScheme == .dark ? 0.18 : 0.42),
                                    lineWidth: AppTheme.surfaceStrokeWidth(for: colorScheme)
                                )
                        )
                )
                .glassEffect(.regular.tint(tint ?? AppTheme.smokedGlassTint), in: .capsule)
                .glass3DDepth(radius: 999, intensity: colorScheme == .dark ? 0.45 : 0.28)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct GlassTextFieldStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let radius: CGFloat
    let strokeColor: Color?
    let strokeWidth: CGFloat

    func body(content: Content) -> some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            content
                .background {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(AppTheme.fieldFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .stroke(
                                    (strokeColor ?? AppTheme.fieldStroke)
                                        .opacity(colorScheme == .dark ? 0.90 : 0.86),
                                    lineWidth: colorScheme == .dark ? max(strokeWidth, 0.75) : strokeWidth
                                )
                        )
                        .glassEffect(.regular.tint(AppTheme.smokedGlassTint), in: .rect(cornerRadius: radius))
                        .glass3DDepth(radius: radius, intensity: colorScheme == .dark ? 0.65 : 0.38)
                }
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(
                            (strokeColor ?? AppTheme.cardStroke).opacity(colorScheme == .dark ? 0.22 : 0.62),
                            lineWidth: colorScheme == .dark ? 0.5 : strokeWidth
                        )
                )
        }
        #else
        content
        #endif
    }
}

private struct Glass3DDepthStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let radius: CGFloat
    let intensity: Double

    func body(content: Content) -> some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            let topOpacity = colorScheme == .dark ? 0.12 * intensity : 0.22 * intensity
            let midOpacity = colorScheme == .dark ? 0.02 * intensity : 0.06 * intensity
            let shadowOpacity = colorScheme == .dark ? 0.20 * intensity : 0.045 * intensity
            let shadowRadius = colorScheme == .dark ? 2.0 : 5.5
            let shadowOffset = colorScheme == .dark ? 2.0 : 2.0

            content
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    .white.opacity(topOpacity),
                                    .white.opacity(midOpacity),
                                    .clear,
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: colorScheme == .dark ? 0.75 : 1
                        )
                }
                .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowOffset)
        } else {
            content
        }
        #else
        content
        #endif
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
            LinearGradient(
                colors: [
                    Color(
                        light: Color(red: 0.984, green: 0.989, blue: 0.998),
                        dark: Color(red: 0.06, green: 0.07, blue: 0.09)
                    ),
                    Color(
                        light: Color(red: 0.946, green: 0.956, blue: 0.978),
                        dark: Color(red: 0.10, green: 0.11, blue: 0.13)
                    ),
                ],
                startPoint: .top,
                endPoint: .bottom
            ).ignoresSafeArea()
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
    @Environment(\.colorScheme) private var colorScheme

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
                .stroke(
                    AppTheme.cardStroke.opacity(colorScheme == .dark ? 0.20 : AppTheme.surfaceStrokeOpacity(for: colorScheme)),
                    lineWidth: colorScheme == .dark ? 0.5 : 1
                )
        )
    }
}

// MARK: - Liquid Glass Convenience Extensions

#if QW_UI_LIQUID
@available(macOS 26, *)
struct GlassGroupBoxStyle: GroupBoxStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
            configuration.content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            AppTheme.cardStroke.opacity(AppTheme.surfaceStrokeOpacity(for: colorScheme)),
                            lineWidth: AppTheme.surfaceStrokeWidth(for: colorScheme)
                        )
                )
        )
        .glassEffect(.regular.tint(AppTheme.smokedGlassTint), in: .rect(cornerRadius: 16))
        .glass3DDepth(radius: 16)
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
            self.background(AppTheme.canvasBackground)
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
        modifier(GlassBadgeStyle(tint: tint))
    }

    /// Profile-aware glass text field background with 3D depth.
    @ViewBuilder
    func glassTextField(
        radius: CGFloat = 8,
        strokeColor: Color? = nil,
        strokeWidth: CGFloat = 1
    ) -> some View {
        modifier(GlassTextFieldStyle(radius: radius, strokeColor: strokeColor, strokeWidth: strokeWidth))
    }

    /// Adds 3D depth to glass surfaces: top-edge highlight gradient + drop shadow.
    @ViewBuilder
    func glass3DDepth(radius: CGFloat = 12, intensity: Double = 1.0) -> some View {
        modifier(Glass3DDepthStyle(radius: radius, intensity: intensity))
    }

}
