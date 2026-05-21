import SwiftUI
import UIKit
import QwenVoiceCore

// Primitives introduced by the May 2026 Vocello iOS redesign (Claude Design
// system). Lives alongside `IOSShellPrimitives.swift`; that file holds the
// older chrome (cards, badges, status strips). This one holds the new
// shared building blocks used by the unified Studio, the Player sheet, the
// Voices tab, and the bottom-sheet family.
//
// Token sources:
// - design_references/Vocello iOS/tokens.css (--radius-*, --space-*, --ease-out)
// - design_references/Vocello Design System/colors_and_type.css (colors,
//   shadows, surface ramp, stroke values)

// MARK: - Corner radii

enum IOSCornerRadius {
    static let chip: CGFloat = 8
    static let input: CGFloat = 10
    static let card: CGFloat = 16
    static let stage: CGFloat = 22
    static let sheetGrabber: CGFloat = 3
    // Pill / capsule shape uses Capsule(); 999 in design = continuous capsule.
}

// MARK: - Motion timing

enum IOSDesignMotion {
    /// 220ms ease-out (cubic-bezier 0.22, 1, 0.36, 1). Default sheet + state
    /// transition timing per `tokens.css` --dur-default / --ease-out.
    static let sheetReveal = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.22)
    /// 360ms ease-out for bottom-sheet slide-up.
    static let sheetSlideUp = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.36)
    /// 420ms ease-out for full-screen Player sheet slide-up.
    static let playerSheetSlideUp = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.42)
    /// 320ms for mode-segmented pill slide.
    static let modePillSlide = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.32)
    /// 150ms ease-out for state changes (chip selection, focus).
    static let stateChange = Animation.easeOut(duration: 0.15)
}

// MARK: - Mode backdrop

/// Radial wash behind the Studio + Player sheet. Anchored to the top of the
/// container; intensity fades toward 0 at the bottom. Per
/// `design_references/Vocello iOS/chrome.jsx` ModeBackdrop.
struct IOSModeBackdrop: View {
    let tint: Color
    let intensity: Intensity

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    enum Intensity {
        case whisper
        case warm
        case loud

        var topOpacity: Double {
            switch self {
            case .whisper: return 0.06
            case .warm: return 0.12
            case .loud: return 0.20
            }
        }
    }

    init(tint: Color, intensity: Intensity = .warm) {
        self.tint = tint
        self.intensity = intensity
    }

    var body: some View {
        if reduceTransparency {
            // Flat fallback — design system requires opaque alternatives.
            IOSBrandTheme.canvasTop
                .ignoresSafeArea()
        } else {
            ZStack {
                IOSBrandTheme.canvasTop
                RadialGradient(
                    colors: [
                        tint.opacity(intensity.topOpacity),
                        tint.opacity(intensity.topOpacity * 0.4),
                        .clear
                    ],
                    center: .top,
                    startRadius: 40,
                    endRadius: 520
                )
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Waveform bars

/// Static or playback-driven waveform bars. Deterministic heights from a
/// seed so repeated renders match. Used by mini-waveform thumbnails
/// (History rows), the inline player in Studio, and the full Player sheet.
///
/// Per `design_references/Vocello iOS/chrome.jsx` MiniWaveform / PlayerWaveform.
struct IOSWaveformBars: View {
    let seed: Int
    let barCount: Int
    let tint: Color
    let progress: Double
    let isAnimating: Bool

    @State private var animationPhase: Double = 0

    init(
        seed: Int,
        barCount: Int = 24,
        tint: Color,
        progress: Double = 1.0,
        isAnimating: Bool = false
    ) {
        self.seed = seed
        self.barCount = barCount
        self.tint = tint
        self.progress = progress
        self.isAnimating = isAnimating
    }

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = max(1, geo.size.width * 0.012)
            let totalSpacing = spacing * CGFloat(barCount - 1)
            let barWidth = (geo.size.width - totalSpacing) / CGFloat(barCount)
            let progressIndex = Int((Double(barCount) * progress).rounded())

            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    let height = barHeight(at: i, container: geo.size.height)
                    let isPast = i < progressIndex
                    Capsule(style: .continuous)
                        .fill(isPast ? tint : tint.opacity(0.35))
                        .frame(width: barWidth, height: height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }

    private func barHeight(at index: Int, container: CGFloat) -> CGFloat {
        // Deterministic pseudo-random in [0.18, 1.0] from seed + index.
        var x = UInt64(bitPattern: Int64(seed &* 1_000_003 &+ index &* 2_654_435_761))
        x ^= x &>> 33
        x &*= 0xff51_afd7_ed55_8ccd
        x ^= x &>> 33
        x &*= 0xc4ce_b9fe_1a85_ec53
        x ^= x &>> 33
        let normalized = Double(x & 0xffff_ffff) / Double(UInt32.max)
        let base = 0.18 + normalized * 0.82
        var amplitude = base
        if isAnimating {
            let wave = sin((animationPhase + Double(index) * 0.35) * .pi * 2)
            amplitude = max(0.25, base + wave * 0.12)
        }
        return max(2, container * CGFloat(amplitude))
    }
}

// MARK: - Voice avatar

/// Circular gradient avatar for built-in or saved voices. Hue derived from
/// the voice id so the same voice renders the same gradient everywhere.
///
/// Per `design_references/Vocello iOS/chrome.jsx` VoiceAvatar.
struct IOSVoiceAvatar: View {
    let seed: String
    let initials: String
    let diameter: CGFloat

    init(seed: String, initials: String, diameter: CGFloat = 44) {
        self.seed = seed
        self.initials = String(initials.prefix(2)).uppercased()
        self.diameter = diameter
    }

    var body: some View {
        let hue = hueForSeed(seed)
        let topColor = Color(hue: hue, saturation: 0.45, brightness: 0.78)
        let bottomColor = Color(hue: hue, saturation: 0.55, brightness: 0.52)

        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [topColor, bottomColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 0.75)
            Text(initials)
                .font(.system(size: diameter * 0.36, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.92))
        }
        .frame(width: diameter, height: diameter)
    }

    private func hueForSeed(_ seed: String) -> Double {
        var hasher = Hasher()
        hasher.combine(seed)
        let raw = UInt64(bitPattern: Int64(hasher.finalize()))
        return Double(raw % 360) / 360.0
    }
}

// MARK: - Mode dot

/// 6×6 colored dot used in History row meta + filter chips.
struct IOSModeDot: View {
    let tint: Color
    let diameter: CGFloat

    init(tint: Color, diameter: CGFloat = 6) {
        self.tint = tint
        self.diameter = diameter
    }

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: diameter, height: diameter)
    }
}

// MARK: - Bottom sheet

/// Reusable bottom sheet container. Drag-to-dismiss via a grabber. Uses the
/// system `.presentationDetents` when presented as a sheet, but the visual
/// chrome (glass surface, grabber, title) is provided here so the look is
/// consistent across pickers.
///
/// Caller wraps in `.sheet(isPresented:)` modifier; this view supplies the
/// content. For drag-to-dismiss the system sheet already handles it.
struct IOSBottomSheet<Content: View>: View {
    let title: String
    let tint: Color
    let onDismiss: (() -> Void)?
    let content: Content

    @Environment(\.dismiss) private var dismiss

    init(
        title: String,
        tint: Color = IOSBrandTheme.accent,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.tint = tint
        self.onDismiss = onDismiss
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            grabber
                .padding(.top, 8)
                .padding(.bottom, 6)

            header
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // R3 G.0 (2026-05-21): the per-sheet `IOSModeBackdrop` was a
        // whisper-intensity radial wash that added a hue to every
        // bottom sheet. Design's `.vc-sheet { background: rgba(20,22,
        // 30,0.92) + blur 32 }` is flat translucent dark with no
        // tint — the sheets read cleaner that way and the dock above
        // already carries the mode hue.
    }

    private var grabber: some View {
        // 36 × 5 pt per app.css `.vc-sheet-grabber`.
        Capsule(style: .continuous)
            .fill(IOSAppTheme.textTertiary.opacity(0.45))
            .frame(width: 36, height: 5)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(.title3, design: .default, weight: .semibold))
                .foregroundStyle(IOSAppTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onDismiss?()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textSecondary)
                    .frame(width: 32, height: 32)
                    .background {
                        Circle()
                            .fill(IOSAppTheme.glassSurfaceFillMuted.opacity(0.6))
                    }
            }
            .accessibilityLabel("Close")
        }
    }
}

// MARK: - Setup chip

/// Two-line setup chip used in Studio. Top line is a tiny eyebrow label
/// (e.g. "Voice"); bottom line is the current value (e.g. "Aiden").
/// Tapping the chip routes to a sheet.
///
/// Per `design_references/Vocello iOS/studio.jsx` setup-chip pattern.
struct IOSStudioSetupChip: View {
    let eyebrow: String
    let value: String
    let leadingSymbol: String?
    let leadingAvatar: AnyView?
    let tint: Color
    let isPlaceholder: Bool
    let action: () -> Void

    init(
        eyebrow: String,
        value: String,
        leadingSymbol: String? = nil,
        leadingAvatar: AnyView? = nil,
        tint: Color = IOSBrandTheme.accent,
        isPlaceholder: Bool = false,
        action: @escaping () -> Void
    ) {
        self.eyebrow = eyebrow
        self.value = value
        self.leadingSymbol = leadingSymbol
        self.leadingAvatar = leadingAvatar
        self.tint = tint
        self.isPlaceholder = isPlaceholder
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                if let leadingAvatar {
                    leadingAvatar
                        .frame(width: 32, height: 32)
                } else if let leadingSymbol {
                    ZStack {
                        Circle()
                            .fill(tint.opacity(0.22))
                            .frame(width: 32, height: 32)
                        Image(systemName: leadingSymbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(eyebrow.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(IOSAppTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(value)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isPlaceholder ? IOSAppTheme.textTertiary : IOSAppTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textTertiary)
                    .padding(.leading, 2)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.05))
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Filter chip row

/// Horizontal row of selectable filter chips. Used by Voices, History, and
/// Settings to filter content.
struct IOSFilterChipRow<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let tint: Color
    let label: (Option) -> String
    let leading: ((Option) -> AnyView)?

    init(
        options: [Option],
        selection: Binding<Option>,
        tint: Color,
        label: @escaping (Option) -> String,
        leading: ((Option) -> AnyView)? = nil
    ) {
        self.options = options
        self._selection = selection
        self.tint = tint
        self.label = label
        self.leading = leading
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options) { option in
                    chip(for: option)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(for option: Option) -> some View {
        let isSelected = option == selection

        return Button {
            withAnimation(IOSDesignMotion.stateChange) {
                selection = option
            }
            IOSHaptics.selection()
        } label: {
            HStack(spacing: 6) {
                if let leading {
                    leading(option)
                }
                Text(label(option))
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(isSelected ? IOSAppTheme.textPrimary : IOSAppTheme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                Capsule(style: .continuous)
                    .fill(isSelected ? IOSAppTheme.accentWash(tint) : IOSAppTheme.glassSurfaceFillMuted.opacity(0.5))
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(isSelected ? tint.opacity(0.32) : Color.white.opacity(0.10), lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Search field

/// Compact search field used in Voices + History tabs. Wraps a UIKit-aware
/// SwiftUI TextField with a leading magnifier glass and trailing clear
/// button.
struct IOSSearchField: View {
    @Binding var text: String
    let placeholder: String

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(IOSAppTheme.textTertiary)

            TextField(placeholder, text: $text)
                .focused($isFocused)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .foregroundStyle(IOSAppTheme.textPrimary)

            if !text.isEmpty {
                Button {
                    text = ""
                    IOSHaptics.selection()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(IOSAppTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: IOSCornerRadius.input, style: .continuous)
                .fill(IOSAppTheme.glassSurfaceFillMuted.opacity(0.62))
        }
        .overlay {
            RoundedRectangle(cornerRadius: IOSCornerRadius.input, style: .continuous)
                .stroke(isFocused ? IOSBrandTheme.accent.opacity(0.32) : Color.white.opacity(0.10), lineWidth: 0.8)
        }
        .iosAppAnimation(IOSDesignMotion.stateChange, value: isFocused)
    }
}

// MARK: - Primary CTA

/// Large gradient button used as the Studio Generate CTA. Tints to the
/// active mode's color; respects Reduce Transparency by falling back to a
/// flat fill.
struct IOSPrimaryCTAButton: View {
    let title: String
    let symbol: String?
    let tint: Color
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        title: String,
        symbol: String? = nil,
        tint: Color,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: {
            if isEnabled { action() }
        }) {
            HStack(alignment: .center, spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(IOSAppTheme.accentForeground)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background {
                if reduceTransparency || !isEnabled {
                    Capsule(style: .continuous)
                        .fill(isEnabled ? tint : IOSAppTheme.glassSurfaceFillMuted)
                } else {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint, tint.opacity(0.78)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.9)
            }
            .shadow(color: tint.opacity(isEnabled ? 0.30 : 0), radius: 14, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1.0 : 0.55)
        .iosAppAnimation(IOSDesignMotion.stateChange, value: isEnabled)
    }
}
