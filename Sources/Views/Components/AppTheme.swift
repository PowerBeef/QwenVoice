import SwiftUI
import AppKit

// MARK: - Adaptive Color Helper

extension Color {
    /// Creates an adaptive color that switches between light and dark mode appearances.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        }))
    }
}

// MARK: - Studio Card Modifier

private struct StudioCardStyle: ViewModifier {
    var padding: CGFloat = LayoutConstants.cardPadding
    var radius: CGFloat = LayoutConstants.cardRadius

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(AppTheme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(AppTheme.cardStroke, lineWidth: LayoutConstants.cardBorderWidth)
            )
    }
}

extension View {
    func studioCard(padding: CGFloat = LayoutConstants.cardPadding, radius: CGFloat = LayoutConstants.cardRadius) -> some View {
        modifier(StudioCardStyle(padding: padding, radius: radius))
    }

    func glassCard() -> some View {
        modifier(StudioCardStyle(padding: LayoutConstants.glassCardPadding, radius: LayoutConstants.cardRadius))
    }

    func stageCard() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: LayoutConstants.stageRadius, style: .continuous)
                    .fill(AppTheme.stageFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LayoutConstants.stageRadius, style: .continuous)
                    .stroke(AppTheme.stageStroke, lineWidth: LayoutConstants.cardBorderWidth)
            )
            .shadow(color: AppTheme.stageGlow, radius: 5, y: 0)
    }

    func appAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        self.animation(AppLaunchConfiguration.current.animation(animation), value: value)
    }
}

// MARK: - Studio Chip Modifier

private struct StudioChipStyle: ViewModifier {
    let isSelected: Bool
    let color: Color

    func body(content: Content) -> some View {
        content
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(isSelected ? color.opacity(0.16) : Color.white.opacity(0.03))
            )
            .foregroundStyle(isSelected ? color : .primary.opacity(0.7))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(isSelected ? color.opacity(0.54) : Color.white.opacity(0.05), lineWidth: isSelected ? 1.1 : LayoutConstants.cardBorderWidth)
            )
            .shadow(color: isSelected ? color.opacity(0.08) : .clear, radius: 6, y: 0)
            .appAnimation(.interpolatingSpring(stiffness: 300, damping: 20), value: isSelected)
    }
}

private struct VoiceChoiceChipStyle: ViewModifier {
    let isSelected: Bool
    let color: Color

    func body(content: Content) -> some View {
        content
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minWidth: 96, maxWidth: 132)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isSelected ? color.opacity(0.15) : Color.white.opacity(0.025))
            )
            .foregroundStyle(isSelected ? color : .primary.opacity(0.72))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(isSelected ? color.opacity(0.5) : Color.white.opacity(0.045), lineWidth: isSelected ? 1.05 : LayoutConstants.cardBorderWidth)
            )
            .shadow(color: isSelected ? color.opacity(0.06) : .clear, radius: 4, y: 0)
            .appAnimation(.interpolatingSpring(stiffness: 300, damping: 20), value: isSelected)
    }
}

extension View {
    func studioChip(isSelected: Bool, color: Color) -> some View {
        modifier(StudioChipStyle(isSelected: isSelected, color: color))
    }

    func chipStyle(isSelected: Bool, color: Color) -> some View {
        modifier(StudioChipStyle(isSelected: isSelected, color: color))
    }

    func voiceChoiceChip(isSelected: Bool, color: Color) -> some View {
        modifier(VoiceChoiceChipStyle(isSelected: isSelected, color: color))
    }
}

// MARK: - Toolbar Row Modifier

private struct ToolbarRowStyle: ViewModifier {
    let label: String

    func body(content: Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            content
        }
    }
}

extension View {
    func toolbarRow(_ label: String) -> some View {
        modifier(ToolbarRowStyle(label: label))
    }
}

// MARK: - AppTheme

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

    // MARK: System Separator Styling

    static var windowTitlebarSeparatorStyle: NSTitlebarSeparatorStyle {
        switch uiProfile {
        case .liquid:
            return .automatic
        case .legacy:
            return .none
        }
    }

    static var splitDividerStyle: NSSplitView.DividerStyle {
        switch uiProfile {
        case .liquid:
            return .thin
        case .legacy:
            return .thin
        }
    }

    static var legacyDividerBlendInset: CGFloat {
        1.0
    }

    static var legacyDividerBlendAlpha: CGFloat {
        0.16
    }

    static var legacyDividerEdgeAlpha: CGFloat {
        0.06
    }

    // MARK: Section Colors

    static let accent = Color(light: Color(red: 0.20, green: 0.68, blue: 0.98),
                               dark: Color(red: 0.38, green: 0.82, blue: 1.00))
    static let customVoice  = accent
    static let voiceDesign  = accent
    static let voiceCloning = accent
    static let history      = accent
    static let voices       = accent
    static let models       = accent
    static let preferences  = accent

    static let canvasBase = Color(light: Color(red: 0.08, green: 0.09, blue: 0.12),
                                  dark: Color(red: 0.06, green: 0.07, blue: 0.09))
    static let canvasInset = Color(light: Color(red: 0.11, green: 0.13, blue: 0.18),
                                   dark: Color(red: 0.10, green: 0.12, blue: 0.16))
    static let cardFill = Color.white.opacity(0.04)
    static let cardStroke = Color.white.opacity(0.085)
    static let railFill = Color.white.opacity(0.038)
    static let railStroke = Color.white.opacity(0.095)
    static let mutedFill = Color.white.opacity(0.05)
    static let stageFill = Color(red: 0.10, green: 0.12, blue: 0.15).opacity(0.96)
    static let stageStroke = Color.white.opacity(0.12)
    static let stageGlow = accent.opacity(0.022)

    static let canvasBackground = canvasBase

    static let railBackground = LinearGradient(
        colors: [
            railFill,
            railFill.opacity(0.88),
            Color.white.opacity(0.024)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: Emotion Colors

    static func emotionColor(for emotionID: String) -> Color {
        switch emotionID {
        case "neutral":  return Color.secondary
        case "happy":    return Color(light: Color(red: 0.75, green: 0.62, blue: 0.25),
                                       dark: Color(red: 0.82, green: 0.72, blue: 0.35))
        case "sad":      return Color(light: Color(red: 0.35, green: 0.48, blue: 0.72),
                                       dark: Color(red: 0.45, green: 0.56, blue: 0.80))
        case "angry":    return Color(light: Color(red: 0.72, green: 0.32, blue: 0.32),
                                       dark: Color(red: 0.80, green: 0.42, blue: 0.42))
        case "fearful":  return Color(light: Color(red: 0.52, green: 0.38, blue: 0.72),
                                       dark: Color(red: 0.62, green: 0.48, blue: 0.80))
        case "whisper":  return Color(light: Color(red: 0.54, green: 0.50, blue: 0.66),
                                       dark: Color(red: 0.64, green: 0.60, blue: 0.76))
        case "dramatic": return Color(light: Color(red: 0.58, green: 0.25, blue: 0.32),
                                       dark: Color(red: 0.72, green: 0.35, blue: 0.42))
        case "calm":     return Color(light: Color(red: 0.40, green: 0.56, blue: 0.42),
                                       dark: Color(red: 0.48, green: 0.66, blue: 0.50))
        case "excited":  return Color(light: Color(red: 0.75, green: 0.50, blue: 0.25),
                                       dark: Color(red: 0.82, green: 0.58, blue: 0.35))
        default:         return .accentColor
        }
    }

    // MARK: Sidebar Color

    static func sidebarColor(for item: SidebarItem) -> Color {
        accent
    }

    // MARK: Mode Color

    static func modeColor(for mode: String) -> Color {
        accent
    }

    static func modeColor(for mode: GenerationMode) -> Color {
        accent
    }

    // MARK: Waveform Gradient

    static let waveformGradient = LinearGradient(
        colors: [accent.opacity(0.6), accent],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Returns a monochrome accent ramp for a given position (0...1).
    static func waveformColor(at position: Double) -> Color {
        let t = max(0, min(1, position))
        return accent.opacity(0.6 + 0.4 * t)
    }
}

// MARK: - Section Header Style

struct SectionHeaderStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

extension View {
    func sectionHeader() -> some View {
        modifier(SectionHeaderStyle())
    }
}

// MARK: - Generate Button Style

struct GlowingGradientButtonStyle: ButtonStyle {
    let baseColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [baseColor, baseColor.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.24), lineWidth: 0.5)
            )
            .shadow(color: baseColor.opacity(0.18), radius: configuration.isPressed ? 4 : 6, y: configuration.isPressed ? 2 : 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .appAnimation(.interpolatingSpring(stiffness: 300, damping: 15), value: configuration.isPressed)
    }
}

// MARK: - Compact Generate Button Style

struct CompactGenerateButtonStyle: ButtonStyle {
    let baseColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.bold))
            .foregroundStyle(.white)
            .padding(12)
            .background(
                Circle()
                    .fill(LinearGradient(
                        colors: [baseColor, baseColor.opacity(0.8)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
            )
            .shadow(color: baseColor.opacity(0.2), radius: configuration.isPressed ? 4 : 8, y: configuration.isPressed ? 2 : 4)
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .appAnimation(.interpolatingSpring(stiffness: 300, damping: 15), value: configuration.isPressed)
    }
}

// MARK: - Aurora Background

struct AuroraBackground: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height

                Circle()
                    .fill(AppTheme.accent.opacity(0.06))
                    .frame(width: width * 0.8)
                    .blur(radius: 80)
                    .offset(x: animate ? width * 0.15 : -width * 0.15, y: animate ? height * 0.1 : -height * 0.1)
            }
            .drawingGroup()
            .appAnimation(.easeInOut(duration: 20).repeatForever(autoreverses: true), value: animate)
            .onAppear {
                animate = true
            }
        }
    }
}

// MARK: - Empty State Style

struct EmptyStateStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.secondary.opacity(0.5))
    }
}

extension View {
    func emptyStateStyle() -> some View {
        modifier(EmptyStateStyle())
    }
}
