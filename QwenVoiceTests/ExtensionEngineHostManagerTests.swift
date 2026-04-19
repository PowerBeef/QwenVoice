import XCTest
@testable import QwenVoiceCore

final class ExtensionEngineHostManagerTests: XCTestCase {
    func testHostManagerPrefersExpectedBundleIdentifier() async throws {
        let recorder = HostManagerTransportRecorder()
        let manager = ExtensionEngineHostManager<String>(
            expectedBundleIdentifier: "com.example.expected",
            candidateProvider: {
                [
                    ExtensionEngineHostCandidate(
                        bundleIdentifier: "com.example.other",
                        identity: "other"
                    ),
                    ExtensionEngineHostCandidate(
                        bundleIdentifier: "com.example.expected",
                        identity: "expected"
                    ),
                ]
            },
            transportFactory: { identity, _ in
                await recorder.makeTransport(identity: identity)
            }
        )

        _ = try await manager.makeTransport(handlers: .noop)

        let identities = await recorder.createdIdentities()
        XCTAssertEqual(identities, ["expected"])
        let activeBundleIdentifier = await manager.activeTransportBundleIdentifier()
        XCTAssertEqual(activeBundleIdentifier, "com.example.expected")
    }

    func testHostManagerFallsBackToFirstCandidate() async throws {
        let recorder = HostManagerTransportRecorder()
        let manager = ExtensionEngineHostManager<String>(
            expectedBundleIdentifier: "com.example.expected",
            candidateProvider: {
                [
                    ExtensionEngineHostCandidate(
                        bundleIdentifier: "com.example.first",
                        identity: "first"
                    ),
                    ExtensionEngineHostCandidate(
                        bundleIdentifier: "com.example.second",
                        identity: "second"
                    ),
                ]
            },
            transportFactory: { identity, _ in
                await recorder.makeTransport(identity: identity)
            }
        )

        _ = try await manager.makeTransport(handlers: .noop)

        let identities = await recorder.createdIdentities()
        XCTAssertEqual(identities, ["first"])
        let activeBundleIdentifier = await manager.activeTransportBundleIdentifier()
        XCTAssertEqual(activeBundleIdentifier, "com.example.first")
    }

    func testHostManagerThrowsWhenNoExtensionCandidateIsAvailable() async throws {
        let recorder = HostManagerTransportRecorder()
        let manager = ExtensionEngineHostManager<String>(
            expectedBundleIdentifier: "com.example.expected",
            candidateProvider: { [] },
            transportFactory: { identity, _ in
                await recorder.makeTransport(identity: identity)
            }
        )

        do {
            _ = try await manager.makeTransport(handlers: .noop)
            XCTFail("Expected host manager to throw when no extension candidates are available.")
        } catch let error as ExtensionEngineHostManagerError {
            XCTAssertEqual(error, .noAvailableExtension)
        }

        let identities = await recorder.createdIdentities()
        XCTAssertTrue(identities.isEmpty)
        let hasActiveTransport = await manager.hasActiveTransport()
        XCTAssertFalse(hasActiveTransport)
    }

    func testHostManagerInvalidatesPreviousTransportWhenReplacingConnection() async throws {
        let recorder = HostManagerTransportRecorder()
        let manager = ExtensionEngineHostManager<String>(
            expectedBundleIdentifier: "com.example.expected",
            candidateProvider: {
                [
                    ExtensionEngineHostCandidate(
                        bundleIdentifier: "com.example.expected",
                        identity: "expected"
                    )
                ]
            },
            transportFactory: { identity, _ in
                await recorder.makeTransport(identity: identity)
            }
        )

        _ = try await manager.makeTransport(handlers: .noop)
        _ = try await manager.makeTransport(handlers: .noop)

        let transports = await recorder.transports()
        XCTAssertEqual(transports.count, 2)
        XCTAssertEqual(transports[0].invalidateCount, 1)
        XCTAssertEqual(transports[1].invalidateCount, 0)
        let hasActiveTransport = await manager.hasActiveTransport()
        XCTAssertTrue(hasActiveTransport)
    }

    func testManagedTransportInvalidationClearsActiveTransport() async throws {
        let recorder = HostManagerTransportRecorder()
        let manager = ExtensionEngineHostManager<String>(
            expectedBundleIdentifier: "com.example.expected",
            candidateProvider: {
                [
                    ExtensionEngineHostCandidate(
                        bundleIdentifier: "com.example.expected",
                        identity: "expected"
                    )
                ]
            },
            transportFactory: { identity, _ in
                await recorder.makeTransport(identity: identity)
            }
        )

        let transport = try await manager.makeTransport(handlers: .noop)
        let hasActiveTransport = await manager.hasActiveTransport()
        XCTAssertTrue(hasActiveTransport)

        transport.invalidate()
        try await waitFor(
            predicate: {
                let hasActiveTransport = await manager.hasActiveTransport()
                return !hasActiveTransport
            },
            message: "Expected managed transport invalidation to clear the active session."
        )

        let transports = await recorder.transports()
        XCTAssertEqual(transports.count, 1)
        XCTAssertEqual(transports[0].invalidateCount, 1)
    }

    func testHostManagerInvalidatesFallbackTransportWhenPreferredCandidateAppears() async throws {
        let recorder = HostManagerTransportRecorder()
        let manager = ExtensionEngineHostManager<String>(
            expectedBundleIdentifier: "com.example.expected",
            candidateProvider: {
                [
                    ExtensionEngineHostCandidate(
                        bundleIdentifier: "com.example.first",
                        identity: "first"
                    )
                ]
            },
            transportFactory: { identity, _ in
                await recorder.makeTransport(identity: identity)
            }
        )

        _ = try await manager.makeTransport(handlers: .noop)
        await manager.handleAvailableCandidatesChanged([
            ExtensionEngineHostCandidate(
                bundleIdentifier: "com.example.first",
                identity: "first"
            ),
            ExtensionEngineHostCandidate(
                bundleIdentifier: "com.example.expected",
                identity: "expected"
            ),
        ])

        try await waitFor(
            predicate: {
                let hasActiveTransport = await manager.hasActiveTransport()
                return !hasActiveTransport
            },
            message: "Expected candidate update to invalidate the fallback transport."
        )

        let transports = await recorder.transports()
        XCTAssertEqual(transports.count, 1)
        XCTAssertEqual(transports[0].invalidateCount, 1)
    }

    func testHostManagerInvalidatesTransportWhenActiveCandidateDisappears() async throws {
        let recorder = HostManagerTransportRecorder()
        let manager = ExtensionEngineHostManager<String>(
            expectedBundleIdentifier: "com.example.expected",
            candidateProvider: {
                [
                    ExtensionEngineHostCandidate(
                        bundleIdentifier: "com.example.expected",
                        identity: "expected"
                    )
                ]
            },
            transportFactory: { identity, _ in
                await recorder.makeTransport(identity: identity)
            }
        )

        _ = try await manager.makeTransport(handlers: .noop)
        await manager.handleAvailableCandidatesChanged([])

        try await waitFor(
            predicate: {
                let hasActiveTransport = await manager.hasActiveTransport()
                return !hasActiveTransport
            },
            message: "Expected missing candidate set to invalidate the active transport."
        )

        let transports = await recorder.transports()
        XCTAssertEqual(transports.count, 1)
        XCTAssertEqual(transports[0].invalidateCount, 1)
    }

    private func waitFor(
        predicate: @escaping () async -> Bool,
        message: String,
        timeout: Duration = .seconds(1)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
    }
}

private actor HostManagerTransportRecorder {
    private var created: [(identity: String, transport: TestManagedExtensionTransport)] = []

    func makeTransport(identity: String) -> TestManagedExtensionTransport {
        let transport = TestManagedExtensionTransport(identity: identity)
        created.append((identity: identity, transport: transport))
        return transport
    }

    func createdIdentities() -> [String] {
        created.map(\.identity)
    }

    func transports() -> [TestManagedExtensionTransport] {
        created.map(\.transport)
    }
}

private final class TestManagedExtensionTransport: ExtensionEngineTransporting, @unchecked Sendable {
    let identity: String
    private(set) var invalidateCount = 0

    init(identity: String) {
        self.identity = identity
    }

    func resume() {}

    func invalidate() {
        invalidateCount += 1
    }

    func perform(_ payload: Data, reply: @escaping @Sendable (Data) -> Void) {
        reply(payload)
    }
}

private extension ExtensionEngineTransportHandlers {
    static let noop = ExtensionEngineTransportHandlers(
        onEventData: { _ in },
        onRemoteError: { _ in },
        onInterrupted: {},
        onInvalidated: {}
    )
}
