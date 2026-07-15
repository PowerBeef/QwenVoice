import XCTest
@testable import QwenVoiceCore

final class GenerationEventDeliveryProbeTests: XCTestCase {
    func testBoundedGenerationStreamAccountsForEvictedKindsAndPreservesTerminal() async {
        let router = GenerationScopedEventRouter()
        let generationID = UUID()
        let stream = router.stream(for: generationID, capacity: 1)
        router.beginGeneration(generationID)

        router.yield(.progress(GenerationProgress(percent: 10, message: "one")), for: generationID)
        router.yield(.progress(GenerationProgress(percent: 20, message: "two")), for: generationID)
        router.yield(.failed("fixture"), for: generationID)

        var received: [GenerationEvent] = []
        for await event in stream {
            received.append(event)
        }
        let snapshot = router.snapshot(for: generationID)
        XCTAssertEqual(received, [.failed("fixture")])
        XCTAssertEqual(snapshot.yielded, 3)
        XCTAssertEqual(snapshot.accepted, 3)
        XCTAssertEqual(snapshot.droppedProgress, 2)
        XCTAssertEqual(snapshot.droppedTerminals, 0)
        XCTAssertEqual(snapshot.terminalYielded, 1)
        XCTAssertEqual(snapshot.terminalEnqueued, 1)
        XCTAssertTrue(snapshot.terminalDeliveryComplete)
        XCTAssertTrue(snapshot.accountingIsExact)
    }

    func testPriorGenerationCannotOccupyNextGenerationBuffer() async {
        let router = GenerationScopedEventRouter()
        let oldID = UUID()
        let newID = UUID()
        let oldStream = router.stream(for: oldID, capacity: 1)
        let newStream = router.stream(for: newID, capacity: 1)
        router.beginGeneration(oldID)
        router.beginGeneration(newID)

        router.yield(.progress(GenerationProgress(percent: 1, message: "old")), for: oldID)
        router.yield(.failed("new-terminal"), for: newID)

        var newEvents: [GenerationEvent] = []
        for await event in newStream { newEvents.append(event) }
        XCTAssertEqual(newEvents, [.failed("new-terminal")])
        XCTAssertEqual(router.snapshot(for: newID).droppedTotal, 0)
        XCTAssertEqual(router.snapshot(for: newID).terminalEnqueued, 1)
        XCTAssertEqual(router.snapshot(for: oldID).yielded, 1)
        withExtendedLifetime(oldStream) {}
    }

    func testConsumerTerminationBeforeTerminalIsReportedExactly() async {
        let router = GenerationScopedEventRouter()
        let generationID = UUID()
        let stream = router.stream(for: generationID, capacity: 4)
        router.beginGeneration(generationID)
        let consumer = Task {
            for await _ in stream {}
        }
        consumer.cancel()
        await consumer.value

        router.yield(.failed("terminal-after-consumer"), for: generationID)

        let snapshot = router.snapshot(for: generationID)
        XCTAssertTrue(snapshot.consumerTerminatedBeforeTerminal)
        XCTAssertEqual(snapshot.yielded, 1)
        XCTAssertEqual(snapshot.unobserved, 1)
        XCTAssertEqual(snapshot.terminalYielded, 1)
        XCTAssertEqual(snapshot.terminalEnqueued, 0)
        XCTAssertFalse(snapshot.terminalDeliveryComplete)
        XCTAssertTrue(snapshot.accountingIsExact)
    }

    func testStressRetainsTerminalAndAccountsForEveryEvictedChunk() async {
        let router = GenerationScopedEventRouter()
        let generationID = UUID()
        let capacity = 8
        let stream = router.stream(for: generationID, capacity: capacity)
        router.beginGeneration(generationID)

        for index in 0..<1_000 {
            router.yield(Self.chunk(index: index, generationID: generationID), for: generationID)
        }
        router.yield(.completed(Self.result), for: generationID)

        var received: [GenerationEvent] = []
        for await event in stream { received.append(event) }
        let snapshot = router.snapshot(for: generationID)
        XCTAssertEqual(received.count, capacity)
        XCTAssertEqual(received.last, .completed(Self.result))
        XCTAssertEqual(snapshot.yielded, 1_001)
        XCTAssertEqual(snapshot.accepted, 1_001)
        XCTAssertEqual(snapshot.droppedChunks, 993)
        XCTAssertEqual(snapshot.droppedTerminals, 0)
        XCTAssertEqual(snapshot.terminalEnqueued, 1)
        XCTAssertTrue(snapshot.accountingIsExact)
    }

    private static func chunk(index: Int, generationID: UUID) -> GenerationEvent {
        .chunk(
            GenerationChunk(
                generationID: generationID,
                requestID: index,
                mode: "custom",
                title: "chunk",
                chunkPath: nil,
                isFinal: false,
                chunkDurationSeconds: nil,
                cumulativeDurationSeconds: nil,
                streamSessionDirectory: nil,
                chunkSequence: UInt64(index)
            )
        )
    }

    private static let result = GenerationResult(
        audioPath: "fixture.wav",
        durationSeconds: 1,
        streamSessionDirectory: nil,
        usedStreaming: true
    )
}
