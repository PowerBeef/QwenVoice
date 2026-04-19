import Foundation
import QwenVoiceCore

enum ModelInventoryStatus: Equatable {
    case checking
    case notInstalled
    case installed(sizeBytes: Int)
    case incomplete(message: String, sizeBytes: Int)
    case error(message: String)
}

@MainActor
protocol ModelStatusProviding: AnyObject {
    func initialStatuses(for models: [TTSModel]) -> [String: ModelInventoryStatus]
    func refreshStatuses(for models: [TTSModel]) async -> [String: ModelInventoryStatus]
    func isLikelyInstalled(_ model: TTSModel) -> Bool
}

@MainActor
final class LocalModelStatusProvider: ModelStatusProviding {
    private let modelAssetStore: any ModelAssetStore

    init(modelAssetStore: any ModelAssetStore) {
        self.modelAssetStore = modelAssetStore
    }

    func initialStatuses(for models: [TTSModel]) -> [String: ModelInventoryStatus] {
        Dictionary(uniqueKeysWithValues: models.map { model in
            let status: ModelInventoryStatus
            guard let descriptor = modelAssetStore.descriptor(id: model.id) else {
                status = .error(message: "Missing asset descriptor")
                return (model.id, status)
            }
            switch modelAssetStore.state(for: descriptor) {
            case .available:
                status = .checking
            default:
                status = Self.status(from: modelAssetStore.state(for: descriptor))
            }
            return (model.id, status)
        })
    }

    func refreshStatuses(for models: [TTSModel]) async -> [String: ModelInventoryStatus] {
        Dictionary(uniqueKeysWithValues: models.map { model in
            let status: ModelInventoryStatus
            guard let descriptor = modelAssetStore.descriptor(id: model.id) else {
                status = .error(message: "Missing asset descriptor")
                return (model.id, status)
            }
            status = Self.status(from: modelAssetStore.state(for: descriptor))
            return (model.id, status)
        })
    }

    func isLikelyInstalled(_ model: TTSModel) -> Bool {
        guard let descriptor = modelAssetStore.descriptor(id: model.id) else {
            return false
        }
        if case .available = modelAssetStore.state(for: descriptor) {
            return true
        }
        return false
    }

    static func status(from assetState: ModelAssetState) -> ModelInventoryStatus {
        switch assetState {
        case .notInstalled:
            return .notInstalled
        case .available(let integrity):
            return .installed(sizeBytes: Int(clamping: integrity.sizeBytes))
        case .incomplete(let integrity):
            let missingCount = integrity.missingRelativePaths.count
            let noun = missingCount == 1 ? "file" : "files"
            return .incomplete(
                message: "Installation incomplete: missing \(missingCount) required \(noun).",
                sizeBytes: Int(clamping: integrity.sizeBytes)
            )
        case .downloading:
            return .checking
        case .deleting:
            return .checking
        case .failed(let message):
            return .error(message: message)
        }
    }
}

/// Read-only model inventory for the current native product path.
@MainActor
final class ModelManagerViewModel: ObservableObject {
    typealias ModelStatus = ModelInventoryStatus

    @Published var statuses: [String: ModelInventoryStatus] = [:]

    private let modelRegistry: ContractBackedModelRegistry
    private let statusProvider: any ModelStatusProviding
    private var refreshTask: Task<Void, Never>?

    init(
        modelRegistry: ContractBackedModelRegistry = TTSContract.registry,
        statusProvider: any ModelStatusProviding
    ) {
        self.modelRegistry = modelRegistry
        self.statusProvider = statusProvider
        self.statuses = statusProvider.initialStatuses(for: TTSModel.all)
    }

    convenience init(
        modelRegistry: ContractBackedModelRegistry = TTSContract.registry,
        modelAssetStore: any ModelAssetStore
    ) {
        self.init(
            modelRegistry: modelRegistry,
            statusProvider: LocalModelStatusProvider(modelAssetStore: modelAssetStore)
        )
    }

    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }

        let task = Task { @MainActor in
            let interval = AppPerformanceSignposts.begin("Model Status Refresh")
            let wallStart = DispatchTime.now().uptimeNanoseconds

            statuses = await statusProvider.refreshStatuses(for: TTSModel.all)

            AppPerformanceSignposts.end(interval)
            #if DEBUG
            let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000)
            print("[Performance][ModelManagerViewModel] refresh_wall_ms=\(elapsedMs)")
            #endif
        }

        refreshTask = task
        await task.value
        refreshTask = nil
    }

    func isAvailable(_ model: TTSModel) -> Bool {
        switch statuses[model.id] {
        case .installed:
            return true
        case .checking:
            return statusProvider.isLikelyInstalled(model)
        case .notInstalled, .incomplete, .error, .none:
            return false
        }
    }

    func isLikelyInstalled(_ model: TTSModel) -> Bool {
        statusProvider.isLikelyInstalled(model)
    }
}
