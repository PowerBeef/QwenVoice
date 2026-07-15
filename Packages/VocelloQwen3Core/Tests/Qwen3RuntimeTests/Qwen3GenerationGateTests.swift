@testable import MLXAudioTTS
import MLXAudioCore
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

    func testHolderFailureReleasesPermitToNextWaiter() async throws {
        enum FixtureError: Error { case failed }
        let gate = Qwen3TTSGenerationGate()
        do {
            _ = try await gate.withPermit { () async throws -> Int in
                throw FixtureError.failed
            }
            XCTFail("holder should throw")
        } catch FixtureError.failed {
            // Expected.
        }

        let value = try await gate.withPermit { 42 }
        XCTAssertEqual(value, 42)
    }

    func testDeterministicMixedAcquireCancelThrowStress() async throws {
        enum FixtureError: Error { case injected }
        let gate = Qwen3TTSGenerationGate()
        let tracker = OwnershipTracker()
        var tasks: [Task<Void, Error>] = []

        for index in 0..<240 {
            let task = Task {
                try await gate.withPermit {
                    await tracker.enter()
                    do {
                        if index.isMultiple(of: 11) { throw FixtureError.injected }
                        await Task.yield()
                        await tracker.leave()
                    } catch {
                        await tracker.leave()
                        throw error
                    }
                }
            }
            if index.isMultiple(of: 7) { task.cancel() }
            tasks.append(task)
        }

        for task in tasks {
            do { try await task.value }
            catch is CancellationError { }
            catch FixtureError.injected { }
        }
        while await tracker.currentCount != 0 { await Task.yield() }
        let peak = await tracker.peak
        let queued = await gate.queuedWaiterCount
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(queued, 0)
        _ = try await gate.withPermit { true }
    }
}

final class Qwen3LearnedComponentWeightTests: XCTestCase {
    func testSpeakerComponentLoadingRejectsMissingWeights() {
        XCTAssertThrowsError(
            try Qwen3TTSModel.speakerEncoderWeightsForLoading([:])
        )
    }

    func testSpeechTokenizerLoadingRejectsMissingWeights() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen3-tokenizer-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = """
        {
          "decoder_config": {
            "latent_dim": 8,
            "codebook_dim": 8,
            "codebook_size": 2048,
            "decoder_dim": 16,
            "hidden_size": 8,
            "intermediate_size": 16,
            "head_dim": 4,
            "num_attention_heads": 2,
            "num_hidden_layers": 1,
            "num_key_value_heads": 2,
            "num_quantizers": 16,
            "num_semantic_quantizers": 1,
            "semantic_codebook_size": 4096,
            "upsample_rates": [2],
            "upsampling_ratios": [2],
            "vector_quantization_hidden_dimension": 8
          }
        }
        """
        try Data(config.utf8).write(to: directory.appendingPathComponent("config.json"))

        do {
            _ = try await Qwen3TTSModel.loadSpeechTokenizer(
                path: directory,
                trustPreparedCheckpoint: false,
                includeEncoder: false,
                skipSpeechTokenizerEval: true,
                diagnosticEventSink: nil
            )
            XCTFail("real speech-tokenizer loader must reject an empty weight directory")
        } catch AudioGenerationError.invalidInput(let message) {
            XCTAssertTrue(message.contains("speech_tokenizer"))
        }
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
    var currentCount: Int { current }

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
