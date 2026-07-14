import Foundation
import QwenVoiceCore

@MainActor
final class IOSModelInstallerViewModel: ObservableObject {
    enum OperationState: Equatable {
        case idle
        case available(estimatedBytes: Int64?)
        case queued
        case waitingForConnectivity(downloadedBytes: Int64, totalBytes: Int64?)
        case downloading(
            progress: Double?, downloadedBytes: Int64, totalBytes: Int64?,
            bytesPerSecond: Int64?, estimatedSecondsRemaining: Double?, message: String?
        )
        case retrying(
            progress: Double?, downloadedBytes: Int64, totalBytes: Int64?,
            retryCount: Int, reason: String?
        )
        case verifying
        case installing
        case cancelling
        case installed
        case deleting
        case unavailable(String)
        case failed(String)
    }

    @Published private(set) var states: [String: OperationState] = [:]

    private let modelAssetStore: LocalModelAssetStore?
    private let modelManager: ModelManagerViewModel
    private var coordinator: IOSModelDownloadCoordinator?
    private var lastAcceptedGeneration: [String: UInt64] = [:]

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

        let coordinator = IOSModelDownloadCoordinator(
            modelAssetStore: modelAssetStore,
            snapshotSink: { [weak self] snapshot in
                self?.apply(snapshot)
            }
        )
        self.coordinator = coordinator

        Task {
            await modelManager.refresh()
            await coordinator.restoreInFlightDownloadsIfNeeded()
        }
    }


    func state(for model: TTSModel) -> OperationState {
        if let state = states[model.id] {
            return state
        }

        if let unavailableMessage = IOSNativeDeviceFeatureGate.unavailableMessage(for: model) {
            return .unavailable(unavailableMessage)
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
                return .failed(message)
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
        guard let coordinator else {
            states[model.id] = .failed("Model delivery is unavailable in this runtime.")
            return
        }

        Task {
            do {
                try await coordinator.install(model: model)
            } catch {
                let generation = (lastAcceptedGeneration[model.id] ?? 0) + 1
                lastAcceptedGeneration[model.id] = generation
                apply(
                    IOSModelDeliverySnapshot(
                        modelID: model.id,
                        phase: .failed,
                        downloadedBytes: 0,
                        totalBytes: model.estimatedDownloadBytes,
                        estimatedBytes: model.estimatedDownloadBytes,
                        message: error.localizedDescription,
                        operationGeneration: generation
                    )
                )
            }
        }
    }

    func cancel(_ model: TTSModel) {
        states[model.id] = .cancelling
        guard let coordinator else { return }
        Task {
            await coordinator.cancel(modelID: model.id)
            await modelManager.refresh()
        }
    }

    func delete(_ model: TTSModel) {
        if IOSNativeDeviceFeatureGate.unavailableMessage(for: model) != nil {
            return
        }
        guard let coordinator else {
            states[model.id] = .failed("Model delivery is unavailable in this runtime.")
            return
        }

        Task {
            do {
                try await coordinator.delete(model: model)
                await modelManager.refresh()
                states.removeValue(forKey: model.id)
            } catch {
                let generation = (lastAcceptedGeneration[model.id] ?? 0) + 1
                lastAcceptedGeneration[model.id] = generation
                apply(
                    IOSModelDeliverySnapshot(
                        modelID: model.id,
                        phase: .failed,
                        downloadedBytes: 0,
                        totalBytes: nil,
                        estimatedBytes: model.estimatedDownloadBytes,
                        message: error.localizedDescription,
                        operationGeneration: generation
                    )
                )
            }
        }
    }

    func handleBackgroundEventsCompletion(_ identifier: String, _ completionHandler: @escaping () -> Void) {
        IOSModelDeliveryBackgroundEventRelay.store(completionHandler, forSessionIdentifier: identifier)
        guard let coordinator else {
            IOSModelDeliveryBackgroundEventRelay.completeOrphans(keeping: [])
            return
        }
        Task {
            await coordinator.resumeBackgroundEventsIfNeeded()
        }
    }

    private func apply(_ snapshot: IOSModelDeliverySnapshot) {
        let previousGeneration = lastAcceptedGeneration[snapshot.modelID] ?? 0
        guard snapshot.operationGeneration >= previousGeneration else { return }
        lastAcceptedGeneration[snapshot.modelID] = snapshot.operationGeneration

        switch snapshot.phase {
        case .queued:
            states[snapshot.modelID] = .queued
        case .waitingForConnectivity:
            states[snapshot.modelID] = .waitingForConnectivity(
                downloadedBytes: snapshot.downloadedBytes,
                totalBytes: snapshot.totalBytes
            )
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
                totalBytes: snapshot.totalBytes,
                bytesPerSecond: snapshot.bytesPerSecond,
                estimatedSecondsRemaining: snapshot.estimatedSecondsRemaining,
                message: snapshot.message
            )
        case .retrying:
            let progress: Double?
            if let totalBytes = snapshot.totalBytes, totalBytes > 0 {
                progress = Double(snapshot.downloadedBytes) / Double(totalBytes)
            } else {
                progress = nil
            }
            states[snapshot.modelID] = .retrying(
                progress: progress,
                downloadedBytes: snapshot.downloadedBytes,
                totalBytes: snapshot.totalBytes,
                retryCount: snapshot.retryCount,
                reason: snapshot.message
            )
        case .verifying:
            states[snapshot.modelID] = .verifying
        case .installing:
            states[snapshot.modelID] = .installing
        case .cancelling:
            states[snapshot.modelID] = .cancelling
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
            lastAcceptedGeneration.removeValue(forKey: snapshot.modelID)
            Task {
                await modelManager.refresh()
            }
        }
    }
}
