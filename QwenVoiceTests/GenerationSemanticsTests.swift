import QwenVoiceCore
import XCTest
@testable import QwenVoice

final class GenerationSemanticsTests: XCTestCase {
    func testEngineActivityLabelsAreModeAware() {
        XCTAssertEqual(
            EngineActivityLabels.generating(mode: .custom),
            "Generating Custom Voice…"
        )
        XCTAssertEqual(
            EngineActivityLabels.generating(mode: .design),
            "Generating Voice Design…"
        )
        XCTAssertEqual(
            EngineActivityLabels.generating(mode: .clone),
            "Generating Voice Cloning…"
        )
        XCTAssertEqual(
            EngineActivityLabels.preparingVoiceReference,
            "Preparing voice reference…"
        )
    }

    func testCloneReferenceResolverOnlyShowsPreparingForMatchingPreparingState() {
        let stalePreparing = CloneReferenceContextResolver.resolve(
            hasReference: true,
            selectedSavedVoiceID: nil,
            hydratedSavedVoiceID: nil,
            transcriptLoadError: nil,
            expectedPreparationKey: "current-key",
            preparationState: .preparing(key: "old-key")
        )
        XCTAssertEqual(stalePreparing, .usableWithoutPriming)

        let idleCurrent = CloneReferenceContextResolver.resolve(
            hasReference: true,
            selectedSavedVoiceID: nil,
            hydratedSavedVoiceID: nil,
            transcriptLoadError: nil,
            expectedPreparationKey: "current-key",
            preparationState: .idle
        )
        XCTAssertEqual(idleCurrent, .usableWithoutPriming)

        let matchingPreparing = CloneReferenceContextResolver.resolve(
            hasReference: true,
            selectedSavedVoiceID: nil,
            hydratedSavedVoiceID: nil,
            transcriptLoadError: nil,
            expectedPreparationKey: "current-key",
            preparationState: .preparing(key: "current-key")
        )
        XCTAssertEqual(matchingPreparing, .preparing)
    }

    func testCloneReferenceResolverReportsFailedPrepAsDegradedAvailableState() {
        let failed = CloneReferenceContextResolver.resolve(
            hasReference: true,
            selectedSavedVoiceID: nil,
            hydratedSavedVoiceID: nil,
            transcriptLoadError: nil,
            expectedPreparationKey: "current-key",
            preparationState: .failed(key: "current-key", message: "Reference prep degraded.")
        )

        XCTAssertEqual(failed, .degraded("Reference prep degraded."))
    }

    func testCloneReferenceResolverWaitsForSavedVoiceHydration() {
        let status = CloneReferenceContextResolver.resolve(
            hasReference: true,
            selectedSavedVoiceID: "voice-123",
            hydratedSavedVoiceID: nil,
            transcriptLoadError: nil,
            expectedPreparationKey: "current-key",
            preparationState: .idle
        )

        XCTAssertEqual(status, .waitingForHydration)
    }

    func testEnglishCustomVoiceAddsConservativeDictionInstruction() {
        let request = GenerationRequest(
            modelID: "pro_custom",
            text: "This product update should sound natural in English.",
            outputPath: "/tmp/out.wav",
            payload: .custom(speakerID: "aiden", deliveryStyle: "Neutral")
        )

        XCTAssertEqual(GenerationSemantics.qwenLanguageHint(for: request), "english")
        XCTAssertEqual(
            GenerationSemantics.customInstruction(for: request),
            GenerationSemantics.englishDictionReinforcement
        )
    }

    func testNeutralDeliveryInstructionsIncludeLegacyAliases() {
        let legacyNeutral = ["Normal", "tone"].joined(separator: " ")

        for instruction in ["", "Neutral", "Neutral tone", legacyNeutral] {
            XCTAssertTrue(GenerationSemantics.isNeutralDeliveryInstruction(instruction))
            XCTAssertFalse(GenerationSemantics.hasMeaningfulDeliveryInstruction(instruction))
        }

        XCTAssertFalse(GenerationSemantics.isNeutralDeliveryInstruction("Calm and reassuring"))
        XCTAssertTrue(GenerationSemantics.hasMeaningfulDeliveryInstruction("Calm and reassuring"))
    }

    func testEnglishCustomVoicePreservesUserDeliveryInstruction() throws {
        let request = GenerationRequest(
            modelID: "pro_custom",
            text: "Please read this sentence with native English diction.",
            outputPath: "/tmp/out.wav",
            payload: .custom(speakerID: "aiden", deliveryStyle: "Warm and conversational")
        )

        let instruction = try XCTUnwrap(GenerationSemantics.customInstruction(for: request))
        XCTAssertEqual(
            instruction,
            "Warm and conversational \(GenerationSemantics.englishDictionReinforcement)"
        )
        XCTAssertFalse(instruction.contains("Delivery style:"))
        XCTAssertTrue(instruction.hasPrefix("Warm and conversational"))
    }

    func testEnglishCustomVoiceStrongPresetKeepsEmotionFirst() {
        let delivery = EmotionPreset.preset(id: "happy")!.instruction(for: .strong)
        let request = GenerationRequest(
            modelID: "pro_custom",
            text: "This product launch should sound genuinely excited.",
            outputPath: "/tmp/out.wav",
            payload: .custom(speakerID: "aiden", deliveryStyle: delivery)
        )

        XCTAssertEqual(
            GenerationSemantics.customInstruction(for: request),
            "\(delivery) \(GenerationSemantics.englishDictionReinforcement)"
        )
    }

    func testExcitedStrongPresetUsesSaferControlledPacingInstruction() {
        XCTAssertEqual(
            EmotionPreset.preset(id: "excited")?.instruction(for: .strong),
            "Very excited and animated, energetic and anticipatory, with lively emphasis, controlled pacing, and clear pronunciation."
        )
    }

    func testWhisperPresetUsesExplicitWhisperInstructions() {
        let whisper = EmotionPreset.preset(id: "whisper")

        XCTAssertEqual(
            whisper?.instruction(for: .subtle),
            "Subtle audible whisper, close-mic and quiet, with gentle breath, hushed tone, and clear words."
        )
        XCTAssertEqual(
            whisper?.instruction(for: .normal),
            "Hushed whisper, intimate and quiet, with breathy texture, clear articulation, and soft pacing."
        )
        XCTAssertEqual(
            whisper?.instruction(for: .strong),
            "Very soft and breathy whisper, intimate and intense, with clear pronunciation and enough audibility to understand every word."
        )
    }

    func testEnglishCustomVoiceWhisperPresetKeepsWhisperBeforeDictionReinforcement() {
        let delivery = EmotionPreset.preset(id: "whisper")!.instruction(for: .subtle)
        let request = GenerationRequest(
            modelID: "pro_custom",
            text: "This line should be delivered in a real whisper.",
            outputPath: "/tmp/out.wav",
            payload: .custom(speakerID: "vivian", deliveryStyle: delivery)
        )

        XCTAssertEqual(
            GenerationSemantics.customInstruction(for: request),
            "\(delivery) \(GenerationSemantics.englishDictionReinforcement)"
        )
        XCTAssertTrue(GenerationSemantics.customInstruction(for: request)?.hasPrefix("Subtle audible whisper") == true)
    }

    func testNonEnglishCustomVoiceDoesNotAddEnglishDictionInstruction() {
        let request = GenerationRequest(
            modelID: "pro_custom",
            text: "你好，这是一段测试文本。",
            outputPath: "/tmp/out.wav",
            payload: .custom(speakerID: "vivian", deliveryStyle: "Neutral")
        )

        XCTAssertEqual(GenerationSemantics.qwenLanguageHint(for: request), "chinese")
        XCTAssertNil(GenerationSemantics.customInstruction(for: request))
    }

    func testEnglishVoiceDesignAddsDictionInstructionAndPreservesBrief() {
        let request = GenerationRequest(
            modelID: "pro_design",
            text: "The product update needs calm, natural English narration.",
            outputPath: "/tmp/out.wav",
            payload: .design(voiceDescription: "A relaxed product narrator", deliveryStyle: "Calm")
        )

        let instruction = GenerationSemantics.voiceDesignInstruction(for: request)
        XCTAssertEqual(GenerationSemantics.qwenLanguageHint(for: request), "english")
        XCTAssertEqual(
            instruction,
            "Calm A relaxed product narrator \(GenerationSemantics.englishDictionReinforcement)"
        )
        XCTAssertFalse(instruction?.contains("Delivery style:") == true)
        XCTAssertFalse(instruction?.contains("Voice description:") == true)
    }

    func testNeutralVoiceDesignDoesNotEmitDeliveryStyleLine() {
        let request = GenerationRequest(
            modelID: "pro_design",
            text: "This should sound neutral and natural.",
            outputPath: "/tmp/out.wav",
            payload: .design(voiceDescription: "A clear product narrator", deliveryStyle: "Neutral")
        )

        let instruction = GenerationSemantics.voiceDesignInstruction(for: request)
        XCTAssertTrue(instruction?.contains(GenerationSemantics.englishDictionReinforcement) == true)
        XCTAssertTrue(instruction?.contains("A clear product narrator") == true)
        XCTAssertFalse(instruction?.contains("Delivery style:") == true)
    }

    func testDesignInstructionUsesNaturalLanguageAndHandlesMissingBrief() {
        XCTAssertEqual(
            GenerationSemantics.designInstruction(
                voiceDescription: "A crisp documentary narrator.",
                emotion: "Dramatic and expressive."
            ),
            "Dramatic and expressive. A crisp documentary narrator."
        )
        XCTAssertEqual(
            GenerationSemantics.designInstruction(
                voiceDescription: "   ",
                emotion: "Very happy."
            ),
            "Very happy."
        )
    }

    func testSpeedAndQualityVariantsResolveSameDeliveryInstruction() throws {
        let speedModel = try XCTUnwrap(TTSModel.model(id: "pro_custom_speed"))
        let qualityModel = try XCTUnwrap(TTSModel.model(id: "pro_custom_quality"))
        let delivery = EmotionPreset.preset(id: "sad")!.instruction(for: .normal)
        let speedRequest = GenerationRequest(
            modelID: speedModel.id,
            text: "This line should sound reflective and subdued.",
            outputPath: "/tmp/speed.wav",
            payload: .custom(speakerID: "aiden", deliveryStyle: delivery)
        )
        let qualityRequest = GenerationRequest(
            modelID: qualityModel.id,
            text: speedRequest.text,
            outputPath: "/tmp/quality.wav",
            payload: .custom(speakerID: "aiden", deliveryStyle: delivery)
        )

        XCTAssertEqual(
            GenerationSemantics.customInstruction(for: speedRequest),
            GenerationSemantics.customInstruction(for: qualityRequest)
        )
    }

    func testCloneRequestsDoNotReceiveHiddenDictionInstruction() {
        let request = GenerationRequest(
            modelID: "pro_clone",
            text: "This English text should follow the cloned reference voice.",
            outputPath: "/tmp/out.wav",
            payload: .clone(reference: CloneReference(audioPath: "/tmp/ref.wav", transcript: "Reference voice text"))
        )

        XCTAssertNil(GenerationSemantics.customInstruction(for: request))
        XCTAssertNil(GenerationSemantics.voiceDesignInstruction(for: request))
    }

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

    func testCustomPrewarmIdentityIgnoresNeutralDeliveryChanges() {
        let defaultRequest = GenerationRequest(
            modelID: "pro_custom",
            text: "Hello",
            outputPath: "/tmp/out.wav",
            payload: .custom(speakerID: "Vivian", deliveryStyle: "Neutral")
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
            payload: .design(voiceDescription: "  Warm, steady narrator  ", deliveryStyle: "Neutral")
        )
        let normalizedMatch = GenerationRequest(
            modelID: "pro_design",
            text: "Hello there.",
            outputPath: "/tmp/out.wav",
            payload: .design(voiceDescription: "warm, steady narrator", deliveryStyle: "Neutral")
        )
        let differentBrief = GenerationRequest(
            modelID: "pro_design",
            text: "Hello there.",
            outputPath: "/tmp/out.wav",
            payload: .design(voiceDescription: "Bright energetic announcer", deliveryStyle: "Neutral")
        )
        let differentLanguage = GenerationRequest(
            modelID: "pro_design",
            text: "你好，这是一段测试文本。",
            outputPath: "/tmp/out.wav",
            payload: .design(voiceDescription: "Warm, steady narrator", deliveryStyle: "Neutral")
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
        let sequenceNumber: Int = 7
        let emittedAtMilliseconds: Double = 1_777_944_000_000.0
        let inferenceMilliseconds: Double = 482.5
        let probe = ChunkProbeMetadata(
            seq: sequenceNumber,
            engineEmittedAtMS: emittedAtMilliseconds,
            inferMS: inferenceMilliseconds
        )
        let requestID: Int = 42
        let mode = "custom"
        let title = "probe round-trip"
        let chunkPath = "/tmp/chunk_007.wav"
        let chunkDurationSeconds: Double = 1.12
        let cumulativeDurationSeconds: Double = 7.84
        let streamSessionDirectory = "/tmp/session-x"
        let chunk = GenerationChunk(
            requestID: requestID,
            mode: mode,
            title: title,
            chunkPath: chunkPath,
            isFinal: false,
            chunkDurationSeconds: chunkDurationSeconds,
            cumulativeDurationSeconds: cumulativeDurationSeconds,
            streamSessionDirectory: streamSessionDirectory,
            previewAudio: nil,
            probeMetadata: probe
        )
        let encoded = try JSONEncoder().encode(chunk)
        let decoded = try JSONDecoder().decode(GenerationChunk.self, from: encoded)
        XCTAssertEqual(decoded.probeMetadata, probe)
        XCTAssertEqual(decoded.requestID, 42)
        XCTAssertEqual(decoded.chunkDurationSeconds, 1.12)
        // Engine probe Phase 1 fields default to nil when not provided
        // by the constructor — legacy / non-Qwen3 chunk path.
        XCTAssertNil(decoded.probeMetadata?.talkerForwardMS)
        XCTAssertNil(decoded.probeMetadata?.codePredictorMS)
        XCTAssertNil(decoded.probeMetadata?.audioDecoderMS)
    }

    func testGenerationChunkRoundTripsWithEngineSubstageTimings() throws {
        // Engine probe Phase 1: ChunkProbeMetadata carries optional
        // sub-stage breakdown of `inferMS`. Round-trip preserves all
        // three deltas with full Double precision.
        let probe = ChunkProbeMetadata(
            seq: 12,
            engineEmittedAtMS: 1_777_944_500_500.0,
            inferMS: 1_017.5,
            talkerForwardMS: 612.4,
            codePredictorMS: 47.1,
            audioDecoderMS: 38.7
        )
        let chunk = GenerationChunk(
            requestID: 99,
            mode: "clone",
            title: "substage round-trip",
            chunkPath: nil,
            isFinal: false,
            chunkDurationSeconds: 1.12,
            cumulativeDurationSeconds: 13.44,
            streamSessionDirectory: nil,
            previewAudio: nil,
            probeMetadata: probe
        )
        let encoded = try JSONEncoder().encode(chunk)
        let decoded = try JSONDecoder().decode(GenerationChunk.self, from: encoded)
        XCTAssertEqual(decoded.probeMetadata?.talkerForwardMS, 612.4)
        XCTAssertEqual(decoded.probeMetadata?.codePredictorMS, 47.1)
        XCTAssertEqual(decoded.probeMetadata?.audioDecoderMS, 38.7)
        XCTAssertEqual(decoded.probeMetadata?.inferMS, 1_017.5)
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

    func testGenerationChunkRoundTripsWithEngineSubstageTimingsPhase2a() throws {
        // Engine probe Phase 2a: extends the breakdown with the three
        // `eval` cadence fields chasing the missing 74-82% of inferMS
        // from the May 2026 Phase 1 re-bench. Round-trip preserves
        // all six sub-stage fields together.
        let probe = ChunkProbeMetadata(
            seq: 8,
            engineEmittedAtMS: 1_777_998_000_000.0,
            inferMS: 1_512.0,
            talkerForwardMS: 80.0,
            codePredictorMS: 240.0,
            audioDecoderMS: 9.5,
            streamStepEvalMS: 415.5,
            streamStepEOSReadMS: 187.25,
            audioChunkEvalMS: 320.75
        )
        let encoded = try JSONEncoder().encode(probe)
        let decoded = try JSONDecoder().decode(ChunkProbeMetadata.self, from: encoded)
        XCTAssertEqual(decoded, probe)
        XCTAssertEqual(decoded.streamStepEvalMS, 415.5)
        XCTAssertEqual(decoded.streamStepEOSReadMS, 187.25)
        XCTAssertEqual(decoded.audioChunkEvalMS, 320.75)
        // Sanity: Phase 1 + Phase 2a sub-stages should roughly sum
        // toward `inferMS`. Six measured stages here = 1253.0 ms vs
        // 1512.0 ms infer = 83 % — within the 80 % Phase 2a target.
        let measured = (decoded.talkerForwardMS ?? 0)
            + (decoded.codePredictorMS ?? 0)
            + (decoded.audioDecoderMS ?? 0)
            + (decoded.streamStepEvalMS ?? 0)
            + (decoded.streamStepEOSReadMS ?? 0)
            + (decoded.audioChunkEvalMS ?? 0)
        XCTAssertGreaterThan(measured, 0)
        XCTAssertLessThanOrEqual(measured, decoded.inferMS + 1.0)
    }

    func testGenerationChunkRoundTripsWithPhase1FieldsOnlyDecodesPhase2aAsNil() throws {
        // Backward-compat: a chunk with only Phase 1 fields populated
        // (e.g. produced before Phase 2a shipped, or from a non-Qwen3
        // backend) round-trips with Phase 2a fields as nil — no
        // missing-key decode error.
        let probe = ChunkProbeMetadata(
            seq: 5,
            engineEmittedAtMS: 1_777_999_000_000.0,
            inferMS: 900.0,
            talkerForwardMS: 50.0,
            codePredictorMS: 200.0,
            audioDecoderMS: 8.0
        )
        let encoded = try JSONEncoder().encode(probe)
        let decoded = try JSONDecoder().decode(ChunkProbeMetadata.self, from: encoded)
        XCTAssertEqual(decoded, probe)
        XCTAssertNil(decoded.streamStepEvalMS)
        XCTAssertNil(decoded.streamStepEOSReadMS)
        XCTAssertNil(decoded.audioChunkEvalMS)
    }
}
