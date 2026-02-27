import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @State private var generations: [Generation] = []
    @State private var searchText = ""
    @State private var sortField: GenerationSortField = .date
    @State private var sortAscending = false
    @State private var showDeleteConfirmation = false
    @State private var generationToDelete: Generation?

    private var filtered: [Generation] {
        if searchText.isEmpty { return generations }
        return generations.filter {
            $0.text.localizedCaseInsensitiveContains(searchText) ||
            ($0.voice ?? "").localizedCaseInsensitiveContains(searchText)
        }
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
            .padding(.bottom, 8)

            // Sort chips
            HStack(spacing: 8) {
                ForEach(GenerationSortField.allCases, id: \.self) { field in
                    Button {
                        if sortField == field {
                            sortAscending.toggle()
                        } else {
                            sortField = field
                            sortAscending = false
                        }
                        Task { await loadHistory() }
                    } label: {
                        Text(field.label)
                            .chipStyle(isSelected: sortField == field, color: AppTheme.history)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("history_sort_\(field.rawValue)")
                }

                Button {
                    sortAscending.toggle()
                    Task { await loadHistory() }
                } label: {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.history)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("history_sortDirection")

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            if filtered.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "clock")
                        .font(.system(size: 48))
                        .emptyStateStyle(color: AppTheme.history)
                    Text(generations.isEmpty ? "No generations yet" : "No results found")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text(generations.isEmpty ? "Generate some audio to see it here" : "Try a different search term")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .accessibilityIdentifier("history_emptyState")
                Spacer()
            } else {
                List {
                    ForEach(filtered) { gen in
                        HistoryRow(generation: gen)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if gen.audioFileExists {
                                    audioPlayer.playFile(gen.audioPath, title: gen.textPreview)
                                }
                            }
                            .contextMenu {
                                Button {
                                    if gen.audioFileExists {
                                        audioPlayer.playFile(gen.audioPath, title: gen.textPreview)
                                    }
                                } label: {
                                    Label("Play", systemImage: "play.fill")
                                }
                                .disabled(!gen.audioFileExists)

                                Button {
                                    exportGeneration(gen)
                                } label: {
                                    Label("Save As\u{2026}", systemImage: "square.and.arrow.down")
                                }
                                .disabled(!gen.audioFileExists)

                                Button {
                                    NSWorkspace.shared.selectFile(gen.audioPath, inFileViewerRootedAtPath: "")
                                } label: {
                                    Label("Reveal in Finder", systemImage: "folder")
                                }
                                .disabled(!gen.audioFileExists)

                                Divider()

                                Button(role: .destructive) {
                                    generationToDelete = gen
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete { indices in
                        deleteGenerations(at: indices)
                    }
                    .onMove(perform: sortField == .manual && searchText.isEmpty ? moveGenerations : nil)
                }
                .listStyle(.inset)
            }

        }
        .contentColumn()
        .task {
            await loadHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .generationSaved)) { _ in
            Task { await loadHistory() }
        }
        .alert("Delete Generation?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                generationToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let gen = generationToDelete, let id = gen.id {
                    do {
                        try DatabaseService.shared.deleteGeneration(id: id)
                        if gen.audioFileExists {
                            try? FileManager.default.removeItem(atPath: gen.audioPath)
                        }
                        generations.removeAll { $0.id == id }
                    } catch {
                        // Database delete failed
                    }
                    generationToDelete = nil
                }
            }
        } message: {
            Text("This will permanently delete the generation and its audio file.")
        }
    }

    private func loadHistory() async {
        do {
            generations = try DatabaseService.shared.fetchGenerations(sortBy: sortField, ascending: sortAscending)
        } catch {
            // Will be empty until database is set up
        }
    }

    private func deleteGenerations(at indices: IndexSet) {
        let toDelete = indices.map { filtered[$0] }
        for gen in toDelete {
            if let id = gen.id {
                do {
                    try DatabaseService.shared.deleteGeneration(id: id)
                    if gen.audioFileExists {
                        try? FileManager.default.removeItem(atPath: gen.audioPath)
                    }
                    generations.removeAll { $0.id == id }
                } catch {
                    // Database delete failed — don't remove from UI
                }
            }
        }
    }

    private func moveGenerations(from source: IndexSet, to destination: Int) {
        generations.move(fromOffsets: source, toOffset: destination)
        let pairs = generations.enumerated().map { (id: $0.element.id!, sortOrder: $0.offset) }
        try? DatabaseService.shared.updateSortOrders(pairs)
    }

    private func exportGeneration(_ gen: Generation) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: gen.audioPath).lastPathComponent
        panel.allowedContentTypes = [.wav]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: gen.audioPath), to: url)
        }
    }
}

struct HistoryRow: View {
    let generation: Generation

    private var modeColor: Color {
        AppTheme.modeColor(for: generation.mode)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: generation.audioFileExists ? "waveform" : "exclamationmark.triangle")
                .foregroundColor(generation.audioFileExists ? modeColor : .orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(generation.textPreview)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(generation.mode.capitalized)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(modeColor))
                    if let voice = generation.voice, !voice.isEmpty {
                        Text(voice)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text(generation.formattedDate)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if let duration = generation.duration, duration > 0 {
                Text(String(format: "%.1fs", duration))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(generation.audioFileExists ? 1 : 0.5)
    }
}
