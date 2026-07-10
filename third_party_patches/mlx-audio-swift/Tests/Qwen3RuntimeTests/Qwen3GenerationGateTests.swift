@testable import MLXAudioTTS
import XCTest

final class Qwen3GenerationGateTests: XCTestCase {
    func testWaitersAcquireInFIFOOrder() async throws {
        let gate = Qwen3TTSGenerationGate()
        let order = AcquisitionOrder()
        try await gate.acquire()

        var tasks: [Task<Void, Error>] = []
        for index in 0..<4 {
            tasks.append(Task {
                try await gate.acquire()
                await order.append(index)
                await gate.release()
            })
            while await gate.queuedWaiterCount < index + 1 {
                await Task.yield()
            }
        }

        await gate.release()
        for task in tasks { try await task.value }
        let recordedOrder = await order.values
        XCTAssertEqual(recordedOrder, [0, 1, 2, 3])
    }

    func testQueuedCancellationDoesNotReleaseCurrentOwner() async throws {
        let gate = Qwen3TTSGenerationGate()
        try await gate.acquire()

        let cancelled = Task {
            try await gate.acquire()
        }
        while await gate.queuedWaiterCount < 1 {
            await Task.yield()
        }
        cancelled.cancel()

        do {
            try await cancelled.value
            XCTFail("queued acquisition should be cancelled")
        } catch is CancellationError {
            // Expected.
        }

        let nextAcquired = expectation(description: "next waiter acquires")
        let next = Task {
            try await gate.acquire()
            nextAcquired.fulfill()
        }
        await gate.release()
        await fulfillment(of: [nextAcquired], timeout: 2)
        try await next.value
        await gate.release()
    }

    func testCancellationImmediatelyAfterTransferReleasesPermit() async throws {
        let transfer = TransferPause()
        let gate = Qwen3TTSGenerationGate(afterTransferHook: {
            await transfer.pause()
        })
        try await gate.acquire()

        let transferred = Task {
            try await gate.acquire()
        }
        while await gate.queuedWaiterCount < 1 {
            await Task.yield()
        }
        await gate.release()
        await transfer.waitUntilEntered()
        transferred.cancel()
        await transfer.resume()

        do {
            try await transferred.value
            XCTFail("transferred acquisition should observe cancellation")
        } catch is CancellationError {
            // Expected; the catch in acquire must release the transferred permit.
        }

        let thirdAcquired = expectation(description: "third caller acquires")
        let third = Task {
            try await gate.acquire()
            thirdAcquired.fulfill()
        }
        await fulfillment(of: [thirdAcquired], timeout: 2)
        try await third.value
        await gate.release()
    }

    func testStressNeverAllowsConcurrentOwners() async throws {
        let gate = Qwen3TTSGenerationGate()
        let tracker = OwnershipTracker()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    try await gate.acquire()
                    await tracker.enter()
                    await Task.yield()
                    await tracker.leave()
                    await gate.release()
                }
            }
            try await group.waitForAll()
        }

        let peak = await tracker.peak
        XCTAssertEqual(peak, 1)
    }
}

final class Qwen3LearnedComponentWeightTests: XCTestCase {
    func testRequestedLearnedComponentRejectsEmptyWeights() {
        XCTAssertThrowsError(
            try Qwen3LearnedComponentWeights.requireNonEmpty(
                0,
                component: "speech_tokenizer"
            )
        )
    }

    func testRequestedLearnedComponentAcceptsVerifiedWeights() throws {
        XCTAssertNoThrow(
            try Qwen3LearnedComponentWeights.requireNonEmpty(
                1,
                component: "speaker_encoder"
            )
        )
    }
}

private actor TransferPause {
    private var entered = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor OwnershipTracker {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current -= 1
    }
}

private actor AcquisitionOrder {
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}
