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

    func testExtensionRequestEnvelopeRoundTripsCancelActiveGeneration() throws {
        let envelope = ExtensionEngineRequestEnvelope(
            id: UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!,
            command: .cancelActiveGeneration
        )

        let encoded = try ExtensionEngineCodec.encode(envelope)
        let decoded = try ExtensionEngineCodec.decode(ExtensionEngineRequestEnvelope.self, from: encoded)

        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.command.transportName, "cancelActiveGeneration")
        XCTAssertEqual(decoded.command.transportTimeout, .seconds(10))
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
