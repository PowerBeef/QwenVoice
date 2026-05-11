import Foundation

public enum GenerationSemantics {
    public enum DesignWarmBucket: String, Sendable {
        case short
        case long
    }

    public static let appStreamingInterval = 0.32
    public static let canonicalCustomWarmText = "Hi."
    public static let canonicalCustomWarmSpeaker = "aiden"
    public static let canonicalCustomWarmLanguage = "english"
    public static let canonicalDesignWarmLanguage = "english"
    public static let englishDictionReinforcement =
        "Native English pronunciation with clear English diction and natural stress."
    public static let canonicalDesignWarmShortText = "Hello world."
    public static let canonicalDesignWarmLongText =
        """
        Artificial intelligence has rapidly transformed from a niche academic pursuit into one of the most consequential technologies of the modern era. Large language models, capable of generating coherent text across a wide range of domains, have captured the imagination of researchers and the general public alike. Meanwhile, text-to-speech systems have reached a point where synthesized voices are often indistinguishable from natural human speech, opening new possibilities for accessibility, creative media production, and personalized assistants.
        """

    public static func isNeutralDeliveryInstruction(_ emotion: String) -> Bool {
        let normalized = normalizedConditioningCacheKeyText(emotion)
        return normalized.isEmpty
            || normalized == "normal tone"
            || normalized == "neutral"
            || normalized == "neutral tone"
    }

    public static func hasMeaningfulDeliveryInstruction(_ emotion: String) -> Bool {
        !isNeutralDeliveryInstruction(emotion)
    }

    public static func supportsIdlePrewarm(mode: GenerationMode) -> Bool {
        mode == .custom
    }

    public static func designInstruction(voiceDescription: String, emotion: String) -> String {
        let trimmedDescription = voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmotion = emotion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasMeaningfulDeliveryInstruction(trimmedEmotion) else {
            return trimmedDescription
        }

        guard !trimmedDescription.isEmpty else {
            return trimmedEmotion
        }
        return "\(trimmedEmotion) \(trimmedDescription)"
    }

    public static func normalizedConditioningCacheKeyText(_ text: String) -> String {
        Qwen3TTSRuntimeProfile.normalizedCacheText(text)
    }

    public static func normalizedDesignConditioningIdentity(
        language: String,
        voiceDescription: String,
        emotion: String?
    ) -> String {
        let normalizedLanguage = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let resolvedInstruction = englishDictionReinforcedInstruction(
            baseInstruction: designInstruction(
                voiceDescription: voiceDescription,
                emotion: emotion ?? ""
            ),
            language: normalizedLanguage
        ) ?? ""
        let normalizedInstruction = normalizedConditioningCacheKeyText(resolvedInstruction)
        return "\(normalizedLanguage)|\(normalizedInstruction)"
    }

    public static func customInstruction(deliveryStyle: String?) -> String? {
        guard let deliveryStyle else { return nil }
        let trimmedDelivery = deliveryStyle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasMeaningfulDeliveryInstruction(trimmedDelivery) else {
            return nil
        }
        return trimmedDelivery
    }

    public static func customInstruction(for request: GenerationRequest) -> String? {
        guard case .custom(_, let deliveryStyle) = request.payload else {
            return nil
        }
        let language = qwenLanguageHint(for: request)
        let baseInstruction = customInstruction(deliveryStyle: deliveryStyle)
        return englishDictionReinforcedInstruction(
            baseInstruction: baseInstruction,
            language: language
        )
    }

    public static func voiceDesignInstruction(for request: GenerationRequest) -> String? {
        guard case .design(let voiceDescription, let deliveryStyle) = request.payload else {
            return nil
        }
        return englishDictionReinforcedInstruction(
            baseInstruction: designInstruction(
                voiceDescription: voiceDescription,
                emotion: deliveryStyle ?? ""
            ),
            language: qwenLanguageHint(for: request)
        )
    }

    public static func englishDictionReinforcedInstruction(
        baseInstruction: String?,
        language: String
    ) -> String? {
        guard Qwen3TTSRuntimeProfile.normalizedLanguage(language) == "english" else {
            return baseInstruction
        }

        let reinforcement = englishDictionReinforcement
        guard let baseInstruction else {
            return reinforcement
        }

        let trimmedBase = baseInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else {
            return reinforcement
        }
        if normalizedConditioningCacheKeyText(trimmedBase)
            .contains(normalizedConditioningCacheKeyText(reinforcement)) {
            return trimmedBase
        }
        return "\(trimmedBase) \(reinforcement)"
    }

    public static func qwenLanguageHint(
        for request: GenerationRequest,
        resolvedCloneTranscript: String? = nil
    ) -> String {
        switch request.payload {
        case .custom:
            return Qwen3TTSRuntimeProfile.normalizedLanguage(
                detectedQwenLanguage(in: request.text) ?? canonicalCustomWarmLanguage
            )
        case .design:
            return Qwen3TTSRuntimeProfile.normalizedLanguage(
                detectedQwenLanguage(in: request.text) ?? "auto"
            )
        case .clone:
            if let transcript = resolvedCloneTranscript,
               let detectedLanguage = detectedQwenLanguage(in: transcript) {
                return Qwen3TTSRuntimeProfile.normalizedLanguage(detectedLanguage)
            }
            return Qwen3TTSRuntimeProfile.normalizedLanguage(
                detectedQwenLanguage(in: request.text) ?? "auto"
            )
        }
    }

    public static func validateQwenPromptContract(for request: GenerationRequest) throws {
        switch request.payload {
        case .custom(_, let deliveryStyle):
            if let deliveryStyle,
               hasMeaningfulDeliveryInstruction(deliveryStyle),
               Qwen3TTSRuntimeProfile.containsDisallowedVoiceImitationInstruction(
                   normalizedConditioningCacheKeyText(deliveryStyle)
               ) {
                throw MLXTTSEngineError.unsupportedRequest(
                    "Custom Voice delivery instructions cannot request celebrity imitation or voice impersonation."
                )
            }
        case .design(let voiceDescription, let deliveryStyle):
            let instruction = designInstruction(
                voiceDescription: voiceDescription,
                emotion: deliveryStyle ?? ""
            )
            if Qwen3TTSRuntimeProfile.containsDisallowedVoiceImitationInstruction(
                normalizedConditioningCacheKeyText(instruction)
            ) {
                throw MLXTTSEngineError.unsupportedRequest(
                    "Voice Design descriptions cannot request celebrity imitation or voice impersonation."
                )
            }
        case .clone:
            break
        }
    }

    public static func canonicalCustomWarmInstruction() -> String? {
        nil
    }

    public static func canonicalDesignWarmInstruction() -> String {
        designInstruction(
            voiceDescription: "A clear, steady narrator with a natural conversational tone.",
            emotion: ""
        )
    }

    public static func canonicalDesignWarmText(for bucket: DesignWarmBucket) -> String {
        switch bucket {
        case .short:
            canonicalDesignWarmShortText
        case .long:
            canonicalDesignWarmLongText
        }
    }

    public static func designWarmBucket(for text: String) -> DesignWarmBucket {
        let normalizedText = normalizedConditioningCacheKeyText(text)
        guard !normalizedText.isEmpty else { return .short }

        let normalizedLongText = normalizedConditioningCacheKeyText(canonicalDesignWarmLongText)
        let longBucketThreshold = max(160, normalizedLongText.count / 2)
        return normalizedText.count >= longBucketThreshold ? .long : .short
    }

    public static func designConditioningWarmKey(
        modelID: String,
        language: String,
        voiceDescription: String,
        emotion: String?,
        text: String
    ) -> String {
        let normalizedConditioning = normalizedDesignConditioningIdentity(
            language: language,
            voiceDescription: voiceDescription,
            emotion: emotion
        )
        return [
            modelID,
            GenerationMode.design.rawValue,
            normalizedConditioning,
            designWarmBucket(for: text).rawValue,
        ].joined(separator: "|")
    }

    public static func designConditioningWarmKey(
        for request: GenerationRequest
    ) -> String? {
        guard case .design(let voiceDescription, let emotion) = request.payload else {
            return nil
        }
        let trimmedVoiceDescription = voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVoiceDescription.isEmpty else { return nil }
        let language = qwenLanguageHint(for: request)
        return designConditioningWarmKey(
            modelID: request.modelID,
            language: language,
            voiceDescription: voiceDescription,
            emotion: emotion,
            text: request.text
        )
    }

    public static func prewarmIdentityKey(
        modelID: String,
        mode: GenerationMode,
        voice: String? = nil,
        instruct: String? = nil,
        refAudio: String? = nil,
        refText: String? = nil
    ) -> String {
        let trimmedVoice = voice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedRefAudio = refAudio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedRefText = refText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedInstruction = instruct?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedInstruction = hasMeaningfulDeliveryInstruction(trimmedInstruction) ? trimmedInstruction : ""
        let identityParts: [String]

        switch mode {
        case .custom:
            _ = trimmedVoice
            _ = normalizedInstruction
            // Keep custom interactive readiness stable at the model level so
            // UI draft churn does not invalidate the hot model state.
            identityParts = [modelID, mode.rawValue]
        case .design:
            identityParts = [modelID, mode.rawValue]
        case .clone:
            identityParts = [modelID, mode.rawValue, trimmedRefAudio, trimmedRefText]
        }

        return identityParts.joined(separator: "|")
    }

    public static func cloneReferenceIdentityKey(
        modelID: String,
        refAudio: String,
        refText: String?
    ) -> String {
        prewarmIdentityKey(
            modelID: modelID,
            mode: .clone,
            refAudio: refAudio,
            refText: refText
        )
    }

    /// Request-form prewarm identity key. For `.custom`, the key INCLUDES
    /// the speaker and (normalized) delivery instruction, so that voice/
    /// delivery changes invalidate the prewarm cache. The parameterized
    /// `prewarmIdentityKey(modelID:mode:...)` above intentionally omits
    /// those for the "stable model-level readiness" code paths — both
    /// forms coexist by design with intentionally different semantics.
    /// Live callers: NativeEngineRuntime, XPCNativeEngineClient,
    /// GenerationSemanticsTests.
    public static func prewarmIdentityKey(for request: GenerationRequest) -> String {
        switch request.payload {
        case .custom(let speakerID, let deliveryStyle):
            let normalizedInstruction = hasMeaningfulDeliveryInstruction(deliveryStyle ?? "")
                ? deliveryStyle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                : ""
            return [
                request.modelID,
                request.modeIdentifier,
                speakerID.trimmingCharacters(in: .whitespacesAndNewlines),
                normalizedInstruction,
            ].joined(separator: "|")
        case .design:
            return [
                request.modelID,
                request.modeIdentifier,
            ].joined(separator: "|")
        case .clone(let reference):
            return clonePreparationKey(modelID: request.modelID, reference: reference)
        }
    }

    /// Public clone-preparation cache key. Mirrors the (now-retired)
    /// QwenVoiceEngineSupport.GenerationSemantics.clonePreparationKey
    /// signature so callers (UITestStubMacEngine, VoiceCloningView,
    /// NativeMLXMacEngineTests, GenerationSemanticsTests, NativeMLXMacEngine)
    /// can switch from the EngineSupport copy to this one without changing
    /// arguments. Format: "<modelID>|clone|<audioPath>|<transcript>".
    public static func clonePreparationKey(modelID: String, reference: CloneReference) -> String {
        [
            modelID,
            "clone",
            reference.audioPath.trimmingCharacters(in: .whitespacesAndNewlines),
            reference.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        ].joined(separator: "|")
    }

    private static func detectedQwenLanguage(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.unicodeScalars.contains(where: \.isJapaneseScalar) {
            return "japanese"
        }
        if trimmed.unicodeScalars.contains(where: \.isHangulScalar) {
            return "korean"
        }
        if trimmed.unicodeScalars.contains(where: \.isArabicScalar) {
            return "arabic"
        }
        if trimmed.unicodeScalars.contains(where: \.isDevanagariScalar) {
            return "hindi"
        }
        if trimmed.unicodeScalars.contains(where: \.isCyrillicScalar) {
            return "russian"
        }
        if trimmed.unicodeScalars.contains(where: \.isCJKScalar) {
            return "chinese"
        }
        if trimmed.unicodeScalars.contains(where: \.isLatinLetterScalar) {
            return "english"
        }
        return nil
    }
}

private extension UnicodeScalar {
    var isCJKScalar: Bool {
        switch value {
        case 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF:
            return true
        default:
            return false
        }
    }

    var isJapaneseScalar: Bool {
        switch value {
        case 0x3040 ... 0x309F, 0x30A0 ... 0x30FF:
            return true
        default:
            return false
        }
    }

    var isHangulScalar: Bool {
        switch value {
        case 0x1100 ... 0x11FF, 0x3130 ... 0x318F, 0xAC00 ... 0xD7AF:
            return true
        default:
            return false
        }
    }

    var isArabicScalar: Bool {
        switch value {
        case 0x0600 ... 0x06FF, 0x0750 ... 0x077F, 0x08A0 ... 0x08FF:
            return true
        default:
            return false
        }
    }

    var isDevanagariScalar: Bool {
        switch value {
        case 0x0900 ... 0x097F:
            return true
        default:
            return false
        }
    }

    var isCyrillicScalar: Bool {
        switch value {
        case 0x0400 ... 0x04FF, 0x0500 ... 0x052F:
            return true
        default:
            return false
        }
    }

    var isLatinLetterScalar: Bool {
        switch value {
        case 0x0041 ... 0x005A, 0x0061 ... 0x007A:
            return true
        default:
            return false
        }
    }
}
