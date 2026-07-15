import XCTest
@testable import QwenVoiceCore

private actor TestGenerationGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

final class ActiveGenerationCoordinatorTests: XCTestCase {
    func testCancellationRetainsOwnershipUntilTaskTerminates() async throws {
        let coordinator = ActiveGenerationCoordinator()
        let terminalGate = TestGenerationGate()
        let worker = Task {
            await terminalGate.wait()
        }
        let registration = try await coordinator.register(
            cancel: { worker.cancel() },
            waitForTermination: { _ = await worker.result }
        )

        let cancellation = Task {
            await coordinator.cancelCurrent(reason: .memoryPressure)
        }

        for _ in 0..<100 {
            if await coordinator.currentCancellationReason != nil { break }
            await Task.yield()
        }
        let cancellationReason = await coordinator.currentCancellationReason
        let isActiveWhileCancelling = await coordinator.hasActiveGeneration
        XCTAssertEqual(cancellationReason, .memoryPressure)
        XCTAssertTrue(isActiveWhileCancelling)

        await terminalGate.open()
        await cancellation.value

        let isActiveAfterCancellation = await coordinator.hasActiveGeneration
        let reasonAfterCancellation = await coordinator.currentCancellationReason
        XCTAssertFalse(isActiveAfterCancellation)
        XCTAssertNil(reasonAfterCancellation)

        let terminalReason = await coordinator.finish(registration)
        XCTAssertEqual(terminalReason, .memoryPressure)
        let isActiveAfterFinish = await coordinator.hasActiveGeneration
        let reasonAfterFinish = await coordinator.currentCancellationReason
        XCTAssertFalse(isActiveAfterFinish)
        XCTAssertNil(reasonAfterFinish)
    }

    func testFinishPreservesEveryTypedReasonAcrossEarlyCancellation() async throws {
        let reasons: [GenerationCancellationReason] = [
            .memoryPressure,
            .superseded,
            .shutdown,
        ]

        for expectedReason in reasons {
            let coordinator = ActiveGenerationCoordinator()
            let terminalGate = TestGenerationGate()
            let worker = Task {
                await terminalGate.wait()
                try Task.checkCancellation()
            }
            let registration = try await coordinator.register(
                cancel: { worker.cancel() },
                waitForTermination: { _ = await worker.result }
            )

            let cancellation = Task {
                await coordinator.cancelCurrent(reason: expectedReason)
            }
            for _ in 0..<100 {
                if await coordinator.currentCancellationReason != nil { break }
                await Task.yield()
            }

            await terminalGate.open()
            await cancellation.value

            let preservedReason = await coordinator.finish(registration)
            XCTAssertEqual(preservedReason, expectedReason)
            let reasonAfterFinish = await coordinator.currentCancellationReason
            XCTAssertNil(reasonAfterFinish)
        }
    }

    func testSecondGenerationIsRejectedWhileFirstOwnsEngine() async throws {
        let coordinator = ActiveGenerationCoordinator()
        let terminalGate = TestGenerationGate()
        let worker = Task {
            await terminalGate.wait()
        }
        let registration = try await coordinator.register(
            cancel: { worker.cancel() },
            waitForTermination: { _ = await worker.result }
        )

        do {
            _ = try await coordinator.register(cancel: {}, waitForTermination: {})
            XCTFail("A second generation must not acquire the engine")
        } catch let error as TTSEngineError {
            guard case .generationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        await terminalGate.open()
        _ = await worker.result
        await coordinator.finish(registration)
        let isActiveAfterFinish = await coordinator.hasActiveGeneration
        XCTAssertFalse(isActiveAfterFinish)
    }
}
