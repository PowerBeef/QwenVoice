import Foundation
import XCTest
@testable import QwenVoiceCore

/// Audit Finding #1 producer-contract coverage. Validates that
/// events yielded into `MLXTTSEngine.session.run`'s `eventSink`
/// callback arrive on the engine's `events` AsyncStream in order when
/// the XPC consumer is actively draining the stream, while stalled
/// consumers are protected by a bounded newest-event buffer.
///
/// Pre-fix, `EngineServiceHost`'s `objectWillChange.sink` used
/// the engine's single-slot `@Published latestEvent` as its chunk
/// transport. Two consecutive `eventSink(event)` calls (most
/// notably the last `.chunk` followed immediately by `.completed`
/// from `NativeStreamingSynthesisSession.run`) could write to the
/// slot faster than the queued `Task { @MainActor in re-read }`
/// dequeued, and the dedup guard
/// `lastPublishedEvent != engine.latestEvent` then suppressed the
/// second read. The user-visible symptom: the trailing audio
/// chunk silently dropped before reaching the `AudioPlayerViewModel`
/// preview pipeline.
///
/// The fix routes chunk delivery through an `AsyncStream<GenerationEvent>`
/// that the XPC service host drains serially via `for await`. The
/// `latestEvent` slot is preserved for snapshot consumers but no longer
/// carries the chunk transport. The stream uses a bounded newest-event
/// buffer so diagnostic PCM payloads cannot accumulate indefinitely if a
/// consumer stalls.
@MainActor
final class MLXTTSEngineEventStreamTests: XCTestCase {

    private var temporaryRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        temporaryRoot = try Self.makeTemporaryRoot()
    }

    override func tearDown() async throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
        try await super.tearDown()
    }

    /// Drives 32 events back-to-back through the streaming
    /// session's `eventSink` closure (no GPU work between
    /// emissions, no `await` points beyond what
    /// `MockNativeStreamingSession.run` itself uses), then asserts
    /// every event reaches `engine.events` in the exact order it
    /// was yielded. Pre-fix, this would have dropped at least the
    /// trailing event because of the slot overwrite race.
    func testEverySessionEventReachesEventsStreamInOrder() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator(loadHandler: { _, capabilityProfile in
            return await NativeModelLoadResult.makeForTesting(
                model: UnsafeSpeechGenerationModel.makeFullySupportingForTesting(),
                capabilityProfile: capabilityProfile
            )
        })

        // 32 chunk events back-to-back. Mimics the burst pattern
        // that `NativeStreamingSynthesisSession.run` produces when
        // multiple chunks materialise in quick succession (e.g.
        // when the engine has been queuing asyncEval'd chunks and
        // the consumer thread drains them after a delay).
        let chunkCount = 32
        let chunks: [GenerationEvent] = (0 ..< chunkCount).map { i in
            GenerationEvent(
                kind: .streamChunk,
                requestID: 1,
                mode: "custom",
                title: "Stream-Loss Audit Test",
                isFinal: i == chunkCount - 1,
                chunkDurationSeconds: 0.05,
                cumulativeDurationSeconds: 0.05 * Double(i + 1)
            )
        }
        let cannedOutputPath = temporaryRoot
            .appendingPathComponent("event-stream-audit.wav")
            .path
        let cannedResult = GenerationResult(
            audioPath: cannedOutputPath,
            durationSeconds: 0.05 * Double(chunkCount),
            streamSessionDirectory: temporaryRoot
                .appendingPathComponent("cache/stream_sessions/event-stream-audit")
                .path,
            benchmarkSample: nil
        )
        let mockSession = MockNativeStreamingSession(
            events: chunks,
            result: cannedResult
        )

        let engine = MLXTTSEngine.makeForTesting(
            modelRegistry: registry,
            rootDirectory: temporaryRoot,
            loadCoordinator: coordinator,
            streamingSessionFactory: { _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
                mockSession
            }
        )
        try await engine.initialize(appSupportDirectory: temporaryRoot)
        try await engine.loadModel(id: "qwen3_custom_voice")

        let request = GenerationRequest(
            modelID: "qwen3_custom_voice",
            text: "Audit Finding #1 producer-contract test.",
            outputPath: cannedOutputPath,
            shouldStream: true,
            streamingTitle: "Stream-Loss Audit Test",
            payload: .custom(speakerID: "vivian", deliveryStyle: "Conversational")
        )

        // Spawn the consumer Task BEFORE generation kicks off so
        // the iterator is ready to receive yields. `prefix(_:)`
        // bounds iteration so the test terminates once the
        // expected number of events has arrived (the AsyncStream
        // itself stays open across the engine's lifetime).
        let collectorTask = Task<[GenerationEvent], Never> {
            var collected: [GenerationEvent] = []
            for await event in engine.events.prefix(chunkCount) {
                collected.append(event)
            }
            return collected
        }

        _ = try await engine.generate(request)

        let received = await collectorTask.value

        XCTAssertEqual(
            received.count,
            chunkCount,
            "Every yielded event must reach the AsyncStream — no drops."
        )
        XCTAssertEqual(
            received,
            chunks,
            "Events must arrive in the same order they were yielded by `eventSink`."
        )
        // The slot still gets the most-recent value for snapshot
        // consumers; verify it lines up with the trailing chunk.
        XCTAssertEqual(engine.latestEvent, chunks.last)
    }

    /// Failure-event coverage: when `MLXTTSEngine.generate(_:)`
    /// catches an error from `runGenerationAttempt` and surfaces
    /// `.failed(...)` to `latestEvent`, that same `.failed` event
    /// must also flow through the AsyncStream so XPC clients see
    /// the failure event without polling the slot.
    func testFailureEventReachesEventsStream() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator(loadHandler: { _, capabilityProfile in
            return await NativeModelLoadResult.makeForTesting(
                model: UnsafeSpeechGenerationModel.makeFullySupportingForTesting(),
                capabilityProfile: capabilityProfile
            )
        })

        let mockError = NSError(
            domain: "MLXTTSEngineEventStreamTests",
            code: 42,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Synthetic mock-session failure for AsyncStream coverage."
            ]
        )
        let mockSession = MockNativeStreamingSession(
            events: [],
            result: nil,
            error: mockError
        )

        let engine = MLXTTSEngine.makeForTesting(
            modelRegistry: registry,
            rootDirectory: temporaryRoot,
            loadCoordinator: coordinator,
            streamingSessionFactory: { _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
                mockSession
            }
        )
        try await engine.initialize(appSupportDirectory: temporaryRoot)
        try await engine.loadModel(id: "qwen3_custom_voice")

        let request = GenerationRequest(
            modelID: "qwen3_custom_voice",
            text: "Trigger an error path.",
            outputPath: temporaryRoot
                .appendingPathComponent("never-written.wav")
                .path,
            shouldStream: true,
            streamingTitle: "Failure-event audit",
            payload: .custom(speakerID: "vivian", deliveryStyle: "Conversational")
        )

        let collectorTask = Task<GenerationEvent?, Never> {
            for await event in engine.events.prefix(1) {
                return event
            }
            return nil
        }

        do {
            _ = try await engine.generate(request)
            XCTFail("Mock session was configured to throw — generate(_:) should have surfaced an error.")
        } catch {
            // Expected.
        }

        let received = await collectorTask.value
        guard case .failed = received else {
            XCTFail("Expected a `.failed` event on the AsyncStream after generate threw, got \(String(describing: received)).")
            return
        }
    }

    func testEventStreamBoundsBufferedPreviewPayloadsWhenConsumerStalls() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator(loadHandler: { _, capabilityProfile in
            return await NativeModelLoadResult.makeForTesting(
                model: UnsafeSpeechGenerationModel.makeFullySupportingForTesting(),
                capabilityProfile: capabilityProfile
            )
        })

        let chunkCount = 96
        let chunks: [GenerationEvent] = (0 ..< chunkCount).map { i in
            GenerationEvent(
                kind: .streamChunk,
                requestID: 1,
                mode: "custom",
                title: "Bounded Event Buffer",
                isFinal: i == chunkCount - 1,
                chunkDurationSeconds: 0.05,
                cumulativeDurationSeconds: 0.05 * Double(i + 1),
                previewAudio: StreamingAudioChunk(
                    requestID: 1,
                    sampleRate: 24_000,
                    frameOffset: Int64(i * 4),
                    frameCount: 4,
                    pcm16LE: Data(repeating: UInt8(i % 255), count: 4_096),
                    isFinal: false
                )
            )
        }
        let cannedOutputPath = temporaryRoot
            .appendingPathComponent("bounded-event-buffer.wav")
            .path
        let mockSession = MockNativeStreamingSession(
            events: chunks,
            result: GenerationResult(
                audioPath: cannedOutputPath,
                durationSeconds: 0.05 * Double(chunkCount),
                streamSessionDirectory: nil,
                benchmarkSample: nil
            )
        )

        let engine = MLXTTSEngine.makeForTesting(
            modelRegistry: registry,
            rootDirectory: temporaryRoot,
            loadCoordinator: coordinator,
            streamingSessionFactory: { _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
                mockSession
            }
        )
        try await engine.initialize(appSupportDirectory: temporaryRoot)
        try await engine.loadModel(id: "qwen3_custom_voice")

        _ = try await engine.generate(
            GenerationRequest(
                modelID: "qwen3_custom_voice",
                text: "Bounded event stream buffer.",
                outputPath: cannedOutputPath,
                shouldStream: true,
                streamingTitle: "Bounded Event Buffer",
                payload: .custom(speakerID: "vivian", deliveryStyle: nil)
            )
        )

        var received: [GenerationEvent] = []
        for await event in engine.events.prefix(64) {
            received.append(event)
        }

        XCTAssertEqual(received, Array(chunks.suffix(64)))
        XCTAssertEqual(engine.latestEvent, chunks.last)
    }

    // MARK: - Helpers

    private static func makeTemporaryRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXTTSEngineEventStreamTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func bundledManifestURL() throws -> URL {
        let bundles = [Bundle.main, Bundle(for: BundleLocator.self)] + Bundle.allBundles + Bundle.allFrameworks
        for bundle in bundles {
            if let url = bundle.url(forResource: "qwenvoice_contract", withExtension: "json") {
                return url
            }
        }
        throw NSError(
            domain: "MLXTTSEngineEventStreamTests",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate qwenvoice_contract.json in any test bundle."]
        )
    }

    private final class BundleLocator {}
}
