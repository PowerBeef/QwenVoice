import SwiftUI
import UniformTypeIdentifiers

private struct VoicesAlertState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct VoicesView: View {
    @EnvironmentObject var pythonBridge: PythonBridge
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel

    @State private var voices: [Voice] = []
    @State private var showingEnroll = false
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var actionAlert: VoicesAlertState?
    @State private var successMessage: String?
    @State private var voiceToDelete: Voice?
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LayoutConstants.sectionSpacing) {
                GenerationHeaderView(
                    title: "Voices",
                    subtitle: "Your voice library for Voice Cloning."
                ) {
                    Button {
                        showingEnroll = true
                    } label: {
                        Label("Enroll Voice", systemImage: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .buttonStyle(GlowingGradientButtonStyle(baseColor: AppTheme.voices))
                    .accessibilityIdentifier("voices_enrollButton")
                }

                if let successMessage {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AppTheme.voices)
                        Text(successMessage)
                            .font(.system(size: 14, weight: .medium))
                        Spacer()
                    }
                    .studioCard(padding: 12, radius: 14)
                    .accessibilityIdentifier("voices_successBanner")
                }

                if !pythonBridge.isReady {
                    voicesStateCard(
                        icon: "arrow.triangle.2.circlepath.circle",
                        title: "Starting backend...",
                        detail: "Enrolled voices will appear once the Python service is ready."
                    )
                } else if let loadError, voices.isEmpty, !isLoading {
                    VStack(spacing: 18) {
                        voicesStateCard(
                            icon: "exclamationmark.triangle",
                            title: "Couldn't load voices",
                            detail: loadError,
                            accessibilityIdentifier: "voices_errorState",
                            tint: .orange
                        )

                        Button("Try Again") {
                            Task { await loadVoices() }
                        }
                        .buttonStyle(GlowingGradientButtonStyle(baseColor: AppTheme.voices))
                        .accessibilityIdentifier("voices_retryButton")
                    }
                } else if isLoading && voices.isEmpty {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(AppTheme.voices)
                        Text("Loading voices...")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .studioCard()
                } else if voices.isEmpty {
                    voicesStateCard(
                        icon: "waveform.badge.plus",
                        title: "No enrolled voices",
                        detail: "Enroll a voice here, then use it in Voice Cloning.",
                        accessibilityIdentifier: "voices_emptyState"
                    )
                } else {
                    LazyVStack(spacing: 12) {
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
            }
            .padding(LayoutConstants.canvasPadding)
            .contentColumn()
        }
        .contentColumn()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen_voices")
        .task {
            if pythonBridge.isReady {
                await loadVoices()
            }
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

    private func loadVoices() async {
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

    private func deleteVoice(_ voice: Voice) {
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

    private func presentActionAlert(title: String, message: String) {
        actionAlert = VoicesAlertState(title: title, message: message)
    }

    @ViewBuilder
    private func voicesStateCard(
        icon: String,
        title: String,
        detail: String,
        accessibilityIdentifier: String = "voices_emptyState",
        tint: Color = AppTheme.voices
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .studioCard()
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

// MARK: - Voice Row (Card-style)

private struct VoiceRow: View {
    let voice: Voice
    let onPlay: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(AppTheme.voices)

            VStack(alignment: .leading, spacing: 5) {
                Text(voice.name)
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 8) {
                    Label(
                        voice.hasTranscript ? "Has transcript" : "No transcript",
                        systemImage: voice.hasTranscript ? "text.badge.checkmark" : "text.badge.minus"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button { onPlay() } label: {
                    Image(systemName: "play.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(AppTheme.voices)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("voicesRow_play_\(voice.id)")

                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("voicesRow_delete_\(voice.id)")
            }
        }
        .studioCard(padding: 12, radius: 14)
    }
}

// MARK: - Enroll Voice Sheet

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
        VStack(spacing: 20) {
            Text("Enroll New Voice")
                .font(.title2.bold())

            TextField("Voice name (e.g. Boss, Mom)", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("voicesEnroll_nameField")

            HStack {
                TextField("Reference audio file", text: $audioPath)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("voicesEnroll_audioPathField")
                Button("Browse...") {
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
                .accessibilityIdentifier("voicesEnroll_browseButton")
            }

            TextField("Transcript — type exactly what the audio says", text: $transcript)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("voicesEnroll_transcriptField")

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
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
        .padding(24)
        .frame(width: 460)
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
