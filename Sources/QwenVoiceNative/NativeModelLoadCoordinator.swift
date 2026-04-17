import Foundation

actor NativeModelLoadCoordinator {
    private struct InFlightLoad {
        let modelID: String
        let task: Task<Void, Error>
    }

    private var currentLoadedModelIDValue: String?
    private var inFlightLoad: InFlightLoad?
    private var prewarmedIdentityKeys: Set<String> = []

    func loadModel(
        id: String,
        performLoad: @escaping @Sendable () async throws -> Void
    ) async throws {
        if currentLoadedModelIDValue == id, inFlightLoad == nil {
            return
        }

        if try await awaitExistingLoadIfNeeded(for: id) {
            return
        }

        if currentLoadedModelIDValue != id {
            currentLoadedModelIDValue = nil
            prewarmedIdentityKeys.removeAll()
        }

        let task = Task {
            try await performLoad()
        }
        inFlightLoad = InFlightLoad(modelID: id, task: task)

        do {
            try await task.value
            currentLoadedModelIDValue = id
            inFlightLoad = nil
        } catch {
            if inFlightLoad?.modelID == id {
                inFlightLoad = nil
            }
            throw error
        }
    }

    func ensureModelLoadedIfNeeded(
        id: String,
        performLoad: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await loadModel(id: id, performLoad: performLoad)
    }

    func prewarmIfNeeded(
        identityKey: String,
        modelID: String,
        performLoad: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await ensureModelLoadedIfNeeded(id: modelID, performLoad: performLoad)
        guard !prewarmedIdentityKeys.contains(identityKey) else {
            return
        }
        prewarmedIdentityKeys.insert(identityKey)
    }

    func unloadModel() {
        currentLoadedModelIDValue = nil
        inFlightLoad = nil
        prewarmedIdentityKeys.removeAll()
    }

    func currentLoadedModelID() -> String? {
        currentLoadedModelIDValue
    }

    func markPrewarmed(identityKey: String) {
        prewarmedIdentityKeys.insert(identityKey)
    }

    func isPrewarmed(identityKey: String) -> Bool {
        prewarmedIdentityKeys.contains(identityKey)
    }

    private func awaitExistingLoadIfNeeded(for modelID: String) async throws -> Bool {
        guard let inFlightLoad else {
            return false
        }

        let task = inFlightLoad.task
        let matchesRequestedModel = inFlightLoad.modelID == modelID
        try await task.value
        return matchesRequestedModel
    }
}
