import Foundation

/// Simulator-only registry of "fake-installed" model IDs and their reported
/// sizes. The fake installer writes here on completion; the
/// `IOSSimulatorFakeStatusProvider` reads here when answering refresh
/// queries, so `modelManager.refresh()` returns `.installed` for these
/// IDs even though no real bytes are on disk.
///
/// Shared as a process-wide singleton because both the installer and the
/// status provider need to see the same set, and they're created in
/// different places at app bootstrap.
@MainActor
final class IOSSimulatorFakeInstallRegistry {
    static let shared = IOSSimulatorFakeInstallRegistry()

    private var entries: [String: Int] = [:]

    private init() {}

    func markInstalled(_ modelID: String, sizeBytes: Int) {
        entries[modelID] = sizeBytes
    }

    func clear(_ modelID: String) {
        entries.removeValue(forKey: modelID)
    }

    func size(for modelID: String) -> Int? {
        entries[modelID]
    }

    var allEntries: [String: Int] {
        entries
    }
}

/// Wraps a real `ModelStatusProviding` and overlays the
/// `IOSSimulatorFakeInstallRegistry` so refresh queries report
/// `.installed(sizeBytes:)` for any model the fake installer has
/// marked as installed. Pass-through for everything else.
@MainActor
final class IOSSimulatorFakeStatusProvider: ModelStatusProviding {
    private let wrapped: any ModelStatusProviding
    private let registry: IOSSimulatorFakeInstallRegistry

    init(
        wrapping wrapped: any ModelStatusProviding,
        registry: IOSSimulatorFakeInstallRegistry = .shared
    ) {
        self.wrapped = wrapped
        self.registry = registry
    }

    func initialStatuses(for models: [TTSModel]) -> [String: ModelInventoryStatus] {
        merge(wrapped.initialStatuses(for: models))
    }

    func refreshStatuses(for models: [TTSModel]) async -> [String: ModelInventoryStatus] {
        merge(await wrapped.refreshStatuses(for: models))
    }

    func isLikelyInstalled(_ model: TTSModel) -> Bool {
        if registry.size(for: model.id) != nil { return true }
        return wrapped.isLikelyInstalled(model)
    }

    private func merge(_ source: [String: ModelInventoryStatus]) -> [String: ModelInventoryStatus] {
        var result = source
        for (modelID, sizeBytes) in registry.allEntries {
            result[modelID] = .installed(sizeBytes: sizeBytes)
        }
        return result
    }
}
