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
        let cancellation = GenerationCancellationSummary(generationID: id, reason: .user)
        let first = accumulator.observe(event: .cancelled(cancellation))
        let duplicate = accumulator.observe(event: .cancelled(cancellation))

        XCTAssertEqual(first?.transportMetrics?.finishReason, .cancelled)
        XCTAssertEqual(first?.transportMetrics?.cancellation, .completed)
        XCTAssertNil(duplicate)
        XCTAssertEqual(accumulator.snapshot.terminalCount, 1)
        XCTAssertEqual(accumulator.snapshot.finishReason, .cancelled)
    }

    func testFailureTextCannotMasqueradeAsTypedCancellation() throws {
        let id = UUID()
        var accumulator = EngineServiceTransportAccumulator(telemetryEnabled: true)
        _ = accumulator.observe(event: chunk(id: id, sequence: 0))

        let terminal = try XCTUnwrap(
            accumulator.observe(event: .failed("Transport failed after cancellation acknowledgement"))
        )

        XCTAssertEqual(terminal.transportMetrics?.finishReason, .failed)
        XCTAssertEqual(accumulator.snapshot.finishReason, .failed)
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

    func testRequestAcceptanceProducesRealRequestToFirstChunkLatency() throws {
        let id = UUID()
        let accepted = ProcessInfo.processInfo.systemUptime - 0.125
        var accumulator = EngineServiceTransportAccumulator(telemetryEnabled: true)
        _ = accumulator.observe(
            event: chunk(id: id, sequence: 0),
            requestAcceptedUptime: accepted
        )
        let terminal = try XCTUnwrap(
            accumulator.observe(
                event: .cancelled(
                    GenerationCancellationSummary(generationID: id, reason: .user)
                )
            )
        )

        let latency = try XCTUnwrap(terminal.transportMetrics?.requestToFirstChunkMS)
        XCTAssertGreaterThanOrEqual(latency, 100)
        XCTAssertLessThan(latency, 500)
        XCTAssertEqual(terminal.timingsMS["requestToFirstChunkMS"], latency)
        XCTAssertEqual(terminal.transportMetrics?.requestAccepted, true)
    }

    func testTelemetryDisabledBuildsNoDurableRecord() {
        let id = UUID()
        var accumulator = EngineServiceTransportAccumulator(telemetryEnabled: false)
        _ = accumulator.observe(event: chunk(id: id, sequence: 0))
        let terminal = accumulator.observe(
            event: .cancelled(
                GenerationCancellationSummary(generationID: id, reason: .user)
            )
        )
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
