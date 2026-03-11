import SwiftUI

/// Full-screen view shown during first-launch environment setup.
struct SetupView: View {
    @ObservedObject var envManager: PythonEnvironmentManager

    var body: some View {
        ZStack {
            AppTheme.canvasBackground

            VStack(spacing: 16) {
                Spacer()

                VStack(spacing: 16) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(AppTheme.accent)
                        .accessibilityIdentifier("setup_icon")

                    Text("QwenVoice")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.accent)
                        .accessibilityIdentifier("setup_title")

                    Text("Runs locally on your Mac. First launch may take a few minutes while QwenVoice prepares Python and dependencies.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                        .accessibilityIdentifier("setup_reassurance")

                    switch envManager.state {
                    case .idle:
                        EmptyView()

                    case .checking:
                        checkingView

                    case .settingUp(let phase):
                        settingUpView(phase: phase)

                    case .failed(let message):
                        failedView(message: message)

                    case .ready:
                        readyView
                    }
                }
                .padding(22)
                .frame(maxWidth: 500)
                .background(
                    RoundedRectangle(cornerRadius: LayoutConstants.stageRadius, style: .continuous)
                        .fill(AppTheme.cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LayoutConstants.stageRadius, style: .continuous)
                        .stroke(AppTheme.stageStroke, lineWidth: 1.2)
                )
                .shadow(color: AppTheme.stageGlow.opacity(0.26), radius: 20, y: 12)

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Substates

    private var checkingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Checking environment")
                .foregroundColor(.secondary)
                .accessibilityIdentifier("setup_checkingLabel")
        }
    }

    private func settingUpView(phase: PythonEnvironmentManager.SetupPhase) -> some View {
        VStack(spacing: 16) {
            switch phase {
            case .findingPython:
                ProgressView()
                    .controlSize(.large)
                Text("Preparing Python")
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("setup_findingPythonLabel")

            case .creatingVenv:
                ProgressView()
                    .controlSize(.large)
                Text("Preparing Python")
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("setup_creatingVenvLabel")

            case .installingDependencies(let installed, let total):
                VStack(spacing: 12) {
                    ProgressView(value: Double(installed), total: Double(max(total, 1)))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 300)
                        .tint(AppTheme.customVoice)
                        .accessibilityIdentifier("setup_progressBar")

                    Text("Installing dependencies (\(installed)/\(total))")
                        .font(.headline)
                        .accessibilityIdentifier("setup_progressLabel")

                    Text("This may take a few minutes on first launch")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("setup_progressHint")
                }

            case .updatingDependencies:
                ProgressView()
                    .controlSize(.large)
                Text("Installing dependencies")
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("setup_updatingDepsLabel")
            }
        }
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.red)
                .accessibilityIdentifier("setup_errorIcon")

            Text("Setup Failed")
                .font(.headline)
                .accessibilityIdentifier("setup_errorTitle")

            Text(message)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .textSelection(.enabled)
                .accessibilityIdentifier("setup_errorMessage")

            Button("Try Again") {
                envManager.retry()
            }
            .buttonStyle(GlowingGradientButtonStyle(baseColor: AppTheme.customVoice))
            .controlSize(.large)
            .accessibilityIdentifier("setup_retryButton")
        }
    }

    private var readyView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Starting QwenVoice")
                .foregroundColor(.secondary)
                .accessibilityIdentifier("setup_startingLabel")
        }
    }
}
