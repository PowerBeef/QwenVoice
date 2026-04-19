import XCTest
@testable import QwenVoiceEngineSupport

final class EngineServiceCodecTests: XCTestCase {
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
}
