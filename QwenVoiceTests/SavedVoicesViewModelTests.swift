import Combine
import XCTest
@testable import QwenVoice
import QwenVoiceNative

private final class SavedVoicesMockEngine: MacTTSEngine, @unchecked Sendable {
    private let subject: CurrentValueSubject<TTSEngineSnapshot, Never>
    private(set) var listPreparedVoicesCallCount = 0
    var preparedVoices: [PreparedVoice]

    init(
        snapshot: TTSEngineSnapshot,
        preparedVoices: [PreparedVoice]
    ) {
        self.subject = CurrentValueSubject(snapshot)
        self.preparedVoices = preparedVoices
    }

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
        throw NSError(domain: "SavedVoicesMockEngine", code: 1)
    }

    func generateBatch(
        _ requests: [GenerationRequest],
        progressHandler: (@Sendable (Double?, String) -> Void)?
    ) async throws -> [QwenVoiceNative.GenerationResult] {
        throw NSError(domain: "SavedVoicesMockEngine", code: 2)
    }

    func cancelActiveGeneration() async throws {}

    func listPreparedVoices() async throws -> [PreparedVoice] {
        listPreparedVoicesCallCount += 1
        return preparedVoices
    }

    func enrollPreparedVoice(name: String, audioPath: String, transcript: String?) async throws -> PreparedVoice {
        fatalError("Not needed in this test")
    }

    func deletePreparedVoice(id: String) async throws {}
    func clearGenerationActivity() {}
    func clearVisibleError() {}
}

final class SavedVoicesViewModelTests: XCTestCase {
    @MainActor
    func testRefreshLoadsPreparedVoicesThroughTTSEngineStore() async {
        SavedVoicesViewModel.resetSessionCacheForTesting()
        defer {
            SavedVoicesViewModel.resetSessionCacheForTesting()
        }

        let engine = SavedVoicesMockEngine(
            snapshot: TTSEngineSnapshot(
                isReady: true,
                loadState: .idle,
                clonePreparationState: .idle,
                visibleErrorMessage: nil
            ),
            preparedVoices: [
                PreparedVoice(
                    id: "Voice One",
                    name: "Voice One",
                    audioPath: "/tmp/voice-one.wav",
                    hasTranscript: true
                )
            ]
        )
        let store = TTSEngineStore(engine: engine)
        let viewModel = SavedVoicesViewModel()

        await viewModel.refresh(using: store)

        for _ in 0..<20 where viewModel.voices.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
            await Task.yield()
        }

        XCTAssertEqual(engine.listPreparedVoicesCallCount, 1)
        XCTAssertEqual(viewModel.voices.count, 1)
        XCTAssertEqual(viewModel.voices.first?.id, "Voice One")
        XCTAssertEqual(viewModel.voices.first?.wavPath, "/tmp/voice-one.wav")
        XCTAssertTrue(viewModel.voices.first?.hasTranscript ?? false)
    }
}
