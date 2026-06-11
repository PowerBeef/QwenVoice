import Foundation

// Single source of truth for the delivery (tone/emotion) presets, shared by the
// macOS app, the iOS app, and the `vocello` CLI (bench/review delivery cells).
// Previously duplicated as Sources/Models/EmotionPreset.swift and
// Sources/iOSSupport/Models/EmotionPreset.swift, which had to be edited in
// lockstep; consolidated here so preset copy changes land once.

public enum EmotionIntensity: Int, CaseIterable, Identifiable, Sendable {
    case subtle = 0
    case normal = 1
    case strong = 2

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .subtle: "Subtle"
        case .normal: "Normal"
        case .strong: "Strong"
        }
    }

    public var rpcValue: String {
        switch self {
        case .subtle: "subtle"
        case .normal: "normal"
        case .strong: "strong"
        }
    }
}

public struct DeliveryProfile: Equatable, Sendable {
    public static let neutralInstruction = "Neutral"

    public let presetID: String?
    public let intensity: EmotionIntensity?
    public let customText: String?
    public let finalInstruction: String

    public init(
        presetID: String?,
        intensity: EmotionIntensity?,
        customText: String?,
        finalInstruction: String
    ) {
        self.presetID = presetID
        self.intensity = intensity
        self.customText = customText
        self.finalInstruction = finalInstruction
    }

    public static let neutral = DeliveryProfile(
        presetID: "neutral",
        intensity: nil,
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

    public static func preset(_ preset: EmotionPreset, intensity: EmotionIntensity) -> DeliveryProfile {
        DeliveryProfile(
            presetID: preset.id,
            intensity: preset.id == "neutral" ? nil : intensity,
            customText: nil,
            finalInstruction: preset.instruction(for: intensity)
        )
    }

    public static func custom(_ text: String) -> DeliveryProfile {
        DeliveryProfile(
            presetID: nil,
            intensity: .normal,
            customText: text,
            finalInstruction: text
        )
    }
}

public struct EmotionPreset: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let sfSymbol: String
    public let instructions: [EmotionIntensity: String]

    public init(
        id: String,
        label: String,
        sfSymbol: String,
        instructions: [EmotionIntensity: String]
    ) {
        self.id = id
        self.label = label
        self.sfSymbol = sfSymbol
        self.instructions = instructions
    }

    public func instruction(for intensity: EmotionIntensity) -> String {
        instructions[intensity] ?? instructions[.normal] ?? DeliveryProfile.neutralInstruction
    }

    public static func preset(id: String?) -> EmotionPreset? {
        guard let id else { return nil }
        return all.first(where: { $0.id == id })
    }

    // Instruction-writing canon (Qwen3-TTS official guidance + measured adherence,
    // researched 2026-06-11): be specific and multidimensional (combine emotion +
    // pace + pitch + timbre), objective, concise — concrete acoustic wording is
    // followed far more reliably than persona-only briefs, and stacked
    // intensifiers do nothing. Negative constraints are officially endorsed and
    // work ("very happy but without laughing"); high-arousal instructions can
    // otherwise trigger literal laughter or added sounds. Intelligibility
    // clauses ("keeps every word audible") bound strong tiers the same way the
    // model's training descriptions do — keep them.
    public static let all: [EmotionPreset] = [
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
                .normal: "Speaks happily and upbeat, smiling through the words with bright energy and a slightly lifted pitch.",
                .strong: "Speaks joyfully and exuberantly, lighting up every word with bouncy, beaming enthusiasm, but without laughing or adding extra sounds.",
            ]
        ),
        EmotionPreset(
            id: "sad",
            label: "Sad",
            sfSymbol: "cloud.rain",
            instructions: [
                .subtle: "Speaks with quiet, reflective sadness, slower and a little subdued.",
                .normal: "Speaks sadly and somberly, with a heavy, restrained tone, lowered pitch, and small gentle pauses.",
                .strong: "Speaks through deep sorrow, fragile and tearful, words slow and weighted with grief, while keeping every word clear.",
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
            id: "surprised",
            label: "Surprised",
            sfSymbol: "exclamationmark.2",
            instructions: [
                .subtle: "Speaks with mild surprise, a light lift in pitch and a slightly quickened pace, as if just noticing something unexpected.",
                .normal: "Speaks with unmistakable surprise, pitch jumping higher, pace quick and animated, stressing the unexpected words as if astonished by the news.",
                .strong: "Speaks in open astonishment, high rising pitch, fast eager bursts and strong emphasis, utterly amazed by every detail, without gasping or adding extra sounds.",
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
                .normal: "Speaks calmly and soothingly, smooth unhurried pacing, low settled pitch, with reassuring warmth.",
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
                .strong: "Speaks with bursting, lively excitement, animated and bright, barely containing the eager energy, but without laughing or shouting.",
            ]
        ),
        EmotionPreset(
            id: "narrator",
            label: "Narrator",
            sfSymbol: "text.book.closed",
            instructions: [
                .subtle: "Speaks like a relaxed storyteller, even pacing and a warm, settled tone.",
                .normal: "Narrates like a composed documentary voice, low warm timbre, deliberate pacing, crisp diction, gentle emphasis on key phrases.",
                .strong: "Narrates with rich documentary gravitas, deep settled timbre, slow deliberate pacing, strong measured emphasis and well-placed pauses.",
            ]
        ),
        EmotionPreset(
            id: "news",
            label: "News",
            sfSymbol: "newspaper",
            instructions: [
                .subtle: "Speaks in a light news-desk style, tidy even pacing and a neutral, professional tone.",
                .normal: "Speaks in a clear news broadcast style, steady professional delivery, even pacing, precise articulation, no dramatics.",
                .strong: "Speaks like a prime-time news anchor, brisk authoritative delivery, firm even stress, crisp precise articulation throughout.",
            ]
        ),
    ]
}
