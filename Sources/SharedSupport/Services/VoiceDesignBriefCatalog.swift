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

    /// Research-aligned (official Qwen3-TTS VoiceDesign): each combines
    /// several of age, gender, tone, timbre, accent, pace, and use-case — the
    /// attributes the model's own example descriptions lean on — kept to one
    /// dense sentence.
    static let startingPoints = [
        "A warm, deep male narrator with a subtle British accent.",
        "A bright young woman, energetic and conversational.",
        "A gravelly older man, slow and intimate, late-night radio.",
        "A soft, breathy young woman, gentle and reassuring.",
    ]

    static let placeholder = "A warm, deep narrator with a subtle British accent."
}
