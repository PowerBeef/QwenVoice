import Foundation

// Single source of truth for the delivery (tone/emotion) presets, shared by the
// macOS app, the iOS app, and the `vocello` CLI (bench/review delivery cells).
// Previously duplicated as Sources/Models/EmotionPreset.swift and
// Sources/iOSSupport/Models/EmotionPreset.swift, which had to be edited in
// lockstep; consolidated here so preset copy changes land once.

public enum DeliveryPresetCategory: String, CaseIterable, Sendable {
    case neutral
    case emotion
    case deliveryStyle
    case vocalTechnique

    public var displayName: String? {
        switch self {
        case .neutral:          return nil
        case .emotion:          return "Emotion"
        case .deliveryStyle:    return "Delivery style"
        case .vocalTechnique:   return "Vocal technique"
        }
    }
}

public struct DeliveryProfile: Equatable, Sendable {
    public static let neutralInstruction = "Neutral"

    public let presetID: String?
    public let customText: String?
    public let finalInstruction: String

    public init(
        presetID: String?,
        customText: String?,
        finalInstruction: String
    ) {
        self.presetID = presetID
        self.customText = customText
        self.finalInstruction = finalInstruction
    }

    public static let neutral = DeliveryProfile(
        presetID: "neutral",
        customText: nil,
        finalInstruction: neutralInstruction
    )

    public static func isNeutralInstruction(_ instruction: String) -> Bool {
        let normalized = instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty
            || normalized == "normal tone"
            || normalized == "neutral"
            || normalized == "neutral tone"
    }

    public var trimmedInstruction: String {
        finalInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedCustomText: String? {
        customText?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isNeutral: Bool {
        DeliveryProfile.isNeutralInstruction(trimmedInstruction)
    }

    public var isMeaningful: Bool {
        !isNeutral
    }

    public static func preset(_ preset: EmotionPreset) -> DeliveryProfile {
        DeliveryProfile(
            presetID: preset.id,
            customText: nil,
            finalInstruction: preset.instruction
        )
    }

    public static func custom(_ text: String) -> DeliveryProfile {
        DeliveryProfile(
            presetID: nil,
            customText: text,
            finalInstruction: text
        )
    }
}

public struct EmotionPreset: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let sfSymbol: String
    public let category: DeliveryPresetCategory
    public let instruction: String

    public init(
        id: String,
        label: String,
        sfSymbol: String,
        category: DeliveryPresetCategory,
        instruction: String
    ) {
        self.id = id
        self.label = label
        self.sfSymbol = sfSymbol
        self.category = category
        self.instruction = instruction
    }

    public static func preset(id: String?) -> EmotionPreset? {
        guard let id else { return nil }
        return all.first(where: { $0.id == id })
    }

    public static let all: [EmotionPreset] = [
        EmotionPreset(
            id: "neutral",
            label: "Neutral",
            sfSymbol: "face.dashed",
            category: .neutral,
            instruction: DeliveryProfile.neutralInstruction
        ),
        EmotionPreset(
            id: "happy",
            label: "Happy",
            sfSymbol: "face.smiling",
            category: .emotion,
            instruction: "Speak happily and upbeat, with a bright, beaming tone, slightly lifted pitch, and a lively, bouncy pace; no laughing."
        ),
        EmotionPreset(
            id: "sad",
            label: "Sad",
            sfSymbol: "cloud.rain",
            category: .emotion,
            instruction: "Speak sadly and softly, with a lowered pitch, slow weighted pace, and a fragile, restrained tone; keep every word clear and audible."
        ),
        EmotionPreset(
            id: "angry",
            label: "Angry",
            sfSymbol: "flame",
            category: .emotion,
            instruction: "Speak angrily and firmly, with sharp consonants, tight stress, forceful tension, and a lower clipped tone; never shout or scream."
        ),
        EmotionPreset(
            id: "fearful",
            label: "Fearful",
            sfSymbol: "exclamationmark.triangle",
            category: .emotion,
            instruction: "Speak fearfully and anxiously, with a breathy, shaky voice, uncertain pacing, and a smaller, urgent tone; stay fully audible."
        ),
        EmotionPreset(
            id: "surprised",
            label: "Surprised",
            sfSymbol: "exclamationmark.2",
            category: .emotion,
            instruction: "Speak with unmistakable surprise, a quick animated pace, pitch jumping higher on key words, and sharp emphasis; no gasping or extra sounds."
        ),
        EmotionPreset(
            id: "excited",
            label: "Excited",
            sfSymbol: "sparkles",
            category: .emotion,
            instruction: "Speak excitedly, with a fast driving pace, bright ringing tone, higher pitch and louder volume than normal; no laughing or shouting."
        ),
        EmotionPreset(
            id: "calm",
            label: "Calm",
            sfSymbol: "leaf",
            category: .emotion,
            instruction: "Speak calmly and soothingly, with smooth unhurried pacing, low settled pitch, and reassuring warmth; no tension or urgency."
        ),
        EmotionPreset(
            id: "narrator",
            label: "Documentary",
            sfSymbol: "text.book.closed",
            category: .deliveryStyle,
            instruction: "Narrate like a composed documentary voice, with a low warm timbre, deliberate pacing, crisp diction, and gentle emphasis on key phrases."
        ),
        EmotionPreset(
            id: "news",
            label: "Newscaster",
            sfSymbol: "newspaper",
            category: .deliveryStyle,
            instruction: "Speak like a clear newscaster, with steady professional delivery, even pacing, precise articulation, and no dramatics."
        ),
        EmotionPreset(
            id: "dramatic",
            label: "Dramatic",
            sfSymbol: "theatermasks",
            category: .deliveryStyle,
            instruction: "Speak dramatically with heightened inflection, deliberate pacing, bold stress on key words, and generous pauses; no shouting."
        ),
        EmotionPreset(
            id: "whisper",
            label: "Whisper",
            sfSymbol: "ear",
            category: .vocalTechnique,
            instruction: "Whisper throughout, hushed and breathy, every word voiced just above breath, close and confidential; never lift into normal speech."
        ),
    ]
}
