@_spi(VocelloQwen3LegacyCompatibility) @testable import VocelloQwen3Core
import HuggingFace
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioTTS
@preconcurrency import MLXLMCommon
import XCTest

final class VocelloQwen3FacadeTests: XCTestCase {
    func testActorRequestCarriesExactCurrentChunkSchedulesAndLegacyDecodeDefaults() throws {
        let cases: [(VocelloQwen3SynthesisInput, Int, Int)] = [
            (.customVoice(speakerID: "fixture", deliveryInstruction: nil), 7, 7),
            (.voiceDesign(description: "fixture"), 7, 14),
            (.voiceClone(referenceID: "fixture"), 7, 14),
        ]
        for (input, expectedFirst, expectedLater) in cases {
            let request = VocelloQwen3SynthesisRequest(
                generationID: UUID(),
                text: "Chunk schedule fixture.",
                language: "en-US",
                input: input,
                sampling: VocelloQwen3SamplingConfiguration(
                    maxNewTokens: 32,
                    temperature: 0.8,
                    topP: 0.9,
                    topK: 50,
                    repetitionPenalty: 1,
                    seed: 1
                ),
                memory: .compatibilityDefault
            )
            XCTAssertEqual(request.chunking.firstCodecFrames, expectedFirst)
            XCTAssertEqual(request.chunking.laterCodecFrames, expectedLater)

            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
                    as? [String: Any]
            )
            object.removeValue(forKey: "chunking")
            let legacyData = try JSONSerialization.data(withJSONObject: object)
            let decoded = try JSONDecoder().decode(
                VocelloQwen3SynthesisRequest.self,
                from: legacyData
            )
            XCTAssertEqual(decoded.chunking, request.chunking)
        }
    }

    func testCompatibilityProducerRejectsChunkControlsItDoesNotImplement() {
        let capabilities = VocelloQwen3CapabilitySet([.streaming, .customVoice])
        let unsupported: [VocelloQwen3StreamChunkConfiguration] = [
            VocelloQwen3StreamChunkConfiguration(
                firstCodecFrames: 7,
                laterCodecFrames: 7,
                pendingFrameLimit: 14
            ),
            VocelloQwen3StreamChunkConfiguration(
                firstCodecFrames: 7,
                laterCodecFrames: 7,
                pendingFrameLimit: 7,
                materializationLeadSteps: 1
            ),
            VocelloQwen3StreamChunkConfiguration(
                firstCodecFrames: 7,
                laterCodecFrames: 7,
                pendingFrameLimit: 7,
                evaluationPolicy: .deferred
            ),
        ]

        for chunking in unsupported {
            let request = VocelloQwen3SynthesisRequest(
                generationID: UUID(),
                text: "Unsupported chunk control fixture.",
                language: "en-US",
                input: .customVoice(speakerID: "fixture", deliveryInstruction: nil),
                sampling: VocelloQwen3SamplingConfiguration(
                    maxNewTokens: 32,
                    temperature: 0.8,
                    topP: 0.9,
                    topK: 50,
                    repetitionPenalty: 1,
                    seed: 1
                ),
                memory: .compatibilityDefault,
                chunking: chunking
            )
            XCTAssertThrowsError(try request.validated(for: capabilities)) { error in
                XCTAssertEqual(
                    error as? VocelloQwen3ContractError,
                    .invalidChunkConfiguration
                )
            }
        }
    }

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

    func testCompatibilityAdapterCarriesCompleteRequestLocalSamplingPolicy() async throws {
        let compatibilityModel = FacadeCompatibilityModel()
        let loaded = try makeLoadedFixture(compatibilityModel: compatibilityModel)
        let sampling = VocelloQwen3SamplingConfiguration(
            effectiveSeed: 7,
            talker: VocelloQwen3SamplingStage(
                temperature: 0.73,
                topP: 0.87,
                topK: 49,
                minP: 0.02
            ),
            subtalker: VocelloQwen3SamplingStage(
                temperature: 0.61,
                topP: 0.81,
                topK: 37,
                minP: 0.01
            ),
            repetitionPenalty: 1.17,
            maxNewTokens: 321,
            requestedSeed: 7
        )
        let stream = try loaded.customVoiceStream(
            text: "Capture every supported sampling field.",
            language: "en-US",
            speaker: "fixture-speaker",
            instruction: nil,
            sampling: sampling,
            memory: VocelloQwen3MemoryConfiguration(
                clearCacheOnStreamChunk: false,
                tokenMemoryClearCadence: 37,
                talkerKVGeneratedWindow: 192
            ),
            streamingInterval: 0.5,
            enableChunkTimings: false
        )
        for try await _ in stream {}

        let captured = try XCTUnwrap(compatibilityModel.capturedGenerationParameters)
        XCTAssertEqual(captured.maxTokens, sampling.maxNewTokens)
        XCTAssertEqual(captured.temperature, sampling.temperature, accuracy: 0.0001)
        XCTAssertEqual(captured.topP, sampling.topP, accuracy: 0.0001)
        XCTAssertEqual(captured.repetitionPenalty, sampling.repetitionPenalty)
        XCTAssertEqual(sampling.topK, 49)
        XCTAssertEqual(sampling.seed, 7)

        let capturedPolicy = try XCTUnwrap(compatibilityModel.capturedSamplingPolicy)
        XCTAssertEqual(capturedPolicy.algorithmVersion, 2)
        XCTAssertEqual(capturedPolicy.effectiveSeed, 7)
        XCTAssertEqual(capturedPolicy.talker.topK, 49)
        XCTAssertEqual(capturedPolicy.talker.minP, 0.02, accuracy: 0.0001)
        XCTAssertEqual(capturedPolicy.subtalker.temperature, 0.61, accuracy: 0.0001)
        XCTAssertEqual(capturedPolicy.subtalker.topP, 0.81, accuracy: 0.0001)
        XCTAssertEqual(capturedPolicy.subtalker.topK, 37)
        XCTAssertEqual(capturedPolicy.subtalker.minP, 0.01, accuracy: 0.0001)
        XCTAssertEqual(capturedPolicy.repetitionPenalty, 1.17, accuracy: 0.0001)
        XCTAssertEqual(capturedPolicy.maximumCodecTokens, 321)
        XCTAssertEqual(
            compatibilityModel.capturedMemoryPolicies,
            [Qwen3RequestMemoryPolicy(
                clearCacheOnStreamChunkEmit: false,
                tokenMemoryClearCadence: 37,
                talkerKVGeneratedWindow: 192
            )]
        )
        XCTAssertEqual(compatibilityModel.capturedStreamingIntervals, [0.5])
    }

    func testRequestLocalMemoryPoliciesDoNotBleedAcrossSequentialStreams() async throws {
        let compatibilityModel = FacadeCompatibilityModel()
        let loaded = try makeLoadedFixture(compatibilityModel: compatibilityModel)
        let sampling = VocelloQwen3SamplingConfiguration(
            effectiveSeed: 99,
            talker: .init(temperature: 0.9, topP: 0.95, topK: 50, minP: 0),
            subtalker: .init(temperature: 0.9, topP: 0.95, topK: 50, minP: 0),
            repetitionPenalty: 1.05,
            maxNewTokens: 64,
            requestedSeed: 99
        )
        let first = VocelloQwen3MemoryConfiguration(
            clearCacheOnStreamChunk: false,
            tokenMemoryClearCadence: 17,
            talkerKVGeneratedWindow: 128
        )
        let second = VocelloQwen3MemoryConfiguration(
            clearCacheOnStreamChunk: true,
            tokenMemoryClearCadence: 83,
            talkerKVGeneratedWindow: nil
        )

        for memory in [first, second] {
            let stream = try loaded.customVoiceStream(
                text: "A request-local memory fixture.",
                language: "en-US",
                speaker: "fixture-speaker",
                instruction: nil,
                sampling: sampling,
                memory: memory,
                streamingInterval: 0.5,
                enableChunkTimings: false
            )
            for try await _ in stream {}
        }

        XCTAssertEqual(
            compatibilityModel.capturedMemoryPolicies,
            [
                Qwen3RequestMemoryPolicy(
                    clearCacheOnStreamChunkEmit: false,
                    tokenMemoryClearCadence: 17,
                    talkerKVGeneratedWindow: 128
                ),
                Qwen3RequestMemoryPolicy(
                    clearCacheOnStreamChunkEmit: true,
                    tokenMemoryClearCadence: 83,
                    talkerKVGeneratedWindow: nil
                ),
            ]
        )
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

    func testEngineReservationCannotOpenBeforeMandatoryAudioClaim() async throws {
        let compatibilityModel = FacadeCompatibilityModel()
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: compatibilityModel)
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )

        let reservedSnapshot = await engine.snapshot()
        XCTAssertEqual(reservedSnapshot.phase, .reservedGeneration)
        XCTAssertNil(compatibilityModel.capturedGenerationParameters)

        do {
            try await engine.open(reservation.id)
            XCTFail("generation must remain inert until output owns audio")
        } catch {
            XCTAssertEqual(error as? VocelloQwen3EngineError, .audioConsumerNotClaimed)
        }

        let audio = try await reservation.session.claimAudioConsumer()
        let drain = Task {
            for try await _ in audio {}
        }
        try await engine.open(reservation.id)
        let terminal = await reservation.session.waitForModelTermination()
        try await drain.value
        XCTAssertEqual(terminal.outcome, .completed(.endOfSequence))

        let awaitingSnapshot = await engine.snapshot()
        XCTAssertEqual(awaitingSnapshot.phase, .awaitingProductFinalization)
        XCTAssertEqual(awaitingSnapshot.activeOperation, reservation.lease)
        do {
            _ = try await engine.reserveGeneration(
                request: makeCustomRequest(generationID: UUID()),
                audioCapacityFrames: 24_000
            )
            XCTFail("model EOS must not release product admission")
        } catch {
            XCTAssertEqual(error as? VocelloQwen3EngineError, .operationInProgress(.generation))
        }

        let acknowledged = try await engine.acknowledgeProductFinalization(
            generationID: reservation.session.generationID,
            leaseID: reservation.lease.id,
            token: reservation.session.finalizationToken,
            disposition: .published
        )
        XCTAssertEqual(acknowledged, .accepted)
        let repeated = try await engine.acknowledgeProductFinalization(
            generationID: reservation.session.generationID,
            leaseID: reservation.lease.id,
            token: reservation.session.finalizationToken,
            disposition: .published
        )
        XCTAssertEqual(repeated, .alreadyAcknowledged)
        let readySnapshot = await engine.snapshot()
        XCTAssertEqual(readySnapshot.phase, .ready)
        XCTAssertNil(readySnapshot.activeOperation)
    }

    func testEngineDirectProducerBackpressuresUntilMandatoryConsumerDrains() async throws {
        let generationID = UUID()
        let stream = AsyncThrowingStream<AudioGeneration, Error> { continuation in
            continuation.yield(.audio(MLXArray([Float(0.1), Float(0.2)])))
            continuation.yield(.audio(MLXArray([Float(0.3), Float(0.4)])))
            continuation.finish()
        }
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(
                compatibilityModel: FacadeCompatibilityModel(streamOverride: stream)
            )
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: generationID),
            audioCapacityFrames: 2
        )
        let audio = try await reservation.session.claimAudioConsumer()

        try await engine.open(reservation.id)
        let suspensionDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < suspensionDeadline {
            if await audio.statistics().producerSuspensionCount > 0 { break }
            await Task.yield()
        }

        let blockedStatistics = await audio.statistics()
        XCTAssertEqual(blockedStatistics.capacityFrames, 2)
        XCTAssertEqual(blockedStatistics.highWaterFrames, 2)
        XCTAssertEqual(blockedStatistics.producerSuspensionCount, 1)
        let generating = await engine.snapshot()
        XCTAssertEqual(generating.phase, .generating)

        var iterator = audio.makeAsyncIterator()
        let first = try await iterator.next()
        let second = try await iterator.next()
        let end = try await iterator.next()
        let terminal = await reservation.session.waitForModelTermination()

        XCTAssertEqual(first?.sequence, 0)
        XCTAssertEqual(first?.samples, [0.1, 0.2])
        XCTAssertEqual(second?.sequence, 1)
        XCTAssertEqual(second?.samples, [0.3, 0.4])
        XCTAssertNil(end)
        XCTAssertEqual(terminal.outcome, .completed(.endOfSequence))
        XCTAssertEqual(terminal.emittedAudioFrameCount, 4)

        _ = try await engine.acknowledgeProductFinalization(
            generationID: generationID,
            leaseID: reservation.lease.id,
            token: reservation.session.finalizationToken,
            disposition: .published
        )
        let ready = await engine.snapshot()
        XCTAssertEqual(ready.phase, .ready)
    }

    func testEngineMapsTypedProducerFailureWithoutDiagnosticInference() async throws {
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(
                compatibilityModel: FacadeCompatibilityModel(generationEndReason: "failed")
            )
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        _ = try await reservation.session.claimAudioConsumer()

        try await engine.open(reservation.id)
        let terminal = await reservation.session.waitForModelTermination()
        XCTAssertEqual(terminal.outcome, .failed(.runtime))

        _ = try await engine.acknowledgeProductFinalization(
            generationID: reservation.session.generationID,
            leaseID: reservation.lease.id,
            token: reservation.session.finalizationToken,
            disposition: .aborted(.runtime)
        )
    }

    func testEngineMapsTypedMaximumTokenFinishReason() async throws {
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(
                compatibilityModel: FacadeCompatibilityModel(
                    generationEndReason: "token_cap"
                )
            )
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        _ = try await reservation.session.claimAudioConsumer()

        try await engine.open(reservation.id)
        let terminal = await reservation.session.waitForModelTermination()
        XCTAssertEqual(terminal.outcome, .completed(.maximumTokens))
        _ = try await engine.acknowledgeProductFinalization(
            generationID: reservation.session.generationID,
            leaseID: reservation.lease.id,
            token: reservation.session.finalizationToken,
            disposition: .published
        )
    }

    func testEngineMapsTypedProducerCancellationAndRecordsReason() async throws {
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(
                compatibilityModel: FacadeCompatibilityModel(
                    generationEndReason: "cancelled"
                )
            )
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        _ = try await reservation.session.claimAudioConsumer()

        try await engine.open(reservation.id)
        let terminal = await reservation.session.waitForModelTermination()
        XCTAssertEqual(terminal.outcome, .cancelled(.user))
        XCTAssertEqual(reservation.session.cancellation.reason, .user)
        _ = try await engine.acknowledgeProductFinalization(
            generationID: reservation.session.generationID,
            leaseID: reservation.lease.id,
            token: reservation.session.finalizationToken,
            disposition: .aborted(.runtime)
        )
    }

    func testEngineRejectsNominalSuccessThatProducedNoAudio() async throws {
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(
                compatibilityModel: FacadeCompatibilityModel(emitsAudio: false)
            )
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        _ = try await reservation.session.claimAudioConsumer()

        try await engine.open(reservation.id)
        let terminal = await reservation.session.waitForModelTermination()
        XCTAssertEqual(terminal.outcome, .failed(.runtime))
        XCTAssertEqual(terminal.emittedAudioFrameCount, 0)

        _ = try await engine.acknowledgeProductFinalization(
            generationID: reservation.session.generationID,
            leaseID: reservation.lease.id,
            token: reservation.session.finalizationToken,
            disposition: .aborted(.runtime)
        )
    }

    func testEngineAbortBeforeOpenHasNoGenerationSideEffects() async throws {
        let compatibilityModel = FacadeCompatibilityModel()
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: compatibilityModel)
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )

        try await engine.abortReservation(reservation.id, reason: .shutdown)
        XCTAssertNil(compatibilityModel.capturedGenerationParameters)
        let terminal = await reservation.session.waitForModelTermination()
        XCTAssertEqual(terminal.outcome, .cancelled(.shutdown))
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertNil(snapshot.activeOperation)
    }

    func testAbortingReservationRejectsOpenAndDuplicateAbortJoinsFinalization() async throws {
        let ownerGate = SuspendedEngineOperationGate()
        let joinerGate = SuspendedEngineOperationGate()
        let compatibilityModel = FacadeCompatibilityModel()
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: compatibilityModel),
            abortLifecycleHook: { event in
                switch event {
                case .owner:
                    await ownerGate.suspend()
                case .joiner:
                    await joinerGate.suspend()
                }
            }
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        _ = try await reservation.session.claimAudioConsumer()

        let owner = Task {
            try await engine.abortReservation(reservation.id, reason: .shutdown)
        }
        await ownerGate.waitUntilEntered()

        do {
            try await engine.open(reservation.id)
            XCTFail("an abort-owned reservation must never reopen generation")
        } catch {
            XCTAssertEqual(error as? VocelloQwen3EngineError, .invalidReservation)
        }

        let joiner = Task {
            try await engine.abortReservation(reservation.id, reason: .superseded)
        }
        await joinerGate.waitUntilEntered()
        var snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .awaitingProductFinalization)
        XCTAssertEqual(snapshot.activeOperation, reservation.lease)
        XCTAssertNil(compatibilityModel.capturedGenerationParameters)

        await joinerGate.release()
        await ownerGate.release()
        try await owner.value
        try await joiner.value

        let terminal = await reservation.session.waitForModelTermination()
        XCTAssertEqual(terminal.outcome, .cancelled(.shutdown))
        snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertNil(snapshot.activeOperation)
    }

    func testReservedGenerationCancellationIsTerminalWithoutSeparateAbort() async throws {
        let compatibilityModel = FacadeCompatibilityModel()
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: compatibilityModel)
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )

        try await engine.cancelGeneration(reservation.id, reason: .superseded)

        let terminal = await reservation.session.waitForModelTermination()
        XCTAssertEqual(terminal.outcome, .cancelled(.superseded))
        XCTAssertEqual(reservation.session.cancellation.reason, .superseded)
        XCTAssertNil(compatibilityModel.capturedGenerationParameters)
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertNil(snapshot.activeOperation)
    }

    func testCriticalPressureReasonSurvivesOpenFailureAndReservationAbort() async throws {
        let compatibilityModel = FacadeCompatibilityModel()
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: compatibilityModel)
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        _ = try await reservation.session.claimAudioConsumer()

        await engine.observeMemoryPressure(.critical)
        do {
            try await engine.open(reservation.id)
            XCTFail("critical pressure must keep an inert reservation closed")
        } catch {
            XCTAssertEqual(
                error as? VocelloQwen3EngineError,
                .admissionClosedForMemoryRelief
            )
        }

        try await engine.abortReservation(reservation.id, reason: .shutdown)
        let terminal = await reservation.session.waitForModelTermination()
        XCTAssertEqual(terminal.outcome, .cancelled(.memoryPressure))
        XCTAssertEqual(reservation.session.cancellation.reason, .memoryPressure)
        XCTAssertNil(compatibilityModel.capturedGenerationParameters)

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertNil(snapshot.activeOperation)
        XCTAssertTrue(snapshot.pressure.admissionClosed)
    }

    func testEngineRejectsStaleFinalizationTokenForNewerReservation() async throws {
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: FacadeCompatibilityModel())
        )
        let first = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        let staleToken = first.session.finalizationToken
        try await engine.abortReservation(first.id)

        let second = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        do {
            _ = try await second.session.acknowledgeProductFinalization(
                generationID: second.session.generationID,
                leaseID: second.lease.id,
                token: staleToken,
                disposition: .published
            )
            XCTFail("stale finalization identity must not release a newer lease")
        } catch {
            XCTAssertEqual(error as? VocelloQwen3SessionError, .invalidFinalizationIdentity)
        }
        try await engine.abortReservation(second.id)
    }

    func testEngineReliefIsTheOnlyTransitionThatReopensCriticalAdmission() async throws {
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: FacadeCompatibilityModel())
        )
        await engine.observeMemoryPressure(.critical)
        await engine.observeMemoryPressure(.warning)
        await engine.observeMemoryPressure(.normal)

        var snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.pressure.level, .critical)
        XCTAssertTrue(snapshot.pressure.admissionClosed)

        try await engine.relieveMemory()

        snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertNil(snapshot.activeOperation)
        XCTAssertEqual(snapshot.pressure.level, .normal)
        XCTAssertFalse(snapshot.pressure.admissionClosed)
    }

    func testEngineFullUnloadReliefRunsWhileCriticalAdmissionIsClosed() async throws {
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: FacadeCompatibilityModel())
        )
        let original = await engine.snapshot()
        await engine.observeMemoryPressure(.critical)

        try await engine.relieveMemory(.fullUnload)

        let snapshot = await engine.snapshot()
        XCTAssertNil(snapshot.loadedModel)
        XCTAssertEqual(snapshot.modelEpoch, original.modelEpoch + 1)
        XCTAssertEqual(snapshot.phase, .unloaded)
        XCTAssertNil(snapshot.activeOperation)
        XCTAssertEqual(snapshot.pressure.level, .normal)
        XCTAssertFalse(snapshot.pressure.admissionClosed)
    }

    func testEngineCarriesGenerationLeaseThroughCriticalFinalizationRelief() async throws {
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: FacadeCompatibilityModel())
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        let audio = try await reservation.session.claimAudioConsumer()
        let drain = Task {
            for try await _ in audio {}
        }
        try await engine.open(reservation.id)
        _ = await reservation.session.waitForModelTermination()
        try await drain.value
        await engine.observeMemoryPressure(.critical)

        let result = try await engine.acknowledgeProductFinalizationAndRelieveMemory(
            generationID: reservation.session.generationID,
            leaseID: reservation.lease.id,
            token: reservation.session.finalizationToken,
            disposition: .published
        )

        XCTAssertEqual(result, .accepted)
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertNil(snapshot.activeOperation)
        XCTAssertEqual(snapshot.pressure.level, .normal)
        XCTAssertFalse(snapshot.pressure.admissionClosed)
        let repeated = try await engine.acknowledgeProductFinalization(
            generationID: reservation.session.generationID,
            leaseID: reservation.lease.id,
            token: reservation.session.finalizationToken,
            disposition: .published
        )
        XCTAssertEqual(repeated, .alreadyAcknowledged)
        let repeatedRelief = try await engine.acknowledgeProductFinalizationAndRelieveMemory(
            generationID: reservation.session.generationID,
            leaseID: reservation.lease.id,
            token: reservation.session.finalizationToken,
            disposition: .published,
            action: .cacheTrim
        )
        XCTAssertEqual(repeatedRelief, .alreadyAcknowledged)
        do {
            _ = try await engine.acknowledgeProductFinalizationAndRelieveMemory(
                generationID: reservation.session.generationID,
                leaseID: reservation.lease.id,
                token: reservation.session.finalizationToken,
                disposition: .published,
                action: .fullUnload
            )
            XCTFail("a completed cache trim cannot masquerade as full unload")
        } catch {
            XCTAssertEqual(
                error as? VocelloQwen3EngineError,
                .finalizationAlreadyReleased
            )
        }
    }

    func testAtomicReliefCannotClaimAPreviouslyReleasedFinalization() async throws {
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: FacadeCompatibilityModel())
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        let audio = try await reservation.session.claimAudioConsumer()
        let drain = Task {
            for try await _ in audio {}
        }
        try await engine.open(reservation.id)
        _ = await reservation.session.waitForModelTermination()
        try await drain.value
        await engine.observeMemoryPressure(.critical)

        _ = try await engine.acknowledgeProductFinalization(
            generationID: reservation.session.generationID,
            leaseID: reservation.lease.id,
            token: reservation.session.finalizationToken,
            disposition: .published
        )
        do {
            _ = try await engine.acknowledgeProductFinalizationAndRelieveMemory(
                generationID: reservation.session.generationID,
                leaseID: reservation.lease.id,
                token: reservation.session.finalizationToken,
                disposition: .published,
                action: .fullUnload
            )
            XCTFail("a released generation lease cannot authorize later atomic relief")
        } catch {
            XCTAssertEqual(
                error as? VocelloQwen3EngineError,
                .finalizationAlreadyReleased
            )
        }

        var snapshot = await engine.snapshot()
        XCTAssertNotNil(snapshot.loadedModel)
        XCTAssertTrue(snapshot.pressure.admissionClosed)
        try await engine.relieveMemory(.fullUnload)
        snapshot = await engine.snapshot()
        XCTAssertNil(snapshot.loadedModel)
        XCTAssertFalse(snapshot.pressure.admissionClosed)
    }

    func testEngineCarriesGenerationLeaseThroughCriticalFullUnload() async throws {
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: FacadeCompatibilityModel())
        )
        let original = await engine.snapshot()
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        let audio = try await reservation.session.claimAudioConsumer()
        let drain = Task {
            for try await _ in audio {}
        }
        try await engine.open(reservation.id)
        _ = await reservation.session.waitForModelTermination()
        try await drain.value
        await engine.observeMemoryPressure(.critical)

        let result = try await engine.acknowledgeProductFinalizationAndRelieveMemory(
            generationID: reservation.session.generationID,
            leaseID: reservation.lease.id,
            token: reservation.session.finalizationToken,
            disposition: .published,
            action: .fullUnload
        )

        XCTAssertEqual(result, .accepted)
        let snapshot = await engine.snapshot()
        XCTAssertNil(snapshot.loadedModel)
        XCTAssertEqual(snapshot.modelEpoch, original.modelEpoch + 1)
        XCTAssertEqual(snapshot.phase, .unloaded)
        XCTAssertNil(snapshot.activeOperation)
        XCTAssertEqual(snapshot.pressure.level, .normal)
        XCTAssertFalse(snapshot.pressure.admissionClosed)
    }

    func testDuplicateAtomicReliefIsRejectedUntilOwnerCompletes() async throws {
        let reliefGate = SuspendedEngineOperationGate()
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: FacadeCompatibilityModel()),
            memoryReliefHook: { action in
                if action == .fullUnload {
                    await reliefGate.suspend()
                }
            }
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        let audio = try await reservation.session.claimAudioConsumer()
        let drain = Task {
            for try await _ in audio {}
        }
        try await engine.open(reservation.id)
        _ = await reservation.session.waitForModelTermination()
        try await drain.value
        await engine.observeMemoryPressure(.critical)

        let owner = Task {
            try await engine.acknowledgeProductFinalizationAndRelieveMemory(
                generationID: reservation.session.generationID,
                leaseID: reservation.lease.id,
                token: reservation.session.finalizationToken,
                disposition: .published,
                action: .fullUnload
            )
        }
        await reliefGate.waitUntilEntered()

        do {
            _ = try await engine.acknowledgeProductFinalizationAndRelieveMemory(
                generationID: reservation.session.generationID,
                leaseID: reservation.lease.id,
                token: reservation.session.finalizationToken,
                disposition: .published,
                action: .fullUnload
            )
            XCTFail("a duplicate relief request must not report early completion")
        } catch {
            XCTAssertEqual(
                error as? VocelloQwen3EngineError,
                .operationInProgress(.memoryRelief)
            )
        }

        await reliefGate.release()
        let ownerResult = try await owner.value
        XCTAssertEqual(ownerResult, .accepted)
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .unloaded)
        XCTAssertFalse(snapshot.pressure.admissionClosed)
    }

    func testRejectedAtomicReliefAcknowledgementReleasesItsClaim() async throws {
        let staleEngine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: FacadeCompatibilityModel())
        )
        let staleReservation = try await staleEngine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        let staleToken = staleReservation.session.finalizationToken
        try await staleEngine.abortReservation(staleReservation.id)

        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: FacadeCompatibilityModel())
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        let audio = try await reservation.session.claimAudioConsumer()
        let drain = Task {
            for try await _ in audio {}
        }
        try await engine.open(reservation.id)
        _ = await reservation.session.waitForModelTermination()
        try await drain.value
        await engine.observeMemoryPressure(.critical)

        do {
            _ = try await engine.acknowledgeProductFinalizationAndRelieveMemory(
                generationID: reservation.session.generationID,
                leaseID: reservation.lease.id,
                token: staleToken,
                disposition: .published,
                action: .cacheTrim
            )
            XCTFail("a stale finalization token must fail closed")
        } catch {
            XCTAssertEqual(error as? VocelloQwen3SessionError, .invalidFinalizationIdentity)
        }

        let result = try await engine.acknowledgeProductFinalizationAndRelieveMemory(
            generationID: reservation.session.generationID,
            leaseID: reservation.lease.id,
            token: reservation.session.finalizationToken,
            disposition: .published,
            action: .cacheTrim
        )
        XCTAssertEqual(result, .accepted)
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertNil(snapshot.activeOperation)
        XCTAssertFalse(snapshot.pressure.admissionClosed)
    }

    func testRejectedAtomicReliefCannotStrandConcurrentOrdinaryFinalization() async throws {
        let claimGate = SuspendedEngineOperationGate()
        let staleEngine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: FacadeCompatibilityModel())
        )
        let staleReservation = try await staleEngine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        let staleToken = staleReservation.session.finalizationToken
        try await staleEngine.abortReservation(staleReservation.id)

        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: FacadeCompatibilityModel()),
            finalizationReliefClaimHook: {
                await claimGate.suspend()
            }
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        let audio = try await reservation.session.claimAudioConsumer()
        let drain = Task {
            for try await _ in audio {}
        }
        try await engine.open(reservation.id)
        _ = await reservation.session.waitForModelTermination()
        try await drain.value
        await engine.observeMemoryPressure(.critical)

        let rejectedRelief = Task {
            try await engine.acknowledgeProductFinalizationAndRelieveMemory(
                generationID: reservation.session.generationID,
                leaseID: reservation.lease.id,
                token: staleToken,
                disposition: .published,
                action: .cacheTrim
            )
        }
        await claimGate.waitUntilEntered()

        let ordinaryFinalization = Task {
            try await engine.acknowledgeProductFinalization(
                generationID: reservation.session.generationID,
                leaseID: reservation.lease.id,
                token: reservation.session.finalizationToken,
                disposition: .published
            )
        }
        let acceptedDisposition = await reservation.session.waitForProductFinalization()
        XCTAssertEqual(acceptedDisposition, .published)
        await claimGate.release()

        do {
            _ = try await rejectedRelief.value
            XCTFail("a stale relief acknowledgement must fail closed")
        } catch {
            XCTAssertEqual(error as? VocelloQwen3SessionError, .invalidFinalizationIdentity)
        }
        _ = try await ordinaryFinalization.value

        var snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertNil(snapshot.activeOperation)
        XCTAssertTrue(snapshot.pressure.admissionClosed)

        try await engine.relieveMemory(.cacheTrim)
        snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertNil(snapshot.activeOperation)
        XCTAssertFalse(snapshot.pressure.admissionClosed)
    }

    func testOrdinaryFinalizerOwnsReleaseAfterRejectedReliefClearsClaim() async throws {
        let rollbackGate = SuspendedEngineOperationGate()
        let staleEngine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: FacadeCompatibilityModel())
        )
        let staleReservation = try await staleEngine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        let staleToken = staleReservation.session.finalizationToken
        try await staleEngine.abortReservation(staleReservation.id)

        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: FacadeCompatibilityModel()),
            finalizationReliefRollbackHook: {
                await rollbackGate.suspend()
            }
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        let audio = try await reservation.session.claimAudioConsumer()
        let drain = Task {
            for try await _ in audio {}
        }
        try await engine.open(reservation.id)
        _ = await reservation.session.waitForModelTermination()
        try await drain.value

        let rejectedRelief = Task {
            try await engine.acknowledgeProductFinalizationAndRelieveMemory(
                generationID: reservation.session.generationID,
                leaseID: reservation.lease.id,
                token: staleToken,
                disposition: .published,
                action: .cacheTrim
            )
        }
        await rollbackGate.waitUntilEntered()

        let ordinaryResult = try await engine.acknowledgeProductFinalization(
            generationID: reservation.session.generationID,
            leaseID: reservation.lease.id,
            token: reservation.session.finalizationToken,
            disposition: .published
        )
        XCTAssertEqual(ordinaryResult, .accepted)
        await rollbackGate.release()

        do {
            _ = try await rejectedRelief.value
            XCTFail("a stale relief acknowledgement must fail closed")
        } catch {
            XCTAssertEqual(error as? VocelloQwen3SessionError, .invalidFinalizationIdentity)
        }

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertNil(snapshot.activeOperation)
    }

    func testEnginePrewarmIsActorOwnedAndReturnsToReady() async throws {
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: FacadeCompatibilityModel())
        )

        try await engine.prewarm(request: makeCustomRequest(generationID: UUID()))

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertNil(snapshot.activeOperation)
    }

    func testSuspendedPrewarmRejectsReentrantGenerationReservation() async throws {
        let prewarmGate = SuspendedEngineOperationGate()
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(
                compatibilityModel: FacadeCompatibilityModel(prewarmGate: prewarmGate)
            )
        )
        let prewarmRequest = makeCustomRequest(generationID: UUID())
        let prewarm = Task {
            try await engine.prewarm(request: prewarmRequest)
        }

        await prewarmGate.waitUntilEntered()
        do {
            _ = try await engine.reserveGeneration(
                request: makeCustomRequest(generationID: UUID()),
                audioCapacityFrames: 24_000
            )
            XCTFail("actor reentrancy must not admit work over a suspended prewarm lease")
        } catch {
            XCTAssertEqual(
                error as? VocelloQwen3EngineError,
                .operationInProgress(.prewarm)
            )
        }

        await prewarmGate.release()
        try await prewarm.value
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertNil(snapshot.activeOperation)
    }

    func testCancelledSuspendedProducerCannotPublishLateStateOrReleaseNewerLease() async throws {
        let producerGate = SuspendedEngineOperationGate()
        let compatibilityModel = FacadeCompatibilityModel(producerGate: producerGate)
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: compatibilityModel)
        )
        let first = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        _ = try await first.session.claimAudioConsumer()
        try await engine.open(first.id)
        await producerGate.waitUntilEntered()

        try await engine.cancelGeneration(first.id, reason: .superseded)
        await producerGate.release()
        let firstTerminal = await first.session.waitForModelTermination()
        XCTAssertEqual(firstTerminal.outcome, .cancelled(.superseded))
        XCTAssertEqual(firstTerminal.generatedTokenCount, 0)
        XCTAssertEqual(firstTerminal.emittedAudioFrameCount, 0)
        let latePrepared = await first.session.prepared.snapshot()
        XCTAssertNil(latePrepared)

        var snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .awaitingProductFinalization)
        XCTAssertEqual(snapshot.activeOperation, first.lease)
        _ = try await engine.acknowledgeProductFinalization(
            generationID: first.session.generationID,
            leaseID: first.lease.id,
            token: first.session.finalizationToken,
            disposition: .aborted(.runtime)
        )

        let second = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        do {
            _ = try await engine.acknowledgeProductFinalization(
                generationID: first.session.generationID,
                leaseID: first.lease.id,
                token: first.session.finalizationToken,
                disposition: .aborted(.runtime)
            )
            XCTFail("a late completion must not release the newer reservation")
        } catch {
            XCTAssertEqual(
                error as? VocelloQwen3EngineError,
                .modelHasNotTerminated
            )
        }
        snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .reservedGeneration)
        XCTAssertEqual(snapshot.activeOperation, second.lease)
        try await engine.cancelGeneration(second.id, reason: .shutdown)
    }

    func testPreparedReplayWaitsForProducerPreparationBoundary() async throws {
        let producerGate = SuspendedEngineOperationGate()
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(
                compatibilityModel: FacadeCompatibilityModel(producerGate: producerGate)
            )
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        _ = try await reservation.session.claimAudioConsumer()
        try await engine.open(reservation.id)

        await producerGate.waitUntilEntered()
        let beforeProducerPrepared = await reservation.session.prepared.snapshot()
        XCTAssertNil(beforeProducerPrepared)

        await producerGate.release()
        _ = await reservation.session.waitForModelTermination()
        let afterProducerPrepared = await reservation.session.prepared.snapshot()
        XCTAssertEqual(afterProducerPrepared?.generationID, reservation.session.generationID)
        _ = try await engine.acknowledgeProductFinalization(
            generationID: reservation.session.generationID,
            leaseID: reservation.lease.id,
            token: reservation.session.finalizationToken,
            disposition: .published
        )
    }

    func testClonePromptConstructionCannotOverlapGenerationLease() async throws {
        let compatibilityModel = FacadeCompatibilityModel()
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(
                compatibilityModel: compatibilityModel,
                capabilities: VocelloQwen3CapabilitySet([
                    .streaming,
                    .customVoice,
                    .voiceClone,
                ])
            )
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )

        do {
            _ = try await engine.makeCloneHandle(
                referenceSamples: Array(repeating: 0.1, count: 2_400),
                referenceText: "Fixture reference",
                xVectorOnlyMode: false,
                conditioningDigest: String(repeating: "a", count: 64)
            )
            XCTFail("clone prompt construction must share the actor operation lease")
        } catch {
            XCTAssertEqual(
                error as? VocelloQwen3EngineError,
                .operationInProgress(.generation)
            )
        }

        try await engine.abortReservation(reservation.id)
    }

    func testCloneHandleBudgetAndReliefInvalidationAreDeterministic() async throws {
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(
                compatibilityModel: FacadeCompatibilityModel(),
                capabilities: VocelloQwen3CapabilitySet([
                    .streaming,
                    .voiceClone,
                ])
            )
        )
        let first = try await engine.makeCloneHandle(
            referenceSamples: [0.1, 0.2],
            referenceText: nil,
            xVectorOnlyMode: true,
            conditioningDigest: String(repeating: "a", count: 64)
        )
        let second = try await engine.makeCloneHandle(
            referenceSamples: [0.3, 0.4],
            referenceText: nil,
            xVectorOnlyMode: true,
            conditioningDigest: String(repeating: "b", count: 64)
        )

        do {
            _ = try await engine.reserveGeneration(
                request: makeCloneRequest(generationID: UUID()),
                cloneHandle: first,
                audioCapacityFrames: 24_000
            )
            XCTFail("the conservative one-handle budget must evict the oldest prompt")
        } catch {
            XCTAssertEqual(error as? VocelloQwen3EngineError, .invalidCloneHandle)
        }

        let preserved = try await engine.reserveGeneration(
            request: makeCloneRequest(generationID: UUID()),
            cloneHandle: second,
            audioCapacityFrames: 24_000
        )
        try await engine.abortReservation(preserved.id)
        try await engine.relieveMemory(.cacheTrim)

        let afterBenignTrim = try await engine.reserveGeneration(
            request: makeCloneRequest(generationID: UUID()),
            cloneHandle: second,
            audioCapacityFrames: 24_000
        )
        try await engine.abortReservation(afterBenignTrim.id)

        let released = await engine.releaseCloneHandle(second)
        let releasedAgain = await engine.releaseCloneHandle(second)
        XCTAssertTrue(released)
        XCTAssertFalse(releasedAgain)
        do {
            _ = try await engine.reserveGeneration(
                request: makeCloneRequest(generationID: UUID()),
                cloneHandle: second,
                audioCapacityFrames: 24_000
            )
            XCTFail("an explicitly released handle must fail closed")
        } catch {
            XCTAssertEqual(error as? VocelloQwen3EngineError, .invalidCloneHandle)
        }

        let pressureHandle = try await engine.makeCloneHandle(
            referenceSamples: [0.5, 0.6],
            referenceText: nil,
            xVectorOnlyMode: true,
            conditioningDigest: String(repeating: "c", count: 64)
        )

        await engine.observeMemoryPressure(.critical)
        try await engine.relieveMemory(.cacheTrim)
        do {
            _ = try await engine.reserveGeneration(
                request: makeCloneRequest(generationID: UUID()),
                cloneHandle: pressureHandle,
                audioCapacityFrames: 24_000
            )
            XCTFail("critical relief must invalidate actor-owned clone tensors")
        } catch {
            XCTAssertEqual(error as? VocelloQwen3EngineError, .invalidCloneHandle)
        }
    }

    func testProductOutputAdapterFinalizesBeforeReleasingLease() async throws {
        let compatibilityModel = FacadeCompatibilityModel()
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: compatibilityModel)
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        let sink = RecordingProductOutputSink()
        let terminals = ProductTerminalRecorder()
        let adapter = VocelloQwen3ProductOutputAdapter(
            terminalPublisher: { terminal in
                await terminals.record(terminal)
            }
        )

        let terminal = try await adapter.run(
            engine: engine,
            reservation: reservation,
            sink: sink
        )

        XCTAssertEqual(terminal.disposition, .published)
        let successFinalizeCount = await sink.finalizeCount
        let successAbortCount = await sink.abortCount
        let successTerminalCount = await terminals.values.count
        XCTAssertEqual(successFinalizeCount, 1)
        XCTAssertEqual(successAbortCount, 0)
        XCTAssertEqual(successTerminalCount, 1)
        XCTAssertEqual(
            compatibilityModel.capturedMemoryPolicies,
            [Qwen3RequestMemoryPolicy(
                clearCacheOnStreamChunkEmit: false,
                tokenMemoryClearCadence: 16,
                talkerKVGeneratedWindow: nil
            )]
        )
        XCTAssertEqual(compatibilityModel.capturedStreamingIntervals.count, 1)
        XCTAssertEqual(
            compatibilityModel.capturedStreamingIntervals[0],
            7.0 / 12.5,
            accuracy: 0.000_001
        )
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertNil(snapshot.activeOperation)
    }

    func testProductOutputAdapterAbortsAndReleasesLeaseAfterSinkFailure() async throws {
        let stream = AsyncThrowingStream<AudioGeneration, Error> { continuation in
            continuation.yield(.audio(MLXArray([Float(0.1), Float(0.2)])))
            continuation.finish()
        }
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(
                compatibilityModel: FacadeCompatibilityModel(streamOverride: stream)
            )
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        let sink = RecordingProductOutputSink(failOnConsume: true)
        let terminals = ProductTerminalRecorder()
        let adapter = VocelloQwen3ProductOutputAdapter(
            terminalPublisher: { terminal in
                await terminals.record(terminal)
            }
        )

        do {
            _ = try await adapter.run(engine: engine, reservation: reservation, sink: sink)
            XCTFail("sink failure must fail product output")
        } catch {
            XCTAssertEqual(error as? ProductOutputSinkFixtureError, .consume)
        }

        let failureAbortCount = await sink.abortCount
        let failureTerminals = await terminals.values
        XCTAssertEqual(failureAbortCount, 1)
        XCTAssertEqual(failureTerminals.count, 1)
        XCTAssertEqual(failureTerminals.first?.disposition, .aborted(.runtime))
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertNil(snapshot.activeOperation)
    }

    func testPrecancelledOutputAdapterAbortsInertReservationWithoutModelWork() async throws {
        let compatibilityModel = FacadeCompatibilityModel()
        let engine = VocelloQwen3Engine(
            loadedModel: try makeLoadedFixture(compatibilityModel: compatibilityModel)
        )
        let reservation = try await engine.reserveGeneration(
            request: makeCustomRequest(generationID: UUID()),
            audioCapacityFrames: 24_000
        )
        let sink = RecordingProductOutputSink()
        let startGate = AdapterStartGate()
        let adapter = VocelloQwen3ProductOutputAdapter()

        let task = Task {
            await startGate.wait()
            return try await adapter.run(
                engine: engine,
                reservation: reservation,
                sink: sink
            )
        }
        task.cancel()
        await startGate.open()

        do {
            _ = try await task.value
            XCTFail("an already-cancelled adapter must not open model generation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(compatibilityModel.capturedMemoryPolicies, [])
        let abortCount = await sink.abortCount
        XCTAssertEqual(abortCount, 1)
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertNil(snapshot.activeOperation)
    }

    private func makeLoadedFixture(
        compatibilityModel: FacadeCompatibilityModel,
        capabilities: VocelloQwen3CapabilitySet = VocelloQwen3CapabilitySet([
            .streaming,
            .customVoice,
        ])
    ) throws -> VocelloQwen3LoadedModel {
        try VocelloQwen3LoadedModel(
            compatibilityModel: compatibilityModel,
            identity: VocelloQwen3ModelIdentity(
                modelID: "fixture-custom",
                repositoryID: "fixture/repository",
                revision: "fixture-revision",
                artifactVersion: "fixture-v1"
            ),
            capabilities: capabilities
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

    private func makeCloneRequest(generationID: UUID) -> VocelloQwen3SynthesisRequest {
        VocelloQwen3SynthesisRequest(
            generationID: generationID,
            text: "Facade clone fixture.",
            language: "en-US",
            input: .voiceClone(referenceID: "fixture-reference"),
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

private enum ProductOutputSinkFixtureError: Error, Equatable {
    case consume
}

private actor RecordingProductOutputSink: VocelloQwen3ProductOutputSink {
    private let failOnConsume: Bool
    private(set) var chunks: [VocelloQwen3AudioChunkEvent] = []
    private(set) var finalizeCount = 0
    private(set) var abortCount = 0

    init(failOnConsume: Bool = false) {
        self.failOnConsume = failOnConsume
    }

    func consume(
        _ chunk: VocelloQwen3AudioChunkEvent
    ) async throws -> VocelloQwen3PreviewAudioChunk {
        if failOnConsume { throw ProductOutputSinkFixtureError.consume }
        chunks.append(chunk)
        return VocelloQwen3PreviewAudioChunk(
            generationID: chunk.generationID,
            sequence: chunk.sequence,
            pcm16LittleEndian: Data(count: chunk.frameCount * MemoryLayout<Int16>.size),
            frameCount: chunk.frameCount,
            sampleRate: chunk.sampleRate,
            channelCount: chunk.channelCount
        )
    }

    func finalize(
        modelTerminal _: VocelloQwen3TerminalEvent
    ) async -> VocelloQwen3ProductFinalizationDisposition {
        finalizeCount += 1
        return .published
    }

    func abort() async {
        abortCount += 1
    }
}

private actor ProductTerminalRecorder {
    private(set) var values: [VocelloQwen3ProductTerminal] = []

    func record(_ terminal: VocelloQwen3ProductTerminal) {
        values.append(terminal)
    }
}

private actor AdapterStartGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
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

private actor SuspendedEngineOperationGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        if !entered {
            entered = true
            let pending = enteredWaiters
            enteredWaiters.removeAll(keepingCapacity: false)
            pending.forEach { $0.resume() }
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            if entered {
                continuation.resume()
            } else {
                enteredWaiters.append(continuation)
            }
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let pending = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }
}

private enum FacadeCompatibilityFixtureError: Error {
    case unsupported
}

private final class FacadeCompatibilityModel: SpeechGenerationModel, Qwen3OptimizedSpeechGenerationModel, Qwen3SuspendingSpeechGenerationModel, SpeechGenerationModelDiagnosticsProvider, @unchecked Sendable {
    let sampleRate = 24_000
    let defaultGenerationParameters = GenerateParameters()
    private let eventCount: Int
    private let generationEndReason: String
    private let streamOverride: AsyncThrowingStream<AudioGeneration, Error>?
    private let prewarmGate: SuspendedEngineOperationGate?
    private let producerGate: SuspendedEngineOperationGate?
    private let emitsAudio: Bool
    private let captureLock = NSLock()
    private var _capturedGenerationParameters: GenerateParameters?
    private var _capturedSamplingPolicy: Qwen3RequestSamplingPolicy?
    private var _capturedMemoryPolicies: [Qwen3RequestMemoryPolicy] = []
    private var _capturedStreamingIntervals: [Double] = []

    init(
        eventCount: Int = 1,
        generationEndReason: String = "eos",
        streamOverride: AsyncThrowingStream<AudioGeneration, Error>? = nil,
        prewarmGate: SuspendedEngineOperationGate? = nil,
        producerGate: SuspendedEngineOperationGate? = nil,
        emitsAudio: Bool = true
    ) {
        self.eventCount = eventCount
        self.generationEndReason = generationEndReason
        self.streamOverride = streamOverride
        self.prewarmGate = prewarmGate
        self.producerGate = producerGate
        self.emitsAudio = emitsAudio
    }

    var capturedGenerationParameters: GenerateParameters? {
        captureLock.lock()
        defer { captureLock.unlock() }
        return _capturedGenerationParameters
    }

    var capturedSamplingPolicy: Qwen3RequestSamplingPolicy? {
        captureLock.lock()
        defer { captureLock.unlock() }
        return _capturedSamplingPolicy
    }

    var capturedMemoryPolicies: [Qwen3RequestMemoryPolicy] {
        captureLock.lock()
        defer { captureLock.unlock() }
        return _capturedMemoryPolicies
    }

    var capturedStreamingIntervals: [Double] {
        captureLock.lock()
        defer { captureLock.unlock() }
        return _capturedStreamingIntervals
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
        generationParameters _: GenerateParameters,
        memoryPolicy _: Qwen3RequestMemoryPolicy,
        isolation: isolated (any Actor)?
    ) async throws {
        _ = isolation
        if let prewarmGate {
            await prewarmGate.suspend()
        }
    }

    func generateCustomVoiceStream(
        text _: String,
        language _: String,
        speaker _: String,
        instruct _: String?,
        generationParameters: GenerateParameters,
        samplingPolicy: Qwen3RequestSamplingPolicy,
        memoryPolicy: Qwen3RequestMemoryPolicy,
        streamingInterval: Double,
        customVoiceProfile _: String?,
        streamStepEvalPolicy _: String?,
        generationSpeedProfile _: String?,
        memoryClearCadence _: Int?,
        enableChunkTimings _: Bool
    ) -> AsyncThrowingStream<AudioGeneration, Error> {
        capture(
            generationParameters,
            samplingPolicy: samplingPolicy,
            memoryPolicy: memoryPolicy,
            streamingInterval: streamingInterval
        )
        return fixtureStream()
    }

    func generateCustomVoice(
        text _: String,
        language _: String,
        speaker _: String,
        instruct _: String?,
        generationParameters _: GenerateParameters,
        samplingPolicy _: Qwen3RequestSamplingPolicy,
        memoryPolicy _: Qwen3RequestMemoryPolicy
    ) async throws -> AudioGenerationCompletion {
        AudioGenerationCompletion(audio: MLXArray([Float(0)]), info: nil, finishReason: .eos)
    }

    func produceCustomVoice(
        text _: String,
        language _: String,
        speaker _: String,
        instruct _: String?,
        generationParameters: GenerateParameters,
        samplingPolicy: Qwen3RequestSamplingPolicy,
        memoryPolicy: Qwen3RequestMemoryPolicy,
        streamingInterval: Double,
        customVoiceProfile _: String?,
        streamStepEvalPolicy _: String?,
        generationSpeedProfile _: String?,
        memoryClearCadence _: Int?,
        enableChunkTimings _: Bool,
        sink: @escaping Qwen3MaterializedGenerationSink,
        isolation: isolated (any Actor)?
    ) async throws -> AudioGenerationFinishReason {
        _ = isolation
        capture(
            generationParameters,
            samplingPolicy: samplingPolicy,
            memoryPolicy: memoryPolicy,
            streamingInterval: streamingInterval
        )
        if let producerGate {
            await producerGate.suspend()
        }
        try await sink(.prepared)
        try await emitFixtureEvents(to: sink)
        switch generationEndReason {
        case "eos": return .eos
        case "token_cap", "max_tokens": return .maxTokens
        case "cancelled": return .cancelled
        default: return .failed
        }
    }

    func prepareVoiceDesign(
        text _: String,
        language _: String,
        voiceDescription _: String,
        generationParameters _: GenerateParameters,
        memoryPolicy _: Qwen3RequestMemoryPolicy,
        isolation: isolated (any Actor)?
    ) async throws {
        _ = isolation
        throw FacadeCompatibilityFixtureError.unsupported
    }

    func generateVoiceDesignStream(
        text _: String,
        language _: String,
        voiceDescription _: String,
        generationParameters _: GenerateParameters,
        samplingPolicy _: Qwen3RequestSamplingPolicy,
        memoryPolicy _: Qwen3RequestMemoryPolicy,
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
        generationParameters _: GenerateParameters,
        samplingPolicy _: Qwen3RequestSamplingPolicy,
        memoryPolicy _: Qwen3RequestMemoryPolicy
    ) async throws -> AudioGenerationCompletion { throw FacadeCompatibilityFixtureError.unsupported }

    func produceVoiceDesign(
        text _: String,
        language _: String,
        voiceDescription _: String,
        generationParameters _: GenerateParameters,
        samplingPolicy _: Qwen3RequestSamplingPolicy,
        memoryPolicy _: Qwen3RequestMemoryPolicy,
        streamingInterval _: Double,
        streamStepEvalPolicy _: String?,
        generationSpeedProfile _: String?,
        memoryClearCadence _: Int?,
        enableChunkTimings _: Bool,
        sink _: @escaping Qwen3MaterializedGenerationSink,
        isolation: isolated (any Actor)?
    ) async throws -> AudioGenerationFinishReason {
        _ = isolation
        throw FacadeCompatibilityFixtureError.unsupported
    }

    func createVoiceClonePrompt(
        refAudio _: MLXArray,
        refText: String?,
        xVectorOnlyMode: Bool
    ) throws -> Qwen3TTSVoiceClonePrompt {
        Qwen3TTSVoiceClonePrompt(
            refCodes: nil,
            speakerEmbedding: MLXArray([Float(0.25)]).reshaped(1, 1),
            refText: refText,
            xVectorOnlyMode: xVectorOnlyMode,
            iclMode: !xVectorOnlyMode
        )
    }

    func prepareVoiceClone(
        text _: String,
        language _: String,
        voiceClonePrompt _: Qwen3TTSVoiceClonePrompt,
        generationParameters _: GenerateParameters,
        memoryPolicy _: Qwen3RequestMemoryPolicy,
        isolation: isolated (any Actor)?
    ) async throws {
        _ = isolation
        throw FacadeCompatibilityFixtureError.unsupported
    }

    func generateVoiceCloneStream(
        text _: String,
        language _: String,
        voiceClonePrompt _: Qwen3TTSVoiceClonePrompt,
        generationParameters _: GenerateParameters,
        samplingPolicy _: Qwen3RequestSamplingPolicy,
        memoryPolicy _: Qwen3RequestMemoryPolicy,
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
        generationParameters _: GenerateParameters,
        samplingPolicy _: Qwen3RequestSamplingPolicy,
        memoryPolicy _: Qwen3RequestMemoryPolicy
    ) async throws -> AudioGenerationCompletion { throw FacadeCompatibilityFixtureError.unsupported }

    func produceVoiceClone(
        text _: String,
        language _: String,
        voiceClonePrompt _: Qwen3TTSVoiceClonePrompt,
        generationParameters _: GenerateParameters,
        samplingPolicy _: Qwen3RequestSamplingPolicy,
        memoryPolicy _: Qwen3RequestMemoryPolicy,
        streamingInterval _: Double,
        streamStepEvalPolicy _: String?,
        generationSpeedProfile _: String?,
        memoryClearCadence _: Int?,
        enableChunkTimings _: Bool,
        sink _: @escaping Qwen3MaterializedGenerationSink,
        isolation: isolated (any Actor)?
    ) async throws -> AudioGenerationFinishReason {
        _ = isolation
        throw FacadeCompatibilityFixtureError.unsupported
    }

    private func fixtureStream() -> AsyncThrowingStream<AudioGeneration, Error> {
        if let streamOverride { return streamOverride }
        return AsyncThrowingStream { continuation in
            for token in 1 ... eventCount { continuation.yield(.token(token)) }
            if emitsAudio {
                continuation.yield(.audio(MLXArray([Float(0.1)])))
            }
            continuation.finish()
        }
    }

    private func failingFixtureStream() -> AsyncThrowingStream<AudioGeneration, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: FacadeCompatibilityFixtureError.unsupported)
        }
    }

    private func emitFixtureEvents(
        to sink: @escaping Qwen3MaterializedGenerationSink
    ) async throws {
        for try await event in fixtureStream() {
            switch event {
            case .token(let token):
                try await sink(.token(token))
            case .info(let info):
                try await sink(.info(info))
            case .audio(let audio):
                try await sink(.audio(audio.asArray(Float.self)))
            case .chunkTimings(let timings):
                try await sink(.chunkTimings(timings))
            }
        }
    }


    private func capture(
        _ generationParameters: GenerateParameters,
        samplingPolicy: Qwen3RequestSamplingPolicy? = nil,
        memoryPolicy: Qwen3RequestMemoryPolicy? = nil,
        streamingInterval: Double? = nil
    ) {
        captureLock.lock()
        _capturedGenerationParameters = generationParameters
        if let samplingPolicy {
            _capturedSamplingPolicy = samplingPolicy
        }
        if let memoryPolicy {
            _capturedMemoryPolicies.append(memoryPolicy)
        }
        if let streamingInterval {
            _capturedStreamingIntervals.append(streamingInterval)
        }
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
