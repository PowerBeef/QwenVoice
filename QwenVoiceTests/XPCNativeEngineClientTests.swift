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

    func testClientMapsRemoteCancelledGenerationReplyToCancellationError() async throws {
        let transport = ClientTestXPCTransport()
        let client = XPCNativeEngineClient(
            transportFactory: { handlers in
                transport.install(handlers: handlers)
                return transport
            }
        )
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        async let initialize: Void = client.initialize(appSupportDirectory: root)
        try await waitForPerformCallCount(1, transport: transport)
        transport.reply(
            with: EngineReplyEnvelope(
                id: try XCTUnwrap(transport.lastRequestID),
                reply: .void
            )
        )
        try await initialize

        let request = GenerationRequest(
            modelID: "pro_custom",
            text: "Cancel me",
            outputPath: root.appendingPathComponent("cancel.wav").path,
            shouldStream: true,
            payload: .custom(speakerID: "vivian", deliveryStyle: nil)
        )

        async let generation: GenerationResult = client.generate(request)
        try await waitForPerformCallCount(2, transport: transport)
        transport.reply(
            with: EngineReplyEnvelope(
                id: try XCTUnwrap(transport.lastRequestID),
                reply: .failure(
                    RemoteErrorPayload(
                        message: "Generation cancelled",
                        domain: "QwenVoiceNative",
                        code: .cancelled
                    )
                )
            )
        )

        do {
            _ = try await generation
            XCTFail("Expected cancelled generation to throw.")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testClientAcceptsCapabilityReplyForPing() async throws {
        let transport = ClientTestXPCTransport()
        let client = XPCNativeEngineClient(
            transportFactory: { handlers in
                transport.install(handlers: handlers)
                return transport
            }
        )
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        async let initialize: Void = client.initialize(appSupportDirectory: root)
        try await waitForPerformCallCount(1, transport: transport)
        transport.reply(
            with: EngineReplyEnvelope(
                id: try XCTUnwrap(transport.lastRequestID),
                reply: .void
            )
        )
        try await initialize

        async let ping: Bool = client.ping()
        try await waitForPerformCallCount(2, transport: transport)
        transport.reply(
            with: EngineReplyEnvelope(
                id: try XCTUnwrap(transport.lastRequestID),
                reply: .capabilities(.macOSXPCDefault)
            )
        )

        let pingResult = try await ping
        XCTAssertTrue(pingResult)
    }

    private func waitForPerformCallCount(
        _ expectedCount: Int,
        transport: ClientTestXPCTransport,
        timeoutSeconds: TimeInterval = 1.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if transport.performCallCount >= expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for transport perform count \(expectedCount)")
    }
}

private final class ClientTestXPCTransport: XPCNativeEngineTransporting, @unchecked Sendable {
    var handlers: XPCNativeEngineTransportHandlers?
    private(set) var performCallCount = 0
    private(set) var lastRequestID: UUID?
    private var replyHandlers: [(@Sendable (Data) -> Void)] = []

    func install(handlers: XPCNativeEngineTransportHandlers) {
        self.handlers = handlers
    }

    func resume() {}

    func invalidate() {}

    func perform(_ payload: Data, reply: @escaping @Sendable (Data) -> Void) {
        performCallCount += 1
        lastRequestID = try? EngineServiceCodec.decode(EngineRequestEnvelope.self, from: payload).id
        replyHandlers.append(reply)
    }

    func reply(with envelope: EngineReplyEnvelope) {
        guard !replyHandlers.isEmpty else { return }
        let replyHandler = replyHandlers.removeFirst()
        let payload = try! EngineServiceCodec.encode(envelope)
        replyHandler(payload)
    }
}
