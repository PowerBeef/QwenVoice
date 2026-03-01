import SwiftUI
import UniformTypeIdentifiers

struct VoicesView: View {
    @EnvironmentObject var pythonBridge: PythonBridge
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel

    @State private var voices: [Voice] = []
    @State private var showingEnroll = false
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Voices")
                    .font(.title2.bold())
                    .foregroundStyle(AppTheme.voices)
                    .accessibilityIdentifier("voices_title")
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
            } else if isLoading {
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
                        .emptyStateStyle(color: AppTheme.voices)
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

                            Button(role: .destructive) {
                                deleteVoice(voice)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }

        }
        .contentColumn()
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
    }

    private func loadVoices() async {
        guard pythonBridge.isReady else {
            isLoading = false
            return
        }
        isLoading = true
        do {
            voices = try await pythonBridge.listVoices()
        } catch {
            // Silent fail
        }
        isLoading = false
    }

    private func deleteVoice(_ voice: Voice) {
        Task {
            try? await pythonBridge.deleteVoice(name: voice.name)
            await loadVoices()
        }
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

            HStack {
                TextField("Reference audio file", text: $audioPath)
                    .textFieldStyle(.roundedBorder)
                Button("Browse...") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.audio, .wav, .mp3, .aiff]
                    if panel.runModal() == .OK, let url = panel.url {
                        audioPath = url.path
                    }
                }
            }

            TextField("Transcript — type exactly what the audio says", text: $transcript)
                .textFieldStyle(.roundedBorder)

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

                Spacer()

                Button("Enroll") {
                    enroll()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || audioPath.isEmpty || isEnrolling)
                .keyboardShortcut(.defaultAction)
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
