import Combine
import Foundation
import XCTest
@testable import QwenVoiceCore

@MainActor
final class ExtensionBackedTTSEngineTests: XCTestCase {
    func testModelDescriptorPrefersSpeedVariantOnIOS() {
        let descriptor = ModelDescriptor(
            id: "pro_custom",
            name: "Custom Voice",
            tier: "pro",
            folder: "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
            mode: .custom,
            huggingFaceRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
            artifactVersion: "2026.04.05.2",
            iosDownloadEligible: false,
            estimatedDownloadBytes: nil,
            outputSubfolder: "CustomVoice",
            requiredRelativePaths: ["model.safetensors"],
            variants: [
                ModelVariantDescriptor(
                    id: "speed",
                    name: "Speed",
                    kind: .speed,
                    platforms: [.iOS, .macOS],
                    folder: "Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
                    huggingFaceRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
                    artifactVersion: "2026.04.05.2",
                    iosDownloadEligible: true,
                    estimatedDownloadBytes: 1_234,
                    requiredRelativePaths: ["model.safetensors"]
                ),
                ModelVariantDescriptor(
                    id: "quality",
                    name: "Quality",
                    kind: .quality,
                    platforms: [.macOS],
                    folder: "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
                    huggingFaceRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
                    artifactVersion: "2026.04.05.2",
                    iosDownloadEligible: false,
                    estimatedDownloadBytes: nil,
                    requiredRelativePaths: ["model.safetensors"]
                ),
            ]
        )

        let resolved = descriptor.resolvedForPlatform(.iOS)

        XCTAssertEqual(resolved.folder, "Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit")
        XCTAssertTrue(resolved.iosDownloadEligible)
        XCTAssertEqual(resolved.estimatedDownloadBytes, 1_234)
    }

    func testExtensionBackedEngineInitializesAndPingsTransport() async throws {
        let transport = ExtensionEngineTestTransport()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = ExtensionBackedTTSEngine(
            modelRegistry: StubModelRegistry(),
            documentIO: LocalDocumentIO(importedReferenceDirectory: root.appendingPathComponent("imports", isDirectory: true)),
            transportFactory: { _ in transport }
        )

        let initializeTask = Task { try await engine.initialize(appSupportDirectory: root) }
        try await waitForPerformCallCount(1, transport: transport)
        transport.reply(
            with: ExtensionEngineReplyEnvelope(
                id: try XCTUnwrap(transport.lastRequestID),
                reply: .snapshot(
                    TTSEngineSnapshot(
                        isReady: true,
                        loadState: .idle,
                        clonePreparationState: .idle,
                        visibleErrorMessage: nil
                    )
                )
            )
        )
        try await initializeTask.value

        let isReady = engine.isReady
        let loadState = engine.loadState
        XCTAssertTrue(isReady)
        XCTAssertEqual(loadState, .idle)

        let pingTask = Task { try await engine.ping() }
        try await waitForPerformCallCount(2, transport: transport)
        transport.reply(
            with: ExtensionEngineReplyEnvelope(
                id: try XCTUnwrap(transport.lastRequestID),
                reply: .bool(true)
            )
        )
        let pingResult = try await pingTask.value
        XCTAssertTrue(pingResult)
    }

    func testExtensionBackedEngineAcceptsCapabilityReplyForPing() async throws {
        let transport = ExtensionEngineTestTransport()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = ExtensionBackedTTSEngine(
            modelRegistry: StubModelRegistry(),
            documentIO: LocalDocumentIO(importedReferenceDirectory: root.appendingPathComponent("imports", isDirectory: true)),
            transportFactory: { _ in transport }
        )

        let initializeTask = Task { try await engine.initialize(appSupportDirectory: root) }
        try await waitForPerformCallCount(1, transport: transport)
        transport.reply(
            with: ExtensionEngineReplyEnvelope(
                id: try XCTUnwrap(transport.lastRequestID),
                reply: .snapshot(
                    TTSEngineSnapshot(
                        isReady: true,
                        loadState: .idle,
                        clonePreparationState: .idle,
                        visibleErrorMessage: nil
                    )
                )
            )
        )
        try await initializeTask.value

        let pingTask = Task { try await engine.ping() }
        try await waitForPerformCallCount(2, transport: transport)
        transport.reply(
            with: ExtensionEngineReplyEnvelope(
                id: try XCTUnwrap(transport.lastRequestID),
                reply: .capabilities(.iOSExtensionDefault)
            )
        )

        let pingResult = try await pingTask.value
        XCTAssertTrue(pingResult)
    }

    func testExtensionBackedEngineMapsCancelledGenerationReplyToCancellationError() async throws {
        let transport = ExtensionEngineTestTransport()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = ExtensionBackedTTSEngine(
            modelRegistry: StubModelRegistry(),
            documentIO: LocalDocumentIO(importedReferenceDirectory: root.appendingPathComponent("imports", isDirectory: true)),
            transportFactory: { _ in transport }
        )

        let initializeTask = Task { try await engine.initialize(appSupportDirectory: root) }
        try await waitForPerformCallCount(1, transport: transport)
        transport.reply(
            with: ExtensionEngineReplyEnvelope(
                id: try XCTUnwrap(transport.lastRequestID),
                reply: .snapshot(
                    TTSEngineSnapshot(
                        isReady: true,
                        loadState: .idle,
                        clonePreparationState: .idle,
                        visibleErrorMessage: nil
                    )
                )
            )
        )
        try await initializeTask.value

        let request = GenerationRequest(
            mode: .custom,
            modelID: "pro_custom",
            text: "Cancel me",
            outputPath: root.appendingPathComponent("cancel.wav").path,
            shouldStream: true,
            payload: .custom(speakerID: "vivian", deliveryStyle: nil)
        )

        let generationTask = Task { try await engine.generate(request) }
        try await waitForPerformCallCount(2, transport: transport)
        transport.reply(
            with: ExtensionEngineReplyEnvelope(
                id: try XCTUnwrap(transport.lastRequestID),
                reply: .failure(
                    ExtensionRemoteErrorPayload(
                        message: "Generation cancelled",
                        domain: "QwenVoiceCore",
                        code: .cancelled
                    )
                )
            )
        )

        do {
            _ = try await generationTask.value
            XCTFail("Expected cancelled generation to throw.")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testExtensionBackedEngineReconnectsAfterInterrupt() async throws {
        let transportBox = ExtensionEngineTestTransportBox()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = ExtensionBackedTTSEngine(
            modelRegistry: StubModelRegistry(),
            documentIO: LocalDocumentIO(importedReferenceDirectory: root.appendingPathComponent("imports", isDirectory: true)),
            transportFactory: { handlers in
                transportBox.makeTransport(handlers: handlers)
            }
        )

        var lifecycleHistory: [ExtensionEngineLifecycleState] = []
        let cancellable = engine.$lifecycleState.sink { lifecycleHistory.append($0) }
        defer { cancellable.cancel() }

        let initializeTask = Task { try await engine.initialize(appSupportDirectory: root) }
        guard let firstTransport = try await waitForTransportCount(1, box: transportBox) else {
            return XCTFail("Expected first transport")
        }
        try await waitForPerformCallCount(1, transport: firstTransport)
        firstTransport.reply(
            with: ExtensionEngineReplyEnvelope(
                id: try XCTUnwrap(firstTransport.lastRequestID),
                reply: .snapshot(
                    TTSEngineSnapshot(
                        isReady: true,
                        loadState: .idle,
                        clonePreparationState: .idle,
                        visibleErrorMessage: nil
                    )
                )
            )
        )
        try await initializeTask.value
        XCTAssertEqual(engine.lifecycleState, .connected)

        let interruptedPingTask = Task { try await engine.ping() }
        try await waitForPerformCallCount(2, transport: firstTransport)
        firstTransport.triggerInterrupted()

        do {
            _ = try await interruptedPingTask.value
            XCTFail("Expected interrupted ping to fail.")
        } catch let error as ExtensionEngineTransportError {
            XCTAssertEqual(error, .interrupted)
        }

        XCTAssertEqual(engine.lifecycleState, .interrupted)

        let recoveredPingTask = Task { try await engine.ping() }
        guard let secondTransport = try await waitForTransportCount(2, box: transportBox) else {
            return XCTFail("Expected second transport")
        }
        try await waitForPerformCallCount(1, transport: secondTransport)
        secondTransport.reply(
            with: ExtensionEngineReplyEnvelope(
                id: try XCTUnwrap(secondTransport.requestID(at: 0)),
                reply: .snapshot(
                    TTSEngineSnapshot(
                        isReady: true,
                        loadState: .idle,
                        clonePreparationState: .idle,
                        visibleErrorMessage: nil
                    )
                )
            )
        )
        try await waitForPerformCallCount(2, transport: secondTransport)
        secondTransport.reply(
            with: ExtensionEngineReplyEnvelope(
                id: try XCTUnwrap(secondTransport.requestID(at: 1)),
                reply: .bool(true)
            )
        )

        let pingResult = try await recoveredPingTask.value
        XCTAssertTrue(pingResult)
        XCTAssertEqual(engine.lifecycleState, .connected)
        XCTAssertTrue(lifecycleHistory.contains(.interrupted))
        XCTAssertTrue(lifecycleHistory.contains(.recovering))
    }

    func testExtensionBackedEngineReconnectsAfterInvalidation() async throws {
        let transportBox = ExtensionEngineTestTransportBox()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = ExtensionBackedTTSEngine(
            modelRegistry: StubModelRegistry(),
            documentIO: LocalDocumentIO(importedReferenceDirectory: root.appendingPathComponent("imports", isDirectory: true)),
            transportFactory: { handlers in
                transportBox.makeTransport(handlers: handlers)
            }
        )

        let initializeTask = Task { try await engine.initialize(appSupportDirectory: root) }
        guard let firstTransport = try await waitForTransportCount(1, box: transportBox) else {
            return XCTFail("Expected first transport")
        }
        try await waitForPerformCallCount(1, transport: firstTransport)
        firstTransport.reply(
            with: ExtensionEngineReplyEnvelope(
                id: try XCTUnwrap(firstTransport.lastRequestID),
                reply: .snapshot(
                    TTSEngineSnapshot(
                        isReady: true,
                        loadState: .idle,
                        clonePreparationState: .idle,
                        visibleErrorMessage: nil
                    )
                )
            )
        )
        try await initializeTask.value

        let request = GenerationRequest(
            mode: .custom,
            modelID: "pro_custom",
            text: "Reconnect after invalidation",
            outputPath: root.appendingPathComponent("reconnect.wav").path,
            shouldStream: true,
            payload: .custom(speakerID: "vivian", deliveryStyle: nil)
        )

        let generationTask = Task { try await engine.generate(request) }
        try await waitForPerformCallCount(2, transport: firstTransport)
        firstTransport.triggerInvalidated()

        do {
            _ = try await generationTask.value
            XCTFail("Expected invalidated generation to fail.")
        } catch let error as ExtensionEngineTransportError {
            XCTAssertEqual(error, .invalidated)
        }

        XCTAssertEqual(engine.lifecycleState, .invalidated)

        let recoveredPingTask = Task { try await engine.ping() }
        guard let secondTransport = try await waitForTransportCount(2, box: transportBox) else {
            return XCTFail("Expected second transport")
        }
        try await waitForPerformCallCount(1, transport: secondTransport)
        secondTransport.reply(
            with: ExtensionEngineReplyEnvelope(
                id: try XCTUnwrap(secondTransport.requestID(at: 0)),
                reply: .snapshot(
                    TTSEngineSnapshot(
                        isReady: true,
                        loadState: .idle,
                        clonePreparationState: .idle,
                        visibleErrorMessage: nil
                    )
                )
            )
        )
        try await waitForPerformCallCount(2, transport: secondTransport)
        secondTransport.reply(
            with: ExtensionEngineReplyEnvelope(
                id: try XCTUnwrap(secondTransport.requestID(at: 1)),
                reply: .bool(true)
            )
        )

        let recoveredPingResult = try await recoveredPingTask.value
        XCTAssertTrue(recoveredPingResult)
        XCTAssertEqual(engine.lifecycleState, .connected)
    }

    private func waitForPerformCallCount(
        _ expectedCount: Int,
        transport: ExtensionEngineTestTransport,
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

    private func waitForTransportCount(
        _ expectedCount: Int,
        box: ExtensionEngineTestTransportBox,
        timeoutSeconds: TimeInterval = 1.0
    ) async throws -> ExtensionEngineTestTransport? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let transports = box.transports
            if transports.count >= expectedCount {
                return transports[expectedCount - 1]
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private final class ExtensionEngineTestTransportBox: @unchecked Sendable {
    private(set) var transports: [ExtensionEngineTestTransport] = []

    func makeTransport(handlers: ExtensionEngineTransportHandlers) -> ExtensionEngineTestTransport {
        let transport = ExtensionEngineTestTransport(handlers: handlers)
        transports.append(transport)
        return transport
    }
}

private struct StubModelRegistry: ModelRegistry {
    let models: [ModelDescriptor] = [
        ModelDescriptor(
            id: "pro_custom",
            name: "Custom Voice",
            tier: "pro",
            folder: "Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
            mode: .custom,
            huggingFaceRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
            artifactVersion: "2026.04.05.2",
            iosDownloadEligible: true,
            estimatedDownloadBytes: 1_234,
            outputSubfolder: "CustomVoice",
            requiredRelativePaths: ["model.safetensors"]
        )
    ]

    let defaultSpeaker = SpeakerDescriptor(group: "English", id: "vivian")
    let groupedSpeakers = ["English": [SpeakerDescriptor(group: "English", id: "vivian")]]
    let allSpeakers = [SpeakerDescriptor(group: "English", id: "vivian")]

    func model(for mode: GenerationMode) -> ModelDescriptor? {
        models.first { $0.mode == mode }
    }

    func model(id: String) -> ModelDescriptor? {
        models.first { $0.id == id }
    }
}

private final class ExtensionEngineTestTransport: ExtensionEngineTransporting, @unchecked Sendable {
    private let handlers: ExtensionEngineTransportHandlers?
    private(set) var performCallCount = 0
    private(set) var lastRequestID: UUID?
    private var requestIDs: [UUID] = []
    private var replyHandlers: [(@Sendable (Data) -> Void)] = []

    init(handlers: ExtensionEngineTransportHandlers? = nil) {
        self.handlers = handlers
    }

    func resume() {}

    func invalidate() {}

    func perform(_ payload: Data, reply: @escaping @Sendable (Data) -> Void) {
        performCallCount += 1
        lastRequestID = try? ExtensionEngineCodec.decode(ExtensionEngineRequestEnvelope.self, from: payload).id
        if let lastRequestID {
            requestIDs.append(lastRequestID)
        }
        replyHandlers.append(reply)
    }

    func reply(with envelope: ExtensionEngineReplyEnvelope) {
        guard !replyHandlers.isEmpty else { return }
        let replyHandler = replyHandlers.removeFirst()
        let payload = try! ExtensionEngineCodec.encode(envelope)
        replyHandler(payload)
    }

    func requestID(at index: Int) -> UUID? {
        guard requestIDs.indices.contains(index) else { return nil }
        return requestIDs[index]
    }

    func triggerInterrupted() {
        handlers?.onInterrupted()
    }

    func triggerInvalidated() {
        handlers?.onInvalidated()
    }
}
