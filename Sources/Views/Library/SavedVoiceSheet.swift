import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SavedVoiceSheetConfiguration: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let confirmLabel: String
    let initialName: String
    let initialAudioPath: String
    let initialTranscript: String

    static let manualAdd = SavedVoiceSheetConfiguration(
        title: "Add Voice Sample",
        subtitle: "Save a reference clip here, then use it in Voice Cloning.",
        confirmLabel: "Add Saved Voice",
        initialName: "",
        initialAudioPath: "",
        initialTranscript: ""
    )

    static func cloneResult(
        suggestedName: String,
        audioPath: String,
        transcript: String
    ) -> SavedVoiceSheetConfiguration {
        SavedVoiceSheetConfiguration(
            title: "Save to Saved Voices",
            subtitle: "Keep this clone as a reusable reference for Voice Cloning.",
            confirmLabel: "Save to Saved Voices",
            initialName: suggestedName,
            initialAudioPath: audioPath,
            initialTranscript: transcript
        )
    }

    static func designResult(
        voiceDescription: String,
        audioPath: String,
        transcript: String
    ) -> SavedVoiceSheetConfiguration {
        SavedVoiceSheetConfiguration(
            title: "Save Designed Voice",
            subtitle: "Keep this designed voice as a reusable reference for Voice Cloning.",
            confirmLabel: "Save to Saved Voices",
            initialName: SavedVoiceNameSuggestion.designResultName(from: voiceDescription),
            initialAudioPath: audioPath,
            initialTranscript: transcript
        )
    }
}

enum SavedVoiceNameSanitizer {
    static func normalizedName(_ rawName: String) -> String {
        rawName
            .replacingOccurrences(
                of: #"[^\w\s-]"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
    }
}

enum SavedVoiceNameSuggestion {
    static let designedVoiceFallback = "Designed_Voice"

    static func designResultName(
        from voiceDescription: String,
        fallback: String = designedVoiceFallback,
        maxLength: Int = 36
    ) -> String {
        let normalized = SavedVoiceNameSanitizer.normalizedName(voiceDescription)
        guard !normalized.isEmpty else { return fallback }
        guard normalized.count > maxLength else { return normalized }

        let components = normalized.split(separator: "_")
        var shortened = ""
        for component in components {
            let separator = shortened.isEmpty ? "" : "_"
            let candidate = shortened + separator + component
            if candidate.count > maxLength {
                break
            }
            shortened = candidate
        }

        if shortened.isEmpty {
            shortened = String(normalized.prefix(maxLength))
                .trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        }

        return shortened.isEmpty ? fallback : shortened
    }
}

struct SavedVoiceSheet: View {
    @EnvironmentObject private var pythonBridge: PythonBridge
    @Environment(\.dismiss) private var dismiss

    let configuration: SavedVoiceSheetConfiguration
    let onComplete: (Voice) -> Void

    @State private var name: String
    @State private var audioPath: String
    @State private var transcript: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var existingNormalizedNames: Set<String> = []

    init(
        configuration: SavedVoiceSheetConfiguration,
        onComplete: @escaping (Voice) -> Void
    ) {
        self.configuration = configuration
        self.onComplete = onComplete
        _name = State(initialValue: configuration.initialName)
        _audioPath = State(initialValue: configuration.initialAudioPath)
        _transcript = State(initialValue: configuration.initialTranscript)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedName: String {
        SavedVoiceNameSanitizer.normalizedName(trimmedName)
    }

    private var validationMessage: String? {
        guard !trimmedName.isEmpty else { return nil }

        if normalizedName.isEmpty {
            return "Enter a name with letters or numbers."
        }

        if existingNormalizedNames.contains(normalizedName) {
            return "A saved voice named \"\(normalizedName)\" already exists. Choose a different name."
        }

        return nil
    }

    private var canSubmit: Bool {
        !trimmedName.isEmpty
            && !audioPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && validationMessage == nil
            && !isSaving
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(configuration.title)
                .font(.title2.weight(.bold))

            Text(configuration.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("Saved voice name", text: $name)
                        .textFieldStyle(.plain)
                        .focusEffectDisabled()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .glassTextField(radius: 8)
                        .accessibilityIdentifier("voicesEnroll_nameField")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Audio")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("Reference audio file", text: $audioPath)
                            .textFieldStyle(.plain)
                            .focusEffectDisabled()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .glassTextField(radius: 8)
                            .accessibilityIdentifier("voicesEnroll_audioPathField")

                        Button("Browse...") {
                            browseForAudio()
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("voicesEnroll_browseButton")
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Transcript (optional but recommended)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    TextEditor(text: $transcript)
                        .font(.body)
                        .focusEffectDisabled()
                        .frame(minHeight: 100)
                        .padding(8)
                        #if QW_UI_LIQUID
                        .background {
                            if #available(macOS 26, *) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(white: 0.16))
                                    .glassEffect(.regular.tint(AppTheme.smokedGlassTint), in: .rect(cornerRadius: 10))
                            } else {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color(nsColor: .textBackgroundColor))
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(AppTheme.cardStroke.opacity(0.45), lineWidth: 1)
                                }
                            }
                        }
                        #else
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(AppTheme.cardStroke.opacity(0.45), lineWidth: 1)
                        )
                        #endif
                        .accessibilityIdentifier("voicesEnroll_transcriptField")
                }
            }

            if let activeMessage = validationMessage ?? errorMessage {
                Text(activeMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .accessibilityIdentifier("voicesEnroll_errorMessage")
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("voicesEnroll_cancelButton")

                Spacer()

                Button(configuration.confirmLabel) {
                    saveVoice()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("voicesEnroll_confirmButton")
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            await loadExistingVoiceNames()
        }
        .onChange(of: name) { _, _ in
            errorMessage = nil
        }
    }

    private func loadExistingVoiceNames() async {
        do {
            let voices = try await pythonBridge.listVoices()
            await MainActor.run {
                existingNormalizedNames = Set(voices.map(\.id))
            }
        } catch {
            await MainActor.run {
                existingNormalizedNames = []
            }
        }
    }

    private func browseForAudio() {
        if UITestAutomationSupport.isStubBackendMode,
           let url = UITestAutomationSupport.enrollAudioURL {
            audioPath = url.path
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .wav, .mp3, .aiff]
        if panel.runModal() == .OK, let url = panel.url {
            audioPath = url.path
        }
    }

    private func saveVoice() {
        guard validationMessage == nil else { return }

        isSaving = true
        errorMessage = nil

        Task {
            do {
                let savedVoice = try await pythonBridge.enrollVoice(
                    name: trimmedName,
                    audioPath: audioPath.trimmingCharacters(in: .whitespacesAndNewlines),
                    transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil
                        : transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                await MainActor.run {
                    onComplete(savedVoice)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
            await MainActor.run {
                isSaving = false
            }
        }
    }
}
