import Foundation

enum EmotionIntensity: Int, CaseIterable, Identifiable {
    case subtle = 0
    case normal = 1
    case strong = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .subtle: "Subtle"
        case .normal: "Normal"
        case .strong: "Strong"
        }
    }

    var rpcValue: String {
        switch self {
        case .subtle: "subtle"
        case .normal: "normal"
        case .strong: "strong"
        }
    }
}

struct DeliveryProfile: Equatable {
    static let neutralInstruction = "Neutral"

    let presetID: String?
    let intensity: EmotionIntensity?
    let customText: String?
    let finalInstruction: String

    static let neutral = DeliveryProfile(
        presetID: "neutral",
        intensity: nil,
        customText: nil,
        finalInstruction: neutralInstruction
    )

    static func isNeutralInstruction(_ instruction: String) -> Bool {
        let normalized = instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty
            || normalized == "normal tone"
            || normalized == "neutral"
            || normalized == "neutral tone"
    }

    var trimmedInstruction: String {
        finalInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedCustomText: String? {
        customText?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isNeutral: Bool {
        DeliveryProfile.isNeutralInstruction(trimmedInstruction)
    }

    var isMeaningful: Bool {
        !isNeutral
    }

    static func preset(_ preset: EmotionPreset, intensity: EmotionIntensity) -> DeliveryProfile {
        DeliveryProfile(
            presetID: preset.id,
            intensity: preset.id == "neutral" ? nil : intensity,
            customText: nil,
            finalInstruction: preset.instruction(for: intensity)
        )
    }

    static func custom(_ text: String) -> DeliveryProfile {
        DeliveryProfile(
            presetID: nil,
            intensity: .normal,
            customText: text,
            finalInstruction: text
        )
    }
}

struct EmotionPreset: Identifiable {
    let id: String
    let label: String
    let sfSymbol: String
    let instructions: [EmotionIntensity: String]

    func instruction(for intensity: EmotionIntensity) -> String {
        instructions[intensity] ?? instructions[.normal] ?? DeliveryProfile.neutralInstruction
    }

    static func preset(id: String?) -> EmotionPreset? {
        guard let id else { return nil }
        return all.first(where: { $0.id == id })
    }

    static let all: [EmotionPreset] = [
        EmotionPreset(
            id: "neutral",
            label: "Neutral",
            sfSymbol: "face.dashed",
            instructions: [
                .subtle: DeliveryProfile.neutralInstruction,
                .normal: DeliveryProfile.neutralInstruction,
                .strong: DeliveryProfile.neutralInstruction,
            ]
        ),
        EmotionPreset(
            id: "happy",
            label: "Happy",
            sfSymbol: "face.smiling",
            instructions: [
                .subtle: "Slightly cheerful and warm, with a gentle smile in the voice and natural pacing.",
                .normal: "Happy and upbeat, with bright energy, clear articulation, and natural conversational pacing.",
                .strong: "Very happy and joyful, energetic and expressive, with lively stress while keeping words clear.",
            ]
        ),
        EmotionPreset(
            id: "sad",
            label: "Sad",
            sfSymbol: "cloud.rain",
            instructions: [
                .subtle: "Slightly sad and reflective, subdued but clear, with slower natural pacing.",
                .normal: "Sad and somber, with a restrained heavy tone and gentle pauses.",
                .strong: "Deeply sad and tearful, with fragile emotion, slow pacing, and soft intensity while staying intelligible.",
            ]
        ),
        EmotionPreset(
            id: "angry",
            label: "Angry",
            sfSymbol: "flame",
            instructions: [
                .subtle: "Slightly irritated and tense, controlled and clipped without shouting.",
                .normal: "Angry and frustrated, with firm stress, sharper consonants, and controlled intensity.",
                .strong: "Furious but intelligible, forceful and tense, with sharp emphasis and no screaming.",
            ]
        ),
        EmotionPreset(
            id: "fearful",
            label: "Fearful",
            sfSymbol: "exclamationmark.triangle",
            instructions: [
                .subtle: "Slightly nervous and uneasy, cautious and quiet with natural hesitation.",
                .normal: "Fearful and anxious, with tense breath, uncertain pacing, and clear words.",
                .strong: "Terrified and urgent, trembling and panicked but still understandable.",
            ]
        ),
        EmotionPreset(
            id: "whisper",
            label: "Whisper",
            sfSymbol: "ear",
            instructions: [
                .subtle: "Subtle audible whisper, close-mic and quiet, with gentle breath, hushed tone, and clear words.",
                .normal: "Hushed whisper, intimate and quiet, with breathy texture, clear articulation, and soft pacing.",
                .strong: "Very soft and breathy whisper, intimate and intense, with clear pronunciation and enough audibility to understand every word.",
            ]
        ),
        EmotionPreset(
            id: "dramatic",
            label: "Dramatic",
            sfSymbol: "theatermasks",
            instructions: [
                .subtle: "Slightly theatrical, with measured emphasis and tasteful pauses.",
                .normal: "Dramatic and expressive, with heightened intonation, deliberate pacing, and clear emphasis.",
                .strong: "Highly dramatic and theatrical, with bold emphasis, sweeping intensity, and well-timed pauses.",
            ]
        ),
        EmotionPreset(
            id: "calm",
            label: "Calm",
            sfSymbol: "leaf",
            instructions: [
                .subtle: "Relaxed and easy-going, steady and warm with unhurried pacing.",
                .normal: "Calm, soothing, and reassuring, with smooth pacing and gentle confidence.",
                .strong: "Deeply serene and meditative, slow and deliberate, with soft warmth and long steady phrasing.",
            ]
        ),
        EmotionPreset(
            id: "excited",
            label: "Excited",
            sfSymbol: "sparkles",
            instructions: [
                .subtle: "Slightly energetic and engaged, with a touch of enthusiasm and natural pace.",
                .normal: "Excited and energetic, enthusiastic and bright, with quick but clear delivery.",
                .strong: "Very excited and animated, energetic and anticipatory, with lively emphasis, controlled pacing, and clear pronunciation.",
            ]
        ),
    ]
}
