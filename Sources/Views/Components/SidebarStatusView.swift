import SwiftUI

struct SidebarStatusView: View {
    @EnvironmentObject var pythonBridge: PythonBridge

    private var stateKey: String {
        switch pythonBridge.sidebarStatus {
        case .idle: return "idle"
        case .starting: return "starting"
        case .running: return "active"
        case .error: return "error"
        case .crashed: return "crashed"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                statusContent
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sidebar_backendStatus")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar_generationStatus")
        .appAnimation(.easeInOut(duration: 0.25), value: stateKey)
    }

    @ViewBuilder
    private var statusContent: some View {
        switch pythonBridge.sidebarStatus {
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
                .frame(width: 6, height: 6)
            Text("Ready")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityIdentifier("sidebar_backendStatus_idle")
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusBackground(color: AppTheme.accent, fillOpacity: 0.04, strokeOpacity: 0.08))
    }

    // MARK: - Starting

    private var startingView: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text("Starting...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("sidebar_backendStatus_starting")
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusBackground(color: AppTheme.accent, fillOpacity: 0.06, strokeOpacity: 0.12))
    }

    // MARK: - Active (with progress bar)

    private func activeView(activity: ActivityStatus) -> some View {
        let percent = Int(((activity.fraction ?? 0.0) * 100.0).rounded())

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(activity.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let fraction = activity.fraction {
                HStack(spacing: 8) {
                    ProgressView(value: min(max(fraction, 0.0), 1.0), total: 1.0)
                        .tint(AppTheme.accent)
                        .scaleEffect(y: 0.6)
                    Text("\(percent)%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityIdentifier("sidebar_backendStatus_active")
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusBackground(color: AppTheme.accent, fillOpacity: 0.08, strokeOpacity: 0.15))
    }

    // MARK: - Error (dismissible)

    private func errorView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Error")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    pythonBridge.lastError = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityIdentifier("sidebar_backendStatus_error")
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusBackground(color: .orange, fillOpacity: 0.08, strokeOpacity: 0.15))
    }

    // MARK: - Crashed

    private func crashedView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text("Engine Stopped")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            }
            Text("Restart the app to continue")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("sidebar_backendStatus_crashed")
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusBackground(color: .red, fillOpacity: 0.08, strokeOpacity: 0.15))
    }

    // MARK: - Shared Background

    private func statusBackground(color: Color, fillOpacity: Double, strokeOpacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(color.opacity(fillOpacity))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(color.opacity(strokeOpacity), lineWidth: 1)
            )
    }
}
