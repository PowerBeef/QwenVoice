import Synchronization
@testable import QwenVoiceCore
import XCTest

final class RecoverableStoreCoordinatorTests: XCTestCase {
    private enum FixtureFailure: Error, Equatable, Sendable {
        case unavailable
    }

    func testExplicitRetryReopensAfterInitialFailure() throws {
        let attempts = Mutex(0)
        let shouldSucceed = Mutex(false)
        let coordinator = RecoverableStoreCoordinator<String, FixtureFailure>(
            openStore: {
                attempts.withLock { $0 += 1 }
                guard shouldSucceed.withLock({ $0 }) else {
                    throw FixtureFailure.unavailable
                }
                return "recovered"
            },
            classify: { ($0 as? FixtureFailure) ?? .unavailable }
        )

        XCTAssertThrowsError(try coordinator.requireStore())
        XCTAssertEqual(attempts.withLock { $0 }, 1)

        shouldSucceed.withLock { $0 = true }
        XCTAssertEqual(try coordinator.reopenIfNeeded(), "recovered")
        XCTAssertEqual(try coordinator.requireStore(), "recovered")
        XCTAssertEqual(attempts.withLock { $0 }, 2)
    }

    func testFailedRetryRemainsFailClosedUntilLaterRecovery() throws {
        let attempts = Mutex(0)
        let coordinator = RecoverableStoreCoordinator<Int, FixtureFailure>(
            openStore: {
                let attempt = attempts.withLock { value in
                    value += 1
                    return value
                }
                guard attempt >= 3 else { throw FixtureFailure.unavailable }
                return 42
            },
            classify: { ($0 as? FixtureFailure) ?? .unavailable }
        )

        XCTAssertThrowsError(try coordinator.requireStore())
        XCTAssertThrowsError(try coordinator.reopenIfNeeded())
        XCTAssertThrowsError(try coordinator.requireStore())
        XCTAssertEqual(try coordinator.reopenIfNeeded(), 42)
        XCTAssertEqual(try coordinator.requireStore(), 42)
        XCTAssertEqual(attempts.withLock { $0 }, 3)
    }
}
