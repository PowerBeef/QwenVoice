import SwiftUI
import UIKit

// View modifiers + reusable shape helpers that build on `Theme`. Kept
// separate from `Theme.swift` so the token namespace stays scannable.

// MARK: - Glass surface modifier

struct ThemeGlassSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let fill: Color
    let strokeOpacity: Double
    let interactive: Bool

    @Environment(\.iosReduceTransparencyEnabled) private var reduceTransparency
    @Environment(\.iosGenerationPerformanceGate) private var performanceGate

    @ViewBuilder
    func body(content: Content) -> some View {
        let base = content
            .background { shape.fill(fill) }
            .overlay {
                shape
                    .stroke(Color.white.opacity(strokeOpacity), lineWidth: 0.8)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .inset(by: 0.65)
                    .stroke(Theme.Surface.glassInnerStroke, lineWidth: 0.55)
                    .allowsHitTesting(false)
            }

        if reduceTransparency || performanceGate {
            base
        } else if interactive {
            base.glassEffect(
                .regular.tint(Theme.glassTint(tint, intensity: 0.9)).interactive(),
                in: shape
            )
        } else {
            base.glassEffect(
                .regular.tint(Theme.glassTint(tint, intensity: 0.9)),
                in: shape
            )
        }
    }
}

extension View {
    /// Liquid Glass surface with subtle tint. Falls back to a flat fill
    /// when Reduce Transparency is on.
    func themeGlassSurface<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        fill: Color = Theme.Surface.card.opacity(0.82),
        strokeOpacity: Double = 0.12,
        interactive: Bool = false
    ) -> some View {
        modifier(
            ThemeGlassSurfaceModifier(
                shape: shape,
                tint: tint,
                fill: fill,
                strokeOpacity: strokeOpacity,
                interactive: interactive
            )
        )
    }
}

// MARK: - Dynamic Type for fixed point sizes

/// Scales a fixed `.system(size:)` font with Dynamic Type, relative to a text
/// style (default `.body`). SwiftUI's `.font(.system(size:))` does not scale —
/// this restores accessibility scaling for content text while keeping the
/// design's exact base sizes. Use for Text content; leave fixed glyph/chrome
/// sizes (icons in fixed frames, decorative waveforms) as-is.
private struct IOSScaledSystemFont: ViewModifier {
    @ScaledMetric private var scaledSize: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo style: Font.TextStyle) {
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: scaledSize, weight: weight, design: design))
    }
}

extension View {
    /// Dynamic-Type-scaling replacement for `.font(.system(size:weight:))` on
    /// content text.
    func iosScaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo style: Font.TextStyle = .body
    ) -> some View {
        modifier(IOSScaledSystemFont(size: size, weight: weight, design: design, relativeTo: style))
    }
}

// MARK: - Common shape factories

enum ThemeShape {
    static func card() -> RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
    }

    static func input() -> RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.input, style: .continuous)
    }

    static func stage() -> RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.stage, style: .continuous)
    }

    static func chip() -> RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
    }

    static func pill() -> Capsule {
        Capsule(style: .continuous)
    }
}

// MARK: - Accent foreground convenience

extension Color {
    /// The "ink on accent" color used for primary CTA labels.
    static var themeOnAccent: Color { Theme.Text.onAccent }
    static var themeOnAccentPressed: Color { Theme.Text.onAccentPressed }
}

// MARK: - Modern haptics (sensoryFeedback wrapper)

/// Centralized trigger keys for `.sensoryFeedback(...trigger:)`.
///
/// Per `references/latest-apis.md` (iOS 17+) views should prefer the
/// declarative `sensoryFeedback` modifier over imperative
/// `UISelectionFeedbackGenerator()` calls. Use these enum values as the
/// trigger payload so the same event fires once per state transition.
enum ThemeFeedback {
    enum Selection: Equatable { case fire(UUID) }
}
