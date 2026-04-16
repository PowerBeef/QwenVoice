import Foundation

@MainActor
final class ModelLoadCoordinator {
    private struct InFlightModelLoad {
        let token: UUID
        let id: String
        let task: Task<[String: RPCValue], Error>
    }

    private var inFlightModelLoad: InFlightModelLoad?
    private var loadedModelID: String?
    private var prewarmedRequestKeys: Set<String> = []
    private var prewarmingRequestKeys: Set<String> = []

    var currentLoadedModelID: String? {
        loadedModelID
    }

    func canSkipLoadModel(requestedID: String) -> Bool {
        loadedModelID == requestedID
    }

    func markLoadedModel(id: String) {
        if loadedModelID != id {
            prewarmedRequestKeys.removeAll()
            prewarmingRequestKeys.removeAll()
        }
        loadedModelID = id
    }

    func markUnloaded() {
        loadedModelID = nil
        prewarmedRequestKeys.removeAll()
        prewarmingRequestKeys.removeAll()
    }

    func reset() {
        inFlightModelLoad = nil
        loadedModelID = nil
        prewarmedRequestKeys.removeAll()
        prewarmingRequestKeys.removeAll()
    }

    func loadModel(
        id: String,
        performLoad: @escaping @MainActor () async throws -> [String: RPCValue]
    ) async throws -> [String: RPCValue] {
        if canSkipLoadModel(requestedID: id) {
            return [
                "success": .bool(true),
                "cached": .bool(true),
                "model_id": .string(id),
            ]
        }

        if let inFlightModelLoad {
            if inFlightModelLoad.id == id {
                return try await inFlightModelLoad.task.value
            }

            _ = try? await inFlightModelLoad.task.value
            if canSkipLoadModel(requestedID: id) {
                return [
                    "success": .bool(true),
                    "cached": .bool(true),
                    "model_id": .string(id),
                ]
            }
        }

        let token = UUID()
        let task = Task { @MainActor in
            let result = try await performLoad()
            self.markLoadedModel(id: id)
            return result
        }
        inFlightModelLoad = InFlightModelLoad(token: token, id: id, task: task)

        do {
            let result = try await task.value
            if inFlightModelLoad?.token == token {
                inFlightModelLoad = nil
            }
            return result
        } catch {
            if inFlightModelLoad?.token == token {
                inFlightModelLoad = nil
            }
            throw error
        }
    }

    func prewarmIfNeeded(
        key: String,
        performPrewarm: @escaping @MainActor () async throws -> Void
    ) async -> Bool {
        guard !prewarmedRequestKeys.contains(key) else { return false }
        guard !prewarmingRequestKeys.contains(key) else { return false }

        prewarmingRequestKeys.insert(key)
        defer { prewarmingRequestKeys.remove(key) }

        do {
            try await performPrewarm()
            prewarmedRequestKeys.insert(key)
            return true
        } catch {
            #if DEBUG
            print("[Performance][PythonBridge] prewarm_failed key=\(key) error=\(error.localizedDescription)")
            #endif
            return false
        }
    }
}
