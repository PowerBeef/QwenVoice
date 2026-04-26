import XCTest
@testable import QwenVoiceEngineSupport
@testable import QwenVoiceNative

private actor SnapshotRecorder {
    private var snapshots: [TTSEngineSnapshot] = []

    func append(_ snapshot: TTSEngineSnapshot) {
        snapshots.append(snapshot)
    }

    func last() -> TTSEngineSnapshot? {
        snapshots.last
    }
}

final class XPCNativeEngineCoordinatorTests: XCTestCase {
    func testCoordinatorTimesOutPendingPingAndRemainsUsable() async throws {
        let transport = TestXPCTransport()
        let coordinator = XPCNativeEngineCoordinator(
            onSnapshot: { _ in },
            onChunk: { _ in },
            transportFactory: { handlers in
                transport.install(handlers: handlers)
                return transport
            },
            timeoutResolver: { command in
                switch command {
                case .ping:
                    .milliseconds(50)
                default:
                    nil
                }
            }
        )

        do {
            _ = try await coordinator.send(.ping)
            XCTFail("Expected ping to time out.")
        } catch let error as EngineTransportError {
            XCTAssertEqual(error, .timedOut(commandName: "ping"))
        }

        let secondReply = EngineReplyEnvelope(
            id: try XCTUnwrap(transport.lastRequestID),
            reply: .bool(true)
        )
        transport.reply(with: secondReply)

        async let secondPing = coordinator.send(.ping)
        try await Task.sleep(for: .milliseconds(10))
        let usableReply = EngineReplyEnvelope(
            id: try XCTUnwrap(transport.lastRequestID),
            reply: .bool(true)
        )
        transport.reply(with: usableReply)

        guard case .bool(let result) = try await secondPing else {
            return XCTFail("Expected bool reply.")
        }
        XCTAssertTrue(result)
    }

    func testCoordinatorInvalidationFailsPendingRequest() async throws {
        let transport = TestXPCTransport()
        let coordinator = XPCNativeEngineCoordinator(
            onSnapshot: { _ in },
            onChunk: { _ in },
            transportFactory: { handlers in
                transport.install(handlers: handlers)
                return transport
            },
            timeoutResolver: { _ in nil }
        )

        async let pending = coordinator.send(.ping)
        try await Task.sleep(for: .milliseconds(10))
        transport.invalidateFromTest()

        do {
            _ = try await pending
            XCTFail("Expected invalidation to fail the request.")
        } catch let error as EngineTransportError {
            XCTAssertEqual(error, .invalidated)
        }
    }

    func testCoordinatorDropsLateReplyAfterTimeout() async throws {
        let transport = TestXPCTransport()
        let coordinator = XPCNativeEngineCoordinator(
            onSnapshot: { _ in },
            onChunk: { _ in },
            transportFactory: { handlers in
                transport.install(handlers: handlers)
                return transport
            },
            timeoutResolver: { command in
                switch command {
                case .ping:
                    .milliseconds(50)
                default:
                    nil
                }
            }
        )

        do {
            _ = try await coordinator.send(.ping)
            XCTFail("Expected ping to time out.")
        } catch {}

        let lateReply = EngineReplyEnvelope(
            id: try XCTUnwrap(transport.lastRequestID),
            reply: .bool(true)
        )
        transport.reply(with: lateReply)

        async let freshPing = coordinator.send(.ping)
        try await Task.sleep(for: .milliseconds(10))
        let freshReply = EngineReplyEnvelope(
            id: try XCTUnwrap(transport.lastRequestID),
            reply: .bool(true)
        )
        transport.reply(with: freshReply)

        guard case .bool(let result) = try await freshPing else {
            return XCTFail("Expected bool reply.")
        }
        XCTAssertTrue(result)
    }

    func testCoordinatorFailsUnreadableReplyAndPublishesFailedSnapshot() async throws {
        let transport = TestXPCTransport()
        let snapshotRecorder = SnapshotRecorder()
        let coordinator = XPCNativeEngineCoordinator(
            onSnapshot: { snapshot in
                Task {
                    await snapshotRecorder.append(snapshot)
                }
            },
            onChunk: { _ in },
            transportFactory: { handlers in
                transport.install(handlers: handlers)
                return transport
            },
            timeoutResolver: { _ in nil }
        )

        async let pending = coordinator.send(.ping)
        try await Task.sleep(for: .milliseconds(10))
        transport.reply(withRawPayload: Data("not-json".utf8))

        do {
            _ = try await pending
            XCTFail("Expected unreadable reply to fail the request.")
        } catch let error as EngineTransportError {
            XCTAssertEqual(error, .invalidReply)
        }

        try await Task.sleep(for: .milliseconds(10))
        let lastSnapshot = await snapshotRecorder.last()
        XCTAssertEqual(
            lastSnapshot,
            TTSEngineSnapshot(
                isReady: false,
                loadState: .failed(message: EngineTransportError.invalidReply.localizedDescription),
                clonePreparationState: .idle,
                visibleErrorMessage: EngineTransportError.invalidReply.localizedDescription
            )
        )
    }

    func testFireAndForgetDoesNotHangWhenTransportNeverReplies() async {
        let transport = TestXPCTransport()
        let coordinator = XPCNativeEngineCoordinator(
            onSnapshot: { _ in },
            onChunk: { _ in },
            transportFactory: { handlers in
                transport.install(handlers: handlers)
                return transport
            },
            timeoutResolver: { _ in .milliseconds(50) }
        )

        await coordinator.fireAndForget(.clearVisibleError)
        _ = await waitUntil(
            timeoutSeconds: 0.5,
            description: "fireAndForget perform reaches transport"
        ) {
            transport.performCallCount >= 1
        }
        XCTAssertEqual(transport.performCallCount, 1)
    }

    func testFireAndForgetDeduplicatesInFlightEnsureModelCommands() async throws {
        let transport = TestXPCTransport()
        let coordinator = XPCNativeEngineCoordinator(
            onSnapshot: { _ in },
            onChunk: { _ in },
            transportFactory: { handlers in
                transport.install(handlers: handlers)
                return transport
            },
            timeoutResolver: { _ in nil }
        )

        await coordinator.fireAndForget(.ensureModelLoadedIfNeeded(id: "pro_custom"))
        await coordinator.fireAndForget(.ensureModelLoadedIfNeeded(id: "pro_custom"))

        await waitUntil(
            timeoutSeconds: 0.5,
            description: "first ensure reaches transport"
        ) {
            transport.performCallCount == 1
        }
        XCTAssertEqual(transport.performedCommands, [.ensureModelLoadedIfNeeded(id: "pro_custom")])

        transport.reply(
            with: EngineReplyEnvelope(
                id: try XCTUnwrap(transport.lastRequestID),
                reply: .void
            )
        )
        try await Task.sleep(for: .milliseconds(20))

        await coordinator.fireAndForget(.ensureModelLoadedIfNeeded(id: "pro_custom"))
        await waitUntil(
            timeoutSeconds: 0.5,
            description: "ensure can run again after reply"
        ) {
            transport.performCallCount == 2
        }
    }

    func testFireAndForgetDeduplicatesSemanticPrewarmIdentity() async {
        let transport = TestXPCTransport()
        let coordinator = XPCNativeEngineCoordinator(
            onSnapshot: { _ in },
            onChunk: { _ in },
            transportFactory: { handlers in
                transport.install(handlers: handlers)
                return transport
            },
            timeoutResolver: { _ in nil }
        )
        let firstRequest = GenerationRequest(
            modelID: "pro_design",
            text: "Short line",
            outputPath: "/tmp/one.wav",
            payload: .design(voiceDescription: "Warm narrator", deliveryStyle: "Calm")
        )
        let equivalentWarmRequest = GenerationRequest(
            modelID: "pro_design",
            text: "Different draft text that should not create a new prewarm",
            outputPath: "/tmp/two.wav",
            payload: .design(voiceDescription: "Another brief", deliveryStyle: "Dramatic")
        )

        await coordinator.fireAndForget(.prewarmModelIfNeeded(request: firstRequest))
        await coordinator.fireAndForget(.prewarmModelIfNeeded(request: equivalentWarmRequest))

        await waitUntil(
            timeoutSeconds: 0.5,
            description: "semantic prewarm reaches transport once"
        ) {
            transport.performCallCount == 1
        }
        XCTAssertEqual(transport.performedCommands, [.prewarmModelIfNeeded(request: firstRequest)])
    }

    func testCoordinatorIgnoresLateInvalidationFromReplacedConnection() async throws {
        let firstTransport = TestXPCTransport()
        let secondTransport = TestXPCTransport()
        let factory = TestTransportFactory([firstTransport, secondTransport])
        let coordinator = XPCNativeEngineCoordinator(
            onSnapshot: { _ in },
            onChunk: { _ in },
            transportFactory: { handlers in
                factory.makeTransport(handlers: handlers)
            },
            timeoutResolver: { _ in nil }
        )

        async let firstPing = coordinator.send(.ping)
        try await Task.sleep(for: .milliseconds(10))
        firstTransport.reply(
            with: EngineReplyEnvelope(
                id: try XCTUnwrap(firstTransport.lastRequestID),
                reply: .bool(true)
            )
        )
        _ = try await firstPing

        firstTransport.invalidateFromTest()
        try await Task.sleep(for: .milliseconds(10))

        async let reconnectPing = coordinator.send(.ping)
        try await Task.sleep(for: .milliseconds(10))
        secondTransport.reply(
            with: EngineReplyEnvelope(
                id: try XCTUnwrap(secondTransport.lastRequestID),
                reply: .bool(true)
            )
        )
        _ = try await reconnectPing

        firstTransport.invalidateFromTest()
        try await Task.sleep(for: .milliseconds(10))

        async let followupPing = coordinator.send(.ping)
        try await Task.sleep(for: .milliseconds(10))
        secondTransport.reply(
            with: EngineReplyEnvelope(
                id: try XCTUnwrap(secondTransport.lastRequestID),
                reply: .bool(true)
            )
        )

        guard case .bool(let result) = try await followupPing else {
            return XCTFail("Expected bool reply.")
        }
        XCTAssertTrue(result)
    }
}

private final class TestXPCTransport: XPCNativeEngineTransporting, @unchecked Sendable {
    var handlers: XPCNativeEngineTransportHandlers?
    private(set) var performCallCount = 0
    private(set) var lastRequestID: UUID?
    private(set) var performedCommands: [EngineCommand] = []
    private var replyHandlers: [(@Sendable (Data) -> Void)] = []

    func install(handlers: XPCNativeEngineTransportHandlers) {
        self.handlers = handlers
    }

    func resume() {}

    func invalidate() {}

    func perform(_ payload: Data, reply: @escaping @Sendable (Data) -> Void) {
        performCallCount += 1
        if let envelope = try? EngineServiceCodec.decode(EngineRequestEnvelope.self, from: payload) {
            lastRequestID = envelope.id
            performedCommands.append(envelope.command)
        }
        replyHandlers.append(reply)
    }

    func invalidateFromTest() {
        handlers?.onInvalidated()
    }

    func reply(with envelope: EngineReplyEnvelope) {
        guard !replyHandlers.isEmpty else { return }
        let replyHandler = replyHandlers.removeFirst()
        let payload = try! EngineServiceCodec.encode(envelope)
        replyHandler(payload)
    }

    func reply(withRawPayload payload: Data) {
        guard !replyHandlers.isEmpty else { return }
        let replyHandler = replyHandlers.removeFirst()
        replyHandler(payload)
    }
}

private final class TestTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [TestXPCTransport]

    init(_ transports: [TestXPCTransport]) {
        self.transports = transports
    }

    func makeTransport(handlers: XPCNativeEngineTransportHandlers) -> any XPCNativeEngineTransporting {
        lock.lock()
        defer { lock.unlock() }
        let transport = transports.removeFirst()
        transport.install(handlers: handlers)
        return transport
    }
}
