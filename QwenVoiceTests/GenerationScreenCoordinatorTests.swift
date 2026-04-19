import Combine
import Foundation
import SwiftUI
import XCTest
import QwenVoiceNative
@testable import QwenVoice

private final class GenerationScreenMockMacTTSEngine: MacTTSEngine, @unchecked Sendable {
    private let subject: CurrentValueSubject<TTSEngineSnapshot, Never>
    private(set) var ensureModelLoadedIDs: [String] = []
    private(set) var prewarmRequests: [GenerationRequest] = []
    private(set) var primedReferences: [(String, CloneReference)] = []
    var generateError: Error?

    init(snapshot: TTSEngineSnapshot) {
        subject = CurrentValueSubject(snapshot)
    }

    var snapshot: TTSEngineSnapshot {
        subject.value
    }

    var snapshotPublisher: AnyPublisher<TTSEngineSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }

    func initialize(appSupportDirectory: URL) async throws {}
    func ping() async throws -> Bool { true }
    func loadModel(id: String) async throws {}
    func unloadModel() async throws {}

    func ensureModelLoadedIfNeeded(id: String) async {
        ensureModelLoadedIDs.append(id)
    }

    func prewarmModelIfNeeded(for request: GenerationRequest) async {
        prewarmRequests.append(request)
    }

    func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {
        primedReferences.append((modelID, reference))
    }

    func cancelClonePreparationIfNeeded() async {}

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        if let generateError {
            throw generateError
        }
        return GenerationResult(
            audioPath: "/tmp/out.wav",
            durationSeconds: 1.0,
            streamSessionDirectory: nil,
            benchmarkSample: BenchmarkSample(streamingUsed: request.shouldStream)
        )
    }

    func generateBatch(
        _ requests: [GenerationRequest],
        progressHandler: (@Sendable (Double?, String) -> Void)?
    ) async throws -> [GenerationResult] {
        []
    }

    func cancelActiveGeneration() async throws {}
    func listPreparedVoices() async throws -> [PreparedVoice] { [] }

    func enrollPreparedVoice(name: String, audioPath: String, transcript: String?) async throws -> PreparedVoice {
        PreparedVoice(id: name, name: name, audioPath: audioPath, hasTranscript: !(transcript?.isEmpty ?? true))
    }

    func deletePreparedVoice(id: String) async throws {}
    func clearGenerationActivity() {}
    func clearVisibleError() {}
}

final class GenerationScreenCoordinatorTests: XCTestCase {
    @MainActor
    private func makeReadyStore() -> (TTSEngineStore, GenerationScreenMockMacTTSEngine) {
        let engine = GenerationScreenMockMacTTSEngine(
            snapshot: TTSEngineSnapshot(
                isReady: true,
                loadState: .idle,
                clonePreparationState: .idle,
                visibleErrorMessage: nil
            )
        )
        return (TTSEngineStore(engine: engine), engine)
    }

    @MainActor
    func testCustomVoiceCoordinatorWarmupLoadsModelOncePerActivation() async {
        let (store, engine) = makeReadyStore()
        let coordinator = CustomVoiceCoordinator()
        let model = TTSModel.model(for: .custom)

        await coordinator.handleScreenActivation(
            activationID: 1,
            model: model,
            isModelAvailable: true,
            ttsEngineStore: store
        )
        await coordinator.handleScreenActivation(
            activationID: 1,
            model: model,
            isModelAvailable: true,
            ttsEngineStore: store
        )
        await coordinator.handleScreenActivation(
            activationID: 2,
            model: model,
            isModelAvailable: true,
            ttsEngineStore: store
        )

        XCTAssertEqual(engine.ensureModelLoadedIDs, [model?.id, model?.id].compactMap { $0 })
    }

    func testCustomVoiceCoordinatorIdlePrewarmRequestRequiresScript() {
        let model = TTSModel.model(for: .custom)!

        XCTAssertNil(
            CustomVoiceCoordinator.makeIdlePrewarmRequest(
                draft: CustomVoiceDraft(
                    selectedSpeaker: "Vivian",
                    emotion: "Normal tone",
                    text: "   "
                ),
                model: model
            )
        )

        XCTAssertEqual(
            CustomVoiceCoordinator.makeIdlePrewarmRequest(
                draft: CustomVoiceDraft(
                    selectedSpeaker: "Vivian",
                    emotion: "Normal tone",
                    text: "Hello there"
                ),
                model: model
            )?.modelID,
            model.id
        )
    }

    @MainActor
    func testVoiceDesignCoordinatorPresentsSavedVoiceSheetForMatchingCandidate() {
        let coordinator = VoiceDesignCoordinator()
        coordinator.latestSavedVoiceCandidate = VoiceDesignSavedVoiceCandidate(
            audioPath: "/tmp/design.wav",
            transcript: "Keep this line",
            suggestedName: "Warm_narrator",
            voiceDescription: "Warm narrator",
            emotion: "Conversational",
            text: "Keep this line"
        )

        coordinator.presentSavedVoiceSheet(
            for: VoiceDesignDraft(
                voiceDescription: "Warm narrator",
                emotion: "Conversational",
                text: "Keep this line"
            )
        )

        guard case .saveVoice(let configuration) = coordinator.presentedSheet else {
            return XCTFail("Expected save voice sheet presentation")
        }
        XCTAssertEqual(configuration.initialAudioPath, "/tmp/design.wav")
        XCTAssertEqual(configuration.initialTranscript, "Keep this line")
    }

    @MainActor
    func testVoiceDesignCoordinatorHandleSavedVoiceMarksCandidateAndEmitsAlert() async {
        let (store, _) = makeReadyStore()
        let coordinator = VoiceDesignCoordinator()
        let draft = VoiceDesignDraft(
            voiceDescription: "Warm narrator",
            emotion: "Conversational",
            text: "Keep this line"
        )
        coordinator.latestSavedVoiceCandidate = VoiceDesignSavedVoiceCandidate(
            audioPath: "/tmp/design.wav",
            transcript: "Keep this line",
            suggestedName: "Warm_narrator",
            voiceDescription: "Warm narrator",
            emotion: "Conversational",
            text: "Keep this line"
        )

        coordinator.handleSavedVoice(
            Voice(name: "Warm_narrator", wavPath: "/tmp/design.wav", hasTranscript: true),
            draft: draft,
            savedVoicesViewModel: SavedVoicesViewModel(),
            ttsEngineStore: store
        )
        await Task.yield()

        XCTAssertEqual(coordinator.latestSavedVoiceCandidate?.savedVoiceName, "Warm_narrator")
        XCTAssertEqual(coordinator.actionAlert?.title, "Saved Voice Added")
    }

    @MainActor
    func testVoiceCloningCoordinatorWarmupLoadsModelWithoutPrimingReference() async {
        let (store, engine) = makeReadyStore()
        let coordinator = VoiceCloningCoordinator()
        let model = TTSModel.model(for: .clone)

        await coordinator.handleScreenActivation(
            activationID: 1,
            cloneModel: model,
            isModelAvailable: true,
            ttsEngineStore: store
        )

        XCTAssertEqual(engine.ensureModelLoadedIDs, [model?.id].compactMap { $0 })
        XCTAssertTrue(engine.primedReferences.isEmpty)
    }

    @MainActor
    func testVoiceCloningCoordinatorPresentBatchCapturesReferenceContext() {
        let coordinator = VoiceCloningCoordinator()
        let draft = VoiceCloningDraft(
            selectedSavedVoiceID: "voice-123",
            referenceAudioPath: "/tmp/reference.wav",
            referenceTranscript: "Reference transcript",
            text: "Clone this line"
        )

        coordinator.presentBatch(draft: draft)

        guard case .batch(let configuration) = coordinator.presentedSheet else {
            return XCTFail("Expected clone batch sheet presentation")
        }
        XCTAssertEqual(configuration.mode, .clone)
        XCTAssertEqual(configuration.refAudio, "/tmp/reference.wav")
        XCTAssertEqual(configuration.refText, "Reference transcript")
    }

    @MainActor
    func testCustomVoiceCoordinatorSwallowsCancellationWithoutErrorBanner() async throws {
        let (store, engine) = makeReadyStore()
        engine.generateError = CancellationError()
        let coordinator = CustomVoiceCoordinator()
        let audioPlayer = AudioPlayerViewModel()

        coordinator.generate(
            draft: CustomVoiceDraft(
                selectedSpeaker: "Vivian",
                emotion: "Normal tone",
                text: "Hello there"
            ),
            activeModel: TTSModel.model(for: .custom),
            isModelAvailable: true,
            ttsEngineStore: store,
            audioPlayer: audioPlayer,
            modelManager: ModelManagerViewModel()
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            coordinator.isGenerating == false
        }

        XCTAssertNil(coordinator.errorMessage)
        XCTAssertFalse(audioPlayer.isLiveStream)
    }

    @MainActor
    func testVoiceDesignCoordinatorSwallowsCancellationWithoutErrorBanner() async throws {
        let (store, engine) = makeReadyStore()
        engine.generateError = CancellationError()
        let coordinator = VoiceDesignCoordinator()
        let audioPlayer = AudioPlayerViewModel()

        coordinator.generate(
            draft: VoiceDesignDraft(
                voiceDescription: "Warm narrator",
                emotion: "Conversational",
                text: "Design this voice"
            ),
            activeModel: TTSModel.model(for: .design),
            isModelAvailable: true,
            ttsEngineStore: store,
            audioPlayer: audioPlayer,
            modelManager: ModelManagerViewModel()
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            coordinator.isGenerating == false
        }

        XCTAssertNil(coordinator.errorMessage)
        XCTAssertFalse(audioPlayer.isLiveStream)
    }

    @MainActor
    func testVoiceCloningCoordinatorSwallowsCancellationWithoutErrorBanner() async throws {
        let (store, engine) = makeReadyStore()
        engine.generateError = CancellationError()
        let coordinator = VoiceCloningCoordinator()
        let audioPlayer = AudioPlayerViewModel()
        let draft = Binding(
            get: {
                VoiceCloningDraft(
                    selectedSavedVoiceID: nil,
                    referenceAudioPath: "/tmp/reference.wav",
                    referenceTranscript: "Reference transcript",
                    text: "Clone this line"
                )
            },
            set: { _ in }
        )

        coordinator.generate(
            draft: draft,
            cloneModel: TTSModel.model(for: .clone),
            isModelAvailable: true,
            clonePrimingRequestKey: nil,
            selectedVoice: nil,
            ttsEngineStore: store,
            audioPlayer: audioPlayer,
            modelManager: ModelManagerViewModel()
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            coordinator.isGenerating == false
        }

        XCTAssertNil(coordinator.errorMessage)
        XCTAssertFalse(audioPlayer.isLiveStream)
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
