import SwiftUI

struct SidebarStatusView: View {
    @EnvironmentObject var pythonBridge: PythonBridge

    private enum StatusState {
        case idle
        case starting
        case active(percent: Int, message: String)
        case error(String)
        case crashed(String)
    }

    private var state: StatusState {
        if let error = pythonBridge.lastError {
            return pythonBridge.isReady ? .error(error) : .crashed(error)
        }
        if !pythonBridge.isReady { return .starting }
        if pythonBridge.isProcessing {
            return .active(
                percent: pythonBridge.progressPercent,
                message: pythonBridge.progressMessage.isEmpty ? "Processing..." : pythonBridge.progressMessage
            )
        }
        return .idle
    }

    private var stateKey: String {
        switch state {
        case .idle: return "idle"
        case .starting: return "starting"
        case .active: return "active"
        case .error: return "error"
        case .crashed: return "crashed"
        }
    }

    var body: some View {
        statusContent
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sidebar_generationStatus")
            .appAnimation(.easeInOut(duration: 0.25), value: stateKey)
    }

    @ViewBuilder
    private var statusContent: some View {
        switch state {
        case .idle:
            idleView
        case .starting:
            startingView
        case .active(let percent, let message):
            activeView(percent: percent, message: message)
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
        .accessibilityIdentifier("sidebar_backendStatus")
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
        .accessibilityIdentifier("sidebar_backendStatus")
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusBackground(color: AppTheme.accent, fillOpacity: 0.06, strokeOpacity: 0.12))
    }

    // MARK: - Active (with progress bar)

    private func activeView(percent: Int, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if percent > 0 {
                HStack(spacing: 8) {
                    ProgressView(value: Double(percent), total: 100)
                        .tint(AppTheme.accent)
                        .scaleEffect(y: 0.6)
                    Text("\(percent)%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityIdentifier("sidebar_backendStatus")
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
        .accessibilityIdentifier("sidebar_backendStatus")
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
        .accessibilityIdentifier("sidebar_backendStatus")
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
