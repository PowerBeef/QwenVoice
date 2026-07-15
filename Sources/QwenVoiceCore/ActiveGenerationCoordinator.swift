import Foundation

/// Owns the one task that may currently execute model generation.
///
/// Callers register the task's cancellation and terminal wait operations as
/// one unit. `cancelCurrent` does not release ownership until the task has
/// actually terminated, which is the barrier required before a hard trim or
/// model unload can safely begin.
actor ActiveGenerationCoordinator {
    struct Registration: Sendable {
        let id: UUID
    }

    private struct Active: Sendable {
        let id: UUID
        let cancel: @Sendable () -> Void
        let waitForTermination: @Sendable () async -> Void
    }

    private var active: Active?
    private var cancellationReason: GenerationCancellationReason?
    private var completedCancellationReasons: [UUID: GenerationCancellationReason] = [:]

    var hasActiveGeneration: Bool {
        active != nil
    }

    func register(
        cancel: @escaping @Sendable () -> Void,
        waitForTermination: @escaping @Sendable () async -> Void
    ) throws -> Registration {
        guard active == nil else {
            throw TTSEngineError.generationFailed(
                "The engine is already generating audio. Wait for it to finish or cancel it before starting another generation."
            )
        }
        let id = UUID()
        active = Active(
            id: id,
            cancel: cancel,
            waitForTermination: waitForTermination
        )
        cancellationReason = nil
        return Registration(id: id)
    }

    /// Releases generation ownership and atomically returns the reason that
    /// requested cancellation, if any. The owner must take the reason before
    /// this call clears coordinator state so an early-cancel terminal event
    /// cannot silently fall back to `.user`.
    @discardableResult
    func finish(_ registration: Registration) -> GenerationCancellationReason? {
        if active?.id == registration.id {
            let terminalCancellationReason = cancellationReason
            active = nil
            cancellationReason = nil
            return terminalCancellationReason
        }
        return completedCancellationReasons.removeValue(forKey: registration.id)
    }

    /// Cancels and awaits the current task. Ownership remains active during
    /// the wait, so a concurrent unload cannot mistake cancellation request
    /// acknowledgement for actual compute termination.
    func cancelCurrent(reason: GenerationCancellationReason) async {
        guard let current = active else { return }
        if cancellationReason == nil {
            cancellationReason = reason
            current.cancel()
        }
        await current.waitForTermination()
        if active?.id == current.id {
            if let cancellationReason {
                completedCancellationReasons[current.id] = cancellationReason
            }
            active = nil
            cancellationReason = nil
        }
    }

    func reason(for registration: Registration) -> GenerationCancellationReason? {
        if active?.id == registration.id {
            return cancellationReason
        }
        return completedCancellationReasons[registration.id]
    }

    var currentCancellationReason: GenerationCancellationReason? {
        cancellationReason
    }
}

/// Prevents a newly created unstructured task from entering the runtime until
/// its cancellation and terminal-wait closures are durably registered.
actor GenerationTaskStartGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }
}
