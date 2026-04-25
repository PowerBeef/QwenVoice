import SwiftUI

/// Vocello "V" monogram — Swift port of the SVG used in the iOS reference
/// (`refs/vocello_mark.png`, traced from `lib/vocello-chrome.jsx:VMark`).
/// Two overlapping V shapes with a back/front gradient pair.
///
/// Default size renders at 28pt × ~24.6pt to match the iOS chrome's wordmark
/// pairing. Pass an explicit `size` to scale.
struct VocelloVMark: View {
    var size: CGFloat = 28

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 32
            let backPath = Path { path in
                path.move(to: CGPoint(x: 2 * scale, y: 2 * scale))
                path.addLine(to: CGPoint(x: 16 * scale, y: 26 * scale))
                path.addLine(to: CGPoint(x: 30 * scale, y: 2 * scale))
                path.addLine(to: CGPoint(x: 23 * scale, y: 2 * scale))
                path.addLine(to: CGPoint(x: 16 * scale, y: 15 * scale))
                path.addLine(to: CGPoint(x: 9 * scale, y: 2 * scale))
                path.closeSubpath()
            }
            let frontPath = Path { path in
                path.move(to: CGPoint(x: 10 * scale, y: 2 * scale))
                path.addLine(to: CGPoint(x: 16 * scale, y: 13 * scale))
                path.addLine(to: CGPoint(x: 22 * scale, y: 2 * scale))
                path.addLine(to: CGPoint(x: 19 * scale, y: 2 * scale))
                path.addLine(to: CGPoint(x: 16 * scale, y: 8 * scale))
                path.addLine(to: CGPoint(x: 13 * scale, y: 2 * scale))
                path.closeSubpath()
            }

            let backGradient = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [AppTheme.brandPurple, AppTheme.voiceDesign]),
                startPoint: .zero,
                endPoint: CGPoint(x: canvasSize.width, y: canvasSize.height)
            )
            context.fill(backPath, with: backGradient)

            // 92% opacity baked into the gradient stops — Canvas shading
            // doesn't expose a per-fill opacity helper, so we apply it via
            // the colors themselves to match the iOS reference's frontV alpha.
            let frontGradient = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [
                    Color.white.opacity(0.96 * 0.92),
                    AppTheme.brandLavender.opacity(0.92),
                ]),
                startPoint: CGPoint(x: canvasSize.width / 2, y: 0),
                endPoint: CGPoint(x: canvasSize.width / 2, y: canvasSize.height)
            )
            context.fill(frontPath, with: frontGradient)
        }
        .frame(width: size, height: size * 0.875)
        .accessibilityHidden(true)
    }
}
