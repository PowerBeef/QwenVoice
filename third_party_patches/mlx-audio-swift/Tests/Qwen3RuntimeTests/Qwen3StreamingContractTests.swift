@testable import MLXAudioTTS
import XCTest

final class Qwen3StreamingContractTests: XCTestCase {
    func testPendingRetentionIsBoundedAndFirstLaterSchedulingIsExact() {
        var schedule = Qwen3StreamChunkSchedule(firstChunkSize: 3, laterChunkSize: 7)
        var emissionSteps: [Int] = []
        for step in 1...24 {
            if schedule.append() {
                emissionSteps.append(step)
                schedule.didEmit()
            }
        }
        XCTAssertEqual(emissionSteps, [3, 10, 17, 24])
        XCTAssertEqual(schedule.peakPendingCount, 7)
        XCTAssertEqual(schedule.pendingCount, 0)
    }

    func testCancellationStopsConsumerAndRunsTermination() async throws {
        let terminated = expectation(description: "producer termination")
        let stream = AsyncThrowingStream<Int, Error> { continuation in
            continuation.onTermination = { _ in terminated.fulfill() }
            let producer = Task {
                var value = 0
                while !Task.isCancelled {
                    continuation.yield(value)
                    value += 1
                    await Task.yield()
                }
                continuation.finish(throwing: CancellationError())
            }
            continuation.onTermination = { _ in
                producer.cancel()
                terminated.fulfill()
            }
        }
        let consumer = Task {
            for try await _ in stream {
                try Task.checkCancellation()
            }
        }
        consumer.cancel()
        do { try await consumer.value } catch is CancellationError { }
        await fulfillment(of: [terminated], timeout: 2)
    }

    func testFinalAudioBarrierOrdersLastChunkBeforeCompletion() async throws {
        let events = EventOrder()
        let stream = AsyncThrowingStream<Int, Error> { continuation in
            continuation.yield(1)
            continuation.yield(2)
            continuation.finish()
        }
        for try await value in stream {
            await events.append("chunk-\(value)")
        }
        await events.append("completion")
        let order = await events.values
        XCTAssertEqual(order, ["chunk-1", "chunk-2", "completion"])
    }
}

private actor EventOrder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
