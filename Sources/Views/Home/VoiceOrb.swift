import SwiftUI

/// Decorative voice orb used in the Home hero — a slowly-rotating conic
/// gradient with a soft inner radial highlight and a centered waveform
/// glyph. Matches `lib/screen-home.jsx:VOrb` from the iOS reference.
///
/// Honors `Reduce Motion`: when on, the rotation is suppressed and the
/// orb renders as a static gradient.
struct VoiceOrb: View {
    @ScaledMetric(relativeTo: .largeTitle) private var scaledSize: CGFloat = 96
    private let overrideSize: CGFloat?

    init(size: CGFloat? = nil) {
        self.overrideSize = size
    }

    private var size: CGFloat { overrideSize ?? scaledSize }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Angle = .degrees(0)

    var body: some View {
        ZStack {
            AngularGradient(
                gradient: Gradient(colors: [
                    AppTheme.accent,
                    AppTheme.voiceDesign,
                    AppTheme.voiceCloning,
                    AppTheme.brandLavender,
                    AppTheme.accent
                ]),
                center: .center,
                angle: phase
            )
            .blur(radius: size * 0.06)

            Circle()
                .inset(by: size * 0.10)
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(0.20),
                            Color(red: 0.04, green: 0.043, blue: 0.051).opacity(0.85)
                        ]),
                        center: UnitPoint(x: 0.30, y: 0.30),
                        startRadius: 0,
                        endRadius: size * 0.45
                    )
                )

            Image(systemName: "waveform")
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle().stroke(AppTheme.cardStroke.opacity(0.4), lineWidth: 0.5)
        )
        .shadow(color: AppTheme.brandLavender.opacity(0.25), radius: 14, y: 8)
        .onAppear { startRotationIfAllowed() }
        .onChange(of: reduceMotion) { _, _ in startRotationIfAllowed() }
        .accessibilityHidden(true)
    }

    private func startRotationIfAllowed() {
        guard !reduceMotion else {
            phase = .degrees(90)
            return
        }
        phase = .degrees(90)
        withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) {
            phase = .degrees(450)
        }
    }
}
