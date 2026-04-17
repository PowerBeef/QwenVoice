import Combine
import XCTest
@testable import QwenVoice
import QwenVoiceNative

@MainActor
private final class SavedVoiceClonePreloadMockEngine: MacTTSEngine {
    private let subject = CurrentValueSubject<TTSEngineSnapshot, Never>(
        TTSEngineSnapshot(
            isReady: true,
            loadState: .idle,
            clonePreparationState: .idle,
            latestEvent: nil,
            visibleErrorMessage: nil
        )
    )

    private(set) var ensuredModelLoadIDs: [String] = []

    var snapshot: TTSEngineSnapshot { subject.value }
    var snapshotPublisher: AnyPublisher<TTSEngineSnapshot, Never> { subject.eraseToAnyPublisher() }

    func initialize(appSupportDirectory: URL) async throws {}
    func ping() async throws -> Bool { true }
    func loadModel(id: String) async throws {}
    func unloadModel() async throws {}
    func ensureModelLoadedIfNeeded(id: String) async {
        ensuredModelLoadIDs.append(id)
    }
    func prewarmModelIfNeeded(for request: GenerationRequest) async {}
    func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {}
    func cancelClonePreparationIfNeeded() async {}
    func generate(_ request: GenerationRequest) async throws -> QwenVoiceNative.GenerationResult {
        throw NSError(domain: "SavedVoiceClonePreloadMockEngine", code: 1)
    }
    func generateBatch(
        _ requests: [GenerationRequest],
        progressHandler: ((Double?, String) -> Void)?
    ) async throws -> [QwenVoiceNative.GenerationResult] {
        throw NSError(domain: "SavedVoiceClonePreloadMockEngine", code: 2)
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

final class PythonBridgeLineParserTests: XCTestCase {

    func testParseValidResultResponse() {
        let json = #"{"jsonrpc":"2.0","id":1,"result":{"status":"ok"}}"#
        let response = PythonBridgeLineParser.parse(json)
        XCTAssertNotNil(response)
        XCTAssertEqual(response?.id, 1)
        XCTAssertNotNil(response?.result)
        XCTAssertNil(response?.error)
        XCTAssertFalse(response?.isNotification ?? true)
    }

    func testParseValidNotification() {
        let json = #"{"jsonrpc":"2.0","method":"ready","params":{}}"#
        let response = PythonBridgeLineParser.parse(json)
        XCTAssertNotNil(response)
        XCTAssertNil(response?.id)
        XCTAssertEqual(response?.method, "ready")
        XCTAssertTrue(response?.isNotification ?? false)
    }

    func testParseInvalidJSON() {
        let response = PythonBridgeLineParser.parse("not valid json {{{")
        XCTAssertNil(response)
    }

    func testParseEmptyString() {
        let response = PythonBridgeLineParser.parse("")
        XCTAssertNil(response)
    }

    func testIsHandledNotificationReady() {
        let json = #"{"jsonrpc":"2.0","method":"ready","params":{}}"#
        let response = PythonBridgeLineParser.parse(json)!
        XCTAssertTrue(PythonBridgeLineParser.isHandledNotification(response))
    }

    func testIsHandledNotificationProgress() {
        let json = #"{"jsonrpc":"2.0","method":"progress","params":{"percent":50}}"#
        let response = PythonBridgeLineParser.parse(json)!
        XCTAssertTrue(PythonBridgeLineParser.isHandledNotification(response))
    }

    func testIsHandledNotificationGenerationChunk() {
        let json = #"{"jsonrpc":"2.0","method":"generation_chunk","params":{}}"#
        let response = PythonBridgeLineParser.parse(json)!
        XCTAssertTrue(PythonBridgeLineParser.isHandledNotification(response))
    }

    func testNonNotificationNotHandled() {
        let json = #"{"jsonrpc":"2.0","id":1,"result":{"status":"ok"}}"#
        let response = PythonBridgeLineParser.parse(json)!
        XCTAssertFalse(PythonBridgeLineParser.isHandledNotification(response))
    }

    func testUnknownNotificationNotHandled() {
        let json = #"{"jsonrpc":"2.0","method":"unknown_event","params":{}}"#
        let response = PythonBridgeLineParser.parse(json)!
        XCTAssertFalse(PythonBridgeLineParser.isHandledNotification(response))
    }

    func testSidebarFooterPresentationInlinesLivePreviewActivity() {
        let activity = ActivityStatus(
            label: "Streaming audio...",
            fraction: 0.45,
            presentation: .inlinePlayer
        )

        let presentation = SidebarFooterPresentation.resolve(
            sidebarStatus: .running(activity),
            isLiveStream: true
        )

        XCTAssertEqual(presentation.inlinePlayerActivity, activity)
        XCTAssertFalse(presentation.showsStandaloneStatus)
    }

    func testSidebarFooterPresentationKeepsStandaloneStatusForRegularWork() {
        let activity = ActivityStatus(
            label: "Preparing model...",
            fraction: 0.12,
            presentation: .standaloneCard
        )

        let presentation = SidebarFooterPresentation.resolve(
            sidebarStatus: .running(activity),
            isLiveStream: true
        )

        XCTAssertNil(presentation.inlinePlayerActivity)
        XCTAssertTrue(presentation.showsStandaloneStatus)
    }

    func testSidebarFooterPresentationFallsBackToStandaloneWhenPlayerIsNotLive() {
        let activity = ActivityStatus(
            label: "Streaming audio...",
            fraction: 0.45,
            presentation: .inlinePlayer
        )

        let presentation = SidebarFooterPresentation.resolve(
            sidebarStatus: .running(activity),
            isLiveStream: false
        )

        XCTAssertNil(presentation.inlinePlayerActivity)
        XCTAssertTrue(presentation.showsStandaloneStatus)
    }

    @MainActor
    func testDesignPrewarmIdentityIgnoresEmotionOnlyChanges() {
        let calmKey = GenerationSemantics.prewarmIdentityKey(for: GenerationRequest(
            modelID: "pro_design",
            text: "Hello",
            outputPath: "/tmp/out.wav",
            payload: .design(voiceDescription: "Warm narrator", deliveryStyle: "Calm")
        ))
        let intenseKey = GenerationSemantics.prewarmIdentityKey(for: GenerationRequest(
            modelID: "pro_design",
            text: "Hello",
            outputPath: "/tmp/out.wav",
            payload: .design(voiceDescription: "Warm narrator", deliveryStyle: "Intense")
        ))

        XCTAssertEqual(calmKey, intenseKey)
    }

    @MainActor
    func testCustomPrewarmIdentityStillTracksVoiceAndDeliveryChanges() {
        let baseKey = GenerationSemantics.prewarmIdentityKey(for: GenerationRequest(
            modelID: "pro_custom",
            text: "Hello",
            outputPath: "/tmp/out.wav",
            payload: .custom(speakerID: "Vivian", deliveryStyle: "Conversational")
        ))
        let voiceChangedKey = GenerationSemantics.prewarmIdentityKey(for: GenerationRequest(
            modelID: "pro_custom",
            text: "Hello",
            outputPath: "/tmp/out.wav",
            payload: .custom(speakerID: "Ethan", deliveryStyle: "Conversational")
        ))
        let instructionChangedKey = GenerationSemantics.prewarmIdentityKey(for: GenerationRequest(
            modelID: "pro_custom",
            text: "Hello",
            outputPath: "/tmp/out.wav",
            payload: .custom(speakerID: "Vivian", deliveryStyle: "Dramatic")
        ))

        XCTAssertNotEqual(baseKey, voiceChangedKey)
        XCTAssertNotEqual(baseKey, instructionChangedKey)
    }

    @MainActor
    func testCustomPrewarmIdentityIgnoresNormalToneChanges() {
        let defaultKey = GenerationSemantics.prewarmIdentityKey(for: GenerationRequest(
            modelID: "pro_custom",
            text: "Hello",
            outputPath: "/tmp/out.wav",
            payload: .custom(speakerID: "Vivian", deliveryStyle: "Normal tone")
        ))
        let blankKey = GenerationSemantics.prewarmIdentityKey(for: GenerationRequest(
            modelID: "pro_custom",
            text: "Hello",
            outputPath: "/tmp/out.wav",
            payload: .custom(speakerID: "Vivian", deliveryStyle: "")
        ))

        XCTAssertEqual(defaultKey, blankKey)
    }

    @MainActor
    func testIdlePrewarmPolicyIncludesCustomMode() {
        XCTAssertTrue(PythonBridge.supportsIdlePrewarm(mode: .custom))
        XCTAssertTrue(PythonBridge.supportsIdlePrewarm(mode: .design))
        XCTAssertTrue(PythonBridge.supportsIdlePrewarm(mode: .clone))
    }

    @MainActor
    func testDeferredClonePrewarmRequiresMatchingPrimedReference() {
        XCTAssertTrue(
            VoiceCloningView.shouldStartDeferredClonePrewarm(
                clonePreparationState: .primed(key: "clone-key"),
                expectedKey: "clone-key",
                isGenerating: false
            )
        )
        XCTAssertFalse(
            VoiceCloningView.shouldStartDeferredClonePrewarm(
                clonePreparationState: .preparing(key: "clone-key"),
                expectedKey: "clone-key",
                isGenerating: false
            )
        )
        XCTAssertFalse(
            VoiceCloningView.shouldStartDeferredClonePrewarm(
                clonePreparationState: .primed(key: "other-key"),
                expectedKey: "clone-key",
                isGenerating: false
            )
        )
        XCTAssertFalse(
            VoiceCloningView.shouldStartDeferredClonePrewarm(
                clonePreparationState: .primed(key: "clone-key"),
                expectedKey: "clone-key",
                isGenerating: true
            )
        )
    }

    @MainActor
    func testSavedVoiceCloneHandoffPlanIncludesEarlyModelLoadTarget() {
        let voice = Voice(
            name: "French Voice",
            wavPath: "/tmp/french.wav",
            hasTranscript: true
        )

        let plan = ContentView.savedVoiceCloneHandoffPlan(
            for: voice,
            cloneModelID: "pro_clone",
            transcriptLoader: { _ in "Bonjour tout le monde." }
        )

        XCTAssertEqual(plan.handoff.savedVoiceID, voice.id)
        XCTAssertEqual(plan.handoff.wavPath, voice.wavPath)
        XCTAssertEqual(plan.handoff.transcript, "Bonjour tout le monde.")
        XCTAssertNil(plan.handoff.transcriptLoadError)
        XCTAssertEqual(plan.cloneModelID, "pro_clone")
    }

    @MainActor
    func testSavedVoiceCloneHandoffPlanUsesModelOnlyForEarlyLoad() {
        let voice = Voice(
            name: "French Voice",
            wavPath: "/tmp/french.wav",
            hasTranscript: true
        )

        let firstPlan = ContentView.savedVoiceCloneHandoffPlan(
            for: voice,
            cloneModelID: "pro_clone",
            transcriptLoader: { _ in "Bonjour tout le monde." }
        )
        let secondPlan = ContentView.savedVoiceCloneHandoffPlan(
            for: voice,
            cloneModelID: "pro_clone",
            transcriptLoader: { _ in "Salut encore." }
        )

        XCTAssertEqual(firstPlan.cloneModelID, "pro_clone")
        XCTAssertEqual(secondPlan.cloneModelID, "pro_clone")
        XCTAssertNotEqual(firstPlan.handoff.transcript, secondPlan.handoff.transcript)
    }

    @MainActor
    func testSavedVoiceCloneHandoffPlanFallsBackToTranscriptWarningWithoutDroppingModelLoad() {
        let voice = Voice(
            name: "French Voice",
            wavPath: "/tmp/french.wav",
            hasTranscript: true
        )

        let plan = ContentView.savedVoiceCloneHandoffPlan(
            for: voice,
            cloneModelID: "pro_clone",
            transcriptLoader: { _ in
                throw CocoaError(.fileReadNoSuchFile)
            }
        )

        XCTAssertEqual(plan.handoff.savedVoiceID, voice.id)
        XCTAssertEqual(plan.handoff.wavPath, voice.wavPath)
        XCTAssertEqual(plan.handoff.transcript, "")
        XCTAssertEqual(
            plan.handoff.transcriptLoadError,
            "Couldn't load the saved transcript for \"French Voice\". You can still clone from the audio file alone."
        )
        XCTAssertEqual(plan.cloneModelID, "pro_clone")
    }

    @MainActor
    func testSavedVoiceCloneHandoffPreloadUsesTTSEngineStoreModelLoad() async {
        let engine = SavedVoiceClonePreloadMockEngine()
        let engineStore = TTSEngineStore(engine: engine)
        let plan = SavedVoiceCloneHandoffPlan(
            handoff: PendingVoiceCloningHandoff(
                savedVoiceID: "voice-id",
                wavPath: "/tmp/french.wav",
                transcript: "Bonjour",
                transcriptLoadError: nil
            ),
            cloneModelID: "pro_clone"
        )

        await ContentView.beginSavedVoiceClonePreloadIfPossible(
            plan: plan,
            engineStore: engineStore
        )

        XCTAssertEqual(engine.ensuredModelLoadIDs, ["pro_clone"])
    }

    @MainActor
    func testCustomVoiceGenerationRequestBuilderProducesStreamingRequest() {
        let draft = CustomVoiceDraft(
            selectedSpeaker: "vivian",
            emotion: "Conversational",
            text: "Hello from native store"
        )
        let model = TTSModel(
            id: "pro_custom",
            name: "Custom Voice",
            tier: "Pro",
            folder: "ProCustom",
            mode: .custom,
            huggingFaceRepo: "test/repo",
            outputSubfolder: "Custom",
            requiredRelativePaths: []
        )

        let request = CustomVoiceView.makeGenerationRequest(
            draft: draft,
            model: model,
            outputPath: "/tmp/custom.wav"
        )

        XCTAssertEqual(request.modelID, "pro_custom")
        XCTAssertEqual(request.text, draft.text)
        XCTAssertEqual(request.outputPath, "/tmp/custom.wav")
        XCTAssertTrue(request.shouldStream)
        XCTAssertEqual(request.streamingTitle, "Hello from native store")
        XCTAssertEqual(
            request.payload,
            .custom(speakerID: "vivian", deliveryStyle: "Conversational")
        )
    }

    @MainActor
    func testVoiceDesignGenerationRequestBuilderProducesStreamingRequest() {
        let draft = VoiceDesignDraft(
            voiceDescription: "Warm documentary narrator",
            emotion: "Calm",
            text: "This is a guided tour."
        )
        let model = TTSModel(
            id: "pro_design",
            name: "Voice Design",
            tier: "Pro",
            folder: "ProDesign",
            mode: .design,
            huggingFaceRepo: "test/repo",
            outputSubfolder: "Design",
            requiredRelativePaths: []
        )

        let request = VoiceDesignView.makeGenerationRequest(
            draft: draft,
            model: model,
            outputPath: "/tmp/design.wav"
        )

        XCTAssertEqual(request.modelID, "pro_design")
        XCTAssertEqual(request.text, draft.text)
        XCTAssertEqual(request.outputPath, "/tmp/design.wav")
        XCTAssertTrue(request.shouldStream)
        XCTAssertEqual(request.streamingTitle, "This is a guided tour.")
        XCTAssertEqual(
            request.payload,
            .design(
                voiceDescription: "Warm documentary narrator",
                deliveryStyle: "Calm"
            )
        )
    }

    @MainActor
    func testVoiceCloningGenerationRequestBuilderIncludesPreparedVoiceIdentity() throws {
        let draft = VoiceCloningDraft(
            selectedSavedVoiceID: "voice-id",
            referenceAudioPath: "/tmp/reference.wav",
            referenceTranscript: "Bonjour tout le monde",
            text: "Hello from clone"
        )
        let model = TTSModel(
            id: "pro_clone",
            name: "Voice Cloning",
            tier: "Pro",
            folder: "ProClone",
            mode: .clone,
            huggingFaceRepo: "test/repo",
            outputSubfolder: "Clones",
            requiredRelativePaths: []
        )

        let request = try XCTUnwrap(
            VoiceCloningCoordinator.makeGenerationRequest(
                draft: draft,
                model: model,
                outputPath: "/tmp/clone.wav"
            )
        )

        XCTAssertEqual(request.modelID, "pro_clone")
        XCTAssertEqual(request.text, draft.text)
        XCTAssertEqual(request.outputPath, "/tmp/clone.wav")
        XCTAssertTrue(request.shouldStream)
        XCTAssertEqual(request.streamingTitle, "Hello from clone")
        XCTAssertEqual(
            request.payload,
            .clone(
                reference: CloneReference(
                    audioPath: "/tmp/reference.wav",
                    transcript: "Bonjour tout le monde",
                    preparedVoiceID: "voice-id"
                )
            )
        )
    }
}
