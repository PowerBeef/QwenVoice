import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @State private var generations: [Generation] = []
    @State private var searchText = ""

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
                    }
                    .onDelete { indices in
                        deleteGenerations(at: indices)
                    }
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
    }

    private func loadHistory() async {
        do {
            generations = try DatabaseService.shared.fetchAllGenerations()
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
