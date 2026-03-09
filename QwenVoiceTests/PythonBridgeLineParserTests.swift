import XCTest
@testable import QwenVoice

@MainActor
final class PythonBridgeLineParserTests: XCTestCase {
    func testSuccessResponseDecodesResultPayload() {
        let line = #"{"jsonrpc":"2.0","id":7,"result":{"status":"ok","size_bytes":123}}"#

        let response = PythonBridgeLineParser.parse(line)

        XCTAssertEqual(response?.id, 7)
        XCTAssertEqual(response?.resultDict["status"]?.stringValue, "ok")
        XCTAssertEqual(response?.resultDict["size_bytes"]?.intValue, 123)
        XCTAssertFalse(response?.isNotification ?? true)
    }

    func testRPCErrorDecodesErrorPayload() {
        let line = #"{"jsonrpc":"2.0","id":9,"error":{"code":-32000,"message":"No model loaded"}}"#

        let response = PythonBridgeLineParser.parse(line)

        XCTAssertEqual(response?.id, 9)
        XCTAssertEqual(response?.error, RPCError(code: -32000, message: "No model loaded"))
    }

    func testProgressNotificationDecodesAndIsHandled() {
        let line = #"{"jsonrpc":"2.0","method":"progress","params":{"percent":45,"message":"Generating audio..."}}"#

        let response = PythonBridgeLineParser.parse(line)

        XCTAssertEqual(response?.method, "progress")
        XCTAssertTrue(response?.isNotification ?? false)
        XCTAssertTrue(response.map(PythonBridgeLineParser.isHandledNotification) ?? false)
        XCTAssertEqual(response?.params?["percent"]?.intValue, 45)
        XCTAssertEqual(response?.params?["message"]?.stringValue, "Generating audio...")
    }

    func testGenerationChunkNotificationIsHandledByAppHandling() {
        let line = #"{"jsonrpc":"2.0","method":"generation_chunk","params":{"request_id":1,"chunk_index":0,"chunk_path":"/tmp/chunk.wav","is_final":false}}"#

        let response = PythonBridgeLineParser.parse(line)

        XCTAssertEqual(response?.method, "generation_chunk")
        XCTAssertTrue(response?.isNotification ?? false)
        XCTAssertTrue(response.map(PythonBridgeLineParser.isHandledNotification) ?? false)
    }

    func testMalformedLineReturnsNil() {
        XCTAssertNil(PythonBridgeLineParser.parse("not json"))
    }

    func testCanSkipLoadModelWhenSameModelIsKnownLoaded() {
        XCTAssertTrue(PythonBridge.canSkipLoadModel(requestedID: "pro_custom", loadedModelID: "pro_custom"))
    }

    func testCanSkipLoadModelReturnsFalseWhenModelDiffers() {
        XCTAssertFalse(PythonBridge.canSkipLoadModel(requestedID: "pro_design", loadedModelID: "pro_custom"))
        XCTAssertFalse(PythonBridge.canSkipLoadModel(requestedID: "pro_design", loadedModelID: nil))
    }

    func testGenerationResultParsesStreamingMetrics() {
        let result = GenerationResult(from: [
            "audio_path": .string("/tmp/output.wav"),
            "duration_seconds": .double(4.2),
            "stream_session_dir": .string("/tmp/stream-session"),
            "metrics": .object([
                "token_count": .int(99),
                "processing_time_seconds": .double(2.4),
                "peak_memory_usage": .double(1.3),
                "streaming_used": .bool(true),
                "prepared_clone_used": .bool(true),
                "clone_cache_hit": .bool(true),
                "first_chunk_ms": .int(240),
            ]),
        ])

        XCTAssertEqual(result.audioPath, "/tmp/output.wav")
        XCTAssertEqual(result.durationSeconds, 4.2)
        XCTAssertEqual(result.streamSessionDirectory, "/tmp/stream-session")
        XCTAssertTrue(result.usedStreaming)
        XCTAssertEqual(result.metrics?.tokenCount, 99)
        XCTAssertEqual(result.metrics?.processingTimeSeconds, 2.4)
        XCTAssertEqual(result.metrics?.peakMemoryUsage, 1.3)
        XCTAssertEqual(result.metrics?.preparedCloneUsed, true)
        XCTAssertEqual(result.metrics?.cloneCacheHit, true)
        XCTAssertEqual(result.metrics?.firstChunkMs, 240)
    }
}
