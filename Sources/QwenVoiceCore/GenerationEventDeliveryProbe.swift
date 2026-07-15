import Foundation
import os

struct GenerationEventDeliverySnapshot: Equatable, Sendable {
    var subscriberPresent = false
    var yielded = 0
    var accepted = 0
    var unobserved = 0
    var droppedChunks = 0
    var droppedProgress = 0
    var droppedTerminals = 0
    var terminatedYields = 0
    var terminalYielded = 0
    var terminalEnqueued = 0
    var consumerTerminatedBeforeTerminal = false
    var minimumRemainingCapacity: Int?

    var droppedTotal: Int {
        droppedChunks + droppedProgress + droppedTerminals
    }

    var terminalDeliveryComplete: Bool {
        !subscriberPresent || (terminalEnqueued == 1 && terminatedYields == 0)
    }

    var accountingIsExact: Bool {
        yielded == accepted + terminatedYields + unobserved
    }
}

/// One bounded stream per generation. A previous generation can therefore
/// never occupy the next generation's buffer or have its terminal evicted by
/// later work. Every producer yield has exactly one accounted outcome:
/// accepted (possibly evicting an older event), terminated, or unobserved.
final class GenerationScopedEventRouter: @unchecked Sendable {
    private struct ActiveSubscription {
        var continuation: AsyncStream<GenerationEvent>.Continuation?
        var snapshot: GenerationEventDeliverySnapshot
        var producerStarted = false
        var terminalYielded = false
    }

    private struct State {
        var active: [UUID: ActiveSubscription] = [:]
        var completed: [UUID: GenerationEventDeliverySnapshot] = [:]
        var completedOrder: [UUID] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func stream(for generationID: UUID, capacity: Int) -> AsyncStream<GenerationEvent> {
        precondition(capacity > 0)
        let pair = AsyncStream<GenerationEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(capacity)
        )
        let stream = pair.stream
        let capturedContinuation = pair.continuation
        let accepted = lock.withLock { state -> Bool in
            if let current = state.active[generationID], current.continuation != nil {
                return false
            }
            var subscription = state.active[generationID] ?? ActiveSubscription(
                continuation: nil,
                snapshot: GenerationEventDeliverySnapshot(),
                producerStarted: false,
                terminalYielded: false
            )
            subscription.continuation = capturedContinuation
            subscription.snapshot.subscriberPresent = true
            state.active[generationID] = subscription
            return true
        }
        if accepted {
            capturedContinuation.onTermination = { [weak self] _ in
                self?.consumerTerminated(generationID: generationID)
            }
        } else {
            capturedContinuation.finish()
        }
        return stream
    }

    func beginGeneration(_ generationID: UUID) {
        lock.withLock { state in
            state.completed.removeValue(forKey: generationID)
            state.completedOrder.removeAll { $0 == generationID }
            if var subscription = state.active[generationID] {
                subscription.snapshot = GenerationEventDeliverySnapshot(
                    subscriberPresent: subscription.continuation != nil
                )
                subscription.producerStarted = true
                subscription.terminalYielded = false
                state.active[generationID] = subscription
            } else {
                state.active[generationID] = ActiveSubscription(
                    continuation: nil,
                    snapshot: GenerationEventDeliverySnapshot(),
                    producerStarted: true,
                    terminalYielded: false
                )
            }
        }
    }

    func yield(_ event: GenerationEvent, for generationID: UUID) {
        let continuation = lock.withLock { state -> AsyncStream<GenerationEvent>.Continuation? in
            if state.active[generationID] == nil {
                state.active[generationID] = ActiveSubscription(
                    continuation: nil,
                    snapshot: GenerationEventDeliverySnapshot(),
                    producerStarted: true,
                    terminalYielded: false
                )
            }
            state.active[generationID]?.snapshot.yielded += 1
            return state.active[generationID]?.continuation
        }

        let result = continuation?.yield(event)
        let continuationToFinish = lock.withLock { state -> AsyncStream<GenerationEvent>.Continuation? in
            guard var subscription = state.active[generationID] else { return nil }
            if let result {
                Self.record(result, into: &subscription.snapshot)
                if event.kind == .completed || event.kind == .cancelled || event.kind == .failed,
                   case .enqueued = result {
                    subscription.snapshot.terminalEnqueued += 1
                } else if event.kind == .completed || event.kind == .cancelled || event.kind == .failed,
                          case .dropped = result {
                    // bufferingNewest accepted this terminal and evicted the
                    // returned older event.
                    subscription.snapshot.terminalEnqueued += 1
                }
            } else {
                subscription.snapshot.unobserved += 1
            }

            let isTerminal = event.kind == .completed
                || event.kind == .cancelled
                || event.kind == .failed
            if isTerminal {
                subscription.snapshot.terminalYielded += 1
                subscription.terminalYielded = true
                let continuationToFinish = subscription.continuation
                Self.archive(subscription.snapshot, generationID: generationID, state: &state)
                state.active.removeValue(forKey: generationID)
                return continuationToFinish
            } else {
                state.active[generationID] = subscription
                return nil
            }
        }
        continuationToFinish?.finish()
    }

    func snapshot(for generationID: UUID, consuming: Bool = false) -> GenerationEventDeliverySnapshot {
        lock.withLock { state in
            let snapshot = state.active[generationID]?.snapshot
                ?? state.completed[generationID]
                ?? GenerationEventDeliverySnapshot()
            if consuming {
                state.completed.removeValue(forKey: generationID)
                state.completedOrder.removeAll { $0 == generationID }
            }
            return snapshot
        }
    }

    private func consumerTerminated(generationID: UUID) {
        lock.withLock { state in
            guard var subscription = state.active[generationID] else { return }
            subscription.continuation = nil
            if subscription.producerStarted && !subscription.terminalYielded {
                subscription.snapshot.consumerTerminatedBeforeTerminal = true
            }
            state.active[generationID] = subscription
        }
    }

    private static func record(
        _ result: AsyncStream<GenerationEvent>.Continuation.YieldResult,
        into snapshot: inout GenerationEventDeliverySnapshot
    ) {
        switch result {
        case .enqueued(let remainingCapacity):
            snapshot.accepted += 1
            snapshot.minimumRemainingCapacity = min(
                snapshot.minimumRemainingCapacity ?? remainingCapacity,
                remainingCapacity
            )
        case .dropped(let event):
            snapshot.accepted += 1
            snapshot.minimumRemainingCapacity = 0
            switch event.kind {
            case .streamChunk:
                snapshot.droppedChunks += 1
            case .progress:
                snapshot.droppedProgress += 1
            case .completed, .cancelled, .failed:
                snapshot.droppedTerminals += 1
            }
        case .terminated:
            snapshot.terminatedYields += 1
        @unknown default:
            snapshot.terminatedYields += 1
        }
    }

    private static func archive(
        _ snapshot: GenerationEventDeliverySnapshot,
        generationID: UUID,
        state: inout State
    ) {
        state.completed[generationID] = snapshot
        state.completedOrder.removeAll { $0 == generationID }
        state.completedOrder.append(generationID)
        while state.completedOrder.count > 16 {
            state.completed.removeValue(forKey: state.completedOrder.removeFirst())
        }
    }
}
