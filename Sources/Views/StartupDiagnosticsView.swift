import AppKit
import SwiftUI

struct StartupDiagnosticsView: View {
    let snapshot: AppLaunchDiagnosticsSnapshot
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Label("QwenVoice", systemImage: "waveform")
                    .font(.title.weight(.semibold))

                Text(snapshot.issue.summary)
                    .font(.title3.weight(.semibold))

                Text("The app can't continue until its bundled resources are valid. You can retry the startup checks or copy the diagnostics for troubleshooting.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    diagnosticsRow("Manifest path", snapshot.manifestPath)
                    diagnosticsRow("Backend path", snapshot.backendPath)
                    diagnosticsRow("Python path", snapshot.pythonPath)
                    diagnosticsRow("ffmpeg path", snapshot.ffmpegPath)

                    Divider()

                    Text("Underlying error")
                        .font(.subheadline.weight(.semibold))

                    Text(snapshot.underlyingError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .profileGroupBoxStyle()

            HStack(spacing: 12) {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .accessibilityIdentifier("startupDiagnostics_retryButton")

                Button("Copy Diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snapshot.diagnosticsText, forType: .string)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("startupDiagnostics_copyButton")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
        .profileBackground(AppTheme.canvasBackground)
        .accessibilityIdentifier("startupDiagnostics_view")
    }

    private func diagnosticsRow(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline.weight(.semibold))
            Text(value ?? "Not found")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
