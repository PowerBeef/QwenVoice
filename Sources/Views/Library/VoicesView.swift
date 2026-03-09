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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Voices")
                    .font(.title2.bold())
                    .foregroundStyle(AppTheme.voices)
                Spacer()
                Button {
                    showingEnroll = true
                } label: {
                    Label("Enroll Voice", systemImage: "plus")
                }
                .tint(AppTheme.voices)
                .accessibilityIdentifier("voices_enrollButton")
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)

            if !pythonBridge.isReady {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(AppTheme.voices)
                    Text("Starting backend...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Enrolled voices will appear once the Python service is ready")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else if let loadError, voices.isEmpty, !isLoading {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("Couldn't load voices")
                        .font(.headline)
                    Text(loadError)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        Task {
                            await loadVoices()
                        }
                    } label: {
                        Text("Try Again")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.voices)
                    .accessibilityIdentifier("voices_retryButton")
                }
                .padding(24)
                .glassCard()
                .accessibilityIdentifier("voices_errorState")
                Spacer()
            } else if isLoading && voices.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(AppTheme.voices)
                    Text("Loading voices...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else if voices.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 48))
                        .emptyStateStyle()
                    Text("No enrolled voices")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Enroll a voice to use it for voice cloning")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .accessibilityIdentifier("voices_emptyState")
                Spacer()
            } else {
                List {
                    ForEach(voices) { voice in
                        HStack(spacing: 12) {
                            Image(systemName: "waveform.circle.fill")
                                .font(.title2)
                                .foregroundColor(AppTheme.voices)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(voice.name)
                                    .font(.body.bold())
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

                            Button {
                                audioPlayer.playFile(voice.wavPath, title: voice.name)
                            } label: {
                                Image(systemName: "play.circle")
                                    .font(.title3)
                                    .foregroundColor(AppTheme.voices)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("voicesRow_play_\(voice.id)")

                            Button(role: .destructive) {
                                deleteVoice(voice)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("voicesRow_delete_\(voice.id)")
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }

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
            Task {
                await loadVoices()
            }
        }
        .sheet(isPresented: $showingEnroll) {
            EnrollVoiceSheet(onComplete: {
                Task { await loadVoices() }
            })
            .environmentObject(pythonBridge)
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
    var onComplete: () -> Void

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
                onComplete()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isEnrolling = false
        }
    }
}
