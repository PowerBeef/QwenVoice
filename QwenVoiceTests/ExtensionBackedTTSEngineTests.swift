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

        async let initialize: Void = engine.initialize(appSupportDirectory: root)
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
        try await initialize

        let isReady = engine.isReady
        let loadState = engine.loadState
        XCTAssertTrue(isReady)
        XCTAssertEqual(loadState, .idle)

        async let ping = engine.ping()
        try await waitForPerformCallCount(2, transport: transport)
        transport.reply(
            with: ExtensionEngineReplyEnvelope(
                id: try XCTUnwrap(transport.lastRequestID),
                reply: .bool(true)
            )
        )
        let pingResult = try await ping
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

        async let initialize: Void = engine.initialize(appSupportDirectory: root)
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
        try await initialize

        let request = GenerationRequest(
            mode: .custom,
            modelID: "pro_custom",
            text: "Cancel me",
            outputPath: root.appendingPathComponent("cancel.wav").path,
            shouldStream: true,
            payload: .custom(speakerID: "vivian", deliveryStyle: nil)
        )

        async let generation: GenerationResult = engine.generate(request)
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
            _ = try await generation
            XCTFail("Expected cancelled generation to throw.")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
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

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
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
    private(set) var performCallCount = 0
    private(set) var lastRequestID: UUID?
    private var replyHandlers: [(@Sendable (Data) -> Void)] = []

    func resume() {}

    func invalidate() {}

    func perform(_ payload: Data, reply: @escaping @Sendable (Data) -> Void) {
        performCallCount += 1
        lastRequestID = try? ExtensionEngineCodec.decode(ExtensionEngineRequestEnvelope.self, from: payload).id
        replyHandlers.append(reply)
    }

    func reply(with envelope: ExtensionEngineReplyEnvelope) {
        guard !replyHandlers.isEmpty else { return }
        let replyHandler = replyHandlers.removeFirst()
        let payload = try! ExtensionEngineCodec.encode(envelope)
        replyHandler(payload)
    }
}
