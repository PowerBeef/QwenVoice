import XCTest
@testable import QwenVoice

@MainActor
private final class MockBatchBridge: BatchGenerationBridging {
    struct CloneCall: Equatable {
        let modelID: String
        let text: String
        let refAudio: String
        let refText: String?
        let outputPath: String
        let batchIndex: Int?
        let batchTotal: Int?
    }

    struct CloneBatchCall: Equatable {
        let modelID: String
        let texts: [String]
        let refAudio: String
        let refText: String?
        let outputPaths: [String]
    }

    var cloneCalls: [CloneCall] = []
    var cloneBatchCalls: [CloneBatchCall] = []
    var cloneBatchProgressEvents: [(Double?, String)] = []
    var clearGenerationActivityCallCount = 0

    func generateCustomFlow(
        modelID: String,
        text: String,
        voice: String,
        emotion: String,
        outputPath: String,
        batchIndex: Int?,
        batchTotal: Int?
    ) async throws -> GenerationResult {
        GenerationResult(audioPath: outputPath, durationSeconds: 0.25, streamSessionDirectory: nil, metrics: nil)
    }

    func generateDesignFlow(
        modelID: String,
        text: String,
        voiceDescription: String,
        emotion: String,
        outputPath: String,
        batchIndex: Int?,
        batchTotal: Int?
    ) async throws -> GenerationResult {
        GenerationResult(audioPath: outputPath, durationSeconds: 0.25, streamSessionDirectory: nil, metrics: nil)
    }

    func generateCloneFlow(
        modelID: String,
        text: String,
        refAudio: String,
        refText: String?,
        outputPath: String,
        batchIndex: Int?,
        batchTotal: Int?
    ) async throws -> GenerationResult {
        cloneCalls.append(
            CloneCall(
                modelID: modelID,
                text: text,
                refAudio: refAudio,
                refText: refText,
                outputPath: outputPath,
                batchIndex: batchIndex,
                batchTotal: batchTotal
            )
        )
        return GenerationResult(audioPath: outputPath, durationSeconds: 0.25, streamSessionDirectory: nil, metrics: nil)
    }

    func generateCloneBatchFlow(
        modelID: String,
        texts: [String],
        refAudio: String,
        refText: String?,
        outputPaths: [String],
        progressHandler: ((Double?, String) -> Void)?
    ) async throws -> [GenerationResult] {
        cloneBatchCalls.append(
            CloneBatchCall(
                modelID: modelID,
                texts: texts,
                refAudio: refAudio,
                refText: refText,
                outputPaths: outputPaths
            )
        )
        for event in cloneBatchProgressEvents {
            progressHandler?(event.0, event.1)
        }
        return outputPaths.map {
            GenerationResult(audioPath: $0, durationSeconds: 0.25, streamSessionDirectory: nil, metrics: nil)
        }
    }

    func cancelActiveGenerationAndRestart(pythonPath: String, appSupportDir: String) async throws {}

    func clearGenerationActivity() {
        clearGenerationActivityCallCount += 1
    }
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
    func testCloneBatchUsesSharedReferenceBatchBridgePath() async throws {
        let bridge = MockBatchBridge()
        let store = MockGenerationStore()
        let runner = BatchGenerationRunner(bridge: bridge, store: store)
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
        let outcome = try await runner.run(
            request: request,
            makeOutputPath: { _, text in "/tmp/\(text.replacingOccurrences(of: " ", with: "_")).wav" },
            onProgress: { snapshot in
                progressSnapshots.append(snapshot)
            }
        )

        XCTAssertEqual(outcome, .completed(completedCount: 2))
        XCTAssertEqual(bridge.cloneBatchCalls.count, 1)
        XCTAssertTrue(bridge.cloneCalls.isEmpty)
        XCTAssertEqual(
            bridge.cloneBatchCalls.first,
            MockBatchBridge.CloneBatchCall(
                modelID: model.id,
                texts: ["First line", "Second line"],
                refAudio: "/tmp/reference.wav",
                refText: "Reference transcript",
                outputPaths: ["/tmp/First_line.wav", "/tmp/Second_line.wav"]
            )
        )
        XCTAssertEqual(store.savedGenerations.count, 2)
        XCTAssertEqual(progressSnapshots.first?.statusMessage, "Preparing batch...")
        XCTAssertEqual(progressSnapshots.last?.statusMessage, "Done")
    }

    @MainActor
    func testSingleCloneStillUsesLegacySingleItemBridgePath() async throws {
        let bridge = MockBatchBridge()
        let store = MockGenerationStore()
        let runner = BatchGenerationRunner(bridge: bridge, store: store)
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

        let outcome = try await runner.run(
            request: request,
            makeOutputPath: { _, _ in "/tmp/solo.wav" },
            onProgress: { _ in }
        )

        XCTAssertEqual(outcome, .completed(completedCount: 1))
        XCTAssertTrue(bridge.cloneBatchCalls.isEmpty)
        XCTAssertEqual(bridge.cloneCalls.count, 1)
        XCTAssertEqual(store.savedGenerations.count, 1)
    }

    @MainActor
    func testCloneBatchProgressSnapshotsIncludeBackendProgressEvents() async throws {
        let bridge = MockBatchBridge()
        bridge.cloneBatchProgressEvents = [
            (0.10, "Normalizing reference..."),
            (0.60, "Generating audio batch..."),
        ]
        let store = MockGenerationStore()
        let runner = BatchGenerationRunner(bridge: bridge, store: store)
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
        _ = try await runner.run(
            request: request,
            makeOutputPath: { _, text in "/tmp/\(text.replacingOccurrences(of: " ", with: "_")).wav" },
            onProgress: { snapshot in
                snapshots.append(snapshot)
            }
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
        let bridge = MockBatchBridge()
        bridge.cloneBatchProgressEvents = [
            (0.25, "Preparing voice context..."),
            (0.75, "Generating audio batch..."),
        ]
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
            bridge: bridge,
            store: store
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            coordinator.progressSnapshot.statusMessage == "Generating audio batch..."
                || coordinator.outcome == .completed(completedCount: 2)
        }

        XCTAssertEqual(coordinator.progressSnapshot.totalCount, 2)
        XCTAssertTrue(
            coordinator.progressSnapshot.statusMessage == "Generating audio batch..."
                || coordinator.outcome == .completed(completedCount: 2)
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            coordinator.outcome == .completed(completedCount: 2)
        }

        XCTAssertEqual(store.savedGenerations.count, 2)
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
