import AppKit
import QwenVoiceNative
import SwiftUI
import UniformTypeIdentifiers

private struct VoicesAlertState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct VoicesView: View {
    @EnvironmentObject private var ttsEngineStore: TTSEngineStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var savedVoicesViewModel: SavedVoicesViewModel

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
        "\(ttsEngineStore.isReady)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.sectionSpacing) {
            StudioCollectionHeader(
                eyebrow: "Library",
                title: "Saved voices",
                subtitle: "Curate reusable references for permitted clone and design workflows.",
                iconName: "person.2.wave.2",
                accentColor: AppTheme.voices,
                trailing: "\(voices.count) voice\(voices.count == 1 ? "" : "s")"
            )

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .profileBackground(AppTheme.canvasBackground)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("screen_voices")
            .task(id: loadTaskID) {
                guard ttsEngineStore.isReady else { return }
                await savedVoicesViewModel.refresh(using: ttsEngineStore)
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
                    handleSavedVoiceSheetCompletion(voice)
                }
                .environmentObject(ttsEngineStore)
            }
            .alert("Delete Saved Voice?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    voiceToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    confirmDeleteVoice()
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
        if !ttsEngineStore.isReady {
            voicesStateContainer(
                identifier: "voices_emptyState",
                markerLabel: "Saved voices backend startup state"
            ) {
                ContentUnavailableView(
                    "Starting speech engine...",
                    systemImage: "arrow.triangle.2.circlepath.circle",
                    description: Text("Saved voices will appear once the speech engine is ready.")
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
                        retryLoadVoices()
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
                                playVoicePreview(voice)
                            },
                            onDelete: {
                                requestDeleteVoice(voice)
                            }
                        )
                        .id(voice.id)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
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

    func handleSavedVoiceSheetCompletion(_ voice: Voice) {
        pendingRevealVoiceID = voice.id
        savedVoicesViewModel.insertOrReplace(voice)
        Task { await savedVoicesViewModel.refresh(using: ttsEngineStore) }
    }

    func retryLoadVoices() {
        Task { await savedVoicesViewModel.refresh(using: ttsEngineStore) }
    }

    func playVoicePreview(_ voice: Voice) {
        audioPlayer.playFile(voice.wavPath, title: voice.name)
    }

    func requestDeleteVoice(_ voice: Voice) {
        voiceToDelete = voice
        showDeleteConfirmation = true
    }

    func confirmDeleteVoice() {
        if let voice = voiceToDelete {
            deleteVoice(voice)
        }
        voiceToDelete = nil
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
                try await ttsEngineStore.deletePreparedVoice(id: voice.id)
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
            await savedVoicesViewModel.refresh(using: ttsEngineStore)
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
        .vocelloGlassSurface(
            padding: 0,
            radius: 16,
            fill: isHighlighted ? AppTheme.accent.opacity(0.12) : AppTheme.inlineFill
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(highlightStroke, lineWidth: isHighlighted ? 1 : 0)
        )
    }

    private var wideRowLayout: some View {
        HStack(alignment: .center, spacing: 14) {
            VoiceRowMetadata(
                voiceName: voice.name,
                voiceID: voice.id,
                transcriptStatus: transcriptStatus,
                detailCopy: detailCopy
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            VoiceRowActions(
                voiceID: voice.id,
                canUseInVoiceCloning: canUseInVoiceCloning,
                onPlay: onPlay,
                onUseInVoiceCloning: onUseInVoiceCloning,
                onDelete: onDelete
            )
        }
    }

    private var stackedRowLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            VoiceRowMetadata(
                voiceName: voice.name,
                voiceID: voice.id,
                transcriptStatus: transcriptStatus,
                detailCopy: detailCopy
            )
            VoiceRowActions(
                voiceID: voice.id,
                canUseInVoiceCloning: canUseInVoiceCloning,
                onPlay: onPlay,
                onUseInVoiceCloning: onUseInVoiceCloning,
                onDelete: onDelete
            )
        }
    }
}

private struct VoiceRowMetadata: View {
    let voiceName: String
    let voiceID: String
    let transcriptStatus: String
    let detailCopy: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(voiceName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityIdentifier("voicesRow_\(voiceID)")

                Text(transcriptStatus)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    #if QW_UI_LIQUID
                    .glassBadge()
                    #else
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
                    #endif
            }

            Text(detailCopy)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

private struct VoiceRowActions: View {
    let voiceID: String
    let canUseInVoiceCloning: Bool
    let onPlay: () -> Void
    let onUseInVoiceCloning: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button("Open in Cloning", action: onUseInVoiceCloning)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .help(
                    canUseInVoiceCloning
                        ? "Open Voice Cloning with this saved voice selected."
                        : "Open Voice Cloning with this saved voice selected. Install the Voice Cloning model in Models to generate from it."
                )
                .accessibilityIdentifier("voicesRow_use_\(voiceID)")

            Button("Preview", action: onPlay)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("voicesRow_play_\(voiceID)")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("voicesRow_delete_\(voiceID)")
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
