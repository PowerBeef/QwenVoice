import Foundation
import os

/// Stable failures for the classified generation-session primitives.
public enum VocelloQwen3SessionError: Error, Equatable, Sendable {
    case audioConsumerAlreadyClaimed
    case concurrentAudioReceive
    case audioChannelClosed
    case audioChannelCancelled(VocelloQwen3CancellationReason)
    case audioChunkExceedsCapacity(frameCount: Int, capacity: Int)
    case invalidAudioChunk
    case invalidFinalizationIdentity
    case conflictingFinalizationAcknowledgement
}

/// Bounded-channel evidence. Capacity and high-water values are measured in
/// audio frames rather than in event count.
public struct VocelloQwen3AudioChannelStatistics: Codable, Hashable, Sendable {
    public let capacityFrames: Int
    public let highWaterFrames: Int
    public let producerSuspensionCount: Int
    public let producerSuspensionNanoseconds: UInt64
    public let cancellationWakeupCount: Int

    public init(
        capacityFrames: Int,
        highWaterFrames: Int,
        producerSuspensionCount: Int,
        producerSuspensionNanoseconds: UInt64,
        cancellationWakeupCount: Int
    ) {
        self.capacityFrames = capacityFrames
        self.highWaterFrames = highWaterFrames
        self.producerSuspensionCount = producerSuspensionCount
        self.producerSuspensionNanoseconds = producerSuspensionNanoseconds
        self.cancellationWakeupCount = cancellationWakeupCount
    }
}

/// The one public audio consumer for a generation. Producers use the paired
/// internal endpoint; consumers cannot publish or forge frames.
public struct VocelloQwen3LosslessAudioSequence: AsyncSequence, Sendable {
    public typealias Element = VocelloQwen3AudioChunkEvent

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let state: VocelloQwen3LosslessAudioChannelState
        private let consumerID: UUID

        fileprivate init(
            state: VocelloQwen3LosslessAudioChannelState,
            consumerID: UUID
        ) {
            self.state = state
            self.consumerID = consumerID
        }

        public mutating func next() async throws -> Element? {
            try await state.next(consumerID: consumerID)
        }
    }

    fileprivate let state: VocelloQwen3LosslessAudioChannelState

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(state: state, consumerID: UUID())
    }

    /// Signals that the mandatory consumer cannot continue. This wakes a
    /// producer suspended on backpressure and prevents silent audio loss.
    public func cancel(reason: VocelloQwen3CancellationReason) async {
        await state.cancel(reason: reason)
    }

    /// Fails the mandatory drain with the consumer's typed failure. Product
    /// adapters use this before requesting generation cancellation so a
    /// producer suspended on backpressure cannot remain stranded behind a
    /// drain that has already failed.
    public func fail(_ error: any Error & Sendable) async {
        await state.fail(error)
    }

    public func statistics() async -> VocelloQwen3AudioChannelStatistics {
        await state.statistics()
    }
}

struct VocelloQwen3LosslessAudioProducer: Sendable {
    fileprivate let state: VocelloQwen3LosslessAudioChannelState

    func send(_ chunk: VocelloQwen3AudioChunkEvent) async throws {
        try await state.send(chunk)
    }

    func finish() async {
        await state.finish()
    }

    func fail(_ error: any Error & Sendable) async {
        await state.fail(error)
    }
}

enum VocelloQwen3LosslessAudioChannel {
    static func make(
        capacityFrames: Int
    ) -> (producer: VocelloQwen3LosslessAudioProducer, consumer: VocelloQwen3LosslessAudioSequence) {
        let state = VocelloQwen3LosslessAudioChannelState(capacityFrames: capacityFrames)
        return (
            VocelloQwen3LosslessAudioProducer(state: state),
            VocelloQwen3LosslessAudioSequence(state: state)
        )
    }
}

private struct VocelloQwen3SendableFailure: Error, Sendable {
    let base: any Error & Sendable
}

fileprivate actor VocelloQwen3LosslessAudioChannelState {
    private struct PendingSend {
        let id: UUID
        let chunk: VocelloQwen3AudioChunkEvent
        let suspendedAt: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private enum Termination {
        case finished
        case cancelled(VocelloQwen3CancellationReason)
        case consumerTaskCancelled
        case failed(VocelloQwen3SendableFailure)
    }

    private struct PendingReceive {
        let id: UUID
        let continuation: CheckedContinuation<VocelloQwen3AudioChunkEvent?, any Error>
    }

    private let capacityFrames: Int
    private var queue: [VocelloQwen3AudioChunkEvent] = []
    private var queuedFrames = 0
    private var waitingReceiver: PendingReceive?
    private var pendingSends: [PendingSend] = []
    private var consumerID: UUID?
    private var termination: Termination?
    private var highWaterFrames = 0
    private var producerSuspensionCount = 0
    private var producerSuspensionNanoseconds: UInt64 = 0
    private var cancellationWakeupCount = 0

    init(capacityFrames: Int) {
        self.capacityFrames = max(1, capacityFrames)
    }

    func send(_ chunk: VocelloQwen3AudioChunkEvent) async throws {
        try Task.checkCancellation()
        guard chunk.channelCount > 0,
              chunk.frameCount > 0,
              chunk.samples.count.isMultiple(of: chunk.channelCount) else {
            throw VocelloQwen3SessionError.invalidAudioChunk
        }
        guard chunk.frameCount <= capacityFrames else {
            throw VocelloQwen3SessionError.audioChunkExceedsCapacity(
                frameCount: chunk.frameCount,
                capacity: capacityFrames
            )
        }
        try throwIfTerminated()

        if let waitingReceiver {
            self.waitingReceiver = nil
            waitingReceiver.continuation.resume(returning: chunk)
            return
        }

        if pendingSends.isEmpty, queuedFrames + chunk.frameCount <= capacityFrames {
            enqueue(chunk)
            return
        }

        producerSuspensionCount += 1
        let pendingID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingSends.append(PendingSend(
                    id: pendingID,
                    chunk: chunk,
                    suspendedAt: .now,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { await self.cancelPendingSend(id: pendingID) }
        }
    }

    func next(consumerID candidate: UUID) async throws -> VocelloQwen3AudioChunkEvent? {
        if Task.isCancelled {
            terminate(.consumerTaskCancelled)
            throw CancellationError()
        }
        if let consumerID, consumerID != candidate {
            throw VocelloQwen3SessionError.audioConsumerAlreadyClaimed
        }
        consumerID = candidate

        if !queue.isEmpty {
            let chunk = queue.removeFirst()
            queuedFrames -= chunk.frameCount
            promotePendingSends()
            return chunk
        }

        if let termination {
            return try terminalResult(termination)
        }
        guard waitingReceiver == nil else {
            throw VocelloQwen3SessionError.concurrentAudioReceive
        }

        let receiveID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    terminate(.consumerTaskCancelled)
                    continuation.resume(throwing: CancellationError())
                } else {
                    waitingReceiver = PendingReceive(
                        id: receiveID,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelPendingReceive(id: receiveID) }
        }
    }

    func finish() {
        guard termination == nil else { return }
        termination = .finished
        precondition(pendingSends.isEmpty, "normal finish requires all lossless sends to complete")
        if queue.isEmpty {
            waitingReceiver?.continuation.resume(returning: nil)
            waitingReceiver = nil
        }
    }

    func fail(_ error: any Error & Sendable) {
        terminate(.failed(VocelloQwen3SendableFailure(base: error)))
    }

    func cancel(reason: VocelloQwen3CancellationReason) {
        terminate(.cancelled(reason))
    }

    func statistics() -> VocelloQwen3AudioChannelStatistics {
        VocelloQwen3AudioChannelStatistics(
            capacityFrames: capacityFrames,
            highWaterFrames: highWaterFrames,
            producerSuspensionCount: producerSuspensionCount,
            producerSuspensionNanoseconds: producerSuspensionNanoseconds,
            cancellationWakeupCount: cancellationWakeupCount
        )
    }

    private func enqueue(_ chunk: VocelloQwen3AudioChunkEvent) {
        queue.append(chunk)
        queuedFrames += chunk.frameCount
        highWaterFrames = max(highWaterFrames, queuedFrames)
    }

    private func promotePendingSends() {
        while let pending = pendingSends.first,
              queuedFrames + pending.chunk.frameCount <= capacityFrames,
              termination == nil {
            pendingSends.removeFirst()
            enqueue(pending.chunk)
            producerSuspensionNanoseconds &+= pending.suspendedAt.duration(to: .now).clampedNanoseconds
            pending.continuation.resume()
        }
    }

    /// A task cancellation is independent of channel cancellation. Removing
    /// the pending send ensures an abandoned producer cannot retain a frame or
    /// block behind a consumer that will never drain it.
    private func cancelPendingSend(id: UUID) {
        guard let index = pendingSends.firstIndex(where: { $0.id == id }) else {
            return
        }
        let pending = pendingSends.remove(at: index)
        producerSuspensionNanoseconds &+= pending.suspendedAt.duration(to: .now).clampedNanoseconds
        pending.continuation.resume(throwing: CancellationError())
    }

    /// Cancellation of the sole receiver means the lossless drain no longer
    /// exists. Terminating the whole channel is required to wake any producer
    /// already suspended on frame capacity.
    private func cancelPendingReceive(id: UUID) {
        guard waitingReceiver?.id == id else { return }
        terminate(.consumerTaskCancelled)
    }

    private func terminate(_ value: Termination) {
        guard termination == nil else { return }
        termination = value
        queue.removeAll(keepingCapacity: false)
        queuedFrames = 0

        if let waitingReceiver {
            self.waitingReceiver = nil
            do {
                waitingReceiver.continuation.resume(returning: try terminalResult(value))
            } catch {
                waitingReceiver.continuation.resume(throwing: error)
            }
        }

        let sends = pendingSends
        pendingSends.removeAll(keepingCapacity: false)
        if case .cancelled = value {
            cancellationWakeupCount += sends.count
        } else if case .consumerTaskCancelled = value {
            cancellationWakeupCount += sends.count
        }
        for pending in sends {
            producerSuspensionNanoseconds &+= pending.suspendedAt.duration(to: .now).clampedNanoseconds
            do {
                _ = try terminalResult(value) as VocelloQwen3AudioChunkEvent?
                pending.continuation.resume(throwing: VocelloQwen3SessionError.audioChannelClosed)
            } catch {
                pending.continuation.resume(throwing: error)
            }
        }
    }

    private func throwIfTerminated() throws {
        guard let termination else { return }
        _ = try terminalResult(termination) as VocelloQwen3AudioChunkEvent?
        throw VocelloQwen3SessionError.audioChannelClosed
    }

    private func terminalResult(
        _ termination: Termination
    ) throws -> VocelloQwen3AudioChunkEvent? {
        switch termination {
        case .finished:
            return nil
        case .cancelled(let reason):
            throw VocelloQwen3SessionError.audioChannelCancelled(reason)
        case .consumerTaskCancelled:
            throw CancellationError()
        case .failed(let error):
            throw error.base
        }
    }
}

/// Replay-latest state is independent from audio consumption. Missing or slow
/// observers cannot block model execution.
public struct VocelloQwen3ReplayLatest<Value: Sendable>: Sendable {
    fileprivate let state: VocelloQwen3ReplayLatestState<Value>

    public func snapshot() async -> Value? {
        await state.snapshot()
    }

    public func updates() -> AsyncStream<Value> {
        let pair = AsyncStream.makeStream(
            of: Value.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        Task { await state.addSubscriber(pair.continuation) }
        return pair.stream
    }
}

fileprivate actor VocelloQwen3ReplayLatestState<Value: Sendable> {
    private var latest: Value?
    private var subscribers: [UUID: AsyncStream<Value>.Continuation] = [:]
    private var finished = false

    func publish(_ value: Value) {
        guard !finished else { return }
        latest = value
        for continuation in subscribers.values { continuation.yield(value) }
    }

    func snapshot() -> Value? { latest }

    func addSubscriber(_ continuation: AsyncStream<Value>.Continuation) {
        if finished {
            if let latest { continuation.yield(latest) }
            continuation.finish()
            return
        }
        let id = UUID()
        subscribers[id] = continuation
        if let latest { continuation.yield(latest) }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        let values = subscribers.values
        subscribers.removeAll(keepingCapacity: false)
        for continuation in values { continuation.finish() }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}

private actor VocelloQwen3AudioConsumerClaim {
    private var claimed = false

    func claim() throws {
        guard !claimed else {
            throw VocelloQwen3SessionError.audioConsumerAlreadyClaimed
        }
        claimed = true
    }

    func isClaimed() -> Bool { claimed }
}

/// Explicitly lossy, PCM-free diagnostics. The buffer is count-bounded and
/// reports how many older observations were evicted.
public struct VocelloQwen3DiagnosticBufferSnapshot: Sendable {
    public let events: [VocelloQwen3DiagnosticEvent]
    public let droppedEventCount: Int
}

public struct VocelloQwen3BoundedDiagnostics: Sendable {
    fileprivate let state: VocelloQwen3BoundedDiagnosticState

    public func snapshot() async -> VocelloQwen3DiagnosticBufferSnapshot {
        await state.snapshot()
    }
}

fileprivate actor VocelloQwen3BoundedDiagnosticState {
    private let capacity: Int
    private var events: [VocelloQwen3DiagnosticEvent] = []
    private var droppedEventCount = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func record(_ event: VocelloQwen3DiagnosticEvent) {
        if events.count == capacity {
            events.removeFirst()
            droppedEventCount += 1
        }
        events.append(event)
    }

    func snapshot() -> VocelloQwen3DiagnosticBufferSnapshot {
        VocelloQwen3DiagnosticBufferSnapshot(
            events: events,
            droppedEventCount: droppedEventCount
        )
    }
}

/// Cancellation ingress is deliberately independent of the engine actor. The
/// lock protects only the first reason and a task-cancellation closure; no MLX
/// state is touched while it is held.
public final class VocelloQwen3CancellationController: @unchecked Sendable {
    private struct State {
        var firstReason: VocelloQwen3CancellationReason?
        var cancelAction: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var reason: VocelloQwen3CancellationReason? {
        state.withLock { $0.firstReason }
    }

    public var isCancelled: Bool { reason != nil }

    public func installCancelAction(_ action: @escaping @Sendable () -> Void) {
        let shouldCancel = state.withLock { value -> Bool in
            value.cancelAction = action
            return value.firstReason != nil
        }
        if shouldCancel { action() }
    }

    @discardableResult
    public func request(_ reason: VocelloQwen3CancellationReason) -> Bool {
        let result = state.withLock { value -> (Bool, (@Sendable () -> Void)?) in
            guard value.firstReason == nil else { return (false, nil) }
            value.firstReason = reason
            return (true, value.cancelAction)
        }
        result.1?()
        return result.0
    }

    public func checkCancellation() throws {
        if let reason {
            throw VocelloQwen3SessionError.audioChannelCancelled(reason)
        }
        try Task.checkCancellation()
    }
}

/// Opaque proof carried from reservation through product finalization. Clients
/// can retain and return a token but cannot construct or alter one.
public struct VocelloQwen3ProductFinalizationToken: Hashable, Sendable {
    public let generationID: UUID
    fileprivate let leaseID: UUID
    fileprivate let nonce: UUID

    fileprivate init(generationID: UUID, leaseID: UUID) {
        self.generationID = generationID
        self.leaseID = leaseID
        nonce = UUID()
    }
}

public enum VocelloQwen3ProductFinalizationDisposition: Hashable, Sendable {
    case published
    case aborted(VocelloQwen3FailureCode)
}

public enum VocelloQwen3FinalizationAcknowledgeResult: Hashable, Sendable {
    case accepted
    case alreadyAcknowledged
}

actor VocelloQwen3ProductFinalizationBarrier {
    private let generationID: UUID
    private let leaseID: UUID
    private let token: VocelloQwen3ProductFinalizationToken
    private var disposition: VocelloQwen3ProductFinalizationDisposition?
    private var waiters: [CheckedContinuation<VocelloQwen3ProductFinalizationDisposition, Never>] = []

    init(generationID: UUID, leaseID: UUID) {
        self.generationID = generationID
        self.leaseID = leaseID
        token = VocelloQwen3ProductFinalizationToken(
            generationID: generationID,
            leaseID: leaseID
        )
    }

    nonisolated var acknowledgementToken: VocelloQwen3ProductFinalizationToken { token }

    func acknowledge(
        generationID: UUID,
        leaseID: UUID,
        token candidate: VocelloQwen3ProductFinalizationToken,
        disposition proposed: VocelloQwen3ProductFinalizationDisposition
    ) throws -> VocelloQwen3FinalizationAcknowledgeResult {
        guard generationID == self.generationID,
              leaseID == self.leaseID,
              candidate == token else {
            throw VocelloQwen3SessionError.invalidFinalizationIdentity
        }
        if let disposition {
            guard disposition == proposed else {
                throw VocelloQwen3SessionError.conflictingFinalizationAcknowledgement
            }
            return .alreadyAcknowledged
        }

        disposition = proposed
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume(returning: proposed) }
        return .accepted
    }

    func wait() async -> VocelloQwen3ProductFinalizationDisposition {
        if let disposition { return disposition }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func acceptedDisposition() -> VocelloQwen3ProductFinalizationDisposition? {
        disposition
    }
}

/// Classified session state used by the engine actor and product adapter. It
/// intentionally contains no combined audio-bearing event stream.
public final class VocelloQwen3ClassifiedGenerationSession: Sendable {
    public let generationID: UUID
    public let leaseID: UUID
    /// Replay-latest producer readiness. This becomes non-nil only after the
    /// Qwen producer reports completed request/input preparation.
    public let prepared: VocelloQwen3ReplayLatest<VocelloQwen3PreparedEvent>
    public let progress: VocelloQwen3ReplayLatest<VocelloQwen3ProgressEvent>
    public let diagnostics: VocelloQwen3BoundedDiagnostics
    public let cancellation: VocelloQwen3CancellationController
    public let finalizationToken: VocelloQwen3ProductFinalizationToken

    private let audioProducer: VocelloQwen3LosslessAudioProducer
    private let audioConsumer: VocelloQwen3LosslessAudioSequence
    private let audioConsumerClaim = VocelloQwen3AudioConsumerClaim()
    private let preparedState: VocelloQwen3ReplayLatestState<VocelloQwen3PreparedEvent>
    private let progressState: VocelloQwen3ReplayLatestState<VocelloQwen3ProgressEvent>
    private let diagnosticState: VocelloQwen3BoundedDiagnosticState
    private let terminalState = VocelloQwen3TerminalState()
    private let finalizationBarrier: VocelloQwen3ProductFinalizationBarrier

    init(
        generationID: UUID,
        leaseID: UUID,
        audioCapacityFrames: Int,
        diagnosticCapacity: Int
    ) {
        self.generationID = generationID
        self.leaseID = leaseID
        let audioChannel = VocelloQwen3LosslessAudioChannel.make(
            capacityFrames: audioCapacityFrames
        )
        audioProducer = audioChannel.producer
        audioConsumer = audioChannel.consumer

        let preparedState = VocelloQwen3ReplayLatestState<VocelloQwen3PreparedEvent>()
        self.preparedState = preparedState
        prepared = VocelloQwen3ReplayLatest(state: preparedState)

        let progressState = VocelloQwen3ReplayLatestState<VocelloQwen3ProgressEvent>()
        self.progressState = progressState
        progress = VocelloQwen3ReplayLatest(state: progressState)

        let diagnosticState = VocelloQwen3BoundedDiagnosticState(capacity: diagnosticCapacity)
        self.diagnosticState = diagnosticState
        diagnostics = VocelloQwen3BoundedDiagnostics(state: diagnosticState)

        cancellation = VocelloQwen3CancellationController()
        let barrier = VocelloQwen3ProductFinalizationBarrier(
            generationID: generationID,
            leaseID: leaseID
        )
        finalizationBarrier = barrier
        finalizationToken = barrier.acknowledgementToken
    }

    public func waitForModelTermination() async -> VocelloQwen3TerminalEvent {
        await terminalState.wait()
    }

    /// Claims the one mandatory audio drain. The engine refuses to open a
    /// reservation until this succeeds.
    public func claimAudioConsumer() async throws -> VocelloQwen3LosslessAudioSequence {
        try await audioConsumerClaim.claim()
        return audioConsumer
    }

    func hasClaimedAudioConsumer() async -> Bool {
        await audioConsumerClaim.isClaimed()
    }

    func acknowledgeProductFinalization(
        generationID: UUID,
        leaseID: UUID,
        token: VocelloQwen3ProductFinalizationToken,
        disposition: VocelloQwen3ProductFinalizationDisposition
    ) async throws -> VocelloQwen3FinalizationAcknowledgeResult {
        try await finalizationBarrier.acknowledge(
            generationID: generationID,
            leaseID: leaseID,
            token: token,
            disposition: disposition
        )
    }

    func acceptedProductFinalizationDisposition()
        async -> VocelloQwen3ProductFinalizationDisposition?
    {
        await finalizationBarrier.acceptedDisposition()
    }

    public func waitForProductFinalization() async -> VocelloQwen3ProductFinalizationDisposition {
        await finalizationBarrier.wait()
    }

    func publishPrepared(_ event: VocelloQwen3PreparedEvent) async {
        await preparedState.publish(event)
    }

    func publishProgress(_ event: VocelloQwen3ProgressEvent) async {
        await progressState.publish(event)
    }

    func publishAudio(_ event: VocelloQwen3AudioChunkEvent) async throws {
        try await audioProducer.send(event)
    }

    func recordDiagnostic(_ event: VocelloQwen3DiagnosticEvent) async {
        await diagnosticState.record(event)
    }

    func resolveModelTerminal(_ event: VocelloQwen3TerminalEvent) async {
        await audioProducer.finish()
        await preparedState.finish()
        await progressState.finish()
        await terminalState.resolve(event)
    }

    func failModelTerminal(
        _ event: VocelloQwen3TerminalEvent,
        error: any Error & Sendable
    ) async {
        await audioProducer.fail(error)
        await preparedState.finish()
        await progressState.finish()
        await terminalState.resolve(event)
    }

    func cancelModelTerminal(
        _ event: VocelloQwen3TerminalEvent,
        reason: VocelloQwen3CancellationReason
    ) async {
        cancellation.request(reason)
        let effectiveReason = cancellation.reason ?? reason
        await audioConsumer.cancel(reason: effectiveReason)
        await preparedState.finish()
        await progressState.finish()
        await terminalState.resolve(event)
    }
}

private extension Duration {
    var clampedNanoseconds: UInt64 {
        let seconds = max(0, components.seconds)
        let attoseconds = max(0, components.attoseconds)
        let secondsValue = UInt64(clamping: seconds)
        let subsecondValue = UInt64(clamping: attoseconds / 1_000_000_000)
        let (whole, overflow) = secondsValue.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return .max }
        let (total, additionOverflow) = whole.addingReportingOverflow(subsecondValue)
        return additionOverflow ? .max : total
    }
}
