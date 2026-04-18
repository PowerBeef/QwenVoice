import XCTest
@testable import QwenVoiceNative

final class XPCNativeEngineClientTests: XCTestCase {
    func testClientInitializesAndPingsBundledEngineService() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let client = XPCNativeEngineClient()
        try await client.initialize(appSupportDirectory: root)

        XCTAssertTrue(try await client.ping())
        XCTAssertTrue(client.snapshot.isReady)
        XCTAssertEqual(client.snapshot.loadState, .idle)
        XCTAssertNil(client.snapshot.visibleErrorMessage)
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
        XCTAssertTrue(try await client.listPreparedVoices().isEmpty)
    }

    func testClientReinitializesAfterConnectionInvalidation() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let client = XPCNativeEngineClient()
        try await client.initialize(appSupportDirectory: root)
        XCTAssertTrue(try await client.ping())

        await client.debugInvalidateConnectionForTesting()

        for _ in 0..<20 where client.snapshot.isReady {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(client.snapshot.isReady)
        XCTAssertNotNil(client.snapshot.visibleErrorMessage)

        XCTAssertTrue(try await client.ping())
        for _ in 0..<20 where !client.snapshot.isReady {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(client.snapshot.isReady)
        XCTAssertEqual(client.snapshot.loadState, .idle)
        XCTAssertNil(client.snapshot.visibleErrorMessage)
    }
}
