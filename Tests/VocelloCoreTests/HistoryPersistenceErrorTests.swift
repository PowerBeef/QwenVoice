import Darwin
import Foundation
import XCTest

final class HistoryPersistenceErrorTests: XCTestCase {
    func testClassifiesStorageAndPermissionFailuresWithoutLeakingSourceText() {
        let full = HistoryPersistenceError.classify(
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
            operation: .write
        )
        XCTAssertEqual(full, HistoryPersistenceError(operation: .write, failure: .storageFull))

        let denied = HistoryPersistenceError.classify(
            NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.Code.fileReadNoPermission.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "/" + "Users/private-user/history.sqlite"]
            ),
            operation: .read
        )
        XCTAssertEqual(denied.failure, .permissionDenied)
        XCTAssertFalse(try XCTUnwrap(denied.errorDescription).contains("/" + "Users/"))
    }

    func testClassifiesSQLiteCorruptionAndLockAsTypedFailures() {
        let corrupt = HistoryPersistenceError.classify(
            NSError(
                domain: "fixture.sqlite",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "database disk image is malformed at /private/data"]
            ),
            operation: .read
        )
        XCTAssertEqual(corrupt.failure, .corrupt)
        XCTAssertFalse(try XCTUnwrap(corrupt.errorDescription).contains("/private/data"))

        let locked = HistoryPersistenceError.classify(
            NSError(
                domain: "fixture.sqlite",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "database is locked"]
            ),
            operation: .delete
        )
        XCTAssertEqual(locked.failure, .locked)
        XCTAssertEqual(locked.operation, .delete)
    }

    func testMigrationFailuresPreserveTypedReasonAcrossLaterOperations() {
        let migration = HistoryPersistenceError.classify(
            NSError(domain: "fixture", code: 1),
            operation: .migrate
        )
        XCTAssertEqual(migration.failure, .migrationFailed)

        let read = migration.replacingOperation(.read)
        XCTAssertEqual(read.operation, .read)
        XCTAssertEqual(read.failure, .migrationFailed)
        XCTAssertTrue(try XCTUnwrap(read.errorDescription).contains("preserved"))
    }
}
