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

private enum TestMemoryPressureAction: Equatable, Sendable {
    case observed(NativeMemoryTrimLevel)
    case cancellationRequested(GenerationCancellationReason)
    case workerTerminated
    case terminalBarrierPassed
    case trimmed(NativeMemoryTrimLevel, String)
}

private actor TestMemoryPressureActionLog {
    private struct Waiter {
        let minimumCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var actions: [TestMemoryPressureAction] = []
    private var waiters: [Waiter] = []

    func append(_ action: TestMemoryPressureAction) {
        actions.append(action)
        let ready = waiters.filter { actions.count >= $0.minimumCount }
        waiters.removeAll { actions.count >= $0.minimumCount }
        ready.forEach { $0.continuation.resume() }
    }

    func waitForCount(_ minimumCount: Int) async {
        guard actions.count < minimumCount else { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(minimumCount: minimumCount, continuation: continuation))
        }
    }

    func snapshot() -> [TestMemoryPressureAction] {
        actions
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

    func testCriticalKernelPressureWaitsForTypedCancellationBarrierBeforeHardTrim() async throws {
        let coordinator = ActiveGenerationCoordinator()
        let terminalGate = TestGenerationGate()
        let actions = TestMemoryPressureActionLog()
        let worker = Task {
            await terminalGate.wait()
            await actions.append(.workerTerminated)
        }
        let registration = try await coordinator.register(
            cancel: { worker.cancel() },
            waitForTermination: { _ = await worker.result }
        )
        let executor = NativeMemoryPressureResponseExecutor(
            recordObservation: { level in
                await actions.append(.observed(level))
            },
            cancelActiveGeneration: { reason in
                await actions.append(.cancellationRequested(reason))
                await coordinator.cancelCurrent(reason: reason)
                await actions.append(.terminalBarrierPassed)
            },
            trim: { level, reason in
                await actions.append(.trimmed(level, reason))
            }
        )

        let response = Task {
            await executor.execute(
                level: .hardTrim,
                reason: "test_kernel_pressure_hardTrim"
            )
        }

        await actions.waitForCount(2)
        let beforeTerminal = await actions.snapshot()
        XCTAssertEqual(
            beforeTerminal,
            [
                .observed(.hardTrim),
                .cancellationRequested(.memoryPressure),
            ]
        )
        XCTAssertFalse(
            beforeTerminal.contains {
                if case .trimmed(_, _) = $0 { return true }
                return false
            },
            "Hard trim must not run before the generation terminal barrier"
        )
        let activeBeforeTerminal = await coordinator.hasActiveGeneration
        XCTAssertTrue(activeBeforeTerminal)

        await terminalGate.open()
        await response.value

        let afterTerminal = await actions.snapshot()
        XCTAssertEqual(
            afterTerminal,
            [
                .observed(.hardTrim),
                .cancellationRequested(.memoryPressure),
                .workerTerminated,
                .terminalBarrierPassed,
                .trimmed(.hardTrim, "test_kernel_pressure_hardTrim"),
            ]
        )
        let terminalReason = await coordinator.finish(registration)
        XCTAssertEqual(terminalReason, .memoryPressure)
    }

    func testWarningKernelPressureSoftTrimsWithoutCancellingGeneration() async {
        let actions = TestMemoryPressureActionLog()
        let executor = NativeMemoryPressureResponseExecutor(
            recordObservation: { level in
                await actions.append(.observed(level))
            },
            cancelActiveGeneration: { reason in
                await actions.append(.cancellationRequested(reason))
            },
            trim: { level, reason in
                await actions.append(.trimmed(level, reason))
            }
        )

        await executor.execute(
            level: .softTrim,
            reason: "test_kernel_pressure_softTrim"
        )

        let recorded = await actions.snapshot()
        XCTAssertEqual(
            recorded,
            [
                .observed(.softTrim),
                .trimmed(.softTrim, "test_kernel_pressure_softTrim"),
            ]
        )
    }
}
