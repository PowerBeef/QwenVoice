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
                            colors: [Color.white.opacity(0.4), Color.white.opacity(0.05), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.3), radius: 30, x: 0, y: 15)
            .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}

// MARK: - AppTheme

enum AppTheme {

    // MARK: Section Colors

    static let customVoice = Color(light: Color(red: 0.549, green: 0.239, blue: 0.859),
                                    dark: Color(red: 0.690, green: 0.463, blue: 0.973))
    static let voiceDesign = Color(light: Color(red: 0.0, green: 0.604, blue: 0.620),
                                    dark: Color(red: 0.2, green: 0.780, blue: 0.800))
    static let voiceCloning = Color(light: Color(red: 0.902, green: 0.522, blue: 0.078),
                                     dark: Color(red: 1.0, green: 0.682, blue: 0.278))
    static let history = Color(light: Color(red: 0.349, green: 0.341, blue: 0.839),
                                dark: Color(red: 0.522, green: 0.522, blue: 0.949))
    static let voices = Color(light: Color(red: 0.843, green: 0.278, blue: 0.651),
                               dark: Color(red: 0.949, green: 0.478, blue: 0.651))
    static let models = Color(light: Color(red: 0.780, green: 0.600, blue: 0.098),
                               dark: Color(red: 0.949, green: 0.780, blue: 0.278))
    static let preferences = Color(light: Color(red: 0.420, green: 0.478, blue: 0.580),
                                    dark: Color(red: 0.620, green: 0.678, blue: 0.780))

    // MARK: Emotion Colors

    static func emotionColor(for emotionID: String) -> Color {
        switch emotionID {
        case "neutral":  return Color(light: .gray, dark: .gray)
        case "happy":    return Color(light: Color(red: 0.878, green: 0.698, blue: 0.118),
                                       dark: Color(red: 0.980, green: 0.820, blue: 0.220))
        case "sad":      return Color(light: Color(red: 0.259, green: 0.518, blue: 0.878),
                                       dark: Color(red: 0.400, green: 0.620, blue: 0.960))
        case "angry":    return Color(light: Color(red: 0.878, green: 0.220, blue: 0.220),
                                       dark: Color(red: 0.960, green: 0.380, blue: 0.380))
        case "fearful":  return Color(light: Color(red: 0.608, green: 0.318, blue: 0.878),
                                       dark: Color(red: 0.740, green: 0.478, blue: 0.960))
        case "whisper":  return Color(light: Color(red: 0.620, green: 0.557, blue: 0.800),
                                       dark: Color(red: 0.761, green: 0.710, blue: 0.918))
        case "dramatic": return Color(light: Color(red: 0.698, green: 0.118, blue: 0.220),
                                       dark: Color(red: 0.878, green: 0.278, blue: 0.380))
        case "calm":     return Color(light: Color(red: 0.380, green: 0.639, blue: 0.420),
                                       dark: Color(red: 0.518, green: 0.780, blue: 0.557))
        case "excited":  return Color(light: Color(red: 0.918, green: 0.498, blue: 0.118),
                                       dark: Color(red: 0.980, green: 0.620, blue: 0.278))
        default:         return .accentColor
        }
    }

    // MARK: Sidebar Color

    static func sidebarColor(for item: SidebarItem) -> Color {
        switch item {
        case .customVoice: return customVoice
        case .voiceCloning: return voiceCloning
        case .history: return history
        case .voices: return voices
        case .models: return models
        case .preferences: return preferences
        }
    }

    // MARK: Mode Color

    static func modeColor(for mode: String) -> Color {
        switch mode.lowercased() {
        case "custom": return customVoice
        case "design": return voiceDesign
        case "clone":  return voiceCloning
        default:       return .accentColor
        }
    }

    static func modeColor(for mode: GenerationMode) -> Color {
        switch mode {
        case .custom: return customVoice
        case .design: return voiceDesign
        case .clone:  return voiceCloning
        }
    }

    // MARK: Waveform Gradient

    static let waveformGradient = LinearGradient(
        colors: [
            Color(red: 0.549, green: 0.239, blue: 0.859),  // purple
            Color(red: 0.259, green: 0.518, blue: 0.878),  // blue
            Color(red: 0.0, green: 0.604, blue: 0.620),    // teal
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Interpolates through purple→blue→teal for a given position (0...1).
    static func waveformColor(at position: Double) -> Color {
        let purple = (r: 0.549, g: 0.239, b: 0.859)
        let blue   = (r: 0.259, g: 0.518, b: 0.878)
        let teal   = (r: 0.0,   g: 0.604, b: 0.620)

        let t = max(0, min(1, position))
        if t < 0.5 {
            let f = t / 0.5
            return Color(
                red: purple.r + (blue.r - purple.r) * f,
                green: purple.g + (blue.g - purple.g) * f,
                blue: purple.b + (blue.b - purple.b) * f
            )
        } else {
            let f = (t - 0.5) / 0.5
            return Color(
                red: blue.r + (teal.r - blue.r) * f,
                green: blue.g + (teal.g - blue.g) * f,
                blue: blue.b + (teal.b - blue.b) * f
            )
        }
    }
}

// MARK: - Section Header Style

struct SectionHeaderStyle: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
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
                            colors: [baseColor.opacity(1.2), baseColor.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.6), Color.white.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: baseColor.opacity(0.6), radius: configuration.isPressed ? 10 : 20, y: configuration.isPressed ? 5 : 10)
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
                        colors: [baseColor.opacity(1.1), baseColor.opacity(0.8)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
            )
            .overlay(
                Circle()
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.5), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            )
            .shadow(color: baseColor.opacity(0.5), radius: configuration.isPressed ? 5 : 10, y: configuration.isPressed ? 2 : 5)
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
                    .fill(isSelected ? color : Color.primary.opacity(0.06))
            )
            .foregroundStyle(isSelected ? .white : color)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.3) : Color.primary.opacity(0.04), lineWidth: 1)
            )
            .shadow(color: isSelected ? color.opacity(0.5) : .clear, radius: 10, y: 4)
            .scaleEffect(isSelected ? 1.05 : 1.0)
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
                
                ZStack {
                    Circle()
                        .fill(AppTheme.customVoice.opacity(0.3))
                        .frame(width: width * 0.8)
                        .blur(radius: 120)
                        .offset(x: animate ? width * 0.2 : -width * 0.2, y: animate ? height * 0.2 : -height * 0.2)

                    Circle()
                        .fill(AppTheme.voiceDesign.opacity(0.3))
                        .frame(width: width * 0.9)
                        .blur(radius: 150)
                        .offset(x: animate ? -width * 0.1 : width * 0.3, y: animate ? -height * 0.3 : height * 0.1)

                    Circle()
                        .fill(AppTheme.voiceCloning.opacity(0.25))
                        .frame(width: width * 0.7)
                        .blur(radius: 100)
                        .offset(x: animate ? width * 0.4 : -width * 0.3, y: animate ? height * 0.3 : -height * 0.4)
                }
            }
            .animation(.easeInOut(duration: 15).repeatForever(autoreverses: true), value: animate)
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
            .foregroundStyle(
                LinearGradient(
                    colors: [color, color.opacity(0.5)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}

extension View {
    func emptyStateStyle(color: Color) -> some View {
        modifier(EmptyStateStyle(color: color))
    }
}
