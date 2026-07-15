import Foundation

/// Emitted once the runtime has accepted and prepared a generation request.
public struct VocelloQwen3PreparedEvent: Codable, Hashable, Sendable {
    public let generationID: UUID
    public let model: VocelloQwen3ModelIdentity
    public let mode: VocelloQwen3SynthesisMode
    public let elapsedMilliseconds: Int

    public init(
        generationID: UUID,
        model: VocelloQwen3ModelIdentity,
        mode: VocelloQwen3SynthesisMode,
        elapsedMilliseconds: Int
    ) {
        self.generationID = generationID
        self.model = model
        self.mode = mode
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

/// One ordered mono or interleaved audio payload produced by a generation.
public struct VocelloQwen3AudioChunkEvent: Codable, Hashable, Sendable {
    public let generationID: UUID
    public let sequence: Int
    public let samples: [Float]
    public let sampleRate: Int
    public let channelCount: Int

    public init(
        generationID: UUID,
        sequence: Int,
        samples: [Float],
        sampleRate: Int,
        channelCount: Int = 1
    ) {
        self.generationID = generationID
        self.sequence = sequence
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public var frameCount: Int {
        guard channelCount > 0 else { return 0 }
        return samples.count / channelCount
    }
}

/// Monotonic progress snapshot. Counts describe work already completed, not a
/// prediction of the model's final duration.
public struct VocelloQwen3ProgressEvent: Codable, Hashable, Sendable {
    public let generationID: UUID
    public let generatedTokenCount: Int
    public let emittedAudioFrameCount: Int
    public let elapsedMilliseconds: Int

    public init(
        generationID: UUID,
        generatedTokenCount: Int,
        emittedAudioFrameCount: Int,
        elapsedMilliseconds: Int
    ) {
        self.generationID = generationID
        self.generatedTokenCount = generatedTokenCount
        self.emittedAudioFrameCount = emittedAudioFrameCount
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

/// The single terminal event for a generation session.
public struct VocelloQwen3TerminalEvent: Codable, Hashable, Sendable {
    public let generationID: UUID
    public let outcome: VocelloQwen3TerminalOutcome
    public let generatedTokenCount: Int
    public let emittedAudioFrameCount: Int
    public let elapsedMilliseconds: Int

    public init(
        generationID: UUID,
        outcome: VocelloQwen3TerminalOutcome,
        generatedTokenCount: Int,
        emittedAudioFrameCount: Int,
        elapsedMilliseconds: Int
    ) {
        self.generationID = generationID
        self.outcome = outcome
        self.generatedTokenCount = generatedTokenCount
        self.emittedAudioFrameCount = emittedAudioFrameCount
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

/// Ordered public event vocabulary for a generation session.
public enum VocelloQwen3GenerationEvent: Codable, Hashable, Sendable {
    case prepared(VocelloQwen3PreparedEvent)
    case audioChunk(VocelloQwen3AudioChunkEvent)
    case progress(VocelloQwen3ProgressEvent)
    case terminal(VocelloQwen3TerminalEvent)
}

/// Stable first-party session boundary. The current Qwen3 generator remains
/// behind a compatibility adapter; adopting this protocol must not create a
/// second generation lifecycle.
///
/// Implementations yield ordered events, yield exactly one terminal event,
/// finish `events`, and return that same event from `waitForTermination()`.
public protocol VocelloQwen3GenerationSession: Sendable {
    var id: UUID { get }
    var events: AsyncStream<VocelloQwen3GenerationEvent> { get }

    func cancel(reason: VocelloQwen3CancellationReason) async
    func waitForTermination() async -> VocelloQwen3TerminalEvent
}

enum VocelloQwen3EventChannelOfferResult: Equatable, Sendable {
    case accepted
    case closed
    case overflow
}

actor VocelloQwen3EventChannel {
    private let capacity: Int
    private var queue: [VocelloQwen3GenerationEvent] = []
    private var waitingConsumer: CheckedContinuation<VocelloQwen3GenerationEvent?, Never>?
    private var finished = false
    private var terminalPublished = false

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    /// Offers one nonterminal event without suspending on consumer progress.
    /// The caller must terminate the generation when `.overflow` is returned;
    /// the rejected event is never silently substituted or reordered.
    func offer(_ event: VocelloQwen3GenerationEvent) -> VocelloQwen3EventChannelOfferResult {
        guard !finished, !terminalPublished else { return .closed }
        guard queue.count < capacity else { return .overflow }
        if let waitingConsumer {
            self.waitingConsumer = nil
            waitingConsumer.resume(returning: event)
        } else {
            queue.append(event)
        }
        return .accepted
    }

    /// Publishes the single terminal event in its reserved slot. The queue may
    /// temporarily contain `capacity + 1` values, but completion never waits
    /// for a consumer and the overall memory bound remains fixed.
    @discardableResult
    func publishTerminal(_ terminal: VocelloQwen3TerminalEvent) -> Bool {
        guard !finished, !terminalPublished else { return false }
        terminalPublished = true
        let event = VocelloQwen3GenerationEvent.terminal(terminal)
        if let waitingConsumer {
            self.waitingConsumer = nil
            waitingConsumer.resume(returning: event)
        } else {
            queue.append(event)
        }
        return true
    }

    /// Cancellation makes queued nonterminal work obsolete. Clearing it before
    /// publishing the terminal guarantees that no chunk follows acknowledgement.
    func replacePendingWithTerminal(_ terminal: VocelloQwen3TerminalEvent) {
        guard !finished, !terminalPublished else { return }
        terminalPublished = true
        queue.removeAll(keepingCapacity: true)
        let event = VocelloQwen3GenerationEvent.terminal(terminal)
        if let waitingConsumer {
            self.waitingConsumer = nil
            waitingConsumer.resume(returning: event)
        } else {
            queue.append(event)
        }
    }

    func next() async -> VocelloQwen3GenerationEvent? {
        if !queue.isEmpty {
            return queue.removeFirst()
        }
        guard !finished else { return nil }
        return await withCheckedContinuation { waitingConsumer = $0 }
    }

    func finish() {
        finished = true
        waitingConsumer?.resume(returning: nil)
        waitingConsumer = nil
    }
}

private struct VocelloQwen3EventBufferOverflow: Error, Sendable {}

actor VocelloQwen3TerminalState {
    private var terminal: VocelloQwen3TerminalEvent?
    private var waiters: [CheckedContinuation<VocelloQwen3TerminalEvent, Never>] = []
    private var cancellationReason: VocelloQwen3CancellationReason?

    func requestCancellation(_ reason: VocelloQwen3CancellationReason) {
        guard cancellationReason == nil else { return }
        cancellationReason = reason
    }

    func requestedCancellationReason() -> VocelloQwen3CancellationReason {
        cancellationReason ?? .user
    }

    func resolve(_ value: VocelloQwen3TerminalEvent) {
        guard terminal == nil else { return }
        terminal = value
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume(returning: value) }
    }

    func wait() async -> VocelloQwen3TerminalEvent {
        if let terminal { return terminal }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

/// Concrete production adapter over the opaque loaded Qwen model. Its event
/// channel is bounded and non-suspending: an undrained full buffer fails the
/// session explicitly instead of deadlocking generation. A reserved terminal
/// slot guarantees that completion never depends on consumer progress.
public final class VocelloQwen3ModelGenerationSession: VocelloQwen3GenerationSession, @unchecked Sendable {
    public let id: UUID
    public let events: AsyncStream<VocelloQwen3GenerationEvent>

    private let channel: VocelloQwen3EventChannel
    private let terminalState = VocelloQwen3TerminalState()
    private let task: Task<Void, Never>

    init(
        model: VocelloQwen3LoadedModel,
        request: VocelloQwen3SynthesisRequest,
        clonePrompt: VocelloQwen3ClonePrompt?,
        streamingInterval: Double,
        enableChunkTimings: Bool,
        eventCapacity: Int
    ) throws {
        let request = try request.validated(for: model.capabilities)
        id = request.generationID
        channel = VocelloQwen3EventChannel(capacity: eventCapacity)
        let channel = self.channel
        events = AsyncStream(
            unfolding: { await channel.next() },
            onCancel: { Task { await channel.finish() } }
        )
        let terminalState = self.terminalState
        task = Task {
            let startedAt = ContinuousClock.now
            var tokenCount = 0
            var frameCount = 0
            do {
                try VocelloQwen3Runtime.apply(memoryConfiguration: request.memory)
                try await Self.offer(.prepared(VocelloQwen3PreparedEvent(
                    generationID: request.generationID,
                    model: model.identity,
                    mode: request.mode,
                    elapsedMilliseconds: startedAt.elapsedMilliseconds
                )), to: channel)

                let stream = try Self.stream(
                    model: model,
                    request: request,
                    clonePrompt: clonePrompt,
                    streamingInterval: streamingInterval,
                    enableChunkTimings: enableChunkTimings
                )
                var sequence = 0
                for try await signal in stream {
                    try Task.checkCancellation()
                    switch signal {
                    case .token:
                        tokenCount += 1
                    case .info(let info):
                        tokenCount = max(tokenCount, info.generationTokenCount)
                    case .chunkTimings:
                        continue
                    case .audio(let samples):
                        frameCount += samples.count
                        try await Self.offer(.audioChunk(VocelloQwen3AudioChunkEvent(
                            generationID: request.generationID,
                            sequence: sequence,
                            samples: samples,
                            sampleRate: model.sampleRate
                        )), to: channel)
                        sequence += 1
                    }
                    try await Self.offer(.progress(VocelloQwen3ProgressEvent(
                        generationID: request.generationID,
                        generatedTokenCount: tokenCount,
                        emittedAudioFrameCount: frameCount,
                        elapsedMilliseconds: startedAt.elapsedMilliseconds
                    )), to: channel)
                }
                try Task.checkCancellation()
                let terminal = VocelloQwen3TerminalEvent(
                    generationID: request.generationID,
                    outcome: .completed(model.streamFinishReason(
                        maximumTokens: request.sampling.maxNewTokens,
                        observedTokens: tokenCount
                    )),
                    generatedTokenCount: tokenCount,
                    emittedAudioFrameCount: frameCount,
                    elapsedMilliseconds: startedAt.elapsedMilliseconds
                )
                await channel.publishTerminal(terminal)
                await terminalState.resolve(terminal)
            } catch is CancellationError {
                let reason = await terminalState.requestedCancellationReason()
                let terminal = VocelloQwen3TerminalEvent(
                    generationID: request.generationID,
                    outcome: .cancelled(reason),
                    generatedTokenCount: tokenCount,
                    emittedAudioFrameCount: frameCount,
                    elapsedMilliseconds: startedAt.elapsedMilliseconds
                )
                await channel.replacePendingWithTerminal(terminal)
                await terminalState.resolve(terminal)
            } catch is VocelloQwen3EventBufferOverflow {
                let terminal = VocelloQwen3TerminalEvent(
                    generationID: request.generationID,
                    outcome: .failed(.runtime),
                    generatedTokenCount: tokenCount,
                    emittedAudioFrameCount: frameCount,
                    elapsedMilliseconds: startedAt.elapsedMilliseconds
                )
                await channel.publishTerminal(terminal)
                await terminalState.resolve(terminal)
            } catch {
                let terminal = VocelloQwen3TerminalEvent(
                    generationID: request.generationID,
                    outcome: .failed(.runtime),
                    generatedTokenCount: tokenCount,
                    emittedAudioFrameCount: frameCount,
                    elapsedMilliseconds: startedAt.elapsedMilliseconds
                )
                await channel.publishTerminal(terminal)
                await terminalState.resolve(terminal)
            }
            await channel.finish()
        }
    }

    public func cancel(reason: VocelloQwen3CancellationReason) async {
        await terminalState.requestCancellation(reason)
        task.cancel()
        _ = await terminalState.wait()
    }

    public func waitForTermination() async -> VocelloQwen3TerminalEvent {
        await terminalState.wait()
    }

    private static func offer(
        _ event: VocelloQwen3GenerationEvent,
        to channel: VocelloQwen3EventChannel
    ) async throws {
        switch await channel.offer(event) {
        case .accepted:
            return
        case .closed:
            throw CancellationError()
        case .overflow:
            throw VocelloQwen3EventBufferOverflow()
        }
    }

    private static func stream(
        model: VocelloQwen3LoadedModel,
        request: VocelloQwen3SynthesisRequest,
        clonePrompt: VocelloQwen3ClonePrompt?,
        streamingInterval: Double,
        enableChunkTimings: Bool
    ) throws -> AsyncThrowingStream<VocelloQwen3GenerationSignal, Error> {
        switch request.input {
        case .customVoice(let speakerID, let instruction):
            return try model.customVoiceStream(
                text: request.text,
                language: request.language,
                speaker: speakerID,
                instruction: instruction,
                sampling: request.sampling,
                streamingInterval: streamingInterval,
                enableChunkTimings: enableChunkTimings
            )
        case .voiceDesign(let description):
            return try model.voiceDesignStream(
                text: request.text,
                language: request.language,
                description: description,
                sampling: request.sampling,
                streamingInterval: streamingInterval,
                enableChunkTimings: enableChunkTimings
            )
        case .voiceClone:
            guard let clonePrompt else { throw VocelloQwen3ContractError.missingClonePrompt }
            return try model.voiceCloneStream(
                text: request.text,
                language: request.language,
                prompt: clonePrompt,
                sampling: request.sampling,
                streamingInterval: streamingInterval,
                enableChunkTimings: enableChunkTimings
            )
        }
    }
}

public extension VocelloQwen3LoadedModel {
    func startGenerationSession(
        request: VocelloQwen3SynthesisRequest,
        clonePrompt: VocelloQwen3ClonePrompt? = nil,
        streamingInterval: Double = 0.5,
        enableChunkTimings: Bool = false,
        eventCapacity: Int = 256
    ) throws -> any VocelloQwen3GenerationSession {
        try VocelloQwen3ModelGenerationSession(
            model: self,
            request: request,
            clonePrompt: clonePrompt,
            streamingInterval: streamingInterval,
            enableChunkTimings: enableChunkTimings,
            eventCapacity: eventCapacity
        )
    }
}

private extension ContinuousClock.Instant {
    var elapsedMilliseconds: Int {
        let duration = duration(to: .now)
        return max(0, Int((Double(duration.components.seconds) * 1_000)
            + (Double(duration.components.attoseconds) / 1e15)))
    }
}
