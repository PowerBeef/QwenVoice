import Foundation
import QwenVoiceCore

@MainActor
final class IOSModelInstallerViewModel: ObservableObject {
    enum OperationState: Equatable {
        case idle
        case available(estimatedBytes: Int64?)
        case downloading(progress: Double?, downloadedBytes: Int64, totalBytes: Int64?)
        case interrupted(message: String?, downloadedBytes: Int64, totalBytes: Int64?)
        case resuming(progress: Double?, downloadedBytes: Int64, totalBytes: Int64?)
        case restarting(progress: Double?, downloadedBytes: Int64, totalBytes: Int64?)
        case verifying
        case installing
        case installed
        case deleting
        case unavailable(String)
        case failed(String)
    }

    @Published private(set) var states: [String: OperationState] = [:]

    private let modelAssetStore: LocalModelAssetStore?
    private let modelManager: ModelManagerViewModel
    private var deliveryActor: IOSModelDeliveryActor?

    /// Called after a model install completes so the engine can preload it in the background.
    var onModelInstalled: ((_ modelID: String) -> Void)?

    init(
        modelAssetStore: LocalModelAssetStore?,
        modelManager: ModelManagerViewModel
    ) {
        self.modelAssetStore = modelAssetStore
        self.modelManager = modelManager

        guard let modelAssetStore else {
            return
        }

        let actor = IOSModelDeliveryActor(
            modelAssetStore: modelAssetStore,
            snapshotSink: { [weak self] snapshot in
                self?.apply(snapshot)
            }
        )
        self.deliveryActor = actor

        Task {
            await modelManager.refresh()
            await actor.resumeBackgroundEventsIfNeeded()
        }
    }

    func state(for model: TTSModel) -> OperationState {
        if let unavailableMessage = IOSNativeDeviceFeatureGate.unavailableMessage(for: model) {
            return .unavailable(unavailableMessage)
        }

        if let state = states[model.id] {
            return state
        }

        switch modelManager.statuses[model.id] {
        case .installed:
            return .idle
        case .checking:
            return .idle
        case .notInstalled, .none:
            guard let descriptor = modelAssetStore?.descriptor(id: model.id)?.model else {
                return .failed("Missing model descriptor.")
            }
            guard IOSNativeDeviceFeatureGate.allowsModelDownloads(for: descriptor) else {
                return .unavailable("iPhone download support for this model is not enabled in this build.")
            }
            return .available(estimatedBytes: descriptor.estimatedDownloadBytes)
        case .incomplete(let message, _):
            guard let descriptor = modelAssetStore?.descriptor(id: model.id)?.model else {
                return .failed("Missing model descriptor.")
            }
            if IOSNativeDeviceFeatureGate.allowsModelDownloads(for: descriptor) {
                return .failed(message)
            }
            return .unavailable("This model is not available on iPhone yet, and the local files are incomplete.")
        case .error(let message):
            guard let descriptor = modelAssetStore?.descriptor(id: model.id)?.model else {
                return .failed(message)
            }
            if IOSNativeDeviceFeatureGate.allowsModelDownloads(for: descriptor) {
                return .failed(message)
            }
            return .unavailable(message)
        }
    }

    func install(_ model: TTSModel) {
        if let unavailableMessage = IOSNativeDeviceFeatureGate.unavailableMessage(for: model) {
            states[model.id] = .unavailable(unavailableMessage)
            return
        }
        guard let deliveryActor else {
            states[model.id] = .failed("Model delivery is unavailable in this runtime.")
            return
        }

        Task {
            do {
                try await deliveryActor.install(model: model)
            } catch {
                apply(
                    IOSModelDeliverySnapshot(
                        modelID: model.id,
                        phase: .failed,
                        downloadedBytes: 0,
                        totalBytes: model.estimatedDownloadBytes,
                        estimatedBytes: model.estimatedDownloadBytes,
                        message: error.localizedDescription
                    )
                )
            }
        }
    }

    func cancel(_ model: TTSModel) {
        // Immediately show available state before background refresh
        if let descriptor = modelAssetStore?.descriptor(id: model.id)?.model {
            states[model.id] = .available(estimatedBytes: descriptor.estimatedDownloadBytes)
        } else {
            states.removeValue(forKey: model.id)
        }
        guard let deliveryActor else { return }
        Task {
            await deliveryActor.cancel(modelID: model.id)
            await modelManager.refresh()
        }
    }

    func delete(_ model: TTSModel) {
        if IOSNativeDeviceFeatureGate.unavailableMessage(for: model) != nil {
            return
        }
        guard let deliveryActor else {
            states[model.id] = .failed("Model delivery is unavailable in this runtime.")
            return
        }

        Task {
            do {
                try await deliveryActor.delete(model: model)
                await modelManager.refresh()
                states.removeValue(forKey: model.id)
            } catch {
                apply(
                    IOSModelDeliverySnapshot(
                        modelID: model.id,
                        phase: .failed,
                        downloadedBytes: 0,
                        totalBytes: nil,
                        estimatedBytes: model.estimatedDownloadBytes,
                        message: error.localizedDescription
                    )
                )
            }
        }
    }

    func handleBackgroundEventsCompletion(_ completionHandler: @escaping () -> Void) {
        IOSModelDeliveryBackgroundEventRelay.store(completionHandler)
        guard let deliveryActor else {
            IOSModelDeliveryBackgroundEventRelay.completeIfPending()
            return
        }
        Task {
            await deliveryActor.resumeBackgroundEventsIfNeeded()
        }
    }

    private func apply(_ snapshot: IOSModelDeliverySnapshot) {
        switch snapshot.phase {
        case .downloading:
            let progress: Double?
            if let totalBytes = snapshot.totalBytes, totalBytes > 0 {
                progress = Double(snapshot.downloadedBytes) / Double(totalBytes)
            } else {
                progress = nil
            }
            states[snapshot.modelID] = .downloading(
                progress: progress,
                downloadedBytes: snapshot.downloadedBytes,
                totalBytes: snapshot.totalBytes
            )
        case .interrupted:
            states[snapshot.modelID] = .interrupted(
                message: snapshot.message,
                downloadedBytes: snapshot.downloadedBytes,
                totalBytes: snapshot.totalBytes
            )
        case .resuming:
            let progress: Double?
            if let totalBytes = snapshot.totalBytes, totalBytes > 0 {
                progress = Double(snapshot.downloadedBytes) / Double(totalBytes)
            } else {
                progress = nil
            }
            states[snapshot.modelID] = .resuming(
                progress: progress,
                downloadedBytes: snapshot.downloadedBytes,
                totalBytes: snapshot.totalBytes
            )
        case .restarting:
            let progress: Double?
            if let totalBytes = snapshot.totalBytes, totalBytes > 0 {
                progress = Double(snapshot.downloadedBytes) / Double(totalBytes)
            } else {
                progress = nil
            }
            states[snapshot.modelID] = .restarting(
                progress: progress,
                downloadedBytes: snapshot.downloadedBytes,
                totalBytes: snapshot.totalBytes
            )
        case .verifying:
            states[snapshot.modelID] = .verifying
        case .installing:
            states[snapshot.modelID] = .installing
        case .installed:
            states[snapshot.modelID] = .installed
            let modelID = snapshot.modelID
            Task {
                await modelManager.refresh()
                onModelInstalled?(modelID)
            }
        case .deleting:
            states[snapshot.modelID] = .deleting
        case .failed:
            states[snapshot.modelID] = .failed(snapshot.message ?? "Model delivery failed.")
            Task {
                await modelManager.refresh()
            }
        case .deleted:
            states.removeValue(forKey: snapshot.modelID)
            Task {
                await modelManager.refresh()
            }
        }
    }
}
