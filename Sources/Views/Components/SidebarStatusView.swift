import SwiftUI

struct SidebarFooterPresentation: Equatable {
    let inlinePlayerActivity: ActivityStatus?
    let showsStandaloneStatus: Bool

    static func resolve(sidebarStatus: SidebarStatus, isLiveStream: Bool) -> Self {
        guard isLiveStream,
              case .running(let activity) = sidebarStatus,
              activity.presentation == .inlinePlayer else {
            return Self(inlinePlayerActivity: nil, showsStandaloneStatus: true)
        }

        return Self(inlinePlayerActivity: activity, showsStandaloneStatus: false)
    }
}

struct SidebarStatusView: View {
    @Environment(\.colorScheme) private var colorScheme
    let sidebarStatus: SidebarStatus
    let clearError: @MainActor () -> Void

    private var stateKey: String {
        switch sidebarStatus {
        case .idle: return "idle"
        case .starting: return "starting"
        case .running: return "active"
        case .error: return "error"
        case .crashed: return "crashed"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Engine")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            statusContent
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sidebar_backendStatus")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar_generationStatus")
        .appAnimation(.easeInOut(duration: 0.25), value: stateKey)
    }

    @ViewBuilder
    private var statusContent: some View {
        switch sidebarStatus {
        case .idle:
            idleView
        case .starting:
            startingView
        case .running(let activity):
            activeView(activity: activity)
        case .error(let message):
            errorView(message: message)
        case .crashed(let message):
            crashedView(message: message)
        }
    }

    // MARK: - Idle

    private var idleView: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(AppTheme.accent)
                .frame(width: 5, height: 5)
            Text("Ready")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("sidebar_backendStatus_idle")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Starting

    private var startingView: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text("Starting engine…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("sidebar_backendStatus_starting")
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Active (with progress bar)

    private func activeView(activity: ActivityStatus) -> some View {
        let percent = Int(((activity.fraction ?? 0.0) * 100.0).rounded())

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(activity.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let fraction = activity.fraction {
                HStack(spacing: 8) {
                    ProgressView(value: min(max(fraction, 0.0), 1.0), total: 1.0)
                        .tint(AppTheme.statusProgressTint)
                        .scaleEffect(y: 0.6)
                    Text("\(percent)%")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityIdentifier("sidebar_backendStatus_active")
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusBackground(color: AppTheme.accent, fillOpacity: 0.035, strokeOpacity: 0.07))
    }

    // MARK: - Error (dismissible)

    private func errorView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Error")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    clearError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Text(message)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityIdentifier("sidebar_backendStatus_error")
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusBackground(color: .orange, fillOpacity: 0.05, strokeOpacity: 0.1))
    }

    // MARK: - Crashed

    private func crashedView(message: String) -> some View {
        let detail = message.isEmpty ? "Restart the app to continue" : message

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text("Engine Stopped")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
            }
            Text(detail)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityIdentifier("sidebar_backendStatus_crashed")
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusBackground(color: .red, fillOpacity: 0.05, strokeOpacity: 0.1))
    }

    // MARK: - Shared Background

    @ViewBuilder
    private func statusBackground(color: Color, fillOpacity: Double, strokeOpacity: Double) -> some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .dark ? Color.clear : AppTheme.inlineFill.opacity(0.62))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            color.opacity(colorScheme == .dark ? strokeOpacity : strokeOpacity * 0.56),
                            lineWidth: colorScheme == .dark ? 1 : 0.85
                        )
                )
                .glassEffect(
                    .regular.tint(colorScheme == .dark ? color : color.opacity(0.18)),
                    in: .rect(cornerRadius: 8)
                )
                .glass3DDepth(radius: 8, intensity: colorScheme == .dark ? 0.35 : 0.16)
        } else {
            statusBackgroundLegacy(color: color, fillOpacity: fillOpacity, strokeOpacity: strokeOpacity)
        }
        #else
        statusBackgroundLegacy(color: color, fillOpacity: fillOpacity, strokeOpacity: strokeOpacity)
        #endif
    }

    private func statusBackgroundLegacy(color: Color, fillOpacity: Double, strokeOpacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(color.opacity(fillOpacity))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(color.opacity(strokeOpacity), lineWidth: 1)
            )
    }
}
