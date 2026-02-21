import Foundation

/// Manages history queries and filtering.
@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var generations: [Generation] = []
    @Published var searchText = ""
    @Published var isLoading = false

    var filtered: [Generation] {
        if searchText.isEmpty { return generations }
        return generations.filter {
            $0.text.localizedCaseInsensitiveContains(searchText) ||
            ($0.voice ?? "").localizedCaseInsensitiveContains(searchText) ||
            $0.mode.localizedCaseInsensitiveContains(searchText)
        }
    }

    func load() {
        isLoading = true
        do {
            generations = try DatabaseService.shared.fetchAllGenerations()
        } catch {
            generations = []
        }
        isLoading = false
    }

    func delete(generation: Generation) {
        guard let id = generation.id else { return }
        try? DatabaseService.shared.deleteGeneration(id: id)
        if generation.audioFileExists {
            try? FileManager.default.removeItem(atPath: generation.audioPath)
        }
        generations.removeAll { $0.id == id }
    }

    func deleteAll() {
        try? DatabaseService.shared.deleteAllGenerations()
        generations.removeAll()
    }
}
