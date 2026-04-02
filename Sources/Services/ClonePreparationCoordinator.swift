import Foundation

@MainActor
final class ClonePreparationCoordinator {
    private struct InFlightCloneReferencePrime {
        let token: UUID
        let key: String
        let task: Task<[String: RPCValue], Error>
    }

    private var inFlightCloneReferencePrime: InFlightCloneReferencePrime?

    private(set) var phase: CloneReferencePrimingPhase = .idle
    private(set) var currentKey: String?
    private(set) var errorMessage: String?

    func setState(
        _ phase: CloneReferencePrimingPhase,
        key: String? = nil,
        error: String? = nil
    ) {
        self.phase = phase
        currentKey = key
        errorMessage = error
    }

    func reset() {
        inFlightCloneReferencePrime = nil
        setState(.idle)
    }

    func ensurePrimed(
        key: String,
        performPrepare: @escaping @MainActor () async throws -> [String: RPCValue]
    ) async throws {
        if phase == .primed, currentKey == key {
            return
        }

        if let inFlightCloneReferencePrime {
            if inFlightCloneReferencePrime.key == key {
                _ = try await inFlightCloneReferencePrime.task.value
                return
            }

            throw PythonBridgeError.cancelled
        }

        let token = UUID()
        setState(.preparing, key: key)

        let task = Task { @MainActor in
            try await performPrepare()
        }
        inFlightCloneReferencePrime = InFlightCloneReferencePrime(token: token, key: key, task: task)

        do {
            _ = try await task.value
            if inFlightCloneReferencePrime?.token == token {
                inFlightCloneReferencePrime = nil
            }
            setState(.primed, key: key)
        } catch {
            if inFlightCloneReferencePrime?.token == token {
                inFlightCloneReferencePrime = nil
            }
            setState(.failed, key: key, error: error.localizedDescription)
            throw error
        }
    }

    func hasDifferentInFlightKey(_ key: String) -> Bool {
        guard let inFlightCloneReferencePrime else { return false }
        return inFlightCloneReferencePrime.key != key
    }

    func hasInFlightTask(for key: String) -> Bool {
        inFlightCloneReferencePrime?.key == key
    }
}
