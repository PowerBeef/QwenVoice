import XCTest
@testable import QwenVoice
import QwenVoiceNative

final class GenerationSemanticsTests: XCTestCase {
    func testCustomPrewarmIdentityTracksVoiceAndMeaningfulDeliveryChanges() {
        let baseRequest = GenerationRequest(
            modelID: "pro_custom",
            text: "Hello",
            outputPath: "/tmp/out.wav",
            payload: .custom(speakerID: "Vivian", deliveryStyle: "Conversational")
        )
        let voiceChangedRequest = GenerationRequest(
            modelID: "pro_custom",
            text: "Hello",
            outputPath: "/tmp/out.wav",
            payload: .custom(speakerID: "Ethan", deliveryStyle: "Conversational")
        )
        let deliveryChangedRequest = GenerationRequest(
            modelID: "pro_custom",
            text: "Hello",
            outputPath: "/tmp/out.wav",
            payload: .custom(speakerID: "Vivian", deliveryStyle: "Dramatic")
        )

        XCTAssertNotEqual(
            GenerationSemantics.prewarmIdentityKey(for: baseRequest),
            GenerationSemantics.prewarmIdentityKey(for: voiceChangedRequest)
        )
        XCTAssertNotEqual(
            GenerationSemantics.prewarmIdentityKey(for: baseRequest),
            GenerationSemantics.prewarmIdentityKey(for: deliveryChangedRequest)
        )
    }

    func testCustomPrewarmIdentityIgnoresNormalToneChanges() {
        let defaultRequest = GenerationRequest(
            modelID: "pro_custom",
            text: "Hello",
            outputPath: "/tmp/out.wav",
            payload: .custom(speakerID: "Vivian", deliveryStyle: "Normal tone")
        )
        let blankRequest = GenerationRequest(
            modelID: "pro_custom",
            text: "Hello",
            outputPath: "/tmp/out.wav",
            payload: .custom(speakerID: "Vivian", deliveryStyle: "")
        )

        XCTAssertEqual(
            GenerationSemantics.prewarmIdentityKey(for: defaultRequest),
            GenerationSemantics.prewarmIdentityKey(for: blankRequest)
        )
    }

    func testDesignPrewarmIdentityIgnoresDeliveryStyleChanges() {
        let calmRequest = GenerationRequest(
            modelID: "pro_design",
            text: "Hello",
            outputPath: "/tmp/out.wav",
            payload: .design(voiceDescription: "Warm narrator", deliveryStyle: "Calm")
        )
        let intenseRequest = GenerationRequest(
            modelID: "pro_design",
            text: "Hello",
            outputPath: "/tmp/out.wav",
            payload: .design(voiceDescription: "Warm narrator", deliveryStyle: "Intense")
        )

        XCTAssertEqual(
            GenerationSemantics.prewarmIdentityKey(for: calmRequest),
            GenerationSemantics.prewarmIdentityKey(for: intenseRequest)
        )
    }

    func testClonePreparationKeyIncludesReferenceAudioAndTranscript() {
        let reference = CloneReference(audioPath: "/tmp/reference.wav", transcript: "Bonjour")

        XCTAssertEqual(
            GenerationSemantics.clonePreparationKey(modelID: "pro_clone", reference: reference),
            "pro_clone|clone|/tmp/reference.wav|Bonjour"
        )
    }

    func testEngineLoadStateCurrentModelIDAndClonePreparationAccessorsExposeReadyState() {
        XCTAssertEqual(EngineLoadState.loaded(modelID: "pro_custom").currentModelID, "pro_custom")
        XCTAssertEqual(
            EngineLoadState.running(modelID: "pro_clone", label: "Preparing", fraction: 0.4).currentModelID,
            "pro_clone"
        )
        XCTAssertNil(EngineLoadState.idle.currentModelID)

        let primed = ClonePreparationState.primed(key: "clone-key")
        let failed = ClonePreparationState.failed(key: "clone-key", message: "degraded")

        XCTAssertEqual(primed.key, "clone-key")
        XCTAssertNil(primed.errorMessage)
        XCTAssertTrue(primed.isPreparingOrPrimed)

        XCTAssertEqual(failed.key, "clone-key")
        XCTAssertEqual(failed.errorMessage, "degraded")
        XCTAssertFalse(failed.isPreparingOrPrimed)
    }

    @MainActor
    func testDeferredClonePrewarmRequiresMatchingPrimedStoreState() {
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
}
