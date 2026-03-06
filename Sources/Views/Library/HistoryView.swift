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

private enum HistorySessionCache {
    static var generations: [Generation] = []
}

private enum HistoryDeletionResult {
    case deleted
    case databaseFailure(String)
    case audioCleanupFailure(String)
}

struct HistoryView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @State private var items: [HistoryListItem] = HistorySessionCache.generations.map(HistoryListItem.init)
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var loadTask: Task<Void, Never>?
    @State private var loadError: String?
    @State private var showDeleteConfirmation = false
    @State private var itemToDelete: HistoryListItem?
    @State private var actionAlert: HistoryActionAlert?

    private var filtered: [HistoryListItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return items }
        return items.filter { $0.searchKey.contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("History")
                    .font(.title2.bold())
                    .foregroundStyle(AppTheme.history)
                    .accessibilityIdentifier("history_title")
                Spacer()
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 150, maxWidth: 240)
                    .accessibilityIdentifier("history_searchField")
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)

            if let loadError, items.isEmpty, !isLoading {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("Couldn't load history")
                        .font(.headline)
                    Text(loadError)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .glassCard()
                .accessibilityIdentifier("history_errorState")
                Spacer()
            } else if isLoading && items.isEmpty {
                Spacer()
                ProgressView("Loading history...")
                    .accessibilityIdentifier("history_loadingState")
                Spacer()
            } else if filtered.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "clock")
                        .font(.system(size: 48))
                        .emptyStateStyle()
                    Text(items.isEmpty ? "No generations yet" : "No results found")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text(items.isEmpty ? "Generate some audio to see it here" : "Try a different search term")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .accessibilityIdentifier("history_emptyState")
                Spacer()
            } else {
                List {
                    ForEach(filtered) { item in
                        HistoryRow(
                            item: item,
                            onPlay: {
                                audioPlayer.playFile(item.generation.audioPath, title: item.textPreview)
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
                    }
                    .onDelete { indices in
                        deleteGenerations(at: indices)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

        }
        .contentColumn()
        .accessibilityIdentifier("screen_history")
        .onAppear {
            reloadHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .generationSaved)) { _ in
            reloadHistory()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
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
    }

    private func reloadHistory() {
        loadTask?.cancel()
        let hasExistingItems = !items.isEmpty
        if !hasExistingItems {
            isLoading = true
            loadError = nil
        }

        loadTask = Task {
            do {
                let loadedItems = try await Task.detached(priority: .userInitiated) {
                    if hasExistingItems {
                        try UITestFaultInjection.throwIfEnabled(.historyFetch)
                    }
                    return try DatabaseService.shared.fetchAllGenerations().map(HistoryListItem.init)
                }.value

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    items = loadedItems
                    HistorySessionCache.generations = loadedItems.map(\.generation)
                    loadError = nil
                    isLoading = false
                }
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
                }
            }
        }
    }

    private func deleteGenerations(at indices: IndexSet) {
        let toDelete = indices.map { filtered[$0] }
        var databaseFailures: [String] = []
        var audioCleanupFailures: [String] = []

        for item in toDelete {
            switch deleteItem(item) {
            case .deleted:
                break
            case .databaseFailure(let message):
                databaseFailures.append(message)
            case .audioCleanupFailure(let message):
                audioCleanupFailures.append(message)
            }
        }

        presentBulkDeleteSummary(
            databaseFailures: databaseFailures,
            audioCleanupFailures: audioCleanupFailures
        )
    }

    private func exportGeneration(_ item: HistoryListItem) {
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

    private func confirmDelete(_ item: HistoryListItem) {
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

    private func deleteItem(_ item: HistoryListItem) -> HistoryDeletionResult {
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

    private func presentBulkDeleteSummary(
        databaseFailures: [String],
        audioCleanupFailures: [String]
    ) {
        guard !databaseFailures.isEmpty || !audioCleanupFailures.isEmpty else { return }

        var lines: [String] = []
        if let firstDatabaseFailure = databaseFailures.first {
            let count = databaseFailures.count
            let label = count == 1 ? "1 generation" : "\(count) generations"
            lines.append("Failed to delete \(label) from history. First error: \(firstDatabaseFailure)")
        }
        if let firstAudioFailure = audioCleanupFailures.first {
            let count = audioCleanupFailures.count
            let label = count == 1 ? "1 history entry" : "\(count) history entries"
            lines.append("Removed \(label), but could not delete the audio file. First error: \(firstAudioFailure)")
        }

        presentActionAlert(
            title: "Delete Completed with Warnings",
            message: lines.joined(separator: "\n")
        )
    }

    private func presentActionAlert(title: String, message: String) {
        actionAlert = HistoryActionAlert(title: title, message: message)
    }
}

private struct HistoryRow: View {
    let item: HistoryListItem
    let onPlay: () -> Void
    let onSaveAs: () -> Void
    let onDelete: () -> Void

    private var modeColor: Color {
        AppTheme.modeColor(for: item.generation.mode)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.audioFileExists ? "waveform" : "exclamationmark.triangle")
                .foregroundColor(item.audioFileExists ? modeColor : .orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.textPreview)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(item.generation.mode.capitalized)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(modeColor))
                    if let voice = item.generation.voice, !voice.isEmpty {
                        Text(voice)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text(item.formattedDate)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if let duration = item.generation.duration, duration > 0 {
                Text(String(format: "%.1fs", duration))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            Button {
                onPlay()
            } label: {
                Image(systemName: "play.circle")
                    .font(.title3)
                    .foregroundColor(AppTheme.history)
            }
            .buttonStyle(.plain)
            .disabled(!item.audioFileExists)

            Button {
                onSaveAs()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.title3)
                    .foregroundColor(AppTheme.history)
            }
            .buttonStyle(.plain)
            .disabled(!item.audioFileExists)

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("historyRow_delete")
        }
        .padding(.vertical, 4)
        .opacity(item.audioFileExists ? 1 : 0.5)
    }
}
