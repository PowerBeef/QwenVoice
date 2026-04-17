import Foundation

public enum GenerationSemantics {
    public static func hasMeaningfulDeliveryInstruction(_ deliveryStyle: String?) -> Bool {
        let trimmed = deliveryStyle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty && trimmed.caseInsensitiveCompare("Normal tone") != .orderedSame
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
