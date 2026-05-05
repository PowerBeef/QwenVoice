import QwenVoiceCore
import XCTest
@testable import QwenVoice

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

    func testDesignConditioningWarmKeyTracksResolvedInstructionAndBucket() {
        let shortRequest = GenerationRequest(
            modelID: "pro_design",
            text: "Hello there.",
            outputPath: "/tmp/out.wav",
            payload: .design(voiceDescription: "Warm narrator", deliveryStyle: "Calm")
        )
        let longRequest = GenerationRequest(
            modelID: "pro_design",
            text: GenerationSemantics.canonicalDesignWarmLongText,
            outputPath: "/tmp/out.wav",
            payload: .design(voiceDescription: "Warm narrator", deliveryStyle: "Calm")
        )

        XCTAssertNotEqual(
            GenerationSemantics.designConditioningWarmKey(for: shortRequest),
            GenerationSemantics.designConditioningWarmKey(for: longRequest)
        )
        XCTAssertEqual(GenerationSemantics.designWarmBucket(for: shortRequest.text), .short)
        XCTAssertEqual(GenerationSemantics.designWarmBucket(for: longRequest.text), .long)
    }

    func testDesignConditioningWarmKeyReusesSemanticBriefAndInvalidatesChanges() {
        let baseRequest = GenerationRequest(
            modelID: "pro_design",
            text: "Hello there.",
            outputPath: "/tmp/out.wav",
            payload: .design(voiceDescription: "  Warm, steady narrator  ", deliveryStyle: "Normal tone")
        )
        let normalizedMatch = GenerationRequest(
            modelID: "pro_design",
            text: "Hello there.",
            outputPath: "/tmp/out.wav",
            payload: .design(voiceDescription: "warm, steady narrator", deliveryStyle: "Normal tone")
        )
        let differentBrief = GenerationRequest(
            modelID: "pro_design",
            text: "Hello there.",
            outputPath: "/tmp/out.wav",
            payload: .design(voiceDescription: "Bright energetic announcer", deliveryStyle: "Normal tone")
        )
        let differentLanguage = GenerationRequest(
            modelID: "pro_design",
            text: "你好，这是一段测试文本。",
            outputPath: "/tmp/out.wav",
            payload: .design(voiceDescription: "Warm, steady narrator", deliveryStyle: "Normal tone")
        )

        let baseKey = GenerationSemantics.designConditioningWarmKey(for: baseRequest)
        XCTAssertEqual(baseKey, GenerationSemantics.designConditioningWarmKey(for: normalizedMatch))
        XCTAssertNotEqual(baseKey, GenerationSemantics.designConditioningWarmKey(for: differentBrief))
        XCTAssertNotEqual(baseKey, GenerationSemantics.designConditioningWarmKey(for: differentLanguage))
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

    // MARK: - ChunkProbeMetadata round-trip

    func testGenerationChunkRoundTripsThroughCodableWithProbeMetadata() throws {
        let probe = ChunkProbeMetadata(
            seq: 7,
            engineEmittedAtMS: 1_777_944_000_000.0,
            inferMS: 482.5
        )
        let chunk = GenerationChunk(
            requestID: 42,
            mode: "custom",
            title: "probe round-trip",
            chunkPath: "/tmp/chunk_007.wav",
            isFinal: false,
            chunkDurationSeconds: 1.12,
            cumulativeDurationSeconds: 7.84,
            streamSessionDirectory: "/tmp/session-x",
            previewAudio: nil,
            probeMetadata: probe
        )
        let encoded = try JSONEncoder().encode(chunk)
        let decoded = try JSONDecoder().decode(GenerationChunk.self, from: encoded)
        XCTAssertEqual(decoded.probeMetadata, probe)
        XCTAssertEqual(decoded.requestID, 42)
        XCTAssertEqual(decoded.chunkDurationSeconds, 1.12)
    }

    func testGenerationChunkDecodesLegacyPayloadWithoutProbeMetadata() throws {
        // Older serialized chunks (or chunks coming from a non-streaming
        // path) carry no `probeMetadata` field. They must still decode
        // cleanly with `nil` so the probe branch in
        // XPCNativeEngineClient.emitChunkProbeEvents is a graceful no-op.
        let legacyJSON = """
        {
            "mode": "design",
            "title": "legacy",
            "isFinal": false
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(GenerationChunk.self, from: data)
        XCTAssertNil(decoded.probeMetadata)
        XCTAssertEqual(decoded.title, "legacy")
    }
}
