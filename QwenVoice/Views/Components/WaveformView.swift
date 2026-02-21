import SwiftUI

/// Draws an audio waveform from sample data, with a progress overlay.
struct WaveformView: View {
    let samples: [Float]
    var progress: Double = 0

    var body: some View {
        GeometryReader { geometry in
            let barWidth: CGFloat = 3
            let spacing: CGFloat = 2
            let totalBarWidth = barWidth + spacing
            let barCount = min(samples.count, Int(geometry.size.width / totalBarWidth))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    let sampleIndex = samples.count > barCount
                        ? index * samples.count / barCount
                        : index
                    let height = max(2, CGFloat(samples[safe: sampleIndex] ?? 0) * geometry.size.height)
                    let progressFraction = barCount > 0 ? Double(index) / Double(barCount) : 0

                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(progressFraction <= progress ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: barWidth, height: height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// Safe array subscript
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
