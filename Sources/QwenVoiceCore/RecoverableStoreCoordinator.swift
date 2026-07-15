import Synchronization

/// Synchronous, lock-protected ownership for a store whose initial open or
/// migration may fail transiently.
///
/// A failure remains sticky for ordinary reads/writes (fail closed). An
/// explicit `reopenIfNeeded()` performs a fresh open and atomically replaces
/// the failed state only after the complete open/migration closure succeeds.
public final class RecoverableStoreCoordinator<Store: Sendable, Failure: Error & Sendable>: Sendable {
    private enum State: Sendable {
        case available(Store)
        case failed(Failure)
    }

    private let state: Mutex<State>
    private let openStore: @Sendable () throws -> Store
    private let classify: @Sendable (Error) -> Failure

    public init(
        openStore: @escaping @Sendable () throws -> Store,
        classify: @escaping @Sendable (Error) -> Failure
    ) {
        self.openStore = openStore
        self.classify = classify
        do {
            state = Mutex(.available(try openStore()))
        } catch {
            state = Mutex(.failed(classify(error)))
        }
    }

    public func requireStore() throws -> Store {
        try state.withLock { state in
            switch state {
            case .available(let store):
                return store
            case .failed(let failure):
                throw failure
            }
        }
    }

    /// Reopens only a failed coordinator. Concurrent callers serialize on the
    /// mutex, so at most one fresh migration/open attempt occurs.
    @discardableResult
    public func reopenIfNeeded() throws -> Store {
        try state.withLock { state in
            if case .available(let store) = state {
                return store
            }
            do {
                let store = try openStore()
                state = .available(store)
                return store
            } catch {
                let failure = classify(error)
                state = .failed(failure)
                throw failure
            }
        }
    }
}
