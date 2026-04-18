import XCTest
@testable import QwenVoiceEngineSupport

final class EngineServiceCodecTests: XCTestCase {
    func testCommandRoundTripsThroughCodec() throws {
        let command = EngineCommand.generateBatch(
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

        let encoded = try EngineServiceCodec.encode(command)
        let decoded = try EngineServiceCodec.decode(EngineCommand.self, from: encoded)

        XCTAssertEqual(decoded, command)
    }

    func testReplyRoundTripsGenerationResult() throws {
        let reply = EngineReply.generationResult(
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

        let encoded = try EngineServiceCodec.encode(reply)
        let decoded = try EngineServiceCodec.decode(EngineReply.self, from: encoded)

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
                requestID: "request-1",
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
