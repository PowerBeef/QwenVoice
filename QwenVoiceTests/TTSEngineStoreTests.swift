import Combine
import Foundation
import XCTest
import QwenVoiceNative

@MainActor
private final class MockMacTTSEngine: MacTTSEngine {
    private let subject: CurrentValueSubject<TTSEngineSnapshot, Never>
    private(set) var generateRequests: [GenerationRequest] = []
    private(set) var batchGenerateRequests: [[GenerationRequest]] = []
    private(set) var prewarmRequests: [GenerationRequest] = []
    private(set) var primedReferences: [(String, CloneReference)] = []
    private(set) var cancelActiveGenerationCallCount = 0

    init(snapshot: TTSEngineSnapshot) {
        subject = CurrentValueSubject(snapshot)
    }

    var snapshot: TTSEngineSnapshot {
        subject.value
    }

    var snapshotPublisher: AnyPublisher<TTSEngineSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }

    func pushSnapshot(_ snapshot: TTSEngineSnapshot) {
        subject.send(snapshot)
    }

    func initialize(appSupportDirectory: URL) async throws {}
    func ping() async throws -> Bool { true }
    func loadModel(id: String) async throws {}
    func unloadModel() async throws {}
    func ensureModelLoadedIfNeeded(id: String) async {}

    func prewarmModelIfNeeded(for request: GenerationRequest) async {
        prewarmRequests.append(request)
    }

    func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {
        primedReferences.append((modelID, reference))
    }

    func cancelClonePreparationIfNeeded() async {}

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        generateRequests.append(request)
        return GenerationResult(
            audioPath: "/tmp/out.wav",
            durationSeconds: 1.25,
            streamSessionDirectory: nil,
            benchmarkSample: BenchmarkSample(streamingUsed: request.shouldStream)
        )
    }

    func generateBatch(
        _ requests: [GenerationRequest],
        progressHandler: ((Double?, String) -> Void)?
    ) async throws -> [GenerationResult] {
        batchGenerateRequests.append(requests)
        progressHandler?(0.5, "Generating batch...")
        return requests.enumerated().map { index, request in
            GenerationResult(
                audioPath: "/tmp/out-\(index).wav",
                durationSeconds: 1.25,
                streamSessionDirectory: nil,
                benchmarkSample: BenchmarkSample(streamingUsed: request.shouldStream)
            )
        }
    }

    func cancelActiveGeneration() async throws {
        cancelActiveGenerationCallCount += 1
    }

    func listPreparedVoices() async throws -> [PreparedVoice] { [] }

    func enrollPreparedVoice(name: String, audioPath: String, transcript: String?) async throws -> PreparedVoice {
        PreparedVoice(id: name, name: name, audioPath: audioPath, hasTranscript: !(transcript?.isEmpty ?? true))
    }

    func deletePreparedVoice(id: String) async throws {}
    func clearGenerationActivity() {}
    func clearVisibleError() {}
}

final class TTSEngineStoreTests: XCTestCase {
    @MainActor
    func testTTSEngineStoreMirrorsSnapshotUpdates() async throws {
        let initial = TTSEngineSnapshot(
            isReady: false,
            loadState: .starting,
            clonePreparationState: .idle,
            latestEvent: nil,
            visibleErrorMessage: nil
        )
        let engine = MockMacTTSEngine(snapshot: initial)
        let store = TTSEngineStore(engine: engine)

        XCTAssertFalse(store.isReady)
        XCTAssertEqual(store.loadState, .starting)

        let updated = TTSEngineSnapshot(
            isReady: true,
            loadState: .loaded(modelID: "pro_custom"),
            clonePreparationState: .primed(key: "clone-key"),
            latestEvent: GenerationEvent(
                kind: .streamChunk,
                requestID: 7,
                mode: "custom",
                title: "Hello",
                chunkPath: "/tmp/chunk.wav",
                isFinal: false
            ),
            visibleErrorMessage: nil
        )
        engine.pushSnapshot(updated)

        await Task.yield()

        XCTAssertTrue(store.isReady)
        XCTAssertEqual(store.loadState, .loaded(modelID: "pro_custom"))
        XCTAssertEqual(store.clonePreparationState, .primed(key: "clone-key"))
        XCTAssertEqual(store.latestEvent?.requestID, 7)
    }

    @MainActor
    func testTTSEngineStoreForwardsGenerateRequests() async throws {
        let engine = MockMacTTSEngine(
            snapshot: TTSEngineSnapshot(
                isReady: true,
                loadState: .loaded(modelID: "pro_custom"),
                clonePreparationState: .idle,
                latestEvent: nil,
                visibleErrorMessage: nil
            )
        )
        let store = TTSEngineStore(engine: engine)
        let request = GenerationRequest(
            modelID: "pro_custom",
            text: "Hello native world",
            outputPath: "/tmp/native.wav",
            shouldStream: true,
            streamingTitle: "Hello native world",
            payload: .custom(speakerID: "vivian", deliveryStyle: "Warm")
        )

        let result = try await store.generate(request)

        XCTAssertEqual(engine.generateRequests, [request])
        XCTAssertEqual(result.audioPath, "/tmp/out.wav")
        XCTAssertTrue(result.usedStreaming)
    }

    @MainActor
    func testTTSEngineStoreForwardsBatchGenerateRequests() async throws {
        let engine = MockMacTTSEngine(
            snapshot: TTSEngineSnapshot(
                isReady: true,
                loadState: .loaded(modelID: "pro_clone"),
                clonePreparationState: .idle,
                latestEvent: nil,
                visibleErrorMessage: nil
            )
        )
        let store = TTSEngineStore(engine: engine)
        let requests = [
            GenerationRequest(
                modelID: "pro_clone",
                text: "Hello",
                outputPath: "/tmp/one.wav",
                payload: .clone(reference: CloneReference(audioPath: "/tmp/ref.wav", transcript: "Bonjour"))
            ),
            GenerationRequest(
                modelID: "pro_clone",
                text: "Salut",
                outputPath: "/tmp/two.wav",
                payload: .clone(reference: CloneReference(audioPath: "/tmp/ref.wav", transcript: "Bonjour"))
            ),
        ]
        var progressUpdates: [(Double?, String)] = []

        let results = try await store.generateBatch(requests) { fraction, message in
            progressUpdates.append((fraction, message))
        }

        XCTAssertEqual(engine.batchGenerateRequests, [requests])
        XCTAssertEqual(results.map { $0.audioPath }, ["/tmp/out-0.wav", "/tmp/out-1.wav"])
        XCTAssertEqual(progressUpdates.count, 1)
        XCTAssertEqual(progressUpdates.first?.0, 0.5)
        XCTAssertEqual(progressUpdates.first?.1, "Generating batch...")
    }

    @MainActor
    func testTTSEngineStoreForwardsActiveGenerationCancellation() async throws {
        let engine = MockMacTTSEngine(
            snapshot: TTSEngineSnapshot(
                isReady: true,
                loadState: .loaded(modelID: "pro_clone"),
                clonePreparationState: .idle,
                latestEvent: nil,
                visibleErrorMessage: nil
            )
        )
        let store = TTSEngineStore(engine: engine)

        try await store.cancelActiveGeneration()

        XCTAssertEqual(engine.cancelActiveGenerationCallCount, 1)
    }
}
