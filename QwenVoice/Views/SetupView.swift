import SwiftUI

/// Full-screen view shown during first-launch environment setup.
struct SetupView: View {
    @ObservedObject var envManager: PythonEnvironmentManager

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(
                    LinearGradient(
                        colors: [AppTheme.customVoice, AppTheme.voiceDesign, AppTheme.voiceCloning],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .accessibilityIdentifier("setup_icon")

            Text("Qwen Voice")
                .font(.largeTitle.bold())
                .foregroundStyle(
                    LinearGradient(
                        colors: [AppTheme.customVoice, AppTheme.voiceDesign],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .accessibilityIdentifier("setup_title")

            switch envManager.state {
            case .checking:
                checkingView

            case .settingUp(let phase):
                settingUpView(phase: phase)

            case .failed(let message):
                failedView(message: message)

            case .ready:
                readyView
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Substates

    private var checkingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Checking Python environment...")
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
                Text("Finding Python...")
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("setup_findingPythonLabel")

            case .creatingVenv:
                ProgressView()
                    .controlSize(.large)
                Text("Creating virtual environment...")
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
                Text("Updating dependencies...")
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
            Text("Starting...")
                .foregroundColor(.secondary)
                .accessibilityIdentifier("setup_startingLabel")
        }
    }
}
