import Combine
import Foundation
import SwiftUI
import XCTest
import QwenVoiceCore
import QwenVoiceNative
@testable import QwenVoice

private final class GenerationScreenMockMacTTSEngine: MacTTSEngine, @unchecked Sendable {
    private let subject: CurrentValueSubject<TTSEngineSnapshot, Never>
    private(set) var ensureModelLoadedIDs: [String] = []
    private(set) var prewarmRequests: [GenerationRequest] = []
    private(set) var prefetchRequests: [GenerationRequest] = []
    private(set) var primedReferences: [(String, CloneReference)] = []
    private(set) var cancelClonePreparationCount = 0
    private(set) var unloadModelCount = 0
    private(set) var generationRequests: [GenerationRequest] = []
    var unloadModelError: Error?
    var suspendUnload = false
    private var unloadContinuation: CheckedContinuation<Void, Never>?
    var generateError: Error?
    var generateResult: GenerationResult?
    var suspendGenerate = false
    private var generateContinuation: CheckedContinuation<Void, Never>?
    var suspendPrewarm = false
    private var prewarmContinuation: CheckedContinuation<Void, Never>?
    var suspendPrefetch = false
    var prefetchDiagnostics = InteractivePrefetchDiagnostics(
        timingsMS: ["custom_prewarm_eval_ms": 12],
        booleanFlags: ["custom_stream_step_prewarmed": true],
        requestKey: "custom-test"
    )
    private var prefetchContinuation: CheckedContinuation<Void, Never>?

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

    func unloadModel() async throws {
        unloadModelCount += 1
        if suspendUnload {
            await withCheckedContinuation { continuation in
                unloadContinuation = continuation
            }
        }
        if let unloadModelError {
            throw unloadModelError
        }
        subject.send(
            TTSEngineSnapshot(
                isReady: subject.value.isReady,
                loadState: .idle,
                clonePreparationState: subject.value.clonePreparationState,
                visibleErrorMessage: subject.value.visibleErrorMessage
            )
        )
    }

    func ensureModelLoadedIfNeeded(id: String) async {
        ensureModelLoadedIDs.append(id)
    }

    func prewarmModelIfNeeded(for request: GenerationRequest) async {
        prewarmRequests.append(request)
        if suspendPrewarm {
            await withCheckedContinuation { continuation in
                prewarmContinuation = continuation
            }
        }
    }

    func prefetchInteractiveReadinessIfNeeded(
        for request: GenerationRequest
    ) async -> InteractivePrefetchDiagnostics? {
        prefetchRequests.append(request)
        if suspendPrefetch {
            await withCheckedContinuation { continuation in
                prefetchContinuation = continuation
            }
        }
        return prefetchDiagnostics
    }

    func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {
        primedReferences.append((modelID, reference))
    }

    func cancelClonePreparationIfNeeded() async {
        cancelClonePreparationCount += 1
    }

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

    func resumeSuspendedUnload() {
        suspendUnload = false
        unloadContinuation?.resume()
        unloadContinuation = nil
    }

    func resumeSuspendedPrefetch() {
        suspendPrefetch = false
        prefetchContinuation?.resume()
        prefetchContinuation = nil
    }

    func resumeSuspendedPrewarm() {
        suspendPrewarm = false
        prewarmContinuation?.resume()
        prewarmContinuation = nil
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
        let coordinator = MacGenerationWarmupCoordinator(
            debounce: .milliseconds(5),
            customVoiceDebounce: .milliseconds(5)
        )
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
        XCTAssertTrue(engine.prewarmRequests.isEmpty)
        XCTAssertTrue(engine.prefetchRequests.isEmpty)
    }

    @MainActor
    func testMacGenerationWarmupCoordinatorUsesFullInteractiveCustomVoicePrewarm() async throws {
        let (store, engine) = makeReadyStore()
        let coordinator = MacGenerationWarmupCoordinator(
            debounce: .milliseconds(5),
            customVoiceDebounce: .milliseconds(5)
        )
        let customModel = TTSModel.model(for: .custom)!

        coordinator.scheduleWarmupIfNeeded(
            mode: .custom,
            modelID: customModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )

        await waitUntil(
            timeoutSeconds: 0.5,
            description: "custom voice warmup sends full interactive prefetch"
        ) {
            engine.prefetchRequests.count == 1
        }

        XCTAssertTrue(engine.ensureModelLoadedIDs.isEmpty)
        XCTAssertTrue(engine.prewarmRequests.isEmpty)
        let request = try XCTUnwrap(engine.prefetchRequests.first)
        XCTAssertEqual(request.modelID, customModel.id)
        XCTAssertEqual(request.text, QwenVoiceCore.GenerationSemantics.canonicalCustomWarmText)
        XCTAssertEqual(request.streamingInterval, QwenVoiceCore.GenerationSemantics.appStreamingInterval)
        guard case .custom(let speakerID, let deliveryStyle) = request.payload else {
            return XCTFail("Expected Custom Voice prewarm request")
        }
        XCTAssertEqual(speakerID, QwenVoiceCore.GenerationSemantics.canonicalCustomWarmSpeaker)
        XCTAssertEqual(deliveryStyle, QwenVoiceCore.GenerationSemantics.canonicalCustomWarmInstruction())
    }

    @MainActor
    func testMacGenerationWarmupCoordinatorRetriesAfterReconnectReturnsIdle() async {
        let (store, engine) = makeReadyStore()
        let coordinator = MacGenerationWarmupCoordinator(
            debounce: .milliseconds(5),
            customVoiceDebounce: .milliseconds(5)
        )
        let customModel = TTSModel.model(for: .custom)!

        coordinator.scheduleWarmupIfNeeded(
            mode: .custom,
            modelID: customModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )

        await waitUntil(
            timeoutSeconds: 0.5,
            description: "initial custom voice warmup sends prefetch"
        ) {
            engine.prefetchRequests.count == 1
        }

        coordinator.observe(
            snapshot: TTSEngineSnapshot(
                isReady: true,
                loadState: .idle,
                clonePreparationState: .idle,
                visibleErrorMessage: nil
            )
        )
        coordinator.scheduleWarmupIfNeeded(
            mode: .custom,
            modelID: customModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )

        await waitUntil(
            timeoutSeconds: 0.5,
            description: "reconnected idle custom voice warmup retries prefetch"
        ) {
            engine.prefetchRequests.count == 2
        }
    }

    @MainActor
    func testMacGenerationWarmupCoordinatorDedupesDuplicateCustomVoicePrewarmWhileInFlight() async {
        let (store, engine) = makeReadyStore()
        let coordinator = MacGenerationWarmupCoordinator(
            debounce: .milliseconds(5),
            customVoiceDebounce: .milliseconds(5)
        )
        let customModel = TTSModel.model(for: .custom)!
        engine.suspendPrefetch = true

        coordinator.scheduleWarmupIfNeeded(
            mode: .custom,
            modelID: customModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )

        await waitUntil(
            timeoutSeconds: 0.5,
            description: "custom voice prefetch starts"
        ) {
            engine.prefetchRequests.count == 1
        }

        coordinator.scheduleWarmupIfNeeded(
            mode: .custom,
            modelID: customModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(engine.prefetchRequests.count, 1)
        XCTAssertTrue(engine.prewarmRequests.isEmpty)
        engine.resumeSuspendedPrefetch()
    }

    @MainActor
    func testMacGenerationWarmupCoordinatorUnloadsDifferentLoadedModelThenWarmsFinalMode() async {
        let (store, engine) = makeReadyStore()
        let coordinator = MacGenerationWarmupCoordinator(
            debounce: .milliseconds(5),
            customVoiceDebounce: .milliseconds(5),
            modeTransitionDebounce: .milliseconds(5)
        )
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

        await waitUntil(
            timeoutSeconds: 0.5,
            description: "loaded different model unloads before warming selected mode"
        ) {
            engine.unloadModelCount == 1 && engine.ensureModelLoadedIDs == [designModel.id]
        }
        XCTAssertTrue(engine.prefetchRequests.isEmpty)
    }

    @MainActor
    func testMacGenerationWarmupCoordinatorRapidLoadedModeSwitchOnlyWarmsFinalMode() async {
        let (store, engine) = makeReadyStore()
        let coordinator = MacGenerationWarmupCoordinator(
            debounce: .milliseconds(5),
            customVoiceDebounce: .milliseconds(5),
            modeTransitionDebounce: .milliseconds(25)
        )
        let customModel = TTSModel.model(for: .custom)!
        let designModel = TTSModel.model(for: .design)!
        let cloneModel = TTSModel.model(for: .clone)!
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
        coordinator.scheduleWarmupIfNeeded(
            mode: .clone,
            modelID: cloneModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )

        await waitUntil(
            timeoutSeconds: 0.5,
            description: "only final loaded-mode switch runs"
        ) {
            engine.unloadModelCount == 1 && engine.ensureModelLoadedIDs == [cloneModel.id]
        }
        XCTAssertTrue(engine.prefetchRequests.isEmpty)
    }

    @MainActor
    func testMacGenerationWarmupCoordinatorStaleTransitionDoesNotWarmOriginalModeAfterUnload() async {
        let (store, engine) = makeReadyStore()
        let coordinator = MacGenerationWarmupCoordinator(
            debounce: .milliseconds(5),
            customVoiceDebounce: .milliseconds(5),
            modeTransitionDebounce: .milliseconds(5)
        )
        let customModel = TTSModel.model(for: .custom)!
        let designModel = TTSModel.model(for: .design)!
        let cloneModel = TTSModel.model(for: .clone)!
        engine.suspendUnload = true
        engine.pushSnapshot(
            TTSEngineSnapshot(
                isReady: true,
                loadState: .loaded(modelID: customModel.id),
                clonePreparationState: .idle,
                visibleErrorMessage: nil
            )
        )
        await Task.yield()

        coordinator.scheduleWarmupIfNeeded(
            mode: .design,
            modelID: designModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )
        await waitUntil(
            timeoutSeconds: 0.5,
            description: "initial transition starts unload"
        ) {
            engine.unloadModelCount == 1
        }

        coordinator.scheduleWarmupIfNeeded(
            mode: .clone,
            modelID: cloneModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )
        engine.resumeSuspendedUnload()
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(engine.ensureModelLoadedIDs.isEmpty)

        coordinator.observe(snapshot: store.snapshot)
        coordinator.scheduleWarmupIfNeeded(
            mode: .clone,
            modelID: cloneModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )

        await waitUntil(
            timeoutSeconds: 0.5,
            description: "final selection can warm after stale transition exits"
        ) {
            engine.ensureModelLoadedIDs == [cloneModel.id]
        }
    }

    @MainActor
    func testMacGenerationWarmupCoordinatorLoadedSameDesignModelDoesNoWork() async {
        let (store, engine) = makeReadyStore()
        let coordinator = MacGenerationWarmupCoordinator(
            debounce: .milliseconds(5),
            customVoiceDebounce: .milliseconds(5),
            modeTransitionDebounce: .milliseconds(5)
        )
        let designModel = TTSModel.model(for: .design)!
        engine.pushSnapshot(
            TTSEngineSnapshot(
                isReady: true,
                loadState: .loaded(modelID: designModel.id),
                clonePreparationState: .idle,
                visibleErrorMessage: nil
            )
        )
        await Task.yield()

        coordinator.scheduleWarmupIfNeeded(
            mode: .design,
            modelID: designModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(engine.unloadModelCount, 0)
        XCTAssertTrue(engine.ensureModelLoadedIDs.isEmpty)
        XCTAssertTrue(engine.prefetchRequests.isEmpty)
    }

    @MainActor
    func testMacGenerationWarmupCoordinatorSkipsTransitionsWhileStartingOrRunning() async {
        let (store, engine) = makeReadyStore()
        let coordinator = MacGenerationWarmupCoordinator(
            debounce: .milliseconds(5),
            customVoiceDebounce: .milliseconds(5),
            modeTransitionDebounce: .milliseconds(5)
        )
        let customModel = TTSModel.model(for: .custom)!
        let designModel = TTSModel.model(for: .design)!

        engine.pushSnapshot(
            TTSEngineSnapshot(
                isReady: true,
                loadState: .starting,
                clonePreparationState: .idle,
                visibleErrorMessage: nil
            )
        )
        await Task.yield()
        coordinator.scheduleWarmupIfNeeded(
            mode: .custom,
            modelID: customModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )

        engine.pushSnapshot(
            TTSEngineSnapshot(
                isReady: true,
                loadState: .running(modelID: customModel.id, label: nil, fraction: nil),
                clonePreparationState: .idle,
                visibleErrorMessage: nil
            )
        )
        await Task.yield()
        coordinator.scheduleWarmupIfNeeded(
            mode: .design,
            modelID: designModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(engine.unloadModelCount, 0)
        XCTAssertTrue(engine.ensureModelLoadedIDs.isEmpty)
        XCTAssertTrue(engine.prefetchRequests.isEmpty)
    }

    @MainActor
    func testMacGenerationWarmupCoordinatorStopsTransitionWhenUnloadFails() async {
        enum TestUnloadError: Error {
            case failed
        }

        let (store, engine) = makeReadyStore()
        let coordinator = MacGenerationWarmupCoordinator(
            debounce: .milliseconds(5),
            customVoiceDebounce: .milliseconds(5),
            modeTransitionDebounce: .milliseconds(5)
        )
        let customModel = TTSModel.model(for: .custom)!
        let designModel = TTSModel.model(for: .design)!
        engine.unloadModelError = TestUnloadError.failed
        engine.pushSnapshot(
            TTSEngineSnapshot(
                isReady: true,
                loadState: .loaded(modelID: customModel.id),
                clonePreparationState: .idle,
                visibleErrorMessage: nil
            )
        )
        await Task.yield()

        coordinator.scheduleWarmupIfNeeded(
            mode: .design,
            modelID: designModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )

        await waitUntil(
            timeoutSeconds: 0.5,
            description: "failed unload is attempted"
        ) {
            engine.unloadModelCount == 1
        }
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(engine.ensureModelLoadedIDs.isEmpty)
        XCTAssertTrue(engine.prefetchRequests.isEmpty)
    }

    @MainActor
    func testMacGenerationWarmupCoordinatorRefreshesCustomVoiceWhenSelectedModelIsLoaded() async {
        let (store, engine) = makeReadyStore()
        let coordinator = MacGenerationWarmupCoordinator(
            debounce: .milliseconds(5),
            customVoiceDebounce: .milliseconds(5)
        )
        let customModel = TTSModel.model(for: .custom)!
        let loadedSnapshot = TTSEngineSnapshot(
            isReady: true,
            loadState: .loaded(modelID: customModel.id),
            clonePreparationState: .idle,
            visibleErrorMessage: nil
        )
        engine.pushSnapshot(loadedSnapshot)
        await Task.yield()

        coordinator.scheduleWarmupIfNeeded(
            mode: .custom,
            modelID: customModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )

        await waitUntil(
            timeoutSeconds: 0.5,
            description: "custom voice loaded-state warmup refreshes readiness"
        ) {
            engine.prefetchRequests.count == 1
        }

        coordinator.scheduleWarmupIfNeeded(
            mode: .custom,
            modelID: customModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(engine.prefetchRequests.count, 1)
        XCTAssertTrue(engine.prewarmRequests.isEmpty)
        XCTAssertTrue(engine.ensureModelLoadedIDs.isEmpty)
    }

    @MainActor
    func testMacGenerationWarmupCoordinatorRefreshesCustomVoiceAgainAfterGenerationRuns() async {
        let (store, engine) = makeReadyStore()
        let coordinator = MacGenerationWarmupCoordinator(
            debounce: .milliseconds(5),
            customVoiceDebounce: .milliseconds(5)
        )
        let customModel = TTSModel.model(for: .custom)!
        let loadedSnapshot = TTSEngineSnapshot(
            isReady: true,
            loadState: .loaded(modelID: customModel.id),
            clonePreparationState: .idle,
            visibleErrorMessage: nil
        )
        engine.pushSnapshot(loadedSnapshot)
        await Task.yield()

        coordinator.scheduleWarmupIfNeeded(
            mode: .custom,
            modelID: customModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )

        await waitUntil(
            timeoutSeconds: 0.5,
            description: "initial loaded custom voice refresh starts"
        ) {
            engine.prefetchRequests.count == 1
        }

        coordinator.observe(
            snapshot: TTSEngineSnapshot(
                isReady: true,
                loadState: .running(modelID: customModel.id, label: nil, fraction: nil),
                clonePreparationState: .idle,
                visibleErrorMessage: nil
            )
        )
        coordinator.observe(snapshot: loadedSnapshot)
        coordinator.scheduleWarmupIfNeeded(
            mode: .custom,
            modelID: customModel.id,
            isModelAvailable: true,
            snapshot: store.snapshot,
            ttsEngineStore: store
        )

        await waitUntil(
            timeoutSeconds: 0.5,
            description: "post-generation custom voice refresh starts"
        ) {
            engine.prefetchRequests.count == 2
        }
    }

    @MainActor
    func testMacGenerationWarmupCoordinatorCancelsStalePendingWarmup() async {
        let (store, engine) = makeReadyStore()
        let coordinator = MacGenerationWarmupCoordinator(
            debounce: .milliseconds(25),
            customVoiceDebounce: .milliseconds(25)
        )
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
        XCTAssertTrue(engine.prewarmRequests.isEmpty)
        XCTAssertTrue(engine.prefetchRequests.isEmpty)
    }

    @MainActor
    func testMacGenerationWarmupCoordinatorSkipsUnavailableModel() async {
        let (store, engine) = makeReadyStore()
        let coordinator = MacGenerationWarmupCoordinator(
            debounce: .milliseconds(5),
            customVoiceDebounce: .milliseconds(5)
        )
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
        XCTAssertTrue(engine.prewarmRequests.isEmpty)
        XCTAssertTrue(engine.prefetchRequests.isEmpty)
    }

    func testCustomVoiceReadinessDoesNotClaimReadyForInitializedIdleEngine() {
        let presentation = CustomVoiceReadinessPresentation.resolve(
            snapshot: TTSEngineSnapshot(
                isReady: true,
                loadState: .idle,
                clonePreparationState: .idle,
                visibleErrorMessage: nil
            ),
            activeModelID: "pro_custom",
            isModelAvailable: true,
            hasText: true,
            isGenerating: false,
            modelDisplayName: "Custom Voice"
        )

        XCTAssertFalse(presentation.isReady)
        XCTAssertEqual(presentation.title, "Preparing Custom Voice")
        XCTAssertEqual(presentation.trailingText, "Preparing")
        XCTAssertTrue(presentation.isBusy)
    }

    func testCustomVoiceReadinessOnlyClaimsReadyWhenActiveModelLoaded() {
        let presentation = CustomVoiceReadinessPresentation.resolve(
            snapshot: TTSEngineSnapshot(
                isReady: true,
                loadState: .loaded(modelID: "pro_custom"),
                clonePreparationState: .idle,
                visibleErrorMessage: nil
            ),
            activeModelID: "pro_custom",
            isModelAvailable: true,
            hasText: true,
            isGenerating: false,
            modelDisplayName: "Custom Voice"
        )

        XCTAssertTrue(presentation.isReady)
        XCTAssertEqual(presentation.title, "Ready to generate")
        XCTAssertEqual(presentation.trailingText, "Ready")
        XCTAssertFalse(presentation.isBusy)
    }

    func testCustomVoiceReadinessDoesNotClaimReadyForDifferentLoadedModel() {
        let presentation = CustomVoiceReadinessPresentation.resolve(
            snapshot: TTSEngineSnapshot(
                isReady: true,
                loadState: .loaded(modelID: "pro_design"),
                clonePreparationState: .idle,
                visibleErrorMessage: nil
            ),
            activeModelID: "pro_custom",
            isModelAvailable: true,
            hasText: true,
            isGenerating: false,
            modelDisplayName: "Custom Voice"
        )

        XCTAssertFalse(presentation.isReady)
        XCTAssertEqual(presentation.title, "Custom Voice will prepare on generate")
        XCTAssertNil(presentation.trailingText)
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
    func testCustomVoiceCoordinatorRejectsWhitespaceOnlyScript() async throws {
        let (store, engine) = makeReadyStore()
        let coordinator = CustomVoiceCoordinator()
        let audioPlayer = AudioPlayerViewModel()

        coordinator.generate(
            draft: CustomVoiceDraft(
                selectedSpeaker: "Vivian",
                emotion: "Normal tone",
                text: " \n\t "
            ),
            activeModel: TTSModel.model(for: .custom),
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
    func testCustomVoiceCoordinatorRoutesOversizedDirectScriptToLongFormBatch() async throws {
        let (store, engine) = makeReadyStore()
        let coordinator = CustomVoiceCoordinator()
        let audioPlayer = AudioPlayerViewModel()
        let text = String(repeating: "Custom long-form sentence. ", count: 40)

        coordinator.generate(
            draft: CustomVoiceDraft(
                selectedSpeaker: "Vivian",
                emotion: "Normal tone",
                text: text
            ),
            activeModel: TTSModel.model(for: .custom),
            isModelAvailable: true,
            ttsEngineStore: store,
            audioPlayer: audioPlayer,
            modelManager: ModelManagerViewModel()
        )

        XCTAssertFalse(coordinator.isGenerating)
        XCTAssertTrue(engine.generationRequests.isEmpty)
        guard case .batch(let configuration) = coordinator.presentedSheet else {
            return XCTFail("Expected oversized script to open long-form batch")
        }
        XCTAssertEqual(configuration.initialText, text)
        XCTAssertEqual(configuration.initialSegmentationMode, .longForm)
    }

    func testLongTextGenerationRouterUsesNineHundredCharacterLimit() {
        XCTAssertFalse(LongTextGenerationRouter.shouldRouteToLongFormBatch(String(repeating: "a", count: 900)))
        XCTAssertTrue(LongTextGenerationRouter.shouldRouteToLongFormBatch(String(repeating: "a", count: 901)))
    }

    @MainActor
    func testCustomVoiceCoordinatorUsesAppStreamingIntervalForUIRequests() throws {
        let model = try XCTUnwrap(TTSModel.model(for: .custom))
        let request = CustomVoiceCoordinator.makeGenerationRequest(
            draft: CustomVoiceDraft(
                selectedSpeaker: "Vivian",
                emotion: "Normal tone",
                text: "Hello there"
            ),
            model: model,
            outputPath: "/tmp/custom.wav"
        )

        XCTAssertEqual(request.streamingInterval, QwenVoiceCore.GenerationSemantics.appStreamingInterval)
    }

    @MainActor
    func testCustomVoiceCoordinatorPreventsDuplicateGenerationRequests() async throws {
        let (store, engine) = makeReadyStore()
        engine.suspendGenerate = true
        engine.generateError = CancellationError()
        let coordinator = CustomVoiceCoordinator()
        let audioPlayer = AudioPlayerViewModel()
        let draft = CustomVoiceDraft(
            selectedSpeaker: "Vivian",
            emotion: "Normal tone",
            text: "Hello there"
        )

        coordinator.generate(
            draft: draft,
            activeModel: TTSModel.model(for: .custom),
            isModelAvailable: true,
            ttsEngineStore: store,
            audioPlayer: audioPlayer,
            modelManager: ModelManagerViewModel()
        )

        await waitUntil(
            timeoutSeconds: 1.0,
            description: "first custom voice generation starts"
        ) {
            coordinator.isGenerating && engine.generationRequests.count == 1
        }

        coordinator.generate(
            draft: draft,
            activeModel: TTSModel.model(for: .custom),
            isModelAvailable: true,
            ttsEngineStore: store,
            audioPlayer: audioPlayer,
            modelManager: ModelManagerViewModel()
        )

        XCTAssertEqual(engine.generationRequests.count, 1)

        engine.resumeSuspendedGenerate()

        await waitUntil(
            timeoutSeconds: 1.0,
            description: "deduped custom voice generation finishes"
        ) {
            coordinator.isGenerating == false
        }

        XCTAssertNil(coordinator.errorMessage)
        XCTAssertFalse(audioPlayer.isLiveStream)
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
        XCTAssertFalse(request.shouldStream)
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
    func testVoiceDesignCoordinatorRoutesOversizedDirectScriptToLongFormBatch() async throws {
        let (store, engine) = makeReadyStore()
        let coordinator = VoiceDesignCoordinator()
        let audioPlayer = AudioPlayerViewModel()
        let text = String(repeating: "Design long-form sentence. ", count: 40)
        let draft = VoiceDesignDraft(
            voiceDescription: "Warm narrator",
            emotion: "Conversational",
            text: text
        )

        coordinator.generate(
            draft: draft,
            activeModel: TTSModel.model(for: .design),
            isModelAvailable: true,
            ttsEngineStore: store,
            audioPlayer: audioPlayer,
            modelManager: ModelManagerViewModel()
        )

        XCTAssertFalse(coordinator.isGenerating)
        XCTAssertTrue(engine.generationRequests.isEmpty)
        guard case .batch(let configuration) = coordinator.presentedSheet else {
            return XCTFail("Expected oversized script to open long-form batch")
        }
        XCTAssertEqual(configuration.initialText, text)
        XCTAssertEqual(configuration.initialSegmentationMode, .longForm)
        XCTAssertEqual(configuration.voiceDescription, "Warm narrator")
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
    func testVoiceCloningCoordinatorRejectsWhitespaceOnlyScript() async throws {
        let (store, engine) = makeReadyStore()
        let coordinator = VoiceCloningCoordinator()
        let audioPlayer = AudioPlayerViewModel()
        let draft = Binding(
            get: {
                VoiceCloningDraft(
                    selectedSavedVoiceID: nil,
                    referenceAudioPath: "/tmp/reference.wav",
                    referenceTranscript: "Reference transcript",
                    text: " \n\t "
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

        await Task.yield()

        XCTAssertFalse(coordinator.isGenerating)
        XCTAssertTrue(engine.generationRequests.isEmpty)
        XCTAssertFalse(audioPlayer.isLiveStream)
    }

    @MainActor
    func testVoiceCloningCoordinatorBuildsExpectedCloneGenerationRequest() throws {
        let model = try XCTUnwrap(TTSModel.model(for: .clone))
        let draft = VoiceCloningDraft(
            selectedSavedVoiceID: "voice-123",
            referenceAudioPath: "/tmp/reference.wav",
            referenceTranscript: "  Reference transcript\n",
            text: "Clone this line"
        )

        let request = try XCTUnwrap(VoiceCloningCoordinator.makeGenerationRequest(
            draft: draft,
            model: model,
            outputPath: "/tmp/clone.wav"
        ))

        XCTAssertEqual(request.modelID, model.id)
        XCTAssertEqual(request.text, "Clone this line")
        XCTAssertEqual(request.outputPath, "/tmp/clone.wav")
        XCTAssertFalse(request.shouldStream)
        XCTAssertEqual(request.streamingTitle, "Clone this line")
        guard case .clone(let reference) = request.payload else {
            return XCTFail("Expected Voice Cloning payload")
        }
        XCTAssertEqual(reference.audioPath, "/tmp/reference.wav")
        XCTAssertEqual(reference.transcript, "Reference transcript")
        XCTAssertEqual(reference.preparedVoiceID, "voice-123")
    }

    @MainActor
    func testVoiceCloningCoordinatorOmitsWhitespaceOnlyReferenceTranscript() throws {
        let model = try XCTUnwrap(TTSModel.model(for: .clone))
        let draft = VoiceCloningDraft(
            selectedSavedVoiceID: nil,
            referenceAudioPath: "/tmp/reference.wav",
            referenceTranscript: " \n\t ",
            text: "Clone this line"
        )

        let request = try XCTUnwrap(VoiceCloningCoordinator.makeGenerationRequest(
            draft: draft,
            model: model,
            outputPath: "/tmp/clone.wav"
        ))

        guard case .clone(let reference) = request.payload else {
            return XCTFail("Expected Voice Cloning payload")
        }
        XCTAssertNil(reference.transcript)
    }

    @MainActor
    func testVoiceCloningCoordinatorPreventsDuplicateGenerationRequests() async throws {
        let (store, engine) = makeReadyStore()
        engine.suspendGenerate = true
        engine.generateError = CancellationError()
        let coordinator = VoiceCloningCoordinator()
        let audioPlayer = AudioPlayerViewModel()
        var draftValue = VoiceCloningDraft(
            selectedSavedVoiceID: nil,
            referenceAudioPath: "/tmp/reference.wav",
            referenceTranscript: "Reference transcript",
            text: "Clone this line"
        )
        let draft = Binding(
            get: { draftValue },
            set: { draftValue = $0 }
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
            description: "first voice cloning generation starts"
        ) {
            coordinator.isGenerating && engine.generationRequests.count == 1
        }

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

        XCTAssertEqual(engine.generationRequests.count, 1)

        engine.resumeSuspendedGenerate()

        await waitUntil(
            timeoutSeconds: 1.0,
            description: "deduped voice cloning generation finishes"
        ) {
            coordinator.isGenerating == false
        }

        XCTAssertNil(coordinator.errorMessage)
        XCTAssertFalse(audioPlayer.isLiveStream)
    }

    @MainActor
    func testVoiceCloningCoordinatorRoutesOversizedDirectScriptToLongFormBatch() async throws {
        let (store, engine) = makeReadyStore()
        let coordinator = VoiceCloningCoordinator()
        let audioPlayer = AudioPlayerViewModel()
        let text = String(repeating: "Clone long-form sentence. ", count: 40)
        var draftValue = VoiceCloningDraft(
            selectedSavedVoiceID: nil,
            referenceAudioPath: "/tmp/reference.wav",
            referenceTranscript: "Reference transcript",
            text: text
        )
        let draft = Binding(
            get: { draftValue },
            set: { draftValue = $0 }
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

        XCTAssertFalse(coordinator.isGenerating)
        XCTAssertTrue(engine.generationRequests.isEmpty)
        guard case .batch(let configuration) = coordinator.presentedSheet else {
            return XCTFail("Expected oversized script to open long-form batch")
        }
        XCTAssertEqual(configuration.initialText, text)
        XCTAssertEqual(configuration.initialSegmentationMode, .longForm)
        XCTAssertEqual(configuration.refAudio, "/tmp/reference.wav")
        XCTAssertEqual(configuration.refText, "Reference transcript")
    }

    @MainActor
    func testVoiceCloningCoordinatorLeavesGeneratingStateAfterEngineInterruption() async throws {
        let (store, engine) = makeReadyStore()
        engine.generateError = NSError(
            domain: "com.qwenvoice.xpc",
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey: "The engine service connection was interrupted.",
            ]
        )
        let coordinator = VoiceCloningCoordinator()
        let audioPlayer = AudioPlayerViewModel()
        var draftValue = VoiceCloningDraft(
            selectedSavedVoiceID: nil,
            referenceAudioPath: "/tmp/reference.wav",
            referenceTranscript: "Reference transcript",
            text: "Clone this line"
        )
        let draft = Binding(
            get: { draftValue },
            set: { draftValue = $0 }
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
            description: "voice cloning interruption finishes"
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
    func testVoiceCloningCoordinatorPrimesWithTrimmedTranscript() async throws {
        let (store, engine) = makeReadyStore()
        let coordinator = VoiceCloningCoordinator()
        let model = try XCTUnwrap(TTSModel.model(for: .clone))

        await coordinator.syncCloneReferencePriming(
            draft: VoiceCloningDraft(
                selectedSavedVoiceID: nil,
                referenceAudioPath: "/tmp/reference.wav",
                referenceTranscript: "  Reference transcript\n",
                text: "Clone this line"
            ),
            cloneModel: model,
            isModelAvailable: true,
            clonePrimingRequestKey: "clone-key",
            ttsEngineStore: store
        )

        XCTAssertEqual(engine.primedReferences.count, 1)
        XCTAssertEqual(engine.primedReferences.first?.0, model.id)
        XCTAssertEqual(engine.primedReferences.first?.1.audioPath, "/tmp/reference.wav")
        XCTAssertEqual(engine.primedReferences.first?.1.transcript, "Reference transcript")
    }

    @MainActor
    func testVoiceCloningCoordinatorCancelsPrimingUntilSavedReferenceHydrates() async throws {
        let (store, engine) = makeReadyStore()
        let coordinator = VoiceCloningCoordinator()
        let model = try XCTUnwrap(TTSModel.model(for: .clone))

        await coordinator.syncCloneReferencePriming(
            draft: VoiceCloningDraft(
                selectedSavedVoiceID: "voice-123",
                referenceAudioPath: "/tmp/reference.wav",
                referenceTranscript: "",
                text: "Clone this line"
            ),
            cloneModel: model,
            isModelAvailable: true,
            clonePrimingRequestKey: "clone-key",
            ttsEngineStore: store
        )

        XCTAssertTrue(engine.primedReferences.isEmpty)
        XCTAssertEqual(engine.cancelClonePreparationCount, 1)
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
