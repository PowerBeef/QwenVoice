@testable import VocelloQwen3Core
import HuggingFace
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioTTS
@preconcurrency import MLXLMCommon
import XCTest

final class VocelloQwen3FacadeTests: XCTestCase {
    func testGenerationSessionPublishesOrderedTypedEventsAndSameTerminalResult() async {
        let generationID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
        let model = VocelloQwen3ModelIdentity(
            modelID: "custom-speed",
            repositoryID: "Qwen/Qwen3-TTS",
            revision: "fixture-revision",
            artifactVersion: "fixture-v1"
        )
        let session = FacadeTestGenerationSession(id: generationID)
        let prepared = VocelloQwen3PreparedEvent(
            generationID: generationID,
            model: model,
            mode: .customVoice,
            elapsedMilliseconds: 20
        )
        let progress = VocelloQwen3ProgressEvent(
            generationID: generationID,
            generatedTokenCount: 4,
            emittedAudioFrameCount: 0,
            elapsedMilliseconds: 25
        )
        let chunk = VocelloQwen3AudioChunkEvent(
            generationID: generationID,
            sequence: 0,
            samples: [0.1, -0.1, 0.2, -0.2],
            sampleRate: 24_000
        )
        let terminal = VocelloQwen3TerminalEvent(
            generationID: generationID,
            outcome: .completed(.endOfSequence),
            generatedTokenCount: 8,
            emittedAudioFrameCount: 4,
            elapsedMilliseconds: 40
        )

        await session.emit(.prepared(prepared))
        await session.emit(.progress(progress))
        await session.emit(.audioChunk(chunk))
        await session.terminate(with: terminal)

        var observed: [VocelloQwen3GenerationEvent] = []
        for await event in session.events {
            observed.append(event)
        }
        let waitedTerminal = await session.waitForTermination()

        XCTAssertEqual(session.id, generationID)
        XCTAssertEqual(
            observed,
            [.prepared(prepared), .progress(progress), .audioChunk(chunk), .terminal(terminal)]
        )
        XCTAssertEqual(chunk.frameCount, 4)
        XCTAssertEqual(waitedTerminal, terminal)
    }

    func testGenerationSessionCancellationUsesTypedTerminalOutcome() async {
        let generationID = UUID(uuidString: "00000000-0000-0000-0000-000000000008")!
        let session = FacadeTestGenerationSession(id: generationID)
        let waiter = Task { await session.waitForTermination() }

        await session.cancel(reason: .shutdown)
        let terminal = await waiter.value

        XCTAssertEqual(terminal.generationID, generationID)
        XCTAssertEqual(terminal.outcome, .cancelled(.shutdown))
    }

    func testCapabilityInventoryIsUniqueAndDeterministic() {
        let capabilities = VocelloQwen3CapabilitySet([
            .voiceClone, .streaming, .voiceClone, .audioOnlyClone,
        ])

        XCTAssertEqual(capabilities.values, [.audioOnlyClone, .streaming, .voiceClone])
        XCTAssertTrue(capabilities.supports(.voiceClone))
        XCTAssertFalse(capabilities.supports(.voiceDesign))
    }

    func testSynthesisRequestValidationPreservesTypedMode() throws {
        let request = VocelloQwen3SynthesisRequest(
            generationID: UUID(),
            text: "A deterministic facade request.",
            language: "en-US",
            input: .voiceClone(referenceID: "fixture-clone"),
            sampling: VocelloQwen3SamplingConfiguration(
                maxNewTokens: 256,
                temperature: 0.9,
                topP: 0.95,
                topK: 50,
                repetitionPenalty: 1.05
            ),
            memory: VocelloQwen3MemoryConfiguration(
                clearCacheOnStreamChunk: true,
                tokenMemoryClearCadence: 24,
                talkerKVGeneratedWindow: 384
            )
        )

        let validated = try request.validated(
            for: VocelloQwen3CapabilitySet([.streaming, .voiceClone, .audioOnlyClone])
        )
        XCTAssertEqual(validated.mode, .voiceClone)
    }

    func testUnsupportedModeFailsClosed() {
        let request = VocelloQwen3SynthesisRequest(
            generationID: UUID(),
            text: "Design a voice.",
            language: "en-US",
            input: .voiceDesign(description: "Calm and resonant"),
            sampling: VocelloQwen3SamplingConfiguration(
                maxNewTokens: 64,
                temperature: 0.8,
                topP: 0.9,
                topK: 50,
                repetitionPenalty: 1
            ),
            memory: VocelloQwen3MemoryConfiguration(
                clearCacheOnStreamChunk: true,
                tokenMemoryClearCadence: 16
            )
        )

        XCTAssertThrowsError(
            try request.validated(for: VocelloQwen3CapabilitySet([.customVoice]))
        ) { error in
            XCTAssertEqual(error as? VocelloQwen3ContractError, .unsupportedMode(.voiceDesign))
        }
    }

    func testTerminalOutcomesRoundTripWithoutStringInference() throws {
        let values: [VocelloQwen3TerminalOutcome] = [
            .completed(.endOfSequence),
            .cancelled(.memoryPressure),
            .failed(.incompatibleModel),
        ]
        let data = try JSONEncoder().encode(values)
        XCTAssertEqual(try JSONDecoder().decode([VocelloQwen3TerminalOutcome].self, from: data), values)
    }

    func testTypedDiagnosticAdapterDropsArbitraryCompatibilityDetails() {
        let event = VocelloQwen3Runtime.typedDiagnosticEvent(
            forCompatibilityAction: "tts-load-after-qwen-from-prepared-directory"
        )
        XCTAssertEqual(event.phase, .modelLoad)
        XCTAssertEqual(event.disposition, .completed)
        XCTAssertNil(event.failureCode)
    }

    func testOwnedCachePolicyPreservesDefaultAndFixedDirectoryBehavior() {
        XCTAssertEqual(
            VocelloQwen3CachePolicy.systemDefault.compatibilityValue.cacheDirectory,
            HubCache.default.cacheDirectory
        )
        let fixed = URL(fileURLWithPath: "/tmp/vocello-qwen3-cache-fixture", isDirectory: true)
        XCTAssertEqual(
            VocelloQwen3CachePolicy.directory(fixed).compatibilityValue.cacheDirectory,
            fixed
        )
    }

    func testCompatibilityAdapterConsumesSupportedSamplingAndRejectsUncarriedFields() async throws {
        let compatibilityModel = FacadeCompatibilityModel()
        let loaded = try makeLoadedFixture(compatibilityModel: compatibilityModel)
        let sampling = VocelloQwen3SamplingConfiguration(
            maxNewTokens: 321,
            temperature: 0.73,
            topP: 0.87,
            topK: VocelloQwen3SamplingConfiguration.compatibilityDefaultTopK,
            repetitionPenalty: 1.17
        )
        let stream = try loaded.customVoiceStream(
            text: "Capture every supported sampling field.",
            language: "en-US",
            speaker: "fixture-speaker",
            instruction: nil,
            sampling: sampling,
            streamingInterval: 0.5,
            enableChunkTimings: false
        )
        for try await _ in stream {}

        let captured = try XCTUnwrap(compatibilityModel.capturedGenerationParameters)
        XCTAssertEqual(captured.maxTokens, sampling.maxNewTokens)
        XCTAssertEqual(captured.temperature, sampling.temperature, accuracy: 0.0001)
        XCTAssertEqual(captured.topP, sampling.topP, accuracy: 0.0001)
        XCTAssertEqual(captured.repetitionPenalty, sampling.repetitionPenalty)
        XCTAssertEqual(sampling.topK, VocelloQwen3SamplingConfiguration.compatibilityDefaultTopK)
        XCTAssertNil(sampling.seed)

        XCTAssertThrowsError(try loaded.customVoiceStream(
            text: "Unsupported top K.",
            language: "en-US",
            speaker: "fixture-speaker",
            instruction: nil,
            sampling: VocelloQwen3SamplingConfiguration(
                maxNewTokens: 32,
                temperature: 0.8,
                topP: 0.9,
                topK: 49,
                repetitionPenalty: 1
            ),
            streamingInterval: 0.5,
            enableChunkTimings: false
        )) { error in
            XCTAssertEqual(error as? VocelloQwen3ContractError, .unsupportedRequestTopK(49))
        }

        XCTAssertThrowsError(try loaded.customVoiceStream(
            text: "Unsupported seed.",
            language: "en-US",
            speaker: "fixture-speaker",
            instruction: nil,
            sampling: VocelloQwen3SamplingConfiguration(
                maxNewTokens: 32,
                temperature: 0.8,
                topP: 0.9,
                topK: VocelloQwen3SamplingConfiguration.compatibilityDefaultTopK,
                repetitionPenalty: 1,
                seed: 7
            ),
            streamingInterval: 0.5,
            enableChunkTimings: false
        )) { error in
            XCTAssertEqual(error as? VocelloQwen3ContractError, .unsupportedRequestSeed)
        }
    }

    func testConcreteSessionMapsRuntimeTokenCapToMaximumTokens() async throws {
        let loaded = try makeLoadedFixture(
            compatibilityModel: FacadeCompatibilityModel(generationEndReason: "token_cap")
        )
        let session = try loaded.startGenerationSession(
            request: makeCustomRequest(generationID: UUID()),
            eventCapacity: 4
        )
        for await _ in session.events {}
        let terminal = await session.waitForTermination()
        XCTAssertEqual(terminal.outcome, .completed(.maximumTokens))
    }

    func testTerminalStatePreservesFirstCancellationReason() async {
        let state = VocelloQwen3TerminalState()
        await state.requestCancellation(.memoryPressure)
        await state.requestCancellation(.shutdown)
        let reason = await state.requestedCancellationReason()
        XCTAssertEqual(reason, .memoryPressure)
    }

    func testConcreteCompatibilityAdapterProducesTypedSessionEvents() async throws {
        let identity = VocelloQwen3ModelIdentity(
            modelID: "fixture-custom",
            repositoryID: "fixture/repository",
            revision: "fixture-revision",
            artifactVersion: "fixture-v1"
        )
        let loaded = try VocelloQwen3LoadedModel(
            compatibilityModel: FacadeCompatibilityModel(),
            identity: identity,
            capabilities: VocelloQwen3CapabilitySet([.streaming, .customVoice])
        )
        let generationID = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
        let session = try loaded.startGenerationSession(
            request: VocelloQwen3SynthesisRequest(
                generationID: generationID,
                text: "Facade adapter fixture.",
                language: "en-US",
                input: .customVoice(speakerID: "fixture-speaker", deliveryInstruction: nil),
                sampling: VocelloQwen3SamplingConfiguration(
                    maxNewTokens: 32,
                    temperature: 0.8,
                    topP: 0.9,
                    topK: VocelloQwen3SamplingConfiguration.compatibilityDefaultTopK,
                    repetitionPenalty: 1
                ),
                memory: VocelloQwen3MemoryConfiguration(
                    clearCacheOnStreamChunk: false,
                    tokenMemoryClearCadence: 16
                )
            ),
            eventCapacity: 4
        )

        var events: [VocelloQwen3GenerationEvent] = []
        for await event in session.events { events.append(event) }
        let terminal = await session.waitForTermination()

        XCTAssertEqual(session.id, generationID)
        XCTAssertEqual(terminal.outcome, .completed(.endOfSequence))
        XCTAssertTrue(events.contains { if case .prepared = $0 { true } else { false } })
        XCTAssertTrue(events.contains {
            if case .progress(let progress) = $0 { return progress.generatedTokenCount == 1 }
            return false
        })
        XCTAssertEqual(events.last, .terminal(terminal))
    }

    func testEventChannelReportsOverflowAndKeepsReservedTerminalSlot() async {
        let generationID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let channel = VocelloQwen3EventChannel(capacity: 1)
        let prepared = VocelloQwen3PreparedEvent(
            generationID: generationID,
            model: VocelloQwen3ModelIdentity(
                modelID: "fixture-custom",
                repositoryID: "fixture/repository",
                revision: "fixture-revision",
                artifactVersion: "fixture-v1"
            ),
            mode: .customVoice,
            elapsedMilliseconds: 1
        )
        let progress = VocelloQwen3ProgressEvent(
            generationID: generationID,
            generatedTokenCount: 1,
            emittedAudioFrameCount: 0,
            elapsedMilliseconds: 2
        )
        let terminal = VocelloQwen3TerminalEvent(
            generationID: generationID,
            outcome: .failed(.runtime),
            generatedTokenCount: 1,
            emittedAudioFrameCount: 0,
            elapsedMilliseconds: 3
        )

        let accepted = await channel.offer(.prepared(prepared))
        let overflow = await channel.offer(.progress(progress))
        let terminalPublished = await channel.publishTerminal(terminal)
        await channel.finish()

        XCTAssertEqual(accepted, .accepted)
        XCTAssertEqual(overflow, .overflow)
        XCTAssertTrue(terminalPublished)
        let first = await channel.next()
        let second = await channel.next()
        let end = await channel.next()
        XCTAssertEqual(first, .prepared(prepared))
        XCTAssertEqual(second, .terminal(terminal))
        XCTAssertNil(end)
    }

    func testConcreteSessionOverflowTerminatesWithoutConsumerDrain() async throws {
        let loaded = try VocelloQwen3LoadedModel(
            compatibilityModel: FacadeCompatibilityModel(eventCount: 128),
            identity: VocelloQwen3ModelIdentity(
                modelID: "fixture-custom",
                repositoryID: "fixture/repository",
                revision: "fixture-revision",
                artifactVersion: "fixture-v1"
            ),
            capabilities: VocelloQwen3CapabilitySet([.streaming, .customVoice])
        )
        let session = try loaded.startGenerationSession(
            request: VocelloQwen3SynthesisRequest(
                generationID: UUID(),
                text: "Undrained bounded-buffer fixture.",
                language: "en-US",
                input: .customVoice(speakerID: "fixture-speaker", deliveryInstruction: nil),
                sampling: VocelloQwen3SamplingConfiguration(
                    maxNewTokens: 128,
                    temperature: 0.8,
                    topP: 0.9,
                    topK: VocelloQwen3SamplingConfiguration.compatibilityDefaultTopK,
                    repetitionPenalty: 1
                ),
                memory: VocelloQwen3MemoryConfiguration(
                    clearCacheOnStreamChunk: false,
                    tokenMemoryClearCadence: 16
                )
            ),
            eventCapacity: 1
        )

        let completed = expectation(description: "terminal completion without an event consumer")
        let terminalTask = Task {
            let terminal = await session.waitForTermination()
            completed.fulfill()
            return terminal
        }
        await fulfillment(of: [completed], timeout: 1)
        let terminal = await terminalTask.value
        XCTAssertEqual(terminal.outcome, .failed(.runtime))

        var observed: [VocelloQwen3GenerationEvent] = []
        for await event in session.events { observed.append(event) }
        XCTAssertEqual(observed.count, 2)
        XCTAssertTrue(observed.first.map { if case .prepared = $0 { true } else { false } } ?? false)
        XCTAssertEqual(observed.last, .terminal(terminal))
    }

    func testConcreteSessionCancellationPublishesTerminalWithoutConsumerDrain() async throws {
        let pending = AsyncThrowingStream<AudioGeneration, Error>.makeStream()
        defer { pending.continuation.finish() }
        let loaded = try makeLoadedFixture(
            compatibilityModel: FacadeCompatibilityModel(streamOverride: pending.stream)
        )
        let session = try loaded.startGenerationSession(
            request: makeCustomRequest(generationID: UUID()),
            eventCapacity: 1
        )

        await session.cancel(reason: .shutdown)
        let terminal = await session.waitForTermination()
        XCTAssertEqual(terminal.outcome, .cancelled(.shutdown))

        var observed: [VocelloQwen3GenerationEvent] = []
        for await event in session.events { observed.append(event) }
        XCTAssertEqual(observed, [.terminal(terminal)])
    }

    private func makeLoadedFixture(
        compatibilityModel: FacadeCompatibilityModel
    ) throws -> VocelloQwen3LoadedModel {
        try VocelloQwen3LoadedModel(
            compatibilityModel: compatibilityModel,
            identity: VocelloQwen3ModelIdentity(
                modelID: "fixture-custom",
                repositoryID: "fixture/repository",
                revision: "fixture-revision",
                artifactVersion: "fixture-v1"
            ),
            capabilities: VocelloQwen3CapabilitySet([.streaming, .customVoice])
        )
    }

    private func makeCustomRequest(generationID: UUID) -> VocelloQwen3SynthesisRequest {
        VocelloQwen3SynthesisRequest(
            generationID: generationID,
            text: "Facade terminal fixture.",
            language: "en-US",
            input: .customVoice(speakerID: "fixture-speaker", deliveryInstruction: nil),
            sampling: VocelloQwen3SamplingConfiguration(
                maxNewTokens: 32,
                temperature: 0.8,
                topP: 0.9,
                topK: VocelloQwen3SamplingConfiguration.compatibilityDefaultTopK,
                repetitionPenalty: 1
            ),
            memory: VocelloQwen3MemoryConfiguration(
                clearCacheOnStreamChunk: false,
                tokenMemoryClearCadence: 16
            )
        )
    }
}

private enum FacadeCompatibilityFixtureError: Error {
    case unsupported
}

private final class FacadeCompatibilityModel: SpeechGenerationModel, Qwen3OptimizedSpeechGenerationModel, SpeechGenerationModelDiagnosticsProvider, @unchecked Sendable {
    let sampleRate = 24_000
    let defaultGenerationParameters = GenerateParameters()
    private let eventCount: Int
    private let generationEndReason: String
    private let streamOverride: AsyncThrowingStream<AudioGeneration, Error>?
    private let captureLock = NSLock()
    private var _capturedGenerationParameters: GenerateParameters?

    init(
        eventCount: Int = 1,
        generationEndReason: String = "eos",
        streamOverride: AsyncThrowingStream<AudioGeneration, Error>? = nil
    ) {
        self.eventCount = eventCount
        self.generationEndReason = generationEndReason
        self.streamOverride = streamOverride
    }

    var capturedGenerationParameters: GenerateParameters? {
        captureLock.lock()
        defer { captureLock.unlock() }
        return _capturedGenerationParameters
    }

    let loadTimingsMS: [String: Int] = [:]
    let loadBooleanFlags: [String: Bool] = [:]
    let latestPreparationTimingsMS: [String: Int] = [:]
    let latestPreparationBooleanFlags: [String: Bool] = [:]
    var latestPreparationStringFlags: [String: String] {
        ["generation_end_reason": generationEndReason]
    }
    func resetPreparationDiagnostics() {}

    func prepareForGeneration(
        text _: String,
        voice _: String?,
        refAudio _: MLXArray?,
        refText _: String?,
        language _: String?,
        generationParameters _: GenerateParameters
    ) async throws {}

    func generate(
        text _: String,
        voice _: String?,
        refAudio _: MLXArray?,
        refText _: String?,
        language _: String?,
        generationParameters _: GenerateParameters
    ) async throws -> MLXArray { MLXArray([Float(0)]) }

    func generateStream(
        text _: String,
        voice _: String?,
        refAudio _: MLXArray?,
        refText _: String?,
        language _: String?,
        generationParameters _: GenerateParameters
    ) -> AsyncThrowingStream<AudioGeneration, Error> { fixtureStream() }

    func generateStream(
        text _: String,
        voice _: String?,
        refAudio _: MLXArray?,
        refText _: String?,
        language _: String?,
        generationParameters: GenerateParameters,
        streamingInterval _: Double
    ) -> AsyncThrowingStream<AudioGeneration, Error> {
        capture(generationParameters)
        return fixtureStream()
    }

    func prepareCustomVoice(
        text _: String,
        language _: String,
        speaker _: String,
        instruct _: String?,
        generationParameters _: GenerateParameters
    ) async throws {}

    func generateCustomVoiceStream(
        text _: String,
        language _: String,
        speaker _: String,
        instruct _: String?,
        generationParameters: GenerateParameters,
        streamingInterval _: Double,
        customVoiceProfile _: String?,
        streamStepEvalPolicy _: String?,
        generationSpeedProfile _: String?,
        memoryClearCadence _: Int?,
        enableChunkTimings _: Bool
    ) -> AsyncThrowingStream<AudioGeneration, Error> {
        capture(generationParameters)
        return fixtureStream()
    }

    func generateCustomVoice(
        text _: String,
        language _: String,
        speaker _: String,
        instruct _: String?,
        generationParameters _: GenerateParameters
    ) async throws -> AudioGenerationCompletion {
        AudioGenerationCompletion(audio: MLXArray([Float(0)]), info: nil, finishReason: .eos)
    }

    func prepareVoiceDesign(
        text _: String,
        language _: String,
        voiceDescription _: String,
        generationParameters _: GenerateParameters
    ) async throws { throw FacadeCompatibilityFixtureError.unsupported }

    func generateVoiceDesignStream(
        text _: String,
        language _: String,
        voiceDescription _: String,
        generationParameters _: GenerateParameters,
        streamingInterval _: Double,
        streamStepEvalPolicy _: String?,
        generationSpeedProfile _: String?,
        memoryClearCadence _: Int?,
        enableChunkTimings _: Bool
    ) -> AsyncThrowingStream<AudioGeneration, Error> { failingFixtureStream() }

    func generateVoiceDesign(
        text _: String,
        language _: String,
        voiceDescription _: String,
        generationParameters _: GenerateParameters
    ) async throws -> AudioGenerationCompletion { throw FacadeCompatibilityFixtureError.unsupported }

    func createVoiceClonePrompt(
        refAudio _: MLXArray,
        refText _: String?,
        xVectorOnlyMode _: Bool
    ) throws -> Qwen3TTSVoiceClonePrompt { throw FacadeCompatibilityFixtureError.unsupported }

    func prepareVoiceClone(
        text _: String,
        language _: String,
        voiceClonePrompt _: Qwen3TTSVoiceClonePrompt,
        generationParameters _: GenerateParameters
    ) async throws { throw FacadeCompatibilityFixtureError.unsupported }

    func generateVoiceCloneStream(
        text _: String,
        language _: String,
        voiceClonePrompt _: Qwen3TTSVoiceClonePrompt,
        generationParameters _: GenerateParameters,
        streamingInterval _: Double,
        streamStepEvalPolicy _: String?,
        generationSpeedProfile _: String?,
        memoryClearCadence _: Int?,
        enableChunkTimings _: Bool
    ) -> AsyncThrowingStream<AudioGeneration, Error> { failingFixtureStream() }

    func generateVoiceClone(
        text _: String,
        language _: String,
        voiceClonePrompt _: Qwen3TTSVoiceClonePrompt,
        generationParameters _: GenerateParameters
    ) async throws -> AudioGenerationCompletion { throw FacadeCompatibilityFixtureError.unsupported }

    private func fixtureStream() -> AsyncThrowingStream<AudioGeneration, Error> {
        if let streamOverride { return streamOverride }
        return AsyncThrowingStream { continuation in
            for token in 1 ... eventCount { continuation.yield(.token(token)) }
            continuation.finish()
        }
    }

    private func failingFixtureStream() -> AsyncThrowingStream<AudioGeneration, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: FacadeCompatibilityFixtureError.unsupported)
        }
    }


    private func capture(_ generationParameters: GenerateParameters) {
        captureLock.lock()
        _capturedGenerationParameters = generationParameters
        captureLock.unlock()
    }
}

private actor FacadeTestGenerationSession: VocelloQwen3GenerationSession {
    nonisolated let id: UUID
    nonisolated let events: AsyncStream<VocelloQwen3GenerationEvent>

    private let continuation: AsyncStream<VocelloQwen3GenerationEvent>.Continuation
    private var terminal: VocelloQwen3TerminalEvent?
    private var waiters: [CheckedContinuation<VocelloQwen3TerminalEvent, Never>] = []

    init(id: UUID) {
        self.id = id
        let stream = AsyncStream.makeStream(of: VocelloQwen3GenerationEvent.self)
        events = stream.stream
        continuation = stream.continuation
    }

    func emit(_ event: VocelloQwen3GenerationEvent) {
        guard terminal == nil else { return }
        continuation.yield(event)
    }

    func terminate(with event: VocelloQwen3TerminalEvent) {
        guard terminal == nil else { return }
        terminal = event
        continuation.yield(.terminal(event))
        continuation.finish()

        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume(returning: event)
        }
    }

    func cancel(reason: VocelloQwen3CancellationReason) {
        terminate(
            with: VocelloQwen3TerminalEvent(
                generationID: id,
                outcome: .cancelled(reason),
                generatedTokenCount: 0,
                emittedAudioFrameCount: 0,
                elapsedMilliseconds: 0
            )
        )
    }

    func waitForTermination() async -> VocelloQwen3TerminalEvent {
        if let terminal { return terminal }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
