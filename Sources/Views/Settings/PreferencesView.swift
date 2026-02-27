import SwiftUI

struct PreferencesView: View {
    @AppStorage("autoPlay") private var autoPlay = true
    @AppStorage("outputDirectory") private var outputDirectory = ""
    @EnvironmentObject private var envManager: PythonEnvironmentManager
    @State private var showResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                prefSection(header: "Playback", icon: "play.circle") {
                    HStack {
                        Text("Auto-play generated audio")
                        Spacer()
                        Toggle("", isOn: $autoPlay)
                            .toggleStyle(.switch)
                            .tint(AppTheme.preferences)
                            .labelsHidden()
                            .controlSize(.small)
                            .accessibilityIdentifier("preferences_autoPlayToggle")
                    }
                    .frame(maxWidth: .infinity)
                }

                prefSection(header: "Output", icon: "folder") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Output directory", text: $outputDirectory)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("preferences_outputDirectory")
                            Button("Browse...") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    outputDirectory = url.path
                                }
                            }
                            Button("Reset") {
                                outputDirectory = ""
                            }
                        }
                        if outputDirectory.isEmpty {
                            Text("Default: ~/Library/Application Support/QwenVoice/outputs/")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Custom: \(outputDirectory)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                prefSection(header: "Storage", icon: "internaldrive") {
                    HStack {
                        Text("App Support Directory")
                        Spacer()
                        Button("Open in Finder") {
                            NSWorkspace.shared.open(QwenVoiceApp.appSupportDir)
                        }
                        .accessibilityIdentifier("preferences_openFinderButton")
                    }
                }

                prefSection(header: "Python", icon: "terminal") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reset Python Environment")
                            Text("Deletes the virtual environment and reinstalls all dependencies.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Reset Environment") {
                            showResetConfirmation = true
                        }
                        .accessibilityIdentifier("preferences_resetEnvButton")
                    }
                }
            }
            .padding(24)
            .contentColumn()
        }
        .navigationTitle("Preferences")
        .alert("Reset Python Environment?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                envManager.resetEnvironment()
            }
        } message: {
            Text("This will delete the Python virtual environment and recreate it from scratch. The app will need to reinstall all dependencies.")
        }
    }

    @ViewBuilder
    private func prefSection<Content: View>(
        header: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(header, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(AppTheme.preferences.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppTheme.preferences.opacity(0.12), lineWidth: 1)
        )
    }
}
