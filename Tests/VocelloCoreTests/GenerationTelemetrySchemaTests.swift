import Foundation
@testable import QwenVoiceCore
import XCTest

final class GenerationTelemetrySchemaTests: XCTestCase {
    func testSubmillisecondStageMarksSortByNanosecondsBeforeStageName() {
        let ended = NativeTelemetryStageMark(
            tMS: 2_915,
            tNS: 2_915_286_041,
            sequence: 2,
            stage: "streamGenerationEnded"
        )
        let completed = NativeTelemetryStageMark(
            tMS: 2_915,
            tNS: 2_915_749_416,
            sequence: 3,
            stage: "streamCompleted"
        )

        let sorted = [completed, ended].sorted(by: NativeTelemetryStageMark.chronologicallyPrecedes)

        XCTAssertEqual(sorted.map(\.stage), ["streamGenerationEnded", "streamCompleted"])
        XCTAssertEqual(sorted.map(\.sequence), [2, 3])
    }

    func testSchemaV6RoundTripCarriesTypedBackendMetrics() throws {
        let record = GenerationTelemetryRecord(
            generationID: UUID().uuidString,
            layer: .engine,
            recordedAt: "2026-07-10T00:00:00Z",
            mode: "custom",
            warmState: .warm,
            usedStreaming: true,
            finishReason: "eos",
            stageMarks: [NativeTelemetryStageMark(tMS: 4, tNS: 4_000_000, sequence: 0, stage: "firstChunk")],
            timingsMS: [
                "qwen_token_loop_total": 120,
                "qwen_stream_decoder_total": 30,
            ],
            counters: ["chunkCount": 2]
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(GenerationTelemetryRecord.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 6)
        XCTAssertEqual(decoded.backendMetrics?.finishReason, .eos)
        XCTAssertEqual(decoded.backendMetrics?.warmState, .warm)
        XCTAssertEqual(decoded.backendMetrics?.stages.count, 1)
        XCTAssertEqual(
            decoded.backendMetrics?.timings.first(where: { $0.key == .tokenLoop })?.milliseconds,
            120
        )
    }

    func testLegacyV5RowDecodesWithoutTypedPayloads() throws {
        let json = """
        {
          "schemaVersion": 5,
          "generationID": "legacy",
          "layer": "engine",
          "processName": "fixture",
          "processIdentifier": 1,
          "recordedAt": "2026-07-10T00:00:00Z",
          "stageMarks": [],
          "timingsMS": {"qwen_token_loop_total": 10},
          "counters": {},
          "notes": {}
        }
        """

        let decoded = try JSONDecoder().decode(
            GenerationTelemetryRecord.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(decoded.schemaVersion, 5)
        XCTAssertNil(decoded.backendMetrics)
        XCTAssertEqual(decoded.timingsMS["qwen_token_loop_total"], 10)
    }

    func testLegacyV1ThroughV5RowsRemainDecodable() throws {
        for version in 1...5 {
            let json = """
            {
              "schemaVersion": \(version),
              "generationID": "legacy-\(version)",
              "layer": "engine",
              "processName": "fixture",
              "processIdentifier": 1,
              "recordedAt": "2026-07-10T00:00:00Z",
              "stageMarks": [],
              "timingsMS": {},
              "counters": {},
              "notes": {}
            }
            """
            let decoded = try JSONDecoder().decode(
                GenerationTelemetryRecord.self,
                from: Data(json.utf8)
            )
            XCTAssertEqual(decoded.schemaVersion, version)
            XCTAssertNil(decoded.frontendMetrics)
            XCTAssertNil(decoded.transportMetrics)
            XCTAssertNil(decoded.backendMetrics)
            XCTAssertNil(decoded.outputMetrics)
        }
    }

    func testTelemetryOffPlansNoSamplerSinkChunkQCOrDerivedDiagnostics() {
        let off = NativeTelemetryWorkPlan(
            mode: .off,
            recorderPresent: true,
            sampleIntervalAvailable: true
        )
        XCTAssertFalse(off.constructsSampler)
        XCTAssertFalse(off.writesSink)
        XCTAssertFalse(off.computesChunkQC)
        XCTAssertFalse(off.computesDerivedDiagnostics)

        let verbose = NativeTelemetryWorkPlan(
            mode: .verbose,
            recorderPresent: true,
            sampleIntervalAvailable: true
        )
        XCTAssertTrue(verbose.constructsSampler)
        XCTAssertTrue(verbose.writesSink)
        XCTAssertTrue(verbose.computesChunkQC)
        XCTAssertTrue(verbose.computesDerivedDiagnostics)
    }

    func testTransportAdapterPreservesGapAndTerminalSemantics() {
        let metrics = GenerationTelemetryCompatibilityAdapter.transport(
            finishReason: "cancelled",
            timingsMS: ["chunkForwardingSpanMS": 42],
            counters: ["chunksForwarded": 4, "chunkGaps": 1]
        )

        XCTAssertEqual(metrics.finishReason, .cancelled)
        XCTAssertEqual(metrics.cancellation, .completed)
        XCTAssertEqual(metrics.firstChunkToTerminalMS, 42)
        XCTAssertEqual(metrics.counters.chunksForwarded, 4)
        XCTAssertEqual(metrics.counters.chunkGaps, 1)
    }

    func testFrontendAdapterDoesNotRequireRawUserContent() {
        let metrics = GenerationTelemetryCompatibilityAdapter.frontend(
            timingsMS: ["submitToCompletedMS": 500],
            counters: ["uiStallCount50": 1]
        )

        XCTAssertEqual(metrics.submitToCompletedMS, 500)
        XCTAssertEqual(metrics.mainThreadStallCount50MS, 1)
    }

    func testFailurePrivacyAdapterDoesNotPersistRawMessageOrPath() {
        let sensitive = "failed for /Users/example/secret/reference.wav"
        let notes = GenerationTelemetryPrivacy.failureNotes(message: sensitive)

        XCTAssertEqual(notes["failureMessageLength"], String(sensitive.count))
        XCTAssertEqual(notes["failureMessageDigest"]?.count, 64)
        XCTAssertFalse(notes.values.contains(where: { $0.contains("secret") || $0.contains("/Users/") }))
    }
}
