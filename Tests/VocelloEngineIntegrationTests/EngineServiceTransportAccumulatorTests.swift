import Foundation
import QwenVoiceCore
@testable import QwenVoiceEngineSupport
import XCTest

final class EngineServiceTransportAccumulatorTests: XCTestCase {
    func testDetectsMissingDuplicateAndOutOfOrderChunks() {
        let id = UUID()
        var accumulator = EngineServiceTransportAccumulator(telemetryEnabled: true)
        _ = accumulator.observe(event: chunk(id: id, sequence: 0))
        _ = accumulator.observe(event: chunk(id: id, sequence: 2))
        _ = accumulator.observe(event: chunk(id: id, sequence: 2))
        _ = accumulator.observe(event: chunk(id: id, sequence: 1))

        XCTAssertEqual(accumulator.snapshot.chunksForwarded, 4)
        XCTAssertEqual(accumulator.snapshot.chunkGaps, 1)
        XCTAssertEqual(accumulator.snapshot.duplicateChunks, 1)
        XCTAssertEqual(accumulator.snapshot.outOfOrderChunks, 1)
    }

    func testCancellationAndTerminalAgreementProducesOneTerminalRecord() throws {
        let id = UUID()
        var accumulator = EngineServiceTransportAccumulator(telemetryEnabled: true)
        _ = accumulator.observe(event: chunk(id: id, sequence: 0))
        let first = accumulator.observe(event: .failed("Generation cancelled"))
        let duplicate = accumulator.observe(event: .failed("Generation cancelled"))

        XCTAssertEqual(first?.transportMetrics?.finishReason, .cancelled)
        XCTAssertEqual(first?.transportMetrics?.cancellation, .completed)
        XCTAssertNil(duplicate)
        XCTAssertEqual(accumulator.snapshot.terminalCount, 1)
        XCTAssertEqual(accumulator.snapshot.finishReason, .cancelled)
    }

    func testGenerationSwitchPublishesSupersededTerminalBeforeNewChunks() {
        let firstID = UUID()
        let secondID = UUID()
        var accumulator = EngineServiceTransportAccumulator(telemetryEnabled: true)
        _ = accumulator.observe(event: chunk(id: firstID, sequence: 0))
        let superseded = accumulator.observe(event: chunk(id: secondID, sequence: 0))

        XCTAssertEqual(superseded?.transportMetrics?.finishReason, .superseded)
        XCTAssertEqual(accumulator.snapshot.generationID, secondID)
        XCTAssertEqual(accumulator.snapshot.chunksForwarded, 1)
    }

    func testTelemetryDisabledBuildsNoDurableRecord() {
        let id = UUID()
        var accumulator = EngineServiceTransportAccumulator(telemetryEnabled: false)
        _ = accumulator.observe(event: chunk(id: id, sequence: 0))
        let terminal = accumulator.observe(event: .failed("cancelled"))
        XCTAssertNil(terminal)
        XCTAssertEqual(accumulator.snapshot.terminalCount, 0)
    }

    private func chunk(id: UUID, sequence: UInt64) -> GenerationEvent {
        .chunk(
            GenerationChunk(
                generationID: id,
                mode: "custom",
                title: "fixture",
                chunkPath: nil,
                isFinal: false,
                chunkDurationSeconds: nil,
                cumulativeDurationSeconds: nil,
                streamSessionDirectory: nil,
                chunkSequence: sequence
            )
        )
    }
}
