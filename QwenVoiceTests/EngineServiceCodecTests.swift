import XCTest
@testable import QwenVoiceEngineSupport
@testable import QwenVoiceCore

final class EngineServiceCodecTests: XCTestCase {
    func testEngineServiceTrustPolicyUsesBundledServiceIdentifier() {
        XCTAssertEqual(
            EngineServiceTrustPolicy.codeSigningRequirement(),
            "identifier \"com.qwenvoice.app.engine-service\""
        )
    }

    func testEngineServiceTrustPolicyBuildsDevelopmentCompatibleClientRequirement() {
        XCTAssertEqual(
            EngineServiceTrustPolicy.clientRequirement(
                environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]
            ),
            "(identifier \"com.qwenvoice.app\" or identifier \"com.qwenvoice.tests\" or identifier \"com.apple.dt.xctest.tool\")"
        )
    }

    func testEngineServiceTrustPolicyBuildsStrictClientRequirementWhenTeamIdentifierIsProvided() {
        XCTAssertEqual(
            EngineServiceTrustPolicy.clientRequirement(
                environment: [:],
                teamIdentifier: "TEAM12345"
            ),
            "identifier \"com.qwenvoice.app\" and certificate leaf[subject.OU] = \"TEAM12345\""
        )
        XCTAssertEqual(
            EngineServiceTrustPolicy.serviceRequirement(
                teamIdentifier: "TEAM12345"
            ),
            "identifier \"com.qwenvoice.app.engine-service\" and certificate leaf[subject.OU] = \"TEAM12345\""
        )
    }

    func testRemoteErrorPayloadMakeMapsCancellationErrorToCancelledCode() {
        let payload = RemoteErrorPayload.make(for: CancellationError())

        XCTAssertEqual(payload.code, .cancelled)
        XCTAssertFalse(payload.message.isEmpty)
    }

    func testRemoteErrorPayloadRoundTripsCancellationCode() throws {
        let payload = RemoteErrorPayload(
            message: "Generation cancelled",
            domain: "QwenVoiceNative",
            code: .cancelled
        )

        let encoded = try EngineServiceCodec.encode(payload)
        let decoded = try EngineServiceCodec.decode(RemoteErrorPayload.self, from: encoded)

        XCTAssertEqual(decoded, payload)
    }

    func testRequestEnvelopeRoundTripsThroughCodec() throws {
        let request = EngineRequestEnvelope(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            command: .generateBatch(
                commandID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                requests: [
                    GenerationRequest(
                        modelID: "pro_custom",
                        text: "Hello from codec tests",
                        outputPath: "/tmp/codec.wav",
                        shouldStream: true,
                        streamingTitle: "Codec preview",
                        payload: .custom(speakerID: "vivian", deliveryStyle: "Warm")
                    )
                ]
            )
        )

        let encoded = try EngineServiceCodec.encode(request)
        let decoded = try EngineServiceCodec.decode(EngineRequestEnvelope.self, from: encoded)

        XCTAssertEqual(decoded, request)
    }

    func testReplyEnvelopeRoundTripsGenerationResult() throws {
        let reply = EngineReplyEnvelope(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            reply: .generationResult(
                GenerationResult(
                    audioPath: "/tmp/result.wav",
                    durationSeconds: 1.25,
                    streamSessionDirectory: "/tmp/session",
                    benchmarkSample: BenchmarkSample(
                        tokenCount: 42,
                        processingTimeSeconds: 0.75,
                        peakMemoryUsage: 1.2,
                        streamingUsed: true,
                        preparedCloneUsed: false,
                        cloneCacheHit: false,
                        firstChunkMs: 123
                    )
                )
            )
        )

        let encoded = try EngineServiceCodec.encode(reply)
        let decoded = try EngineServiceCodec.decode(EngineReplyEnvelope.self, from: encoded)

        XCTAssertEqual(decoded, reply)
    }

    func testReplyEnvelopeRoundTripsCapabilities() throws {
        let reply = EngineReplyEnvelope(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            reply: .capabilities(.macOSXPCDefault)
        )

        let encoded = try EngineServiceCodec.encode(reply)
        let decoded = try EngineServiceCodec.decode(EngineReplyEnvelope.self, from: encoded)

        XCTAssertEqual(decoded, reply)
    }

    func testEventEnvelopeRoundTripsChunkAndProgressPayloads() throws {
        let event = EngineEventEnvelope.batchProgress(
            EngineBatchProgressUpdate(
                commandID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
                fraction: 0.5,
                message: "Halfway there"
            )
        )
        let chunk = EngineEventEnvelope.generationChunk(
            GenerationEvent(
                kind: .streamChunk,
                requestID: 1,
                mode: "custom",
                title: "Chunk title",
                chunkPath: "/tmp/chunk.wav",
                isFinal: true,
                chunkDurationSeconds: 0.4,
                cumulativeDurationSeconds: 0.4,
                streamSessionDirectory: "/tmp/session"
            )
        )

        XCTAssertEqual(
            try EngineServiceCodec.decode(
                EngineEventEnvelope.self,
                from: EngineServiceCodec.encode(event)
            ),
            event
        )
        XCTAssertEqual(
            try EngineServiceCodec.decode(
                EngineEventEnvelope.self,
                from: EngineServiceCodec.encode(chunk)
            ),
            chunk
        )
    }

    func testExtensionRequestEnvelopeRoundTripsSharedGenerationRequest() throws {
        let request = QwenVoiceCore.ExtensionEngineRequestEnvelope(
            id: UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!,
            command: .generate(
                request: GenerationRequest(
                    modelID: "pro_custom",
                    text: "Hello from the extension codec",
                    outputPath: "/tmp/extension.wav",
                    shouldStream: true,
                    streamingTitle: "Extension preview",
                    payload: .custom(speakerID: "vivian", deliveryStyle: "Warm")
                )
            )
        )

        let encoded = try QwenVoiceCore.ExtensionEngineCodec.encode(request)
        let decoded = try QwenVoiceCore.ExtensionEngineCodec.decode(
            QwenVoiceCore.ExtensionEngineRequestEnvelope.self,
            from: encoded
        )

        XCTAssertEqual(decoded, request)
    }

    func testExtensionEventEnvelopeRoundTripsSnapshotAndChunkPayloads() throws {
        let snapshotEvent = QwenVoiceCore.ExtensionEngineEventEnvelope.snapshot(
            TTSEngineSnapshot(
                isReady: true,
                loadState: .loaded(modelID: "pro_custom"),
                clonePreparationState: .primed(key: "clone-key"),
                visibleErrorMessage: nil
            )
        )
        let chunkEvent = QwenVoiceCore.ExtensionEngineEventEnvelope.generationChunk(
            GenerationEvent(
                kind: .streamChunk,
                requestID: 7,
                mode: "custom",
                title: "Extension chunk",
                chunkPath: "/tmp/chunk.wav",
                isFinal: false,
                chunkDurationSeconds: 0.25,
                cumulativeDurationSeconds: 0.5,
                streamSessionDirectory: "/tmp/session"
            )
        )

        XCTAssertEqual(
            try QwenVoiceCore.ExtensionEngineCodec.decode(
                QwenVoiceCore.ExtensionEngineEventEnvelope.self,
                from: QwenVoiceCore.ExtensionEngineCodec.encode(snapshotEvent)
            ),
            snapshotEvent
        )
        XCTAssertEqual(
            try QwenVoiceCore.ExtensionEngineCodec.decode(
                QwenVoiceCore.ExtensionEngineEventEnvelope.self,
                from: QwenVoiceCore.ExtensionEngineCodec.encode(chunkEvent)
            ),
            chunkEvent
        )
    }
}
