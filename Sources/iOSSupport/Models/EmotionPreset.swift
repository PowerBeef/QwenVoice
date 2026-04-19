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
    let presetID: String?
    let intensity: EmotionIntensity?
    let customText: String?
    let finalInstruction: String

    static let neutral = DeliveryProfile(
        presetID: "neutral",
        intensity: nil,
        customText: nil,
        finalInstruction: "Normal tone"
    )

    var trimmedInstruction: String {
        finalInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedCustomText: String? {
        customText?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isNeutral: Bool {
        let instruction = trimmedInstruction
        return instruction.isEmpty || instruction.caseInsensitiveCompare("Normal tone") == .orderedSame
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
        instructions[intensity] ?? instructions[.normal] ?? "Normal tone"
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
                .subtle: "Normal tone",
                .normal: "Normal tone",
                .strong: "Normal tone",
            ]
        ),
        EmotionPreset(
            id: "happy",
            label: "Happy",
            sfSymbol: "face.smiling",
            instructions: [
                .subtle: "Slightly cheerful tone with a hint of warmth",
                .normal: "Happy and upbeat tone",
                .strong: "Very happy, enthusiastic, and joyful",
            ]
        ),
        EmotionPreset(
            id: "sad",
            label: "Sad",
            sfSymbol: "cloud.rain",
            instructions: [
                .subtle: "Slightly melancholic and subdued tone",
                .normal: "Sad and somber tone",
                .strong: "Deeply sad and tearful voice",
            ]
        ),
        EmotionPreset(
            id: "angry",
            label: "Angry",
            sfSymbol: "flame",
            instructions: [
                .subtle: "Slightly irritated and tense tone",
                .normal: "Angry and frustrated tone",
                .strong: "Furious and intensely angry, sharp and forceful delivery",
            ]
        ),
        EmotionPreset(
            id: "fearful",
            label: "Fearful",
            sfSymbol: "exclamationmark.triangle",
            instructions: [
                .subtle: "Slightly nervous and uneasy tone",
                .normal: "Fearful and anxious voice",
                .strong: "Terrified, panicked voice with trembling urgency",
            ]
        ),
        EmotionPreset(
            id: "whisper",
            label: "Whisper",
            sfSymbol: "ear",
            instructions: [
                .subtle: "Soft, quiet speaking voice",
                .normal: "Hushed, whispering voice",
                .strong: "Barely audible, intimate whisper",
            ]
        ),
        EmotionPreset(
            id: "dramatic",
            label: "Dramatic",
            sfSymbol: "theatermasks",
            instructions: [
                .subtle: "Slightly theatrical with mild emphasis",
                .normal: "Dramatic delivery with expressive intonation",
                .strong: "Highly dramatic, theatrical voice with bold pauses and sweeping intensity",
            ]
        ),
        EmotionPreset(
            id: "calm",
            label: "Calm",
            sfSymbol: "leaf",
            instructions: [
                .subtle: "Relaxed, easy-going tone",
                .normal: "Calm, soothing, and reassuring",
                .strong: "Deeply serene, meditative voice with slow, deliberate pace",
            ]
        ),
        EmotionPreset(
            id: "excited",
            label: "Excited",
            sfSymbol: "sparkles",
            instructions: [
                .subtle: "Slightly energetic with a touch of enthusiasm",
                .normal: "Excited and energetic, speaking with enthusiasm",
                .strong: "Extremely excited, fast-paced, brimming with energy and anticipation",
            ]
        ),
    ]
}
