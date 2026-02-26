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

// MARK: - Glassmorphism Extension

extension View {
    func glassCard() -> some View {
        self
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.25), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
            .shadow(color: Color.black.opacity(0.15), radius: 20, x: 0, y: 10)
    }
}

// MARK: - AppTheme

enum AppTheme {

    // MARK: Section Colors

    static let accent = Color(light: Color(red: 0.33, green: 0.40, blue: 0.65),
                               dark: Color(red: 0.50, green: 0.58, blue: 0.85))
    static let customVoice  = accent
    static let voiceDesign  = accent
    static let voiceCloning = accent
    static let history      = accent
    static let voices       = accent
    static let models       = accent
    static let preferences  = accent

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
    let color: Color

    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

extension View {
    func sectionHeader(color: Color) -> some View {
        modifier(SectionHeaderStyle(color: color))
    }
}

// MARK: - Generate Button Style

struct GlowingGradientButtonStyle: ButtonStyle {
    let baseColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [baseColor, baseColor.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
            )
            .shadow(color: baseColor.opacity(0.25), radius: configuration.isPressed ? 6 : 12, y: configuration.isPressed ? 3 : 6)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.interpolatingSpring(stiffness: 300, damping: 15), value: configuration.isPressed)
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
            .animation(.interpolatingSpring(stiffness: 300, damping: 15), value: configuration.isPressed)
    }
}

// MARK: - Chip Style

struct ChipStyle: ViewModifier {
    let isSelected: Bool
    let color: Color

    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.bold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? color.opacity(0.15) : Color.primary.opacity(0.06))
            )
            .foregroundStyle(isSelected ? color : color.opacity(0.8))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? color.opacity(0.3) : Color.primary.opacity(0.04), lineWidth: 0.5)
            )
            .scaleEffect(isSelected ? 1.02 : 1.0)
            .animation(.interpolatingSpring(stiffness: 300, damping: 15), value: isSelected)
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
            .animation(.easeInOut(duration: 20).repeatForever(autoreverses: true), value: animate)
            .onAppear {
                animate = true
            }
        }
    }
}

extension View {
    func chipStyle(isSelected: Bool, color: Color) -> some View {
        modifier(ChipStyle(isSelected: isSelected, color: color))
    }
}

// MARK: - Empty State Style

struct EmptyStateStyle: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.secondary.opacity(0.5))
    }
}

extension View {
    func emptyStateStyle(color: Color) -> some View {
        modifier(EmptyStateStyle(color: color))
    }
}
