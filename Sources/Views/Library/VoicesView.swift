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

private struct VoicesAlertState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct VoicesView: View {
    @EnvironmentObject private var pythonBridge: PythonBridge
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var savedVoicesViewModel: SavedVoicesViewModel

    let isActive: Bool
    let enrollRequestID: UUID?
    let canUseInVoiceCloning: Bool
    let onUseInVoiceCloning: (Voice) -> Void

    @State private var savedVoiceSheetConfiguration: SavedVoiceSheetConfiguration?
    @State private var actionAlert: VoicesAlertState?
    @State private var voiceToDelete: Voice?
    @State private var showDeleteConfirmation = false
    @State private var pendingRevealVoiceID: String?
    @State private var highlightedVoiceID: String?
    @State private var highlightResetTask: Task<Void, Never>?

    private var voices: [Voice] {
        savedVoicesViewModel.voices
    }

    private var isLoading: Bool {
        savedVoicesViewModel.isLoading
    }

    private var loadError: String? {
        savedVoicesViewModel.loadError
    }

    private var loadTaskID: String {
        "\(isActive)-\(pythonBridge.isReady)"
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("screen_voices")
            .task(id: loadTaskID) {
                guard isActive, pythonBridge.isReady else { return }
                await savedVoicesViewModel.ensureLoaded(using: pythonBridge)
            }
            .onChange(of: enrollRequestID) { _, newValue in
                guard newValue != nil else { return }
                presentAddSavedVoiceSheet()
            }
            .onDisappear {
                highlightResetTask?.cancel()
                highlightResetTask = nil
            }
            .sheet(item: $savedVoiceSheetConfiguration) { configuration in
                SavedVoiceSheet(configuration: configuration) { voice in
                    pendingRevealVoiceID = voice.id
                    savedVoicesViewModel.insertOrReplace(voice)
                    Task { await savedVoicesViewModel.refresh(using: pythonBridge) }
                }
                .environmentObject(pythonBridge)
            }
            .alert("Delete Saved Voice?", isPresented: $showDeleteConfirmation) {
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
                    Text("This will permanently remove \"\(voice.name)\" from Saved Voices.")
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
            voicesStateContainer(
                identifier: "voices_emptyState",
                markerLabel: "Saved voices backend startup state"
            ) {
                ContentUnavailableView(
                    "Starting backend...",
                    systemImage: "arrow.triangle.2.circlepath.circle",
                    description: Text("Saved voices will appear once the Python service is ready.")
                )
            }
        } else if let loadError, voices.isEmpty, !isLoading {
            voicesStateContainer(identifier: "voices_errorState", markerLabel: "Saved voices error state") {
                VStack(alignment: .leading, spacing: 12) {
                    ContentUnavailableView(
                        "Couldn't load saved voices",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )

                    Button("Try Again") {
                        Task { await savedVoicesViewModel.refresh(using: pythonBridge) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("voices_retryButton")
                }
            }
        } else if isLoading && voices.isEmpty {
            voicesStateContainer(identifier: "voices_loadingState", markerLabel: "Saved voices loading state") {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading saved voices...")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        } else if voices.isEmpty {
            voicesStateContainer(identifier: "voices_emptyState", markerLabel: "Saved voices empty state") {
                ContentUnavailableView(
                    "No saved voices",
                    systemImage: "person.2.wave.2",
                    description: Text("Add a voice sample from the toolbar, then use it in Voice Cloning.")
                )
            }
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(voices) { voice in
                        VoiceRow(
                            voice: voice,
                            isHighlighted: highlightedVoiceID == voice.id,
                            canUseInVoiceCloning: canUseInVoiceCloning,
                            onUseInVoiceCloning: {
                                onUseInVoiceCloning(voice)
                            },
                            onPlay: {
                                audioPlayer.playFile(voice.wavPath, title: voice.name)
                            },
                            onDelete: {
                                voiceToDelete = voice
                                showDeleteConfirmation = true
                            }
                        )
                        .id(voice.id)
                    }
                }
                .listStyle(.inset)
                .onChange(of: voices) { _, newVoices in
                    guard let pendingRevealVoiceID else { return }
                    guard newVoices.contains(where: { $0.id == pendingRevealVoiceID }) else { return }
                    revealVoice(pendingRevealVoiceID, using: proxy)
                }
            }
        }
    }
}

@MainActor
private extension VoicesView {
    @ViewBuilder
    func voicesStateContainer<Content: View>(
        identifier: String,
        markerLabel: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack {
            content()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            Text(markerLabel)
                .font(.system(size: 1))
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityIdentifier(identifier)
        }
    }

    func presentAddSavedVoiceSheet() {
        savedVoiceSheetConfiguration = .manualAdd
    }

    func revealVoice(_ voiceID: String, using proxy: ScrollViewProxy) {
        pendingRevealVoiceID = nil
        highlightedVoiceID = voiceID

        AppLaunchConfiguration.performAnimated(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(voiceID, anchor: .center)
        }

        highlightResetTask?.cancel()
        highlightResetTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run {
                if highlightedVoiceID == voiceID {
                    highlightedVoiceID = nil
                }
            }
        }
    }

    func deleteVoice(_ voice: Voice) {
        Task {
            do {
                try await pythonBridge.deleteVoice(name: voice.name)
                await MainActor.run {
                    savedVoicesViewModel.removeVoiceFromVisibleState(id: voice.id)
                }
            } catch {
                await MainActor.run {
                    presentActionAlert(
                        title: "Delete Failed",
                        message: "Failed to remove the saved voice: \(error.localizedDescription)"
                    )
                }
            }
            await savedVoicesViewModel.refresh(using: pythonBridge)
        }
    }

    func presentActionAlert(title: String, message: String) {
        actionAlert = VoicesAlertState(title: title, message: message)
    }
}

private struct VoiceRow: View {
    let voice: Voice
    let isHighlighted: Bool
    let canUseInVoiceCloning: Bool
    let onUseInVoiceCloning: () -> Void
    let onPlay: () -> Void
    let onDelete: () -> Void

    private var highlightFill: Color {
        isHighlighted ? AppTheme.accent.opacity(0.12) : .clear
    }

    private var highlightStroke: Color {
        isHighlighted ? AppTheme.accent.opacity(0.22) : .clear
    }

    private var transcriptStatus: String {
        voice.hasTranscript ? "Transcript added" : "No transcript"
    }

    private var detailCopy: String {
        voice.hasTranscript
            ? "Ready as a reusable cloning reference."
            : "Add a transcript later for stronger cloning guidance."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 24, alignment: .center)
                .padding(.top, 4)

            ViewThatFits(in: .horizontal) {
                wideRowLayout
                stackedRowLayout
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(highlightFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(highlightStroke, lineWidth: isHighlighted ? 1 : 0)
        )
    }

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(voice.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityIdentifier("voicesRow_\(voice.id)")

                Text(transcriptStatus)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }

            Text(detailCopy)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var actionCluster: some View {
        HStack(spacing: 8) {
            Button("Open in Cloning", action: onUseInVoiceCloning)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canUseInVoiceCloning)
                .fixedSize(horizontal: true, vertical: false)
                .help(canUseInVoiceCloning ? "Open Voice Cloning with this saved voice selected." : "Install the Voice Cloning model in Models to open this saved voice there.")
                .accessibilityIdentifier("voicesRow_use_\(voice.id)")

            Button("Preview", action: onPlay)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("voicesRow_play_\(voice.id)")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("voicesRow_delete_\(voice.id)")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var wideRowLayout: some View {
        HStack(alignment: .center, spacing: 14) {
            metadataBlock
                .frame(maxWidth: .infinity, alignment: .leading)

            actionCluster
        }
    }

    private var stackedRowLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            metadataBlock
            actionCluster
        }
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
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("voicesEnroll_nameField")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Audio")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("Reference audio file", text: $audioPath)
                            .textFieldStyle(.roundedBorder)
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
                        .frame(minHeight: 100)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(AppTheme.cardStroke.opacity(0.45), lineWidth: 1)
                        )
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
