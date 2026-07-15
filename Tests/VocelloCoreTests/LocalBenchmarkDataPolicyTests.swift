import Foundation
@testable import QwenVoiceCore
import XCTest

final class LocalBenchmarkDataPolicyTests: XCTestCase {
    func testNoExplicitDataDirectoryAlwaysUsesDebugRoot() {
        let base = URL(fileURLWithPath: "/tmp/Application Support", isDirectory: true)

        let resolved = LocalBenchmarkDataPolicy.resolvedDataDirectory(
            explicitOverride: nil,
            applicationSupportBase: base
        )

        XCTAssertEqual(resolved.path, "/tmp/Application Support/QwenVoice-Debug")
        XCTAssertNotEqual(resolved.path, "/tmp/Application Support/QwenVoice")
    }

    func testExplicitDataDirectoryIsPreserved() {
        let base = URL(fileURLWithPath: "/tmp/Application Support", isDirectory: true)
        let resolved = LocalBenchmarkDataPolicy.resolvedDataDirectory(
            explicitOverride: "/tmp/isolated-bench",
            applicationSupportBase: base
        )

        XCTAssertEqual(resolved.path, "/tmp/isolated-bench")
    }

    func testProductionDiagnosticsCannotBeClearedWithoutForce() {
        let production = URL(fileURLWithPath: "/tmp/Application Support/QwenVoice")
        XCTAssertFalse(
            LocalBenchmarkDataPolicy.mayClearDiagnostics(
                in: production,
                productionDataDirectory: production,
                force: false
            )
        )
        XCTAssertTrue(
            LocalBenchmarkDataPolicy.mayClearDiagnostics(
                in: production,
                productionDataDirectory: production,
                force: true
            )
        )
    }

    func testSymlinkAliasCannotBypassProductionClearGuard() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocello-bench-policy-\(UUID().uuidString)", isDirectory: true)
        let production = root.appendingPathComponent("QwenVoice", isDirectory: true)
        let alias = root.appendingPathComponent("bench-alias", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: production, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: production)

        XCTAssertFalse(
            LocalBenchmarkDataPolicy.mayClearDiagnostics(
                in: alias,
                productionDataDirectory: production,
                force: false
            )
        )
    }
}
