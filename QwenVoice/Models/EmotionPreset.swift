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
}

struct EmotionPreset: Identifiable {
    let id: String
    let label: String
    let sfSymbol: String
    let instructions: [EmotionIntensity: String]

    func instruction(for intensity: EmotionIntensity) -> String {
        instructions[intensity] ?? instructions[.normal] ?? "Normal tone"
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
