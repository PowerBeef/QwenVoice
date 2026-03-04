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

struct HistoryView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @State private var items: [HistoryListItem] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var loadTask: Task<Void, Never>?
    @State private var loadError: String?
    @State private var showDeleteConfirmation = false
    @State private var itemToDelete: HistoryListItem?
    @State private var exportError: String?

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
        .task {
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
                if let item = itemToDelete, let id = item.generation.id {
                    do {
                        try DatabaseService.shared.deleteGeneration(id: id)
                        if item.audioFileExists {
                            try? FileManager.default.removeItem(atPath: item.generation.audioPath)
                        }
                        items.removeAll { $0.id == item.id }
                    } catch {
                        // Database delete failed
                    }
                    itemToDelete = nil
                }
            }
        } message: {
            Text("This will permanently delete the generation and its audio file.")
        }
        .alert("Export Error", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private func reloadHistory() {
        loadTask?.cancel()
        if items.isEmpty {
            isLoading = true
        }
        loadError = nil

        loadTask = Task {
            do {
                let loadedItems = try await Task.detached(priority: .userInitiated) {
                    try DatabaseService.shared.fetchAllGenerations().map(HistoryListItem.init)
                }.value

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    items = loadedItems
                    loadError = nil
                    isLoading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if items.isEmpty {
                        loadError = error.localizedDescription
                    }
                    isLoading = false
                }
            }
        }
    }

    private func deleteGenerations(at indices: IndexSet) {
        let toDelete = indices.map { filtered[$0] }
        for item in toDelete {
            if let id = item.generation.id {
                do {
                    try DatabaseService.shared.deleteGeneration(id: id)
                    if item.audioFileExists {
                        try? FileManager.default.removeItem(atPath: item.generation.audioPath)
                    }
                    items.removeAll { $0.id == item.id }
                } catch {
                    // Database delete failed — don't remove from UI
                }
            }
        }
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
                exportError = "Export failed: \(error.localizedDescription)"
            }
        }
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
        }
        .padding(.vertical, 4)
        .opacity(item.audioFileExists ? 1 : 0.5)
    }
}
