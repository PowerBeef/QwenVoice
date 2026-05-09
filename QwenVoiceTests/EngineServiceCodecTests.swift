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

    func testEngineServiceTrustPolicyTreatsUnresolvedBuildSettingAsDevelopmentFallback() {
        XCTAssertEqual(
            EngineServiceTrustPolicy.serviceRequirement(teamIdentifier: "$(QWENVOICE_DEVELOPMENT_TEAM)"),
            "identifier \"com.qwenvoice.app.engine-service\""
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

    func testRemoteErrorPayloadRedactsSensitiveDetails() {
        let error = NSError(
            domain: "QwenVoiceTests",
            code: 7,
            userInfo: [
                "prompt": "Say the private customer sentence",
                "sourcePath": "/Users/example/Private/reference.wav",
                NSLocalizedFailureReasonErrorKey: "Failed while reading /tmp/private-reference.wav",
            ]
        )

        let payload = RemoteErrorPayload.make(for: error)
        XCTAssertEqual(payload.details?["prompt"], "<redacted>")
        XCTAssertFalse(payload.details?["sourcePath"]?.contains("/Users/example") ?? true)
        XCTAssertFalse(payload.details?["NSLocalizedFailureReason"]?.contains("/tmp/private-reference.wav") ?? true)
    }

    func testRemoteErrorPayloadRedactsPrimaryMessage() {
        let error = NSError(
            domain: "QwenVoiceTests",
            code: 8,
            userInfo: [
                NSLocalizedDescriptionKey: "Failed reference: /Users/example/Private/reference.wav prompt: Say the private phrase"
            ]
        )

        let payload = RemoteErrorPayload.make(for: error)
        XCTAssertFalse(payload.message.contains("/Users/example"))
        XCTAssertFalse(payload.message.contains("Say the private phrase"))
        XCTAssertTrue(payload.message.contains("<redacted"))
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
        XCTAssertEqual(decoded.schemaVersion, EngineRequestEnvelope.currentSchemaVersion)
    }

    func testRequestEnvelopeRoundTripsInteractivePrefetchCommand() throws {
        let request = EngineRequestEnvelope(
            id: UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!,
            command: .prefetchInteractiveReadinessIfNeeded(
                request: GenerationRequest(
                    modelID: "pro_custom",
                    text: "Hi.",
                    outputPath: "",
                    shouldStream: true,
                    streamingInterval: 0.32,
                    payload: .custom(speakerID: "vivian", deliveryStyle: "Neutral")
                ),
                customPrewarmDepth: "skip-stream-step"
            )
        )

        let encoded = try EngineServiceCodec.encode(request)
        let decoded = try EngineServiceCodec.decode(EngineRequestEnvelope.self, from: encoded)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.schemaVersion, EngineRequestEnvelope.currentSchemaVersion)
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
        XCTAssertEqual(decoded.schemaVersion, EngineReplyEnvelope.currentSchemaVersion)
    }

    func testReplyEnvelopeRoundTripsCapabilities() throws {
        let reply = EngineReplyEnvelope(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            reply: .capabilities(.macOSXPCDefault)
        )

        let encoded = try EngineServiceCodec.encode(reply)
        let decoded = try EngineServiceCodec.decode(EngineReplyEnvelope.self, from: encoded)

        XCTAssertEqual(decoded, reply)
        XCTAssertEqual(decoded.schemaVersion, EngineReplyEnvelope.currentSchemaVersion)
    }

    func testReplyEnvelopeRoundTripsInteractivePrefetchDiagnostics() throws {
        let reply = EngineReplyEnvelope(
            id: UUID(uuidString: "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            reply: .interactivePrefetchDiagnostics(
                InteractivePrefetchDiagnostics(
                    timingsMS: [
                        "custom_prewarm_eval_ms": 42,
                        "custom_stream_step_warm_ms": 7,
                    ],
                    booleanFlags: [
                        "custom_prefix_cache_hit": true,
                        "decoder_bucket_cache_hit": false,
                    ],
                    requestKey: "custom|vivian|normal"
                )
            )
        )

        let encoded = try EngineServiceCodec.encode(reply)
        let decoded = try EngineServiceCodec.decode(EngineReplyEnvelope.self, from: encoded)

        XCTAssertEqual(decoded, reply)
        XCTAssertEqual(decoded.schemaVersion, EngineReplyEnvelope.currentSchemaVersion)
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
        XCTAssertEqual(event.schemaVersion, EngineEventEnvelope.currentSchemaVersion)
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
        XCTAssertEqual(decoded.schemaVersion, QwenVoiceCore.ExtensionEngineRequestEnvelope.currentSchemaVersion)
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
        XCTAssertEqual(snapshotEvent.schemaVersion, QwenVoiceCore.ExtensionEngineEventEnvelope.currentSchemaVersion)
        XCTAssertEqual(
            try QwenVoiceCore.ExtensionEngineCodec.decode(
                QwenVoiceCore.ExtensionEngineEventEnvelope.self,
                from: QwenVoiceCore.ExtensionEngineCodec.encode(chunkEvent)
            ),
            chunkEvent
        )
    }

    func testWireEnvelopeDecodesLegacyMissingSchemaVersionAsVersionOne() throws {
        let request = EngineRequestEnvelope(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            command: .ping
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: EngineServiceCodec.encode(request)) as? [String: Any]
        )
        object.removeValue(forKey: "schemaVersion")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try EngineServiceCodec.decode(EngineRequestEnvelope.self, from: legacyData)
        XCTAssertEqual(decoded.schemaVersion, QwenVoiceWireSchema.legacyMissingVersion)
        XCTAssertEqual(decoded.command, .ping)
    }

    func testExtensionWireEnvelopeDecodesLegacyMissingSchemaVersionAsVersionOne() throws {
        let request = QwenVoiceCore.ExtensionEngineRequestEnvelope(
            id: UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!,
            command: .ping
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: QwenVoiceCore.ExtensionEngineCodec.encode(request)) as? [String: Any]
        )
        object.removeValue(forKey: "schemaVersion")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try QwenVoiceCore.ExtensionEngineCodec.decode(
            QwenVoiceCore.ExtensionEngineRequestEnvelope.self,
            from: legacyData
        )
        XCTAssertEqual(decoded.schemaVersion, QwenVoiceWireSchema.legacyMissingVersion)
        XCTAssertEqual(decoded.command, .ping)
    }

    func testWireEnvelopeRejectsFutureSchemaVersion() throws {
        let request = EngineRequestEnvelope(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            command: .ping
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: EngineServiceCodec.encode(request)) as? [String: Any]
        )
        object["schemaVersion"] = 99
        let futureData = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try EngineServiceCodec.decode(EngineRequestEnvelope.self, from: futureData)
        )
    }
}
