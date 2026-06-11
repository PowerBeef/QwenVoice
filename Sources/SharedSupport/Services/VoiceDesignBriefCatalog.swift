import Foundation

/// Single source of truth for the Voice Design brief product copy + limits,
/// shared by the iOS brief sheet (`IOSVoiceDesignBriefSheet`) and the macOS
/// inline editor (`VoiceBriefEditor`).
enum VoiceDesignBriefCatalog {
    /// Voice Design BRIEF (the voice DESCRIPTION) limit — deliberately
    /// decoupled from the spoken-script limit. Research on the official
    /// Qwen3-TTS VoiceDesign docs found no model-imposed description cap for
    /// the open-weights model; the hosted API caps voice_prompt at 2048 chars,
    /// and official example descriptions are short (one dense sentence,
    /// ~21–160 chars). 500 fits 2–3 dense sentences with headroom while
    /// discouraging paragraph-length rambling the examples suggest is
    /// unnecessary.
    static let descriptionLimit = 500

    /// Research-aligned (official Qwen3-TTS VoiceDesign guidance): each brief
    /// combines several dimensions from the official voice-design table —
    /// gender, age, pitch, pace, emotion, timbre, and purpose/use-case — in one
    /// dense sentence, the shape the model's own example descriptions use.
    /// The last four mirror official example archetypes (documentary narrator,
    /// fast upbeat commercial voice, animation child voice, and the
    /// persona-plus-delivery-mechanics teenager from the design-then-clone
    /// example). Accent wording is a flavor hint, not a guarantee — instruct
    ///-driven accent/dialect control is unreliable on the open checkpoints.
    static let startingPoints = [
        "A warm, deep male narrator with a subtle British accent.",
        "A bright young woman, energetic and conversational.",
        "A gravelly older man, slow and intimate, late-night radio.",
        "A soft, breathy young woman, gentle and reassuring.",
        "A calm middle-aged male voice with slow pace and a deep, magnetic tone, ideal for documentary narration.",
        "A lively young female voice with fast pace and upward intonation, suited to upbeat product videos.",
        "A cute child's voice, around eight years old, slightly mischievous, suited to animated characters.",
        "A teenage male voice, tenor range, gaining confidence, though the vowels still tighten when he is nervous.",
    ]

    static let placeholder = "A warm, deep narrator with a subtle British accent."
}
