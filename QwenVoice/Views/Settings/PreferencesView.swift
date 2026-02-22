import SwiftUI

struct PreferencesView: View {
    @AppStorage("autoPlay") private var autoPlay = true
    @AppStorage("outputDirectory") private var outputDirectory = ""
    @EnvironmentObject private var envManager: PythonEnvironmentManager
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section("Playback") {
                Toggle("Auto-play generated audio", isOn: $autoPlay)
                    .accessibilityIdentifier("preferences_autoPlayToggle")
            }

            Section("Output") {
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

            Section("Storage") {
                HStack {
                    Text("App Support Directory")
                    Spacer()
                    Button("Open in Finder") {
                        NSWorkspace.shared.open(QwenVoiceApp.appSupportDir)
                    }
                    .accessibilityIdentifier("preferences_openFinderButton")
                }
            }

            Section("Python Environment") {
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
        .formStyle(.grouped)
        .navigationTitle("Preferences")
        .padding(24)
        .alert("Reset Python Environment?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                envManager.resetEnvironment()
            }
        } message: {
            Text("This will delete the Python virtual environment and recreate it from scratch. The app will need to reinstall all dependencies.")
        }
    }
}
