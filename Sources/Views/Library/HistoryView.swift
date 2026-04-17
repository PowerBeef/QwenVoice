import AppKit
import QwenVoiceNative
import SwiftUI
import UniformTypeIdentifiers

private struct HistoryListItem: Identifiable {
    let generation: Generation
    let audioFileExists: Bool
    let textPreview: String
    let formattedDate: String
    let searchKey: String

    var id: String {
        if let generationID = generation.id {
            return "generation-\(generationID)"
        }
        return "generation-\(generation.audioPath)-\(generation.createdAt.timeIntervalSince1970)"
    }

    init(generation: Generation) {
        self.generation = generation
        self.audioFileExists = FileManager.default.fileExists(atPath: generation.audioPath)
        self.textPreview = generation.textPreview
        self.formattedDate = generation.formattedDate
        self.searchKey = "\(generation.text)\n\(generation.voice ?? "")".lowercased()
    }
}

private struct HistoryActionAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor private enum HistorySessionCache {
    static var generations: [Generation] = []
}

private enum HistoryDeletionResult {
    case deleted
    case databaseFailure(String)
    case audioCleanupFailure(String)
}

enum HistorySortOrder: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case longestDuration
    case shortestDuration
    case mode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newest:
            return "Newest"
        case .oldest:
            return "Oldest"
        case .longestDuration:
            return "Longest"
        case .shortestDuration:
            return "Shortest"
        case .mode:
            return "Mode"
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var ttsEngineStore: TTSEngineStore
    @EnvironmentObject private var savedVoicesViewModel: SavedVoicesViewModel
    @EnvironmentObject private var generationLibraryEvents: GenerationLibraryEvents
    @Binding var searchText: String
    @Binding var sortOrder: HistorySortOrder

    @State private var items: [HistoryListItem] = HistorySessionCache.generations.map(HistoryListItem.init)
    @State private var isLoading = false
    @State private var loadTask: Task<Void, Never>?
    @State private var loadError: String?
    @State private var showDeleteConfirmation = false
    @State private var itemToDelete: HistoryListItem?
    @State private var actionAlert: HistoryActionAlert?
    @State private var savedVoiceSheetConfiguration: SavedVoiceSheetConfiguration?
    @State private var pendingReloadAfterCurrentLoad = false
    @State private var filteredItems: [HistoryListItem] = []
    @State private var itemsRevision = 0
    @State private var searchDebounceTask: Task<Void, Never>?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("screen_history")
            .onAppear(perform: handleAppear)
            .onReceive(generationLibraryEvents.generationSaved) { _ in handleGenerationSaved() }
            .onChange(of: itemsRevision) { _, _ in recomputeFilteredItems() }
            .onChange(of: sortOrder) { _, _ in recomputeFilteredItems() }
            .onChange(of: searchText) { _, _ in
                searchDebounceTask?.cancel()
                searchDebounceTask = Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    recomputeFilteredItems()
                }
            }
            .onDisappear(perform: handleDisappear)
            .alert("Delete Generation?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    itemToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let item = itemToDelete {
                        confirmDelete(item)
                    }
                    itemToDelete = nil
                }
            } message: {
                Text("This will permanently delete the generation and its audio file.")
            }
            .alert(item: $actionAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .sheet(item: $savedVoiceSheetConfiguration) { configuration in
                SavedVoiceSheet(configuration: configuration) { voice in
                    handleSavedVoice(voice)
                }
                .environmentObject(ttsEngineStore)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError, items.isEmpty, !isLoading {
            historyStateContainer(identifier: "history_errorState", markerLabel: "History error state") {
                ContentUnavailableView(
                    "Couldn't load history",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            }
        } else if isLoading && items.isEmpty {
            historyStateContainer(identifier: "history_loadingState", markerLabel: "History loading state") {
                VStack(spacing: 12) {
                    ProgressView("Loading history...")
                }
            }
        } else if filteredItems.isEmpty {
            historyStateContainer(identifier: "history_emptyState", markerLabel: "History empty state") {
                ContentUnavailableView(
                    items.isEmpty ? "No generations yet" : "No results found",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(
                        items.isEmpty
                        ? "Generate some audio to see it here."
                        : "Try a different search term or clear the search."
                    )
                )
            }
        } else {
            List(filteredItems) { item in
                let saveVoiceConfiguration = saveVoiceConfiguration(for: item)
                HistoryRow(
                    item: item,
                    onPlay: {
                        audioPlayer.playFile(item.generation.audioPath, title: item.textPreview)
                    },
                    onSaveToSavedVoices: saveVoiceConfiguration.map { configuration in
                        {
                            savedVoiceSheetConfiguration = configuration
                        }
                    },
                    onSaveAs: {
                        exportGeneration(item)
                    },
                    onDelete: {
                        itemToDelete = item
                        showDeleteConfirmation = true
                    }
                )
                .contextMenu {
                    Button {
                        NSWorkspace.shared.selectFile(item.generation.audioPath, inFileViewerRootedAtPath: "")
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .disabled(!item.audioFileExists)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            .listStyle(.inset)
        }
    }
}

private extension HistoryView {
    func saveVoiceConfiguration(for item: HistoryListItem) -> SavedVoiceSheetConfiguration? {
        switch item.generation.mode {
        case GenerationMode.clone.rawValue:
            return .cloneResult(
                suggestedName: suggestedSavedVoiceName(for: item),
                audioPath: item.generation.audioPath,
                transcript: item.generation.text
            )
        case GenerationMode.design.rawValue:
            return .designResult(
                voiceDescription: item.generation.voice ?? "",
                audioPath: item.generation.audioPath,
                transcript: item.generation.text
            )
        default:
            return nil
        }
    }

    func handleAppear() {
        reloadHistory()
    }

    func handleGenerationSaved() {
        reloadHistory()
    }

    func handleDisappear() {
        loadTask?.cancel()
        loadTask = nil
        searchDebounceTask?.cancel()
    }

    func handleSavedVoice(_ voice: Voice) {
        savedVoicesViewModel.insertOrReplace(voice)
        Task { await savedVoicesViewModel.refresh(using: ttsEngineStore) }
        presentActionAlert(
            title: "Saved Voice Added",
            message: "\"\(voice.name)\" is ready in Saved Voices."
        )
    }

    func recomputeFilteredItems() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result = query.isEmpty ? items : items.filter { $0.searchKey.contains(query) }

        switch sortOrder {
        case .newest:
            result.sort { $0.generation.createdAt > $1.generation.createdAt }
        case .oldest:
            result.sort { $0.generation.createdAt < $1.generation.createdAt }
        case .longestDuration:
            result.sort { ($0.generation.duration ?? 0) > ($1.generation.duration ?? 0) }
        case .shortestDuration:
            result.sort { ($0.generation.duration ?? 0) < ($1.generation.duration ?? 0) }
        case .mode:
            result.sort { $0.generation.mode < $1.generation.mode }
        }

        filteredItems = result
    }

    @ViewBuilder
    func historyStateContainer<Content: View>(
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

    func reloadHistory() {
        if loadTask != nil {
            pendingReloadAfterCurrentLoad = true
            return
        }

        let hasExistingItems = !items.isEmpty
        if !hasExistingItems {
            isLoading = true
            loadError = nil
        }

        let interval = AppPerformanceSignposts.begin("History Reload")
        let wallStart = DispatchTime.now().uptimeNanoseconds

        loadTask = Task {
            var didFinishReload = false
            defer {
                if !didFinishReload {
                    Task { @MainActor in
                        cancelReload(interval: interval)
                    }
                }
            }

            do {
                if hasExistingItems {
                    try UITestFaultInjection.throwIfEnabled(.historyFetch)
                }
                let generations = try DatabaseService.shared.fetchAllGenerations()
                let loadedItems = generations.map(HistoryListItem.init)

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    items = loadedItems
                    itemsRevision &+= 1
                    HistorySessionCache.generations = loadedItems.map(\.generation)
                    loadError = nil
                    isLoading = false
                    finishReload(wallStart: wallStart, interval: interval)
                }
                didFinishReload = true
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if hasExistingItems {
                        presentActionAlert(
                            title: "Couldn't refresh history",
                            message: error.localizedDescription
                        )
                    } else {
                        loadError = error.localizedDescription
                    }
                    isLoading = false
                    finishReload(wallStart: wallStart, interval: interval)
                }
                didFinishReload = true
            }
        }
    }

    func finishReload(wallStart: UInt64, interval: AppPerformanceSignposts.Interval) {
        AppPerformanceSignposts.end(interval)
        #if DEBUG
        let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000)
        print("[Performance][HistoryView] reload_wall_ms=\(elapsedMs)")
        #endif

        loadTask = nil

        if pendingReloadAfterCurrentLoad {
            pendingReloadAfterCurrentLoad = false
            reloadHistory()
        }
    }

    func cancelReload(interval: AppPerformanceSignposts.Interval) {
        AppPerformanceSignposts.end(interval)
        isLoading = false
        loadTask = nil
        pendingReloadAfterCurrentLoad = false
    }

    func exportGeneration(_ item: HistoryListItem) {
        if UITestAutomationSupport.isStubBackendMode,
           let outputDirectoryURL = UITestAutomationSupport.outputDirectoryURL {
            do {
                try FileManager.default.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)
                let destination = outputDirectoryURL.appendingPathComponent(URL(fileURLWithPath: item.generation.audioPath).lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: item.generation.audioPath), to: destination)
                UITestAutomationSupport.recordAction("history-export", details: destination.path, appSupportDir: QwenVoiceApp.appSupportDir)
            } catch {
                presentActionAlert(
                    title: "Export Error",
                    message: "Export failed: \(error.localizedDescription)"
                )
            }
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: item.generation.audioPath).lastPathComponent
        panel.allowedContentTypes = [.wav]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try FileManager.default.copyItem(at: URL(fileURLWithPath: item.generation.audioPath), to: url)
            } catch {
                presentActionAlert(
                    title: "Export Error",
                    message: "Export failed: \(error.localizedDescription)"
                )
            }
        }
    }

    func suggestedSavedVoiceName(for item: HistoryListItem) -> String {
        if let voice = item.generation.voice?.trimmingCharacters(in: .whitespacesAndNewlines),
           !voice.isEmpty {
            return "\(voice) Sample"
        }

        return URL(fileURLWithPath: item.generation.audioPath)
            .deletingPathExtension()
            .lastPathComponent
    }

    func confirmDelete(_ item: HistoryListItem) {
        switch deleteItem(item) {
        case .deleted:
            break
        case .databaseFailure(let message):
            presentActionAlert(
                title: "Delete Error",
                message: "Failed to delete generation: \(message)"
            )
        case .audioCleanupFailure(let message):
            presentActionAlert(
                title: "Delete Warning",
                message: "Generation removed from history, but the audio file could not be deleted: \(message)"
            )
        }
    }

    func deleteItem(_ item: HistoryListItem) -> HistoryDeletionResult {
        guard let id = item.generation.id else {
            return .databaseFailure("Missing generation identifier.")
        }

        do {
            try UITestFaultInjection.throwIfEnabled(.historyDeleteDatabase)
            try DatabaseService.shared.deleteGeneration(id: id)
        } catch {
            return .databaseFailure(error.localizedDescription)
        }

        items.removeAll { $0.id == item.id }
        itemsRevision &+= 1
        HistorySessionCache.generations.removeAll { generation in
            guard let generationID = generation.id, let itemID = item.generation.id else {
                return generation.audioPath == item.generation.audioPath
            }
            return generationID == itemID
        }

        guard item.audioFileExists else {
            return .deleted
        }

        do {
            try UITestFaultInjection.throwIfEnabled(.historyDeleteAudio)
            try FileManager.default.removeItem(atPath: item.generation.audioPath)
            return .deleted
        } catch {
            return .audioCleanupFailure(error.localizedDescription)
        }
    }

    func presentActionAlert(title: String, message: String) {
        actionAlert = HistoryActionAlert(title: title, message: message)
    }
}

private struct HistoryRowMetadata: View {
    let mode: String
    let voice: String?
    let formattedDate: String
    let modeColor: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(mode.capitalized)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                #if QW_UI_LIQUID
                .glassBadge(tint: modeColor)
                #else
                .background(
                    Capsule()
                        .fill(modeColor.opacity(0.15))
                )
                #endif

            if let voice, !voice.isEmpty {
                Text(voice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(formattedDate)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct HistoryRowActions: View {
    let audioFileExists: Bool
    let onSaveToSavedVoices: (() -> Void)?
    let onSaveAs: () -> Void
    let onDelete: () -> Void
    let itemID: String

    var body: some View {
        ControlGroup {
            if let onSaveToSavedVoices {
                Button(action: onSaveToSavedVoices) {
                    Image(systemName: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!audioFileExists)
                .accessibilityLabel("Save to Saved Voices")
                .accessibilityIdentifier("historyRow_saveVoice_\(itemID)")
            }

            Button(action: onSaveAs) {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!audioFileExists)
            .accessibilityIdentifier("historyRow_saveAs")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("historyRow_delete")
        }
    }
}

private struct HistoryRow: View {
    let item: HistoryListItem
    let onPlay: () -> Void
    let onSaveToSavedVoices: (() -> Void)?
    let onSaveAs: () -> Void
    let onDelete: () -> Void

    private var modeColor: Color {
        AppTheme.modeColor(for: item.generation.mode)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onPlay) {
                Label(
                    item.audioFileExists ? "Play" : "Audio unavailable",
                    systemImage: item.audioFileExists ? "play.fill" : "exclamationmark.triangle.fill"
                )
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!item.audioFileExists)
            .accessibilityLabel(item.audioFileExists ? "Play generation" : "Audio unavailable")
            .accessibilityIdentifier("historyRow_play")
            .accessibilityRepresentation {
                Button(item.audioFileExists ? "Play generation" : "Audio unavailable", action: onPlay)
                    .disabled(!item.audioFileExists)
                    .accessibilityIdentifier("historyRow_play")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(item.textPreview)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                HistoryRowMetadata(
                    mode: item.generation.mode,
                    voice: item.generation.voice,
                    formattedDate: item.formattedDate,
                    modeColor: modeColor
                )
            }

            Spacer()

            Text(durationText)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)

            HistoryRowActions(
                audioFileExists: item.audioFileExists,
                onSaveToSavedVoices: onSaveToSavedVoices,
                onSaveAs: onSaveAs,
                onDelete: onDelete,
                itemID: item.id
            )
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("historyRow_\(item.id)")
        .accessibilityElement(children: .contain)
    }

    private var durationText: String {
        if let duration = item.generation.duration, duration > 0 {
            return String(format: "%.1fs", duration)
        }
        return "-"
    }
}
