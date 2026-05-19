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
                .subtle: "Speaks with a hint of warmth and a faint smile in the voice.",
                .normal: "Speaks happily and upbeat, smiling through the words with bright energy.",
                .strong: "Speaks joyfully and exuberantly, lighting up every word with bouncy, beaming enthusiasm.",
            ]
        ),
        EmotionPreset(
            id: "sad",
            label: "Sad",
            sfSymbol: "cloud.rain",
            instructions: [
                .subtle: "Speaks with quiet, reflective sadness, slower and a little subdued.",
                .normal: "Speaks sadly and somberly, with a heavy, restrained tone and small gentle pauses.",
                .strong: "Speaks through deep sorrow, fragile and tearful, words slow and weighted with grief.",
            ]
        ),
        EmotionPreset(
            id: "angry",
            label: "Angry",
            sfSymbol: "flame",
            instructions: [
                .subtle: "Speaks with quiet irritation, controlled and clipped, holding back the bigger feeling.",
                .normal: "Speaks angrily and frustrated, firm and pushed, with sharp consonants and tight stress.",
                .strong: "Speaks furiously, biting every word with forceful tension, never breaking into a scream.",
            ]
        ),
        EmotionPreset(
            id: "fearful",
            label: "Fearful",
            sfSymbol: "exclamationmark.triangle",
            instructions: [
                .subtle: "Speaks with quiet unease, cautious and hesitant, voice a little smaller than usual.",
                .normal: "Speaks fearfully and anxiously, breath caught, pacing uncertain, words pushed out shakily.",
                .strong: "Speaks in trembling panic, voice quavering and urgent, but still keeps every word audible.",
            ]
        ),
        EmotionPreset(
            id: "whisper",
            label: "Whisper",
            sfSymbol: "ear",
            instructions: [
                .subtle: "Whispers gently, close-mic and quiet, with soft breath and easy pacing.",
                .normal: "Whispers throughout, hushed and breathy, every word voiced just above breath, close and confidential.",
                .strong: "Whispers urgently and barely voiced, secretive close-mic breath, audible but never lifted into normal speech.",
            ]
        ),
        EmotionPreset(
            id: "dramatic",
            label: "Dramatic",
            sfSymbol: "theatermasks",
            instructions: [
                .subtle: "Speaks with measured theatrical weight, leaning into key beats without overdoing it.",
                .normal: "Speaks dramatically and expressively, lifting key phrases with heightened inflection and deliberate pacing.",
                .strong: "Speaks with sweeping theatrical grandeur, bold stress on key words, generous well-timed pauses that command attention.",
            ]
        ),
        EmotionPreset(
            id: "calm",
            label: "Calm",
            sfSymbol: "leaf",
            instructions: [
                .subtle: "Speaks easily and unhurriedly, relaxed and warm throughout.",
                .normal: "Speaks calmly and soothingly, smooth pacing with reassuring warmth and gentle confidence.",
                .strong: "Speaks with serene, meditative stillness, slow and softly grounded, each phrase fully landed.",
            ]
        ),
        EmotionPreset(
            id: "excited",
            label: "Excited",
            sfSymbol: "sparkles",
            instructions: [
                .subtle: "Speaks with a touch of enthusiasm, slightly energized and engaged.",
                .normal: "Speaks energetically and enthusiastically, bright and animated, picking up the pace just slightly.",
                .strong: "Speaks with bursting, lively excitement, animated and bright, can hardly contain the eager energy.",
            ]
        ),
    ]
}
