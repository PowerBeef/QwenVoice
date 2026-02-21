import Foundation

/// Represents a TTS model that can be downloaded and used for generation.
struct TTSModel: Identifiable, Hashable {
    let id: String          // e.g. "pro_custom"
    let name: String        // e.g. "Custom Voice"
    let folder: String      // e.g. "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
    let mode: GenerationMode
    let tier: ModelTier
    let huggingFaceRepo: String

    var displayName: String {
        "\(name) (\(tier.displayName))"
    }
}

enum ModelTier: String, CaseIterable, Codable, Hashable {
    case pro
    case lite

    var displayName: String {
        switch self {
        case .pro: return "Pro 1.7B"
        case .lite: return "Lite 0.6B"
        }
    }

    var shortName: String {
        switch self {
        case .pro: return "Pro"
        case .lite: return "Lite"
        }
    }
}

enum GenerationMode: String, CaseIterable, Codable, Hashable {
    case custom
    case design
    case clone

    var displayName: String {
        switch self {
        case .custom: return "Custom Voice"
        case .design: return "Voice Design"
        case .clone: return "Voice Cloning"
        }
    }

    var iconName: String {
        switch self {
        case .custom: return "person.wave.2"
        case .design: return "paintbrush"
        case .clone: return "doc.on.doc"
        }
    }
}

// MARK: - Model Registry

extension TTSModel {
    /// All available models (mirrors server.py MODELS dict)
    static let all: [TTSModel] = [
        // Pro (1.7B)
        TTSModel(
            id: "pro_custom",
            name: "Custom Voice",
            folder: "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
            mode: .custom,
            tier: .pro,
            huggingFaceRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
        ),
        TTSModel(
            id: "pro_design",
            name: "Voice Design",
            folder: "Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit",
            mode: .design,
            tier: .pro,
            huggingFaceRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit"
        ),
        TTSModel(
            id: "pro_clone",
            name: "Voice Cloning",
            folder: "Qwen3-TTS-12Hz-1.7B-Base-8bit",
            mode: .clone,
            tier: .pro,
            huggingFaceRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"
        ),
        // Lite (0.6B)
        TTSModel(
            id: "lite_custom",
            name: "Custom Voice",
            folder: "Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
            mode: .custom,
            tier: .lite,
            huggingFaceRepo: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
        ),
        // Note: Lite VoiceDesign 8-bit does not exist on HuggingFace
        TTSModel(
            id: "lite_clone",
            name: "Voice Cloning",
            folder: "Qwen3-TTS-12Hz-0.6B-Base-8bit",
            mode: .clone,
            tier: .lite,
            huggingFaceRepo: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"
        ),
    ]

    /// Find a model matching a given mode and tier
    static func model(for mode: GenerationMode, tier: ModelTier) -> TTSModel? {
        all.first { $0.mode == mode && $0.tier == tier }
    }

    /// Deterministic display order for languages (Swift dictionaries are unordered)
    static let languageOrder = ["English", "Chinese", "Japanese", "Korean"]

    /// All speakers grouped by language
    static let speakerMap: [String: [String]] = [
        "English": ["ryan", "aiden", "serena", "vivian"],
        "Chinese": ["vivian", "serena", "uncle_fu", "dylan", "eric"],
        "Japanese": ["ono_anna"],
        "Korean": ["sohee"],
    ]

    /// Flat list of all unique speakers
    static var allSpeakers: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for names in speakerMap.values {
            for name in names {
                if seen.insert(name).inserted {
                    result.append(name)
                }
            }
        }
        return result.sorted()
    }
}
