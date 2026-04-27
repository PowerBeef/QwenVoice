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
    private(set) var generationRequests: [GenerationRequest] = []
    var generateError: Error?
    var generateResult: GenerationResult?
    var suspendGenerate = false
    private var generateContinuation: CheckedContinuation<Void, Never>?

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
        generationRequests.append(request)
        if suspendGenerate {
            await withCheckedContinuation { continuation in
                generateContinuation = continuation
            }
        }
        if let generateError {
            throw generateError
        }
        return generateResult ?? GenerationResult(
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

    func resumeSuspendedGenerate() {
        suspendGenerate = false
        generateContinuation?.resume()
        generateContinuation = nil
    }
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
    func testMacGenerationWarmupCoordinatorDebouncesToFinalSelectedMode() async {
        let (store, engine) = makeReadyStore()
        let coordinator = MacGenerationWarmupCoordinator(debounce: .milliseconds(5))
        let customModel = TTSModel.model(for: .custom)!
        let designModel = TTSModel.model(for: .design)!

        coordinator.scheduleWarmupIfNeeded(
            mode: .custom,
            modelID: customModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )
        coordinator.scheduleWarmupIfNeeded(
            mode: .design,
            modelID: designModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )

        await waitUntil(
            timeoutSeconds: 0.5,
            description: "root warmup sends only final mode"
        ) {
            engine.ensureModelLoadedIDs == [designModel.id]
        }
    }

    @MainActor
    func testMacGenerationWarmupCoordinatorSkipsWhenAnyModelIsLoaded() async {
        let (store, engine) = makeReadyStore()
        let coordinator = MacGenerationWarmupCoordinator(debounce: .milliseconds(5))
        let customModel = TTSModel.model(for: .custom)!
        let designModel = TTSModel.model(for: .design)!
        let loadedSnapshot = TTSEngineSnapshot(
            isReady: true,
            loadState: .loaded(modelID: customModel.id),
            clonePreparationState: .idle,
            visibleErrorMessage: nil
        )
        engine.pushSnapshot(loadedSnapshot)
        await Task.yield()

        coordinator.scheduleWarmupIfNeeded(
            mode: .design,
            modelID: designModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(engine.ensureModelLoadedIDs.isEmpty)
    }

    @MainActor
    func testMacGenerationWarmupCoordinatorCancelsStalePendingWarmup() async {
        let (store, engine) = makeReadyStore()
        let coordinator = MacGenerationWarmupCoordinator(debounce: .milliseconds(25))
        let customModel = TTSModel.model(for: .custom)!

        coordinator.scheduleWarmupIfNeeded(
            mode: .custom,
            modelID: customModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )
        coordinator.cancelPendingWarmup()
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertTrue(engine.ensureModelLoadedIDs.isEmpty)
    }

    @MainActor
    func testMacGenerationWarmupCoordinatorSkipsUnavailableModel() async {
        let (store, engine) = makeReadyStore()
        let coordinator = MacGenerationWarmupCoordinator(debounce: .milliseconds(5))
        let customModel = TTSModel.model(for: .custom)!

        coordinator.scheduleWarmupIfNeeded(
            mode: .custom,
            modelID: customModel.id,
            isModelAvailable: false,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(engine.ensureModelLoadedIDs.isEmpty)
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
    func testVoiceDesignCoordinatorDoesNotPresentSavedVoiceSheetForChangedDraft() {
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
                text: "A different line"
            )
        )

        XCTAssertNil(coordinator.presentedSheet)
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

        await waitUntil(
            timeoutSeconds: 1.0,
            description: "custom voice cancellation finishes"
        ) {
            coordinator.isGenerating == false
        }

        XCTAssertNil(coordinator.errorMessage)
        XCTAssertFalse(audioPlayer.isLiveStream)
    }

    @MainActor
    func testCustomVoiceCoordinatorLeavesGeneratingStateAfterEngineInterruption() async throws {
        let (store, engine) = makeReadyStore()
        engine.generateError = NSError(
            domain: "com.qwenvoice.xpc",
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey: "The engine service connection was interrupted.",
            ]
        )
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

        await waitUntil(
            timeoutSeconds: 1.0,
            description: "custom voice interruption finishes"
        ) {
            coordinator.isGenerating == false
        }

        XCTAssertEqual(
            coordinator.errorMessage,
            "The engine service connection was interrupted."
        )
        XCTAssertFalse(audioPlayer.isLiveStream)
    }

    @MainActor
    func testEngineReconnectSnapshotPreservesLoadedPlaybackState() async throws {
        let (store, engine) = makeReadyStore()
        let audioPlayer = AudioPlayerViewModel()
        audioPlayer.currentFilePath = "/tmp/final.wav"
        audioPlayer.currentTitle = "hello there"
        audioPlayer.duration = 1.2

        engine.pushSnapshot(
            TTSEngineSnapshot(
                isReady: false,
                loadState: .starting,
                clonePreparationState: .idle,
                visibleErrorMessage: "Reconnecting engine…"
            )
        )

        await waitUntil(
            timeoutSeconds: 1.0,
            description: "store enters reconnecting state"
        ) {
            store.frontendState.lifecycleState == .recovering
        }

        XCTAssertEqual(audioPlayer.currentFilePath, "/tmp/final.wav")
        XCTAssertEqual(audioPlayer.currentTitle, "hello there")
        XCTAssertEqual(audioPlayer.duration, 1.2)
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

        await waitUntil(
            timeoutSeconds: 1.0,
            description: "voice design cancellation finishes"
        ) {
            coordinator.isGenerating == false
        }

        XCTAssertNil(coordinator.errorMessage)
        XCTAssertFalse(audioPlayer.isLiveStream)
    }

    @MainActor
    func testVoiceDesignCoordinatorRejectsWhitespaceOnlyInputs() async throws {
        let (store, engine) = makeReadyStore()
        let coordinator = VoiceDesignCoordinator()
        let audioPlayer = AudioPlayerViewModel()
        let model = TTSModel.model(for: .design)

        coordinator.generate(
            draft: VoiceDesignDraft(
                voiceDescription: "   \n",
                emotion: "Conversational",
                text: "Design this voice"
            ),
            activeModel: model,
            isModelAvailable: true,
            ttsEngineStore: store,
            audioPlayer: audioPlayer,
            modelManager: ModelManagerViewModel()
        )
        coordinator.generate(
            draft: VoiceDesignDraft(
                voiceDescription: "Warm narrator",
                emotion: "Conversational",
                text: "  \n\t"
            ),
            activeModel: model,
            isModelAvailable: true,
            ttsEngineStore: store,
            audioPlayer: audioPlayer,
            modelManager: ModelManagerViewModel()
        )

        await Task.yield()

        XCTAssertFalse(coordinator.isGenerating)
        XCTAssertTrue(engine.generationRequests.isEmpty)
        XCTAssertFalse(audioPlayer.isLiveStream)
    }

    @MainActor
    func testVoiceDesignCoordinatorBuildsExpectedDesignGenerationRequest() throws {
        let model = try XCTUnwrap(TTSModel.model(for: .design))
        let draft = VoiceDesignDraft(
            voiceDescription: "Warm narrator",
            emotion: "Conversational",
            text: "Design this voice"
        )

        let request = VoiceDesignCoordinator.makeGenerationRequest(
            draft: draft,
            model: model,
            outputPath: "/tmp/design.wav"
        )

        XCTAssertEqual(request.modelID, model.id)
        XCTAssertEqual(request.text, "Design this voice")
        XCTAssertEqual(request.outputPath, "/tmp/design.wav")
        XCTAssertTrue(request.shouldStream)
        XCTAssertEqual(request.streamingTitle, "Design this voice")
        guard case .design(let voiceDescription, let deliveryStyle) = request.payload else {
            return XCTFail("Expected Voice Design payload")
        }
        XCTAssertEqual(voiceDescription, "Warm narrator")
        XCTAssertEqual(deliveryStyle, "Conversational")
    }

    @MainActor
    func testVoiceDesignCoordinatorPreventsDuplicateGenerationRequests() async throws {
        let (store, engine) = makeReadyStore()
        engine.suspendGenerate = true
        engine.generateError = CancellationError()
        let coordinator = VoiceDesignCoordinator()
        let audioPlayer = AudioPlayerViewModel()
        let draft = VoiceDesignDraft(
            voiceDescription: "Warm narrator",
            emotion: "Conversational",
            text: "Design this voice"
        )

        coordinator.generate(
            draft: draft,
            activeModel: TTSModel.model(for: .design),
            isModelAvailable: true,
            ttsEngineStore: store,
            audioPlayer: audioPlayer,
            modelManager: ModelManagerViewModel()
        )

        await waitUntil(
            timeoutSeconds: 1.0,
            description: "first voice design generation starts"
        ) {
            coordinator.isGenerating && engine.generationRequests.count == 1
        }

        coordinator.generate(
            draft: draft,
            activeModel: TTSModel.model(for: .design),
            isModelAvailable: true,
            ttsEngineStore: store,
            audioPlayer: audioPlayer,
            modelManager: ModelManagerViewModel()
        )

        XCTAssertEqual(engine.generationRequests.count, 1)

        engine.resumeSuspendedGenerate()

        await waitUntil(
            timeoutSeconds: 1.0,
            description: "deduped voice design generation finishes"
        ) {
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

        await waitUntil(
            timeoutSeconds: 1.0,
            description: "voice cloning cancellation finishes"
        ) {
            coordinator.isGenerating == false
        }

        XCTAssertNil(coordinator.errorMessage)
        XCTAssertFalse(audioPlayer.isLiveStream)
    }

    @MainActor
    func testVoiceDesignCoordinatorLeavesGeneratingStateAfterEngineInterruption() async throws {
        let (store, engine) = makeReadyStore()
        engine.generateError = NSError(
            domain: "com.qwenvoice.xpc",
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey: "The engine service connection was interrupted.",
            ]
        )
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

        await waitUntil(
            timeoutSeconds: 1.0,
            description: "voice design interruption finishes"
        ) {
            coordinator.isGenerating == false
        }

        XCTAssertEqual(
            coordinator.errorMessage,
            "The engine service connection was interrupted."
        )
        XCTAssertFalse(audioPlayer.isLiveStream)
    }
}
