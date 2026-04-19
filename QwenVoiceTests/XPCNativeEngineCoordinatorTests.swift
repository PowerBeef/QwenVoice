import XCTest
@testable import QwenVoiceEngineSupport
@testable import QwenVoiceNative

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
        for _ in 0..<20 where transport.performCallCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(transport.performCallCount, 1)
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

    func invalidateFromTest() {
        handlers?.onInvalidated()
    }

    func reply(with envelope: EngineReplyEnvelope) {
        guard !replyHandlers.isEmpty else { return }
        let replyHandler = replyHandlers.removeFirst()
        let payload = try! EngineServiceCodec.encode(envelope)
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
