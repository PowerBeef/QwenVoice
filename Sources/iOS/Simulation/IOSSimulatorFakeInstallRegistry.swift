import Foundation
import QwenVoiceCore

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
    private let fileManager = FileManager.default

    private var persistenceURL: URL {
        AppPaths.modelDownloadRootDir.appendingPathComponent(
            "ios_simulator_fake_installs.json",
            isDirectory: false
        )
    }

    private init() {
        entries = loadPersistedEntries()
    }

    func markInstalled(_ modelID: String, sizeBytes: Int) {
        entries[modelID] = sizeBytes
        persist()
    }

    func clear(_ modelID: String) {
        entries.removeValue(forKey: modelID)
        persist()
    }

    func size(for modelID: String) -> Int? {
        entries[modelID]
    }

    var allEntries: [String: Int] {
        entries
    }

    func applyEnvironmentSeed(models: [ModelDescriptor]) {
        guard IOSSimulatorRuntimeSupport.isSimulator else { return }
        let raw = ProcessInfo.processInfo.environment["QVOICE_SIM_FAKE_MODELS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return }

        let normalizedTokens = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        if normalizedTokens.contains("none") {
            entries = [:]
            persist()
            return
        }

        var seeded: [String: Int] = [:]
        let knownModes = Set(GenerationMode.allCases.map(\.rawValue))
        for token in normalizedTokens {
            if token == "all" {
                for model in models {
                    seeded[model.id] = Self.reportedSize(for: model)
                }
                continue
            }

            if knownModes.contains(token),
               let mode = GenerationMode(rawValue: token) {
                for model in models where model.mode == mode {
                    seeded[model.id] = Self.reportedSize(for: model)
                }
                continue
            }

            if let model = models.first(where: { $0.id.lowercased() == token }) {
                seeded[model.id] = Self.reportedSize(for: model)
            }
        }

        entries = seeded
        persist()
    }

    private static func reportedSize(for model: ModelDescriptor) -> Int {
        Int(clamping: model.estimatedDownloadBytes ?? 2_300_000_000)
    }

    private func loadPersistedEntries() -> [String: Int] {
        guard fileManager.fileExists(atPath: persistenceURL.path),
              let data = try? Data(contentsOf: persistenceURL),
              let entries = try? JSONDecoder().decode([String: Int].self, from: data)
        else {
            return [:]
        }
        return entries
    }

    private func persist() {
        do {
            try fileManager.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: persistenceURL, options: [.atomic])
        } catch {
            #if DEBUG
            print("[IOSSimulatorFakeInstallRegistry] persist failed: \(error.localizedDescription)")
            #endif
        }
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
