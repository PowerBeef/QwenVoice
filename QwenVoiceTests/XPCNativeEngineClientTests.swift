import XCTest
@testable import QwenVoiceNative

final class XPCNativeEngineClientTests: XCTestCase {
    private func invalidateAndDrain(_ clients: XPCNativeEngineClient...) async {
        for client in clients {
            await client.debugInvalidateConnectionForTesting()
        }
        try? await Task.sleep(for: .milliseconds(50))
    }

    func testClientInitializesAndPingsBundledEngineService() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let client = XPCNativeEngineClient()
        try await client.initialize(appSupportDirectory: root)

        let pingResult = try await client.ping()
        XCTAssertTrue(pingResult)
        XCTAssertTrue(client.snapshot.isReady)
        XCTAssertEqual(client.snapshot.loadState, .idle)
        XCTAssertNil(client.snapshot.visibleErrorMessage)

        await invalidateAndDrain(client)
    }

    func testClientPreparedVoiceLifecycleUsesEngineServiceAppSupportDirectory() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceAudio = root.appendingPathComponent("reference.wav")
        try NativeRuntimeTestSupport.writeTestWAV(to: sourceAudio, sampleRate: 24_000, channels: 1)

        let client = XPCNativeEngineClient()
        try await client.initialize(appSupportDirectory: root)

        let enrolled = try await client.enrollPreparedVoice(
            name: "XPC Test Voice",
            audioPath: sourceAudio.path,
            transcript: "hello from xpc"
        )
        XCTAssertEqual(enrolled.id, "XPC Test Voice")
        XCTAssertTrue(enrolled.audioPath.hasPrefix(root.appendingPathComponent("voices").path))

        let listed = try await client.listPreparedVoices()
        XCTAssertEqual(listed.map(\.id), ["XPC Test Voice"])
        XCTAssertTrue(listed.first?.hasTranscript ?? false)

        try await client.deletePreparedVoice(id: enrolled.id)
        let remainingVoices = try await client.listPreparedVoices()
        XCTAssertTrue(remainingVoices.isEmpty)

        await invalidateAndDrain(client)
    }

    func testClientReinitializesAfterConnectionInvalidation() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let client = XPCNativeEngineClient()
        try await client.initialize(appSupportDirectory: root)
        let initialPing = try await client.ping()
        XCTAssertTrue(initialPing)

        await client.debugInvalidateConnectionForTesting()

        for _ in 0..<20 where client.snapshot.isReady {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(client.snapshot.isReady)
        XCTAssertNotNil(client.snapshot.visibleErrorMessage)

        let reconnectPing = try await client.ping()
        XCTAssertTrue(reconnectPing)
        for _ in 0..<20 where !client.snapshot.isReady {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(client.snapshot.isReady)
        XCTAssertEqual(client.snapshot.loadState, .idle)
        XCTAssertNil(client.snapshot.visibleErrorMessage)

        await invalidateAndDrain(client)
    }

    func testSecondClientRemainsActiveWhenFirstConnectionInvalidates() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstClient = XPCNativeEngineClient()
        let secondClient = XPCNativeEngineClient()

        try await firstClient.initialize(appSupportDirectory: root)
        try await secondClient.initialize(appSupportDirectory: root)

        let firstPing = try await firstClient.ping()
        let secondInitialPing = try await secondClient.ping()
        XCTAssertTrue(firstPing)
        XCTAssertTrue(secondInitialPing)

        await firstClient.debugInvalidateConnectionForTesting()

        for _ in 0..<20 where secondClient.snapshot.visibleErrorMessage != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let secondPing = try await secondClient.ping()
        XCTAssertTrue(secondPing)
        XCTAssertTrue(secondClient.snapshot.isReady)
        XCTAssertNil(secondClient.snapshot.visibleErrorMessage)

        await invalidateAndDrain(firstClient, secondClient)
    }
}
