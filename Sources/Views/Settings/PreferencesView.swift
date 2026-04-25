import SwiftUI

struct PreferencesView: View {
    @AppStorage("autoPlay") private var autoPlay = true
    @AppStorage("outputDirectory") private var outputDirectory = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LayoutConstants.sectionSpacing) {
                StudioCollectionHeader(
                    eyebrow: "Settings",
                    title: "Preferences",
                    subtitle: "Tune playback and storage while keeping the local studio easy to reason about.",
                    iconName: "slider.horizontal.3",
                    accentColor: AppTheme.preferences,
                    trailing: autoPlay ? "Autoplay on" : "Autoplay off"
                )

                StudioSectionCard(
                    title: "General",
                    iconName: "play.circle",
                    accentColor: AppTheme.preferences
                ) {
                    Toggle("Auto-play generated audio", isOn: $autoPlay)
                        .tint(AppTheme.preferences)
                        .accessibilityIdentifier("preferences_autoPlayToggle")

                    Text("Play the latest result automatically after generation finishes.")
                        .font(.callout)
                        .foregroundStyle(AppTheme.textSecondary)
                }

                StudioSectionCard(
                    title: "Storage",
                    iconName: "externaldrive",
                    accentColor: AppTheme.preferences
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Output directory")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)

                        TextField("Output directory", text: $outputDirectory)
                            .textFieldStyle(.plain)
                            .focusEffectDisabled()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .glassTextField(radius: 10)
                            .accessibilityIdentifier("preferences_outputDirectory")

                        HStack(spacing: 8) {
                            Button {
                                browseForOutputDirectory()
                            } label: {
                                Label("Browse...", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("preferences_browseButton")

                            Button {
                                outputDirectory = ""
                            } label: {
                                Label("Reset", systemImage: "arrow.counterclockwise")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("preferences_outputResetButton")

                            Spacer(minLength: 0)

                            Button {
                                openAppSupportDirectory()
                            } label: {
                                Label("App Support", systemImage: "arrow.up.forward.app")
                            }
                            .buttonStyle(VocelloGlassButton(baseColor: AppTheme.preferences.opacity(0.90)))
                            .accessibilityIdentifier("preferences_openFinderButton")
                        }

                        Text(outputDirectorySummary)
                            .font(.callout)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }

                StudioSectionCard(
                    title: "Maintenance",
                    iconName: "checkmark.seal",
                    accentColor: AppTheme.preferences
                ) {
                    Text("Vocello runs natively and keeps generation and voice management inside the Swift runtime.")
                        .font(.callout)
                        .foregroundStyle(AppTheme.textSecondary)
                        .accessibilityIdentifier("preferences_nativeMaintenanceNote")
                }
            }
            .padding(20)
            .contentColumn(maxWidth: 760)
        }
        .profileBackground(AppTheme.canvasBackground)
        .frame(minWidth: 580, minHeight: 420)
        .navigationTitle("Preferences")
        .accessibilityIdentifier("screen_preferences")
    }

    private var outputDirectorySummary: String {
        if outputDirectory.isEmpty {
            return "Default: ~/Library/Application Support/QwenVoice/outputs/"
        }
        return "Custom: \(outputDirectory)"
    }

    private func browseForOutputDirectory() {
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

}
