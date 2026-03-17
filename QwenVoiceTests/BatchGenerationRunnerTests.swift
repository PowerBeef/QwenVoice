import XCTest
@testable import QwenVoice
import Darwin

@MainActor
final class BatchGenerationRunnerTests: XCTestCase {
    func testRunPersistsAllCompletedItems() async throws {
        let bridge = FakeBatchBridge(behaviors: [.success, .success])
        let store = RecordingGenerationStore()
        let runner = BatchGenerationRunner(bridge: bridge, store: store)

        let outcome = try await runner.run(
            request: makeRequest(lines: ["First line", "Second line"]),
            makeOutputPath: makeOutputPath(subfolder:text:),
            onItemStarted: { _, _ in }
        )

        XCTAssertEqual(outcome, .completed(completedCount: 2))
        XCTAssertEqual(store.savedGenerations.map(\.text), ["First line", "Second line"])
        XCTAssertEqual(store.savedGenerations.map(\.modelTier), ["pro", "pro"])
    }

    func testImmediateCancelInterruptsInFlightGeneration() async throws {
        let bridge = FakeBatchBridge(behaviors: [.success, .waitForCancel])
        let store = RecordingGenerationStore()
        let runner = BatchGenerationRunner(bridge: bridge, store: store)

        let task = Task {
            try await runner.run(
                request: makeRequest(lines: ["First line", "Second line"]),
                makeOutputPath: makeOutputPath(subfolder:text:),
                onItemStarted: { _, _ in }
            )
        }

        await waitForPendingGeneration(in: bridge)
        try await runner.requestCancellation(
            pythonPath: "/opt/homebrew/bin/python3",
            appSupportDir: "/tmp/QwenVoiceTests"
        )
        let outcome = try await task.value

        XCTAssertEqual(outcome, .cancelled(completedCount: 1))
        XCTAssertEqual(store.savedGenerations.map(\.text), ["First line"])
        XCTAssertEqual(bridge.cancelRequests.count, 1)
        XCTAssertEqual(bridge.clearGenerationActivityCallCount, 1)
    }

    func testRestartFailureAfterCancelIsSurfaced() async throws {
        let bridge = FakeBatchBridge(
            behaviors: [.success, .waitForCancel],
            restartError: TestFailure("Restart failed")
        )
        let store = RecordingGenerationStore()
        let runner = BatchGenerationRunner(bridge: bridge, store: store)

        let task = Task {
            try await runner.run(
                request: makeRequest(lines: ["First line", "Second line"]),
                makeOutputPath: makeOutputPath(subfolder:text:),
                onItemStarted: { _, _ in }
            )
        }

        await waitForPendingGeneration(in: bridge)
        do {
            try await runner.requestCancellation(
                pythonPath: "/opt/homebrew/bin/python3",
                appSupportDir: "/tmp/QwenVoiceTests"
            )
            XCTFail("Cancellation restart failure should be thrown")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Restart failed")
        }

        let outcome = try await task.value
        XCTAssertEqual(outcome, .cancelled(completedCount: 1))
        XCTAssertEqual(store.savedGenerations.map(\.text), ["First line"])
    }

    func testOnlyCompletedItemsArePersistedWhenCancellationOccursMidBatch() async throws {
        let bridge = FakeBatchBridge(behaviors: [.success, .waitForCancel, .success])
        let store = RecordingGenerationStore()
        let runner = BatchGenerationRunner(bridge: bridge, store: store)

        let task = Task {
            try await runner.run(
                request: makeRequest(lines: ["First line", "Second line", "Third line"]),
                makeOutputPath: makeOutputPath(subfolder:text:),
                onItemStarted: { _, _ in }
            )
        }

        await waitForPendingGeneration(in: bridge)
        try await runner.requestCancellation(
            pythonPath: "/opt/homebrew/bin/python3",
            appSupportDir: "/tmp/QwenVoiceTests"
        )
        _ = try await task.value

        XCTAssertEqual(store.savedGenerations.count, 1)
        XCTAssertEqual(store.savedGenerations.first?.text, "First line")
    }

    private func waitForPendingGeneration(in bridge: FakeBatchBridge) async {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if bridge.hasPendingGeneration {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for a pending batch generation")
    }

    private func makeRequest(lines: [String]) -> BatchGenerationRequest {
        BatchGenerationRequest(
            mode: .custom,
            model: TTSModel.model(for: .custom)!,
            lines: lines,
            voice: TTSModel.defaultSpeaker,
            emotion: "Normal tone",
            deliveryProfile: nil,
            voiceDescription: nil,
            refAudio: nil,
            refText: nil
        )
    }

    private func makeOutputPath(subfolder: String, text: String) -> String {
        "/tmp/\(subfolder)/\(text.replacingOccurrences(of: " ", with: "_")).wav"
    }
}

@MainActor
private final class RecordingGenerationStore: GenerationPersisting {
    private(set) var savedGenerations: [Generation] = []

    func saveGeneration(_ generation: inout Generation) throws {
        generation.id = Int64(savedGenerations.count + 1)
        savedGenerations.append(generation)
    }
}

@MainActor
private final class FakeBatchBridge: BatchGenerationBridging {
    enum Behavior {
        case success
        case waitForCancel
    }

    private var behaviors: [Behavior]
    private var pendingContinuation: CheckedContinuation<GenerationResult, Error>?
    private let restartError: Error?

    private(set) var cancelRequests: [(pythonPath: String, appSupportDir: String)] = []
    private(set) var clearGenerationActivityCallCount = 0

    init(behaviors: [Behavior], restartError: Error? = nil) {
        self.behaviors = behaviors
        self.restartError = restartError
    }

    var hasPendingGeneration: Bool {
        pendingContinuation != nil
    }

    func generateCustomFlow(
        modelID: String,
        text: String,
        voice: String,
        emotion: String,
        outputPath: String,
        batchIndex: Int?,
        batchTotal: Int?
    ) async throws -> GenerationResult {
        try await generate(text: text, outputPath: outputPath)
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
        try await generate(text: text, outputPath: outputPath)
    }

    func generateCloneFlow(
        modelID: String,
        text: String,
        refAudio: String,
        refText: String?,
        emotion: String,
        deliveryProfile: DeliveryProfile?,
        outputPath: String,
        batchIndex: Int?,
        batchTotal: Int?
    ) async throws -> GenerationResult {
        try await generate(text: text, outputPath: outputPath)
    }

    func cancelActiveGenerationAndRestart(pythonPath: String, appSupportDir: String) async throws {
        cancelRequests.append((pythonPath, appSupportDir))
        pendingContinuation?.resume(throwing: PythonBridgeError.cancelled)
        pendingContinuation = nil

        if let restartError {
            throw restartError
        }
    }

    func clearGenerationActivity() {
        clearGenerationActivityCallCount += 1
    }

    private func generate(text: String, outputPath: String) async throws -> GenerationResult {
        let behavior = behaviors.removeFirst()
        switch behavior {
        case .success:
            return GenerationResult(from: [
                "audio_path": .string(outputPath),
                "duration_seconds": .double(1.25),
            ])
        case .waitForCancel:
            return try await withCheckedThrowingContinuation { continuation in
                pendingContinuation = continuation
            }
        }
    }
}

private struct TestFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

@MainActor
final class ModelManagerViewModelRecoveryTests: XCTestCase {
    func testErrorStateFallsBackToDiskAvailabilityAndRefreshes() async throws {
        let model = try XCTUnwrap(TTSModel.model(for: .design))
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("QwenVoiceModelManagerRecovery-\(UUID().uuidString)", isDirectory: true)
        let modelsDir = fixtureRoot.appendingPathComponent("models", isDirectory: true)
        let installDir = model.installDirectory(in: modelsDir)

        let previousOverride = ProcessInfo.processInfo.environment[AppPaths.appSupportOverrideEnvironmentKey]
        setenv(AppPaths.appSupportOverrideEnvironmentKey, fixtureRoot.path, 1)
        defer {
            if let previousOverride {
                setenv(AppPaths.appSupportOverrideEnvironmentKey, previousOverride, 1)
            } else {
                unsetenv(AppPaths.appSupportOverrideEnvironmentKey)
            }
            try? FileManager.default.removeItem(at: fixtureRoot)
        }

        for relativePath in model.requiredRelativePaths {
            let fileURL = installDir.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: fileURL.path, contents: Data("fixture".utf8))
        }

        let viewModel = ModelManagerViewModel()
        viewModel.statuses[model.id] = .error(message: "Simulated failure")

        XCTAssertTrue(
            viewModel.isAvailable(model),
            "A stale error state should not block generation when the model files are complete on disk"
        )

        await viewModel.refresh()

        guard case let .downloaded(sizeBytes) = viewModel.statuses[model.id] else {
            return XCTFail("Refresh should re-evaluate error states and mark complete models as downloaded")
        }
        XCTAssertGreaterThan(sizeBytes, 0, "Completed model fixtures should report a non-zero directory size")
    }
}

final class SidebarItemInitialSelectionTests: XCTestCase {
    func testDefaultInitialSelectionFallsBackToModelsWhenNoGenerationModelsAreInstalled() {
        let modelsDir = makeTemporaryModelsDirectory()
        defer { try? FileManager.default.removeItem(at: modelsDir.deletingLastPathComponent()) }

        XCTAssertEqual(
            SidebarItem.defaultInitialSelection(launchOverride: nil, modelsDirectory: modelsDir),
            .models
        )
    }

    func testDefaultInitialSelectionPrefersFirstAvailableGenerationDestination() throws {
        let modelsDir = makeTemporaryModelsDirectory()
        defer { try? FileManager.default.removeItem(at: modelsDir.deletingLastPathComponent()) }

        let designModel = try XCTUnwrap(TTSModel.model(for: .design))
        try installRequiredFixtureFiles(for: designModel, in: modelsDir)

        XCTAssertEqual(
            SidebarItem.defaultInitialSelection(launchOverride: nil, modelsDirectory: modelsDir),
            .voiceDesign
        )
    }

    func testDefaultInitialSelectionHonorsExplicitLaunchOverride() throws {
        let modelsDir = makeTemporaryModelsDirectory()
        defer { try? FileManager.default.removeItem(at: modelsDir.deletingLastPathComponent()) }

        let designModel = try XCTUnwrap(TTSModel.model(for: .design))
        try installRequiredFixtureFiles(for: designModel, in: modelsDir)

        XCTAssertEqual(
            SidebarItem.defaultInitialSelection(launchOverride: .customVoice, modelsDirectory: modelsDir),
            .customVoice
        )
    }

    private func makeTemporaryModelsDirectory() -> URL {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("QwenVoiceSidebarSelection-\(UUID().uuidString)", isDirectory: true)
        let modelsDir = fixtureRoot.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        return modelsDir
    }

    private func installRequiredFixtureFiles(for model: TTSModel, in modelsDir: URL) throws {
        let installDir = model.installDirectory(in: modelsDir)

        for relativePath in model.requiredRelativePaths {
            let fileURL = installDir.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: fileURL.path, contents: Data("fixture".utf8))
        }
    }
}
