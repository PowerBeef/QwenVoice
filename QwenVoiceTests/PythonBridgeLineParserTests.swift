import XCTest
@testable import QwenVoice

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
        let calmKey = PythonBridge.prewarmIdentityKey(
            modelID: "pro_design",
            mode: .design,
            instruct: "Calm"
        )
        let intenseKey = PythonBridge.prewarmIdentityKey(
            modelID: "pro_design",
            mode: .design,
            instruct: "Intense"
        )

        XCTAssertEqual(calmKey, intenseKey)
    }

    @MainActor
    func testCustomPrewarmIdentityStillTracksVoiceAndDeliveryChanges() {
        let baseKey = PythonBridge.prewarmIdentityKey(
            modelID: "pro_custom",
            mode: .custom,
            voice: "Vivian",
            instruct: "Conversational"
        )
        let voiceChangedKey = PythonBridge.prewarmIdentityKey(
            modelID: "pro_custom",
            mode: .custom,
            voice: "Ethan",
            instruct: "Conversational"
        )
        let instructionChangedKey = PythonBridge.prewarmIdentityKey(
            modelID: "pro_custom",
            mode: .custom,
            voice: "Vivian",
            instruct: "Dramatic"
        )

        XCTAssertNotEqual(baseKey, voiceChangedKey)
        XCTAssertNotEqual(baseKey, instructionChangedKey)
    }

    @MainActor
    func testCustomPrewarmIdentityIgnoresNormalToneChanges() {
        let defaultKey = PythonBridge.prewarmIdentityKey(
            modelID: "pro_custom",
            mode: .custom,
            voice: "Vivian",
            instruct: "Normal tone"
        )
        let blankKey = PythonBridge.prewarmIdentityKey(
            modelID: "pro_custom",
            mode: .custom,
            voice: "Vivian",
            instruct: ""
        )

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
                primingPhase: .primed,
                primingKey: "clone-key",
                expectedKey: "clone-key",
                isGenerating: false
            )
        )
        XCTAssertFalse(
            VoiceCloningView.shouldStartDeferredClonePrewarm(
                primingPhase: .preparing,
                primingKey: "clone-key",
                expectedKey: "clone-key",
                isGenerating: false
            )
        )
        XCTAssertFalse(
            VoiceCloningView.shouldStartDeferredClonePrewarm(
                primingPhase: .primed,
                primingKey: "other-key",
                expectedKey: "clone-key",
                isGenerating: false
            )
        )
        XCTAssertFalse(
            VoiceCloningView.shouldStartDeferredClonePrewarm(
                primingPhase: .primed,
                primingKey: "clone-key",
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
}
