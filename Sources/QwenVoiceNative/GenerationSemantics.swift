import Foundation

public enum GenerationSemantics {
    public static let appStreamingInterval = 0.32
    public static let canonicalCustomLanguage = "english"

    public static func hasMeaningfulDeliveryInstruction(_ deliveryStyle: String?) -> Bool {
        let trimmed = deliveryStyle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty && trimmed.caseInsensitiveCompare("Normal tone") != .orderedSame
    }

    public static func customInstruction(deliveryStyle: String?) -> String? {
        guard hasMeaningfulDeliveryInstruction(deliveryStyle) else {
            return nil
        }
        return deliveryStyle?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func qwenLanguageHint(for request: GenerationRequest) -> String {
        let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return canonicalCustomLanguage
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
        return canonicalCustomLanguage
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
}

private extension UnicodeScalar {
    var isJapaneseScalar: Bool {
        (0x3040...0x30FF).contains(value) || (0x4E00...0x9FFF).contains(value)
    }

    var isHangulScalar: Bool {
        (0x1100...0x11FF).contains(value) || (0xAC00...0xD7AF).contains(value)
    }

    var isArabicScalar: Bool {
        (0x0600...0x06FF).contains(value)
    }

    var isDevanagariScalar: Bool {
        (0x0900...0x097F).contains(value)
    }
}
