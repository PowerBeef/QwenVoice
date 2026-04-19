import Foundation

public enum GenerationSemantics {
    public enum DesignWarmBucket: String, Sendable {
        case short
        case long
    }

    public static let appStreamingInterval = 0.32
    public static let canonicalCustomWarmSpeaker = "vivian"
    public static let canonicalCustomWarmLanguage = "english"
    public static let canonicalDesignWarmLanguage = "english"
    public static let canonicalDesignWarmShortText = "Hello world."
    public static let canonicalDesignWarmLongText =
        """
        Artificial intelligence has rapidly transformed from a niche academic pursuit into one of the most consequential technologies of the modern era. Large language models, capable of generating coherent text across a wide range of domains, have captured the imagination of researchers and the general public alike. Meanwhile, text-to-speech systems have reached a point where synthesized voices are often indistinguishable from natural human speech, opening new possibilities for accessibility, creative media production, and personalized assistants.
        """

    public static func hasMeaningfulDeliveryInstruction(_ emotion: String) -> Bool {
        let normalized = normalizedConditioningCacheKeyText(emotion)
        return !normalized.isEmpty && normalized.caseInsensitiveCompare("normal tone") != .orderedSame
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

        return """
        Voice description: \(trimmedDescription)
        Delivery style: \(trimmedEmotion)
        """
    }

    public static func normalizedConditioningCacheKeyText(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    public static func normalizedDesignConditioningIdentity(
        language: String,
        voiceDescription: String,
        emotion: String?
    ) -> String {
        let normalizedLanguage = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let resolvedInstruction = designInstruction(
            voiceDescription: voiceDescription,
            emotion: emotion ?? ""
        )
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

    public static func qwenLanguageHint(
        for request: GenerationRequest,
        resolvedCloneTranscript: String? = nil
    ) -> String {
        switch request.payload {
        case .custom:
            return detectedQwenLanguage(in: request.text) ?? canonicalCustomWarmLanguage
        case .design:
            return detectedQwenLanguage(in: request.text) ?? "auto"
        case .clone:
            if let transcript = resolvedCloneTranscript,
               let detectedLanguage = detectedQwenLanguage(in: transcript) {
                return detectedLanguage
            }
            return detectedQwenLanguage(in: request.text) ?? "auto"
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
}
