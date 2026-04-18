import SwiftUI

struct PreferencesView: View {
    @AppStorage("autoPlay") private var autoPlay = true
    @AppStorage("outputDirectory") private var outputDirectory = ""

    var body: some View {
        Form {
            Section("General") {
                Toggle("Auto-play generated audio", isOn: $autoPlay)
                    .tint(AppTheme.preferences)
                    .accessibilityIdentifier("preferences_autoPlayToggle")

                Text("Play the latest result automatically after generation finishes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("Output directory") {
                    VStack(alignment: .trailing, spacing: 8) {
                        TextField("Output directory", text: $outputDirectory)
                            .textFieldStyle(.plain)
                            .focusEffectDisabled()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(minWidth: 260)
                            .glassTextField(radius: 8)
                            .accessibilityIdentifier("preferences_outputDirectory")

                        HStack {
                            Button("Browse...") {
                                browseForOutputDirectory()
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("preferences_browseButton")

                            Button("Reset") {
                                outputDirectory = ""
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("preferences_outputResetButton")
                        }
                    }
                }

                Text(outputDirectorySummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button("Open App Support Directory") {
                    openAppSupportDirectory()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("preferences_openFinderButton")
            }

            Section("Maintenance") {
                Text("QwenVoice runs natively and keeps generation and voice management inside the Swift runtime.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("preferences_nativeMaintenanceNote")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 580, minHeight: 420)
        .navigationTitle("Preferences")
        .accessibilityIdentifier("screen_preferences")
        .overlay(alignment: .topLeading) {
            if UITestAutomationSupport.isEnabled {
                hiddenReadinessMarker
            }
        }
    }

    private var outputDirectorySummary: String {
        if outputDirectory.isEmpty {
            return "Default: ~/Library/Application Support/QwenVoice/outputs/"
        }
        return "Custom: \(outputDirectory)"
    }

    private func browseForOutputDirectory() {
        if UITestAutomationSupport.isStubBackendMode,
           let outputDirectoryURL = UITestAutomationSupport.outputDirectoryURL {
            outputDirectory = outputDirectoryURL.path
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url.path
        }
    }

    private func openAppSupportDirectory() {
        NSWorkspace.shared.open(QwenVoiceApp.appSupportDir)
    }

    private var hiddenReadinessMarker: some View {
        Text("ready")
            .font(.caption2)
            .foregroundStyle(.clear)
            .opacity(0.01)
            .frame(width: 1, height: 1, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityLabel("ready")
            .accessibilityValue("ready")
            .accessibilityIdentifier("settingsWindow_ready")
    }
}
