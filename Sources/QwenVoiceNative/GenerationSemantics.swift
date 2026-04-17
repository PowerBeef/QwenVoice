import Foundation

public enum GenerationSemantics {
    public enum DesignWarmBucket: String, Sendable {
        case short
        case long
    }

    public static let appStreamingInterval = 0.32
    public static let canonicalCustomLanguage = "english"
    public static let canonicalDesignWarmShortText = "Hello world."
    public static let canonicalDesignWarmLongText =
        """
        Artificial intelligence has rapidly transformed from a niche academic pursuit into one of the most consequential technologies of the modern era. Large language models, capable of generating coherent text across a wide range of domains, have captured the imagination of researchers and the general public alike. Meanwhile, text-to-speech systems have reached a point where synthesized voices are often indistinguishable from natural human speech, opening new possibilities for accessibility, creative media production, and personalized assistants.
        """

    public static func hasMeaningfulDeliveryInstruction(_ deliveryStyle: String?) -> Bool {
        let normalized = normalizedConditioningCacheKeyText(deliveryStyle ?? "")
        return !normalized.isEmpty && normalized.caseInsensitiveCompare("normal tone") != .orderedSame
    }

    public static func customInstruction(deliveryStyle: String?) -> String? {
        guard hasMeaningfulDeliveryInstruction(deliveryStyle) else {
            return nil
        }
        return deliveryStyle?.trimmingCharacters(in: .whitespacesAndNewlines)
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

    public static func qwenLanguageHint(
        for request: GenerationRequest,
        resolvedCloneTranscript: String? = nil
    ) -> String {
        switch request.payload {
        case .custom:
            return detectedQwenLanguage(in: request.text) ?? canonicalCustomLanguage
        case .design:
            return detectedQwenLanguage(in: request.text) ?? "auto"
        case .clone:
            if let resolvedCloneTranscript,
               let detectedLanguage = detectedQwenLanguage(in: resolvedCloneTranscript) {
                return detectedLanguage
            }
            return detectedQwenLanguage(in: request.text) ?? "auto"
        }
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
        guard !normalizedText.isEmpty else {
            return .short
        }

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
            "design",
            normalizedConditioning,
            designWarmBucket(for: text).rawValue,
        ].joined(separator: "|")
    }

    public static func designConditioningWarmKey(for request: GenerationRequest) -> String? {
        guard case .design(let voiceDescription, let emotion) = request.payload else {
            return nil
        }
        let trimmedVoiceDescription = voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVoiceDescription.isEmpty else {
            return nil
        }

        return designConditioningWarmKey(
            modelID: request.modelID,
            language: qwenLanguageHint(for: request),
            voiceDescription: voiceDescription,
            emotion: emotion,
            text: request.text
        )
    }

    public static func prewarmIdentityKey(for request: GenerationRequest) -> String {
        switch request.payload {
        case .custom(let speakerID, let deliveryStyle):
            let normalizedInstruction = hasMeaningfulDeliveryInstruction(deliveryStyle)
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
        guard !trimmed.isEmpty else {
            return nil
        }

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
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
    }

    var isJapaneseScalar: Bool {
        (0x3040...0x309F).contains(value) || (0x30A0...0x30FF).contains(value)
    }

    var isHangulScalar: Bool {
        (0x1100...0x11FF).contains(value)
            || (0x3130...0x318F).contains(value)
            || (0xAC00...0xD7AF).contains(value)
    }

    var isArabicScalar: Bool {
        (0x0600...0x06FF).contains(value)
    }

    var isDevanagariScalar: Bool {
        (0x0900...0x097F).contains(value)
    }

    var isCyrillicScalar: Bool {
        (0x0400...0x04FF).contains(value)
    }
}
