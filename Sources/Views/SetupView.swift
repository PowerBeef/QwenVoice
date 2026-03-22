import SwiftUI

struct SetupView: View {
    @ObservedObject var envManager: PythonEnvironmentManager

    var body: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Label("QwenVoice", systemImage: "waveform")
                    .font(.title.weight(.semibold))
                    .accessibilityIdentifier("setup_title")

                Text("Runs locally on your Mac. First launch may take a few minutes while QwenVoice prepares Python and dependencies.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setup_reassurance")
            }
            .frame(maxWidth: 480, alignment: .leading)

            stateContent
                .frame(maxWidth: 480, alignment: .leading)
                .profileGroupBoxStyle()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .profileBackground(AppTheme.canvasBackground)
        .overlay(alignment: .topLeading) {
            if UITestAutomationSupport.isEnabled {
                Text("setup")
                    .font(.system(size: 1))
                    .opacity(0.01)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("setupView_visible")
                    .accessibilityHidden(false)
            }
        }
    }
}

private extension SetupView {
    @ViewBuilder
    var stateContent: some View {
        switch envManager.state {
        case .idle:
            EmptyView()
        case .checking:
            progressCard(
                title: "Checking environment",
                detail: "Making sure Python and dependencies are available.",
                accessibilityIdentifier: "setup_checkingLabel"
            )
        case .settingUp(let phase):
            setupPhaseView(phase: phase)
        case .failed(let message):
            failedView(message: message)
        case .ready:
            progressCard(
                title: "Starting QwenVoice",
                detail: "The app is almost ready.",
                accessibilityIdentifier: "setup_startingLabel"
            )
        }
    }

    func progressCard(
        title: String,
        detail: String,
        accessibilityIdentifier: String
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ProgressView()
                    .controlSize(.large)

                Text(title)
                    .font(.headline)
                    .accessibilityIdentifier(accessibilityIdentifier)

                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    func setupPhaseView(phase: PythonEnvironmentManager.SetupPhase) -> some View {
        switch phase {
        case .findingPython:
            progressCard(
                title: "Preparing Python",
                detail: "Looking for a usable runtime.",
                accessibilityIdentifier: "setup_findingPythonLabel"
            )
        case .creatingVenv:
            progressCard(
                title: "Preparing Python",
                detail: "Creating the local environment for QwenVoice.",
                accessibilityIdentifier: "setup_creatingVenvLabel"
            )
        case .installingDependencies(let installed, let total):
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    ProgressView(value: Double(installed), total: Double(max(total, 1)))
                        .accessibilityIdentifier("setup_progressBar")

                    Text("Installing dependencies (\(installed)/\(total))")
                        .font(.headline)
                        .accessibilityIdentifier("setup_progressLabel")

                    Text("This may take a few minutes on first launch.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("setup_progressHint")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .updatingDependencies:
            progressCard(
                title: "Installing dependencies",
                detail: "Refreshing the local Python environment.",
                accessibilityIdentifier: "setup_updatingDepsLabel"
            )
        }
    }

    func failedView(message: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Setup Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("setup_errorTitle")

                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("setup_errorMessage")

                Button("Try Again") {
                    envManager.retry()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.customVoice)
                .accessibilityIdentifier("setup_retryButton")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
