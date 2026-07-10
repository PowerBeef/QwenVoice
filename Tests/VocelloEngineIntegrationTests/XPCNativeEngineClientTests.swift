import Foundation
import QwenVoiceCore
import QwenVoiceEngineSupport
@testable import QwenVoiceNative
import XCTest

final class XPCNativeEngineClientTests: XCTestCase {
    func testRequestReplyCorrelationReturnsMatchingReply() async throws {
        let factory = FakeTransportFactory(mode: .replyNormally)
        let client = makeClient(factory: factory)

        let pingSucceeded = try await client.ping()
        XCTAssertTrue(pingSucceeded)
        XCTAssertEqual(factory.commands(), [.ping])
    }

    func testMismatchedReplyDoesNotCompletePendingRequest() async {
        let factory = FakeTransportFactory(mode: .mismatchedReply)
        let client = makeClient(factory: factory, timeout: .milliseconds(30))

        do {
            _ = try await client.ping()
            XCTFail("mismatched reply must not complete the request")
        } catch let error as EngineTransportError {
            guard case .timedOut(commandName: "ping") = error else {
                return XCTFail("unexpected transport error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let pendingAfterMismatch = await client.pendingRequestCount
        XCTAssertEqual(pendingAfterMismatch, 0)
    }

    func testTimeoutCleansPendingRequestAndSendsGenerationCancellation() async throws {
        let factory = FakeTransportFactory(mode: .holdGeneration)
        let client = makeClient(factory: factory, timeout: .milliseconds(30))
        let request = GenerationRequest(
            mode: .custom,
            modelID: "pro_custom_speed",
            text: "Timeout cleanup fixture.",
            outputPath: "/tmp/transport-timeout.wav",
            shouldStream: true,
            payload: .custom(speakerID: "aiden", deliveryStyle: nil)
        )

        do {
            _ = try await client.generate(request)
            XCTFail("held generation should time out")
        } catch let error as EngineTransportError {
            guard case .timedOut(commandName: "generate") = error else {
                return XCTFail("unexpected transport error: \(error)")
            }
        }

        try await waitUntil { factory.commands().contains(.cancelActiveGeneration) }
        let pendingAfterTimeout = await client.pendingRequestCount
        XCTAssertEqual(pendingAfterTimeout, 0)
    }

    func testCancelledGenerationSendsCleanupAfterCancellation() async throws {
        let factory = FakeTransportFactory(mode: .holdGeneration)
        let client = makeClient(factory: factory, timeout: nil)
        let request = GenerationRequest(
            mode: .custom,
            modelID: "pro_custom_speed",
            text: "Transport cancellation fixture.",
            outputPath: "/tmp/transport-cancel.wav",
            shouldStream: true,
            payload: .custom(speakerID: "aiden", deliveryStyle: nil)
        )

        let generation = Task { try await client.generate(request) }
        try await waitUntil { factory.commands().contains(where: { command in
            if case .generate = command { return true }
            return false
        }) }
        generation.cancel()

        do {
            _ = try await generation.value
            XCTFail("cancelled generation should throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }

        try await waitUntil { factory.commands().contains(.cancelActiveGeneration) }
        let commands = factory.commands()
        let generationIndex = commands.firstIndex { command in
            if case .generate = command { return true }
            return false
        }
        let cancellationIndex = commands.firstIndex(of: .cancelActiveGeneration)
        XCTAssertNotNil(generationIndex)
        XCTAssertNotNil(cancellationIndex)
        XCTAssertLessThan(generationIndex!, cancellationIndex!)
    }

    func testInterruptionCreatesFreshConnectionAndReinitializes() async throws {
        let factory = FakeTransportFactory(mode: .replyNormally)
        let client = makeClient(factory: factory, reconnectDelays: [.milliseconds(1)])
        try await client.initialize(appSupportDirectory: URL(fileURLWithPath: "/tmp/vocello-xpc-tests"))
        XCTAssertTrue(client.snapshot.isReady)

        factory.firstTransport()?.interrupt()
        try await waitUntil { factory.transportCount >= 2 }
        try await waitUntil { client.snapshot.isReady && client.snapshot.visibleErrorMessage == nil }

        XCTAssertGreaterThanOrEqual(
            factory.commands().filter { command in
                if case .initialize = command { return true }
                return false
            }.count,
            2
        )
    }

    func testExpectedRetirementDoesNotReconnectEagerly() async throws {
        let factory = FakeTransportFactory(mode: .replyNormally)
        let client = makeClient(factory: factory, reconnectDelays: [.milliseconds(1)])
        try await client.initialize(appSupportDirectory: URL(fileURLWithPath: "/tmp/vocello-xpc-tests"))

        let retired = await client.retireServiceIfIdle()
        XCTAssertTrue(retired)
        factory.firstTransport()?.invalidateFromRemote()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(factory.transportCount, 1)
        XCTAssertTrue(client.snapshot.isReady)
        XCTAssertNil(client.snapshot.visibleErrorMessage)
    }

    private func makeClient(
        factory: FakeTransportFactory,
        timeout: Duration? = .seconds(1),
        reconnectDelays: [Duration] = []
    ) -> XPCNativeEngineClient {
        XPCNativeEngineClient(
            transportFactory: { handlers in factory.make(handlers: handlers) },
            timeoutResolver: { _ in timeout },
            onChunk: { _ in },
            reconnectDelays: reconnectDelays
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition did not become true before timeout")
    }
}

private final class FakeTransportFactory: @unchecked Sendable {
    enum Mode: Equatable {
        case replyNormally
        case mismatchedReply
        case holdGeneration
    }

    private let lock = NSLock()
    private let mode: Mode
    private var transports: [FakeTransport] = []

    init(mode: Mode) {
        self.mode = mode
    }

    var transportCount: Int {
        lock.withLock { transports.count }
    }

    func make(handlers: XPCNativeEngineTransportHandlers) -> FakeTransport {
        let transport = FakeTransport(handlers: handlers, mode: mode)
        lock.withLock { transports.append(transport) }
        return transport
    }

    func firstTransport() -> FakeTransport? {
        lock.withLock { transports.first }
    }

    func commands() -> [EngineCommand] {
        lock.withLock { transports.flatMap { $0.commands } }
    }
}

private final class FakeTransport: XPCNativeEngineTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private let handlers: XPCNativeEngineTransportHandlers
    private let mode: FakeTransportFactory.Mode
    private var storedCommands: [EngineCommand] = []

    init(handlers: XPCNativeEngineTransportHandlers, mode: FakeTransportFactory.Mode) {
        self.handlers = handlers
        self.mode = mode
    }

    var commands: [EngineCommand] {
        lock.withLock { storedCommands }
    }

    func resume() {}
    func invalidate() {}

    func perform(_ payload: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let request = try? EngineServiceCodec.decode(EngineRequestEnvelope.self, from: payload) else {
            handlers.onRemoteError(EngineTransportError.invalidReply)
            return
        }
        lock.withLock { storedCommands.append(request.command) }

        if mode == .holdGeneration, case .generate = request.command {
            return
        }

        let replyID = mode == .mismatchedReply ? UUID() : request.id
        let envelope = EngineReplyEnvelope(id: replyID, reply: response(for: request.command))
        guard let data = try? EngineServiceCodec.encode(envelope) else {
            handlers.onRemoteError(EngineTransportError.invalidReply)
            return
        }
        reply(data)
    }

    func interrupt() {
        handlers.onInterrupted()
    }

    func invalidateFromRemote() {
        handlers.onInvalidated()
    }

    private func response(for command: EngineCommand) -> EngineReply {
        switch command {
        case .initialize:
            .snapshot(
                TTSEngineSnapshot(
                    isReady: true,
                    loadState: .idle,
                    clonePreparationState: .idle,
                    visibleErrorMessage: nil
                )
            )
        case .ping:
            .bool(true)
        default:
            .void
        }
    }
}
