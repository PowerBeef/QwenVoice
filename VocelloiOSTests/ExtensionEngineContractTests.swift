import XCTest
@testable import QwenVoiceCore

final class ExtensionEngineContractTests: XCTestCase {
    func testExtensionReplyEnvelopeRoundTripsCapabilities() throws {
        let envelope = ExtensionEngineReplyEnvelope(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            reply: .capabilities(.iOSExtensionDefault)
        )

        let encoded = try ExtensionEngineCodec.encode(envelope)
        let decoded = try ExtensionEngineCodec.decode(ExtensionEngineReplyEnvelope.self, from: encoded)

        XCTAssertEqual(decoded, envelope)
    }

    func testLifecycleStateMatchesFoundationReconnectVocabulary() {
        XCTAssertEqual(EngineLifecycleState.idle.rawValue, "idle")
        XCTAssertEqual(EngineLifecycleState.launching.rawValue, "launching")
        XCTAssertEqual(EngineLifecycleState.connected.rawValue, "connected")
        XCTAssertEqual(EngineLifecycleState.interrupted.rawValue, "interrupted")
        XCTAssertEqual(EngineLifecycleState.recovering.rawValue, "recovering")
        XCTAssertEqual(EngineLifecycleState.invalidated.rawValue, "invalidated")
        XCTAssertEqual(EngineLifecycleState.failed.rawValue, "failed")
    }

    func testCapabilityProfilesSeparateMacAndIPhoneHostFeatures() {
        XCTAssertTrue(EngineCapabilities.macOSXPCDefault.supportsBatchGeneration)
        XCTAssertFalse(EngineCapabilities.macOSXPCDefault.supportsAudioPreparation)
        XCTAssertFalse(EngineCapabilities.iOSExtensionDefault.supportsBatchGeneration)
        XCTAssertTrue(EngineCapabilities.iOSExtensionDefault.supportsAudioPreparation)
        XCTAssertTrue(EngineCapabilities.iOSExtensionDefault.supportsInteractivePrefetch)
        XCTAssertTrue(EngineCapabilities.iOSExtensionDefault.supportsMemoryTrim)
    }
}
