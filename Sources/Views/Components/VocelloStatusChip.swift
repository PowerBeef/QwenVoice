import SwiftUI

/// Memory / runtime health indicator chip — a colored dot + memory reading +
/// state label. Mirrors the iOS reference's `VHeader` chip. Uses
/// `AppTheme.statusHealthy/Guarded/Critical` for the dot tone.
struct VocelloStatusChip: View {
    enum State: String {
        case healthy = "Healthy"
        case guarded = "Guarded"
        case critical = "Critical"

        var color: Color {
            switch self {
            case .healthy: return AppTheme.statusHealthy
            case .guarded: return AppTheme.statusGuarded
            case .critical: return AppTheme.statusCritical
            }
        }
    }

    let memoryMB: Double?
    let state: State

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            statusDot
            memoryGroup
            stateLabel
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(chipBackground)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Runtime status \(state.rawValue)")
        .accessibilityValue(memoryMB.map { "\(Int($0)) megabytes" } ?? "")
    }

    private var statusDot: some View {
        Circle()
            .fill(state.color)
            .frame(width: 6, height: 6)
    }

    @ViewBuilder
    private var memoryGroup: some View {
        if let memoryMB {
            Text(memoryFormatted(memoryMB))
                .font(.vocelloCaption)
                .foregroundStyle(AppTheme.textSecondary)
                .monospacedDigit()
            Text("·")
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary.opacity(0.65))
        }
    }

    private var stateLabel: some View {
        Text(state.rawValue)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.color)
    }

    private var chipBackground: some View {
        Capsule(style: .continuous)
            .fill(AppTheme.inlineFill.opacity(colorScheme == .dark ? 0.74 : 0.85))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(AppTheme.inlineStroke.opacity(colorScheme == .dark ? 0.22 : 0.45), lineWidth: 0.5)
            )
    }

    private func memoryFormatted(_ mb: Double) -> String {
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024.0)
        }
        return String(format: "%.1f MB", mb)
    }
}
