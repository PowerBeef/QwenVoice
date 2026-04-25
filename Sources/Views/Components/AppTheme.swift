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

    static let vocelloGold = Color(
        light: Color(red: 0.71, green: 0.51, blue: 0.18),
        dark: Color(red: 0.93, green: 0.80, blue: 0.54)
    )
    static let vocelloGoldDeep = Color(
        light: Color(red: 0.52, green: 0.35, blue: 0.10),
        dark: Color(red: 0.74, green: 0.55, blue: 0.25)
    )
    static let vocelloLavender = Color(
        light: Color(red: 0.52, green: 0.42, blue: 0.72),
        dark: Color(red: 0.75, green: 0.67, blue: 0.86)
    )
    static let vocelloTerracotta = Color(
        light: Color(red: 0.70, green: 0.43, blue: 0.24),
        dark: Color(red: 0.86, green: 0.66, blue: 0.53)
    )
    static let warmIvory = Color(
        light: Color(red: 0.13, green: 0.12, blue: 0.10),
        dark: Color(red: 0.95, green: 0.93, blue: 0.88)
    )
    static let mutedSilver = Color(
        light: Color(red: 0.42, green: 0.43, blue: 0.45),
        dark: Color(red: 0.70, green: 0.72, blue: 0.76)
    )
    static let charcoalShadow = Color(
        light: Color(red: 0.25, green: 0.22, blue: 0.18),
        dark: Color(red: 0.020, green: 0.024, blue: 0.032)
    )
    static let warmEdgeHighlight = Color(
        light: Color(red: 1.0, green: 0.97, blue: 0.88),
        dark: Color(red: 1.0, green: 0.91, blue: 0.74)
    )

    static let accent = vocelloGold
    static let inlinePreviewProgressTint = vocelloGold
    static let statusProgressTint = vocelloGold
    static let textPrimary = warmIvory
    static let textSecondary = mutedSilver
    static let smokedGlassTint = Color(
        light: Color(red: 0.96, green: 0.91, blue: 0.80).opacity(0.46),
        dark: Color(red: 0.16, green: 0.15, blue: 0.13).opacity(0.62)
    )
    // Vocello mode palette (mirrors Sources/iOS/IOSShellPrimitives.swift:IOSBrandTheme).
    // Dark values match the iOS brand exactly; light values are darkened variants
    // that keep usable WCAG contrast against the app's light-mode canvas background.
    static let customVoice = Color(
        light: Color(red: 0.71, green: 0.51, blue: 0.18),  // rich amber
        dark:  Color(red: 0.93, green: 0.80, blue: 0.54)   // warm golden — Vocello primary
    )
    static let voiceDesign = Color(
        light: Color(red: 0.52, green: 0.42, blue: 0.72),  // deeper purple
        dark:  Color(red: 0.75, green: 0.67, blue: 0.86)   // lavender purple
    )
    static let voiceCloning = Color(
        light: Color(red: 0.70, green: 0.43, blue: 0.24),  // deeper terracotta
        dark:  Color(red: 0.86, green: 0.66, blue: 0.53)   // warm terracotta
    )
    // Per-section tints (silver-gold for Library, silver for Settings) — the
    // non-generation halves of the app each get their own muted brand color so
    // chrome stops reading as a single uniform gold while still feeling Vocello.
    // Dark values match Sources/iOS/IOSShellPrimitives.swift:IOSBrandTheme; light
    // values are darkened variants for usable WCAG contrast.
    static let library = Color(
        light: Color(red: 0.45, green: 0.43, blue: 0.36),
        dark:  Color(red: 0.75, green: 0.74, blue: 0.71)   // silver-gold
    )
    static let settings = Color(
        light: Color(red: 0.36, green: 0.40, blue: 0.46),
        dark:  Color(red: 0.68, green: 0.71, blue: 0.76)   // silver
    )
    static let history = library
    static let voices = library
    static let models = settings
    static let preferences = settings

    // V mark / wordmark gradient stops.
    static let brandPurple = Color(
        light: Color(red: 0.45, green: 0.38, blue: 0.62),
        dark:  Color(red: 0.73, green: 0.66, blue: 0.84)
    )
    static let brandLavender = Color(
        light: Color(red: 0.62, green: 0.55, blue: 0.74),
        dark:  Color(red: 0.87, green: 0.82, blue: 0.93)
    )

    // Status chip dot colors (memory/healthy indicator). Match the iOS
    // IOSBrandTheme memory* tokens exactly so cross-platform telemetry chips
    // read identical.
    static let statusHealthy = Color(
        light: Color(red: 0.34, green: 0.49, blue: 0.34),
        dark:  Color(red: 0.55, green: 0.70, blue: 0.55)
    )
    static let statusGuarded = Color(
        light: Color(red: 0.62, green: 0.46, blue: 0.20),
        dark:  Color(red: 0.85, green: 0.70, blue: 0.45)
    )
    static let statusCritical = Color(
        light: Color(red: 0.62, green: 0.28, blue: 0.28),
        dark:  Color(red: 0.85, green: 0.50, blue: 0.50)
    )

    static let canvasBackground = Color(
        light: Color(red: 0.952, green: 0.943, blue: 0.920),
        dark: Color(red: 0.055, green: 0.062, blue: 0.077)
    )
    static let stageFill = Color(
        light: Color(red: 0.944, green: 0.934, blue: 0.908).opacity(0.72),
        dark: Color(red: 0.075, green: 0.083, blue: 0.102).opacity(0.74)
    )
    static let stageStroke = Color(
        light: Color(red: 1.0, green: 0.97, blue: 0.88).opacity(0.42),
        dark: Color(red: 1.0, green: 0.91, blue: 0.74).opacity(0.13)
    )
    static let cardFill = Color(
        light: Color(red: 0.970, green: 0.960, blue: 0.934).opacity(0.80),
        dark: Color(red: 0.092, green: 0.098, blue: 0.116).opacity(0.70)
    )
    static let cardStroke = Color(
        light: Color(red: 1.0, green: 0.97, blue: 0.88).opacity(0.48),
        dark: Color(red: 1.0, green: 0.91, blue: 0.74).opacity(0.16)
    )
    static let inlineFill = Color(
        light: Color(red: 0.956, green: 0.946, blue: 0.922).opacity(0.74),
        dark: Color(red: 0.115, green: 0.120, blue: 0.140).opacity(0.66)
    )
    static let inlineStroke = Color(
        light: Color(red: 1.0, green: 0.97, blue: 0.88).opacity(0.42),
        dark: Color(red: 1.0, green: 0.91, blue: 0.74).opacity(0.12)
    )
    static let fieldFill = Color(
        light: Color(red: 0.978, green: 0.968, blue: 0.944).opacity(0.88),
        dark: Color(red: 0.145, green: 0.150, blue: 0.172).opacity(0.88)
    )
    static let fieldStroke = Color(
        light: Color(red: 0.71, green: 0.51, blue: 0.18).opacity(0.18),
        dark: Color(red: 1.0, green: 0.91, blue: 0.74).opacity(0.12)
    )
    static let railBackground = Color(
        light: Color(red: 0.940, green: 0.928, blue: 0.900).opacity(0.78),
        dark: Color(red: 0.070, green: 0.076, blue: 0.092).opacity(0.72)
    )
    static let railStroke = Color(
        light: Color(red: 1.0, green: 0.97, blue: 0.88).opacity(0.34),
        dark: Color(red: 1.0, green: 0.91, blue: 0.74).opacity(0.10)
    )
    static let stageGlow = Color(
        light: Color(red: 1.0, green: 0.97, blue: 0.88).opacity(0.38),
        dark: Color(red: 1.0, green: 0.91, blue: 0.74).opacity(0.08)
    )
    static let sidebarSelectionFill = Color(
        light: Color(red: 0.71, green: 0.51, blue: 0.18).opacity(0.12),
        dark: Color(red: 0.93, green: 0.80, blue: 0.54).opacity(0.08)
    )
    static let sidebarSelectionStroke = Color(
        light: Color(red: 0.71, green: 0.51, blue: 0.18).opacity(0.32),
        dark: Color(red: 0.93, green: 0.80, blue: 0.54).opacity(0.28)
    )
    static let sidebarHoverFill = Color(
        light: Color(red: 1.0, green: 0.97, blue: 0.88).opacity(0.22),
        dark: Color(red: 1.0, green: 0.91, blue: 0.74).opacity(0.04)
    )
    static let sidebarHoverStroke = Color(
        light: Color(red: 0.71, green: 0.51, blue: 0.18).opacity(0.16),
        dark: Color(red: 1.0, green: 0.91, blue: 0.74).opacity(0.08)
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
            return mutedSilver
        case "happy", "excited":
            return vocelloGold
        case "sad", "whisper":
            return mutedSilver.opacity(0.88)
        case "angry":
            return Color(red: 0.84, green: 0.35, blue: 0.30)
        case "fearful":
            return vocelloLavender
        case "dramatic":
            return vocelloTerracotta
        case "calm":
            return Color(red: 0.58, green: 0.67, blue: 0.56)
        default:
            return accent
        }
    }

    static func sidebarColor(for item: SidebarItem) -> Color {
        switch item {
        case .customVoice: return customVoice
        case .voiceDesign: return voiceDesign
        case .voiceCloning: return voiceCloning
        case .history: return history
        case .voices: return voices
        case .models: return models
        }
    }

    static func modeColor(for mode: String) -> Color {
        switch mode {
        case GenerationMode.custom.rawValue: return customVoice
        case GenerationMode.design.rawValue: return voiceDesign
        case GenerationMode.clone.rawValue: return voiceCloning
        default: return accent
        }
    }

    static func modeColor(for mode: GenerationMode) -> Color {
        switch mode {
        case .custom: return customVoice
        case .design: return voiceDesign
        case .clone: return voiceCloning
        }
    }

    static func accentWash(_ color: Color, for colorScheme: ColorScheme) -> Color {
        color.opacity(colorScheme == .dark ? 0.20 : 0.09)
    }

    static func accentGlassTint(_ color: Color, for colorScheme: ColorScheme) -> Color {
        color.opacity(colorScheme == .dark ? 0.88 : 0.18)
    }

    /// Subtle mode-aware tint for big Liquid-Glass surfaces (Configuration
    /// panel, Script panel, cards). Weaker alpha than `accentGlassTint` so
    /// the panels read as softly Vocello-colored without overpowering the
    /// content inside them.
    static func surfaceGlassTint(_ color: Color, for colorScheme: ColorScheme) -> Color {
        color.opacity(colorScheme == .dark ? 0.14 : 0.08)
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

private struct VocelloGlassSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.cardGlassTint) private var cardGlassTint

    let padding: CGFloat
    let radius: CGFloat
    let fill: Color

    func body(content: Content) -> some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            let resolvedTint: Color = cardGlassTint.map {
                AppTheme.surfaceGlassTint($0, for: colorScheme)
            } ?? AppTheme.smokedGlassTint
            let resolvedStroke: Color = cardGlassTint.map {
                AppTheme.accentStroke($0, for: colorScheme).opacity(0.55)
            } ?? AppTheme.cardStroke.opacity(AppTheme.surfaceStrokeOpacity(for: colorScheme))
            let depthIntensity: Double = cardGlassTint == nil ? 1.0 : 1.15
            content
                .padding(padding)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(fill)
                        .overlay(
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(
                                    resolvedStroke,
                                    lineWidth: AppTheme.surfaceStrokeWidth(for: colorScheme)
                                )
                        )
                )
                .glassEffect(.regular.tint(resolvedTint), in: .rect(cornerRadius: radius))
                .glass3DDepth(radius: radius, intensity: depthIntensity)
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
                .foregroundStyle(isSelected ? color : AppTheme.textPrimary)
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
    func vocelloGlassSurface(
        padding: CGFloat = LayoutConstants.cardPadding,
        radius: CGFloat = LayoutConstants.cardRadius,
        fill: Color = AppTheme.cardFill
    ) -> some View {
        modifier(VocelloGlassSurface(padding: padding, radius: radius, fill: fill))
    }

    func studioCard(
        padding: CGFloat = LayoutConstants.cardPadding,
        radius: CGFloat = LayoutConstants.cardRadius
    ) -> some View {
        vocelloGlassSurface(padding: padding, radius: radius, fill: AppTheme.cardFill)
    }

    func glassCard() -> some View {
        studioCard(padding: LayoutConstants.glassCardPadding, radius: LayoutConstants.cardRadius)
    }

    func stageCard() -> some View {
        vocelloGlassSurface(padding: 0, radius: LayoutConstants.stageRadius, fill: AppTheme.stageFill)
    }

    func inlinePanel(padding: CGFloat = 14, radius: CGFloat = 16) -> some View {
        vocelloGlassSurface(padding: padding, radius: radius, fill: AppTheme.inlineFill)
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
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 52, alignment: .leading)
            content
        }
    }
}

private struct VocelloGlassBadge: ViewModifier {
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

private struct VocelloGlassField: ViewModifier {
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

private struct VocelloGlassRail: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            content
                .background(
                    Rectangle()
                        .fill(AppTheme.railBackground)
                        .overlay(alignment: .trailing) {
                            Rectangle()
                                .fill(AppTheme.railStroke)
                                .frame(width: 1)
                        }
                )
                .glassEffect(.regular.tint(AppTheme.smokedGlassTint), in: .rect(cornerRadius: 0))
                .glass3DDepth(radius: 0, intensity: colorScheme == .dark ? 0.35 : 0.22)
        } else {
            content
                .background(AppTheme.railBackground)
        }
        #else
        content
            .background(AppTheme.railBackground)
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
                                    AppTheme.warmEdgeHighlight.opacity(topOpacity),
                                    AppTheme.warmEdgeHighlight.opacity(midOpacity),
                                    .clear,
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: colorScheme == .dark ? 0.75 : 1
                        )
                }
                .shadow(color: AppTheme.charcoalShadow.opacity(shadowOpacity), radius: shadowRadius, y: shadowOffset)
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
            .foregroundStyle(AppTheme.textSecondary)
    }
}

struct VocelloGlassButton: ButtonStyle {
    let baseColor: Color

    func makeBody(configuration: Configuration) -> some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(AppTheme.warmIvory)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular.tint(baseColor), in: .rect(cornerRadius: 8))
                .opacity(configuration.isPressed ? 0.86 : 1.0)
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .offset(y: configuration.isPressed ? 1 : 0)
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
            .foregroundStyle(AppTheme.warmIvory)
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
                .foregroundStyle(AppTheme.warmIvory)
                .padding(12)
                .glassEffect(.regular.tint(baseColor), in: .circle)
                .opacity(configuration.isPressed ? 0.86 : 1.0)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .offset(y: configuration.isPressed ? 1 : 0)
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
            .foregroundStyle(AppTheme.warmIvory)
            .padding(12)
            .background(
                Circle()
                    .fill(baseColor.opacity(configuration.isPressed ? 0.75 : 0.95))
            )
            .appAnimation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct VocelloStudioBackground: View {
    var body: some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            LinearGradient(
                colors: [
                    Color(
                        light: Color(red: 0.962, green: 0.950, blue: 0.922),
                        dark: Color(red: 0.060, green: 0.067, blue: 0.083)
                    ),
                    Color(
                        light: Color(red: 0.930, green: 0.914, blue: 0.884),
                        dark: Color(red: 0.090, green: 0.096, blue: 0.116)
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
        content.foregroundStyle(AppTheme.textSecondary)
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
            RoundedRectangle(cornerRadius: LayoutConstants.cardRadius, style: .continuous)
                .fill(AppTheme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LayoutConstants.cardRadius, style: .continuous)
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
    @Environment(\.cardGlassTint) private var cardGlassTint

    func makeBody(configuration: Configuration) -> some View {
        let resolvedTint: Color = cardGlassTint.map {
            AppTheme.surfaceGlassTint($0, for: colorScheme)
        } ?? AppTheme.smokedGlassTint
        let resolvedStroke: Color = cardGlassTint.map {
            AppTheme.accentStroke($0, for: colorScheme).opacity(0.55)
        } ?? AppTheme.cardStroke.opacity(AppTheme.surfaceStrokeOpacity(for: colorScheme))
        let depthIntensity: Double = cardGlassTint == nil ? 1.0 : 1.15
        return VStack(alignment: .leading, spacing: 8) {
            configuration.label
            configuration.content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: LayoutConstants.cardRadius, style: .continuous)
                .fill(AppTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: LayoutConstants.cardRadius, style: .continuous)
                        .strokeBorder(
                            resolvedStroke,
                            lineWidth: AppTheme.surfaceStrokeWidth(for: colorScheme)
                        )
                )
        )
        .glassEffect(.regular.tint(resolvedTint), in: .rect(cornerRadius: LayoutConstants.cardRadius))
        .glass3DDepth(radius: LayoutConstants.cardRadius, intensity: depthIntensity)
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
            self.background(VocelloStudioBackground())
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
        modifier(VocelloGlassBadge(tint: tint))
    }

    @ViewBuilder
    func vocelloGlassBadge(tint: Color? = nil) -> some View {
        modifier(VocelloGlassBadge(tint: tint))
    }

    /// Profile-aware glass text field background with 3D depth.
    @ViewBuilder
    func glassTextField(
        radius: CGFloat = 8,
        strokeColor: Color? = nil,
        strokeWidth: CGFloat = 1
    ) -> some View {
        modifier(VocelloGlassField(radius: radius, strokeColor: strokeColor, strokeWidth: strokeWidth))
    }

    @ViewBuilder
    func vocelloGlassField(
        radius: CGFloat = 8,
        strokeColor: Color? = nil,
        strokeWidth: CGFloat = 1
    ) -> some View {
        modifier(VocelloGlassField(radius: radius, strokeColor: strokeColor, strokeWidth: strokeWidth))
    }

    @ViewBuilder
    func vocelloGlassRail() -> some View {
        modifier(VocelloGlassRail())
    }

    /// Adds 3D depth to glass surfaces: top-edge highlight gradient + drop shadow.
    @ViewBuilder
    func glass3DDepth(radius: CGFloat = 12, intensity: Double = 1.0) -> some View {
        modifier(Glass3DDepthStyle(radius: radius, intensity: intensity))
    }

}

// MARK: - Mode-aware Liquid Glass tinting

/// Environment key injected by each generation screen (Custom Voice,
/// Voice Design, Voice Cloning) so downstream card surfaces
/// (`StudioSectionCard`, `CompactConfigurationSection`) pick up a
/// Vocello-mode-colored glass tint without every view taking an
/// explicit color parameter. A `nil` value preserves the default
/// `AppTheme.smokedGlassTint` treatment used by neutral surfaces
/// (Library, Settings, Models).
private struct CardGlassTintKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    var cardGlassTint: Color? {
        get { self[CardGlassTintKey.self] }
        set { self[CardGlassTintKey.self] = newValue }
    }
}

extension View {
    /// Tag a subtree so every Liquid-Glass card surface underneath uses a
    /// subtle mode-colored tint (warm golden on Custom Voice, lavender
    /// purple on Voice Design, terracotta on Voice Cloning). Resolves to
    /// the neutral smoked tint when unset or when mode color is nil.
    func modeGlassTint(_ color: Color?) -> some View {
        environment(\.cardGlassTint, color)
    }

    /// Layers a subtle top wash of the mode color behind the content canvas
    /// so Liquid Glass above it has something warm to refract.
    func modeCanvasBackdrop(_ color: Color?) -> some View {
        background(ModeCanvasBackdrop(color: color))
    }
}

private struct ModeCanvasBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    let color: Color?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                AppTheme.canvasBackground
                if let color {
                    LinearGradient(
                        colors: [
                            color.opacity(colorScheme == .dark ? 0.13 : 0.07),
                            color.opacity(0)
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                    .frame(width: geo.size.width, height: max(geo.size.height * 0.55, 240))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
    }
}
