import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct HistorySearchField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.placeholderString = "Search..."
        textField.stringValue = text
        textField.isBordered = true
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.focusRingType = .default
        textField.identifier = NSUserInterfaceItemIdentifier("history_searchField")
        textField.setAccessibilityIdentifier("history_searchField")
        textField.setAccessibilityLabel("Search history")
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            self._text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text = textField.stringValue
        }
    }
}

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

private enum HistorySortOrder: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case longestDuration
    case shortestDuration
    case mode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        case .longestDuration: return "Longest"
        case .shortestDuration: return "Shortest"
        case .mode: return "Mode"
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @State private var items: [HistoryListItem] = HistorySessionCache.generations.map(HistoryListItem.init)
    @State private var searchText = ""
    @State private var sortOrder: HistorySortOrder = .newest
    @State private var isLoading = false
    @State private var loadTask: Task<Void, Never>?
    @State private var loadError: String?
    @State private var showDeleteConfirmation = false
    @State private var itemToDelete: HistoryListItem?
    @State private var actionAlert: HistoryActionAlert?

    private var filtered: [HistoryListItem] {
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

        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LayoutConstants.sectionSpacing) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityIdentifier("screen_history")
                    .allowsHitTesting(false)

                GenerationHeaderView(
                    title: "History",
                    subtitle: "Review, replay, export, and remove generated audio.",
                    titleAccessibilityIdentifier: "history_title"
                )

                StudioSectionCard(
                    title: "Browse",
                    iconName: "line.3.horizontal.decrease.circle",
                    accentColor: AppTheme.history
                ) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 14) {
                            HistorySearchField(text: $searchText)
                                .frame(minWidth: 280, maxWidth: .infinity)

                            Picker("Sort", selection: $sortOrder) {
                                ForEach(HistorySortOrder.allCases) { order in
                                    Text(order.label).tag(order)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 160)
                            .accessibilityIdentifier("history_sortPicker")
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            HistorySearchField(text: $searchText)
                                .frame(maxWidth: .infinity)

                            Picker("Sort", selection: $sortOrder) {
                                ForEach(HistorySortOrder.allCases) { order in
                                    Text(order.label).tag(order)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 180)
                            .accessibilityIdentifier("history_sortPicker")
                        }
                    }
                }

                if let loadError, items.isEmpty, !isLoading {
                    historyStateCard(
                        icon: "exclamationmark.triangle",
                        title: "Couldn't load history",
                        detail: loadError,
                        accessibilityIdentifier: "history_errorState",
                        tint: .orange
                    )
                } else if isLoading && items.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView("Loading history...")
                            .accessibilityIdentifier("history_loadingState")
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .studioCard()
                } else if filtered.isEmpty {
                    historyStateCard(
                        icon: "clock",
                        title: items.isEmpty ? "No generations yet" : "No results found",
                        detail: items.isEmpty
                            ? "Generate some audio to see it here."
                            : "Try a different search term or clear the search.",
                        accessibilityIdentifier: "history_emptyState"
                    )
                } else {
                    LazyVStack(spacing: 12) {
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
                    }
                }
            }
            .padding(LayoutConstants.canvasPadding)
            .contentColumn()
        }
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

    @ViewBuilder
    private func historyStateCard(
        icon: String,
        title: String,
        detail: String,
        accessibilityIdentifier: String,
        tint: Color = AppTheme.history
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

// MARK: - History Row (Table-style)

private struct HistoryRow: View {
    let item: HistoryListItem
    let onPlay: () -> Void
    let onSaveAs: () -> Void
    let onDelete: () -> Void

    private var modeColor: Color {
        AppTheme.modeColor(for: item.generation.mode)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if item.audioFileExists {
                    Button { onPlay() } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppTheme.history)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(AppTheme.history.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.orange)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.orange.opacity(0.14)))
                }
            }
            .accessibilityIdentifier("historyRow_play")

            VStack(alignment: .leading, spacing: 8) {
                Text(item.textPreview)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Text(item.generation.mode.capitalized)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(modeColor))

                    if let voice = item.generation.voice, !voice.isEmpty {
                        Label(voice, systemImage: "person.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(item.formattedDate)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(durationText)
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button { onSaveAs() } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.history)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .disabled(!item.audioFileExists)
                .accessibilityIdentifier("historyRow_saveAs")

                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .accessibilityIdentifier("historyRow_delete")
            }
        }
        .opacity(item.audioFileExists ? 1 : 0.65)
        .studioCard(padding: 12, radius: 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("historyRow_\(item.id)")
    }

    private var durationText: String {
        if let duration = item.generation.duration, duration > 0 {
            return String(format: "%.1fs", duration)
        }
        return "—"
    }
}
