import SwiftUI
import UniformTypeIdentifiers

private struct VoicesAlertState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct VoicesView: View {
    @EnvironmentObject private var pythonBridge: PythonBridge
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    let enrollRequestID: UUID?

    @State private var voices: [Voice] = []
    @State private var showingEnroll = false
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var actionAlert: VoicesAlertState?
    @State private var successMessage: String?
    @State private var voiceToDelete: Voice?
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let successMessage {
                Label(successMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.voices)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .accessibilityIdentifier("voices_successBanner")
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("screen_voices")
        .task {
            if pythonBridge.isReady {
                await loadVoices()
            }
        }
        .onChange(of: enrollRequestID) { _, newValue in
            guard newValue != nil else { return }
            showingEnroll = true
        }
        .onChange(of: pythonBridge.isReady) { _, isReady in
            guard isReady else { return }
            Task { await loadVoices() }
        }
        .sheet(isPresented: $showingEnroll) {
            EnrollVoiceSheet(onComplete: { voiceName in
                successMessage = "\"\(voiceName)\" is ready. Use it in Voice Cloning."
                Task { await loadVoices() }
            })
            .environmentObject(pythonBridge)
        }
        .alert("Delete Voice?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                voiceToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let voice = voiceToDelete {
                    deleteVoice(voice)
                }
                voiceToDelete = nil
            }
        } message: {
            if let voice = voiceToDelete {
                Text("This will permanently remove \"\(voice.name)\" from your voice library.")
            }
        }
        .alert(item: $actionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if !pythonBridge.isReady {
            ContentUnavailableView(
                "Starting backend...",
                systemImage: "arrow.triangle.2.circlepath.circle",
                description: Text("Enrolled voices will appear once the Python service is ready.")
            )
            .accessibilityIdentifier("voices_emptyState")
        } else if let loadError, voices.isEmpty, !isLoading {
            VStack(alignment: .leading, spacing: 12) {
                ContentUnavailableView(
                    "Couldn't load voices",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
                .accessibilityIdentifier("voices_errorState")

                Button("Try Again") {
                    Task { await loadVoices() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("voices_retryButton")
            }
        } else if isLoading && voices.isEmpty {
            ProgressView("Loading voices...")
        } else if voices.isEmpty {
            ContentUnavailableView(
                "No enrolled voices",
                systemImage: "person.2.wave.2",
                description: Text("Enroll a voice here, then use it in Voice Cloning.")
            )
            .accessibilityIdentifier("voices_emptyState")
        } else {
            List {
                Section {
                    LabeledContent("Saved voices", value: "\(voices.count)")
                        .accessibilityIdentifier("voices_librarySummary")
                }

                Section("Voice Library") {
                    ForEach(voices) { voice in
                        VoiceRow(
                            voice: voice,
                            onPlay: {
                                audioPlayer.playFile(voice.wavPath, title: voice.name)
                            },
                            onDelete: {
                                voiceToDelete = voice
                                showDeleteConfirmation = true
                            }
                        )
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

private extension VoicesView {
    func loadVoices() async {
        guard pythonBridge.isReady else {
            isLoading = false
            return
        }

        let hadVoices = !voices.isEmpty
        isLoading = true
        do {
            let loadedVoices = try await pythonBridge.listVoices()
            voices = loadedVoices
            loadError = nil
        } catch {
            if hadVoices {
                presentActionAlert(
                    title: "Couldn't refresh voices",
                    message: error.localizedDescription
                )
            } else {
                loadError = error.localizedDescription
            }
        }
        isLoading = false
    }

    func deleteVoice(_ voice: Voice) {
        Task {
            do {
                try await pythonBridge.deleteVoice(name: voice.name)
                voices.removeAll { $0.id == voice.id }
            } catch {
                presentActionAlert(
                    title: "Error",
                    message: "Failed to delete voice: \(error.localizedDescription)"
                )
            }
            await loadVoices()
        }
    }

    func presentActionAlert(title: String, message: String) {
        actionAlert = VoicesAlertState(title: title, message: message)
    }
}

private struct VoiceRow: View {
    let voice: Voice
    let onPlay: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label(voice.name, systemImage: "waveform.circle.fill")
                .font(.body.weight(.semibold))

            Spacer()

            Text(voice.hasTranscript ? "Transcript available" : "No transcript saved")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ControlGroup {
                Button("Preview", action: onPlay)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("voicesRow_play_\(voice.id)")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("voicesRow_delete_\(voice.id)")
            }
        }
        .padding(.vertical, 4)
    }
}

struct EnrollVoiceSheet: View {
    @EnvironmentObject var pythonBridge: PythonBridge
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var audioPath = ""
    @State private var transcript = ""
    @State private var isEnrolling = false
    @State private var errorMessage: String?

    var onComplete: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enroll New Voice")
                .font(.title2.weight(.bold))

            Text("Add a reference clip and transcript so the voice is ready for cloning.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                TextField("Voice name (e.g. Boss, Mom)", text: $name)
                    .accessibilityIdentifier("voicesEnroll_nameField")

                HStack {
                    TextField("Reference audio file", text: $audioPath)
                        .accessibilityIdentifier("voicesEnroll_audioPathField")

                    Button("Browse...") {
                        browseForAudio()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("voicesEnroll_browseButton")
                }

                TextField("Transcript", text: $transcript)
                    .accessibilityIdentifier("voicesEnroll_transcriptField")
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("voicesEnroll_cancelButton")

                Spacer()

                Button("Enroll") {
                    enroll()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || audioPath.isEmpty || isEnrolling)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("voicesEnroll_confirmButton")
            }
        }
        .padding(20)
        .frame(width: 480)
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

    private func enroll() {
        isEnrolling = true
        errorMessage = nil
        Task {
            do {
                try await pythonBridge.enrollVoice(
                    name: name,
                    audioPath: audioPath,
                    transcript: transcript.isEmpty ? nil : transcript
                )
                onComplete(name)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isEnrolling = false
        }
    }
}
