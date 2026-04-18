import Combine
import XCTest
@testable import QwenVoice
import QwenVoiceNative

private final class MockBatchEngine: MacTTSEngine, @unchecked Sendable {
    private let subject = CurrentValueSubject<TTSEngineSnapshot, Never>(
        TTSEngineSnapshot(
            isReady: true,
            loadState: .loaded(modelID: "pro_clone"),
            clonePreparationState: .idle,
            visibleErrorMessage: nil
        )
    )

    var generateRequests: [GenerationRequest] = []
    var batchGenerateRequests: [[GenerationRequest]] = []
    var batchProgressEvents: [(Double?, String)] = []
    var cancelActiveGenerationCallCount = 0
    var clearGenerationActivityCallCount = 0

    var snapshot: TTSEngineSnapshot { subject.value }
    var snapshotPublisher: AnyPublisher<TTSEngineSnapshot, Never> { subject.eraseToAnyPublisher() }

    func initialize(appSupportDirectory: URL) async throws {}
    func ping() async throws -> Bool { true }
    func loadModel(id: String) async throws {}
    func unloadModel() async throws {}
    func ensureModelLoadedIfNeeded(id: String) async {}
    func prewarmModelIfNeeded(for request: GenerationRequest) async {}
    func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {}
    func cancelClonePreparationIfNeeded() async {}

    func generate(_ request: GenerationRequest) async throws -> QwenVoiceNative.GenerationResult {
        generateRequests.append(request)
        return QwenVoiceNative.GenerationResult(
            audioPath: request.outputPath,
            durationSeconds: 0.25,
            streamSessionDirectory: nil,
            benchmarkSample: BenchmarkSample(streamingUsed: request.shouldStream)
        )
    }

    func generateBatch(
        _ requests: [GenerationRequest],
        progressHandler: (@Sendable (Double?, String) -> Void)?
    ) async throws -> [QwenVoiceNative.GenerationResult] {
        batchGenerateRequests.append(requests)
        for event in batchProgressEvents {
            progressHandler?(event.0, event.1)
        }
        return requests.map {
            QwenVoiceNative.GenerationResult(
                audioPath: $0.outputPath,
                durationSeconds: 0.25,
                streamSessionDirectory: nil,
                benchmarkSample: BenchmarkSample(streamingUsed: $0.shouldStream)
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

    func clearGenerationActivity() {
        clearGenerationActivityCallCount += 1
    }

    func clearVisibleError() {}
}

@MainActor
private final class MockGenerationStore: GenerationPersisting {
    var savedGenerations: [Generation] = []

    func saveGeneration(_ generation: inout Generation) throws {
        generation.id = Int64(savedGenerations.count + 1)
        savedGenerations.append(generation)
    }
}

final class BatchGenerationRunnerTests: XCTestCase {
    @MainActor
    func testCustomBatchUsesEngineBatchPath() async throws {
        let engine = MockBatchEngine()
        let engineStore = TTSEngineStore(engine: engine)
        let store = MockGenerationStore()
        let runner = BatchGenerationRunner(engineStore: engineStore, store: store)
        let model = try XCTUnwrap(TTSModel.model(for: .custom))
        let request = BatchGenerationRequest(
            mode: .custom,
            model: model,
            lines: ["First line", "Second line"],
            voice: "vivian",
            emotion: "Normal tone",
            voiceDescription: nil,
            refAudio: nil,
            refText: nil
        )

        let outcome = await runner.run(
            request: request,
            makeOutputPath: { _, text in "/tmp/\(text.replacingOccurrences(of: " ", with: "_")).wav" },
            onProgress: { _ in },
            onItemsUpdated: { _ in }
        )

        guard case .completed(let items) = outcome else {
            return XCTFail("Expected completed outcome, got \(outcome)")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.filter(\.isSaved).count, 2)
        XCTAssertEqual(engine.batchGenerateRequests.count, 1)
        XCTAssertTrue(engine.generateRequests.isEmpty)
        XCTAssertEqual(
            engine.batchGenerateRequests.first?.map(\.text),
            ["First line", "Second line"]
        )
        XCTAssertEqual(store.savedGenerations.count, 2)
    }

    @MainActor
    func testCloneBatchUsesSharedReferenceEngineBatchPath() async throws {
        let engine = MockBatchEngine()
        let engineStore = TTSEngineStore(engine: engine)
        let store = MockGenerationStore()
        let runner = BatchGenerationRunner(engineStore: engineStore, store: store)
        let model = try XCTUnwrap(TTSModel.model(for: .clone))
        let request = BatchGenerationRequest(
            mode: .clone,
            model: model,
            lines: ["First line", "Second line"],
            voice: nil,
            emotion: nil,
            voiceDescription: nil,
            refAudio: "/tmp/reference.wav",
            refText: "Reference transcript"
        )

        var progressSnapshots: [BatchProgressSnapshot] = []
        let outcome = await runner.run(
            request: request,
            makeOutputPath: { _, text in "/tmp/\(text.replacingOccurrences(of: " ", with: "_")).wav" },
            onProgress: { snapshot in
                progressSnapshots.append(snapshot)
            },
            onItemsUpdated: { _ in }
        )

        guard case .completed(let items) = outcome else {
            return XCTFail("Expected completed outcome, got \(outcome)")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.filter(\.isSaved).count, 2)
        XCTAssertEqual(engine.batchGenerateRequests.count, 1)
        XCTAssertTrue(engine.generateRequests.isEmpty)
        XCTAssertEqual(
            engine.batchGenerateRequests.first?.map(\.text),
            ["First line", "Second line"]
        )
        XCTAssertEqual(
            engine.batchGenerateRequests.first?.map(\.outputPath),
            ["/tmp/First_line.wav", "/tmp/Second_line.wav"]
        )
        XCTAssertEqual(store.savedGenerations.count, 2)
        XCTAssertEqual(progressSnapshots.first?.statusMessage, "Preparing batch...")
        XCTAssertEqual(progressSnapshots.last?.statusMessage, "Done")
    }

    @MainActor
    func testSingleCloneStillUsesSingleRequestEnginePath() async throws {
        let engine = MockBatchEngine()
        let engineStore = TTSEngineStore(engine: engine)
        let store = MockGenerationStore()
        let runner = BatchGenerationRunner(engineStore: engineStore, store: store)
        let model = try XCTUnwrap(TTSModel.model(for: .clone))
        let request = BatchGenerationRequest(
            mode: .clone,
            model: model,
            lines: ["Solo line"],
            voice: nil,
            emotion: nil,
            voiceDescription: nil,
            refAudio: "/tmp/reference.wav",
            refText: "Reference transcript"
        )

        let outcome = await runner.run(
            request: request,
            makeOutputPath: { _, _ in "/tmp/solo.wav" },
            onProgress: { _ in },
            onItemsUpdated: { _ in }
        )

        guard case .completed(let items) = outcome else {
            return XCTFail("Expected completed outcome, got \(outcome)")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.status, .saved(audioPath: "/tmp/solo.wav"))
        XCTAssertTrue(engine.batchGenerateRequests.isEmpty)
        XCTAssertEqual(engine.generateRequests.count, 1)
        XCTAssertEqual(engine.generateRequests.first?.text, "Solo line")
        XCTAssertEqual(store.savedGenerations.count, 1)
    }

    @MainActor
    func testCloneBatchProgressSnapshotsIncludeBackendProgressEvents() async throws {
        let engine = MockBatchEngine()
        engine.batchProgressEvents = [
            (0.10, "Normalizing reference..."),
            (0.60, "Generating audio batch..."),
        ]
        let engineStore = TTSEngineStore(engine: engine)
        let store = MockGenerationStore()
        let runner = BatchGenerationRunner(engineStore: engineStore, store: store)
        let model = try XCTUnwrap(TTSModel.model(for: .clone))
        let request = BatchGenerationRequest(
            mode: .clone,
            model: model,
            lines: ["First line", "Second line"],
            voice: nil,
            emotion: nil,
            voiceDescription: nil,
            refAudio: "/tmp/reference.wav",
            refText: "Reference transcript"
        )

        var snapshots: [BatchProgressSnapshot] = []
        _ = await runner.run(
            request: request,
            makeOutputPath: { _, text in "/tmp/\(text.replacingOccurrences(of: " ", with: "_")).wav" },
            onProgress: { snapshot in
                snapshots.append(snapshot)
            },
            onItemsUpdated: { _ in }
        )

        XCTAssertTrue(
            snapshots.contains {
                $0.backendFraction == 0.10 && $0.statusMessage == "Normalizing reference..."
            }
        )
        XCTAssertTrue(
            snapshots.contains {
                $0.backendFraction == 0.60 && $0.statusMessage == "Generating audio batch..."
            }
        )
    }

    @MainActor
    func testCoordinatorTracksCloneBatchProgressSnapshots() async throws {
        let engine = MockBatchEngine()
        engine.batchProgressEvents = [
            (0.25, "Preparing voice context..."),
            (0.75, "Generating audio batch..."),
        ]
        let engineStore = TTSEngineStore(engine: engine)
        let store = MockGenerationStore()
        let coordinator = BatchGenerationCoordinator()
        let model = TTSModel(
            id: "test_clone",
            name: "Test Clone",
            tier: "test",
            folder: "TestClone",
            mode: .clone,
            huggingFaceRepo: "test/repo",
            outputSubfolder: "Clones",
            requiredRelativePaths: []
        )

        coordinator.startBatch(
            batchText: "First line\nSecond line",
            requestBuilder: { lines in
                BatchGenerationRequest(
                    mode: .clone,
                    model: model,
                    lines: lines,
                    voice: nil,
                    emotion: nil,
                    voiceDescription: nil,
                    refAudio: "/tmp/reference.wav",
                    refText: "Reference transcript"
                )
            },
            isModelAvailable: { _ in true },
            recoveryDetail: { _ in "Install model" },
            engineStore: engineStore,
            store: store
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            coordinator.progressSnapshot.statusMessage == "Generating audio batch..."
                || coordinator.outcome?.completedCount == 2
        }

        XCTAssertEqual(coordinator.progressSnapshot.totalCount, 2)
        XCTAssertTrue(
            coordinator.progressSnapshot.statusMessage == "Generating audio batch..."
                || coordinator.outcome?.completedCount == 2
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            coordinator.outcome?.completedCount == 2
        }

        guard case .completed(let items) = coordinator.outcome else {
            return XCTFail("Expected completed batch outcome, got \(String(describing: coordinator.outcome))")
        }
        XCTAssertEqual(items.filter(\.isSaved).count, 2)
        XCTAssertEqual(coordinator.itemStates.filter(\.isSaved).count, 2)
        XCTAssertEqual(store.savedGenerations.count, 2)
    }

    @MainActor
    func testRunnerCancellationUsesEngineStoreCancellation() async throws {
        let engine = MockBatchEngine()
        let engineStore = TTSEngineStore(engine: engine)
        let store = MockGenerationStore()
        let runner = BatchGenerationRunner(engineStore: engineStore, store: store)

        try await runner.requestCancellation()

        XCTAssertEqual(engine.cancelActiveGenerationCallCount, 1)
    }

    func testBatchGenerationOutcomeRetryHelpersSeparateRemainingAndFailedLines() {
        let outcome = BatchGenerationOutcome.cancelled(
            items: [
                BatchGenerationItemState(index: 0, line: "Saved line", status: .saved(audioPath: "/tmp/saved.wav")),
                BatchGenerationItemState(index: 1, line: "Pending line", status: .pending),
                BatchGenerationItemState(index: 2, line: "Failed line", status: .failed(message: "boom")),
                BatchGenerationItemState(index: 3, line: "Cancelled line", status: .cancelled),
            ],
            restartFailedMessage: nil
        )

        XCTAssertEqual(outcome.completedCount, 1)
        XCTAssertEqual(outcome.retryRemainingLines, ["Pending line", "Cancelled line"])
        XCTAssertEqual(outcome.retryFailedLines, ["Failed line"])
        XCTAssertEqual(outcome.savedAudioPaths, ["/tmp/saved.wav"])
    }

    @MainActor
    private func waitUntil(
        timeoutSeconds: TimeInterval,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}
