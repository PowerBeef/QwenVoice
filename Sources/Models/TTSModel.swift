import Foundation

/// Represents a TTS model that can be downloaded and used for generation.
struct TTSModel: Identifiable, Hashable {
    let id: String          // e.g. "pro_custom"
    let name: String        // e.g. "Custom Voice"
    let folder: String      // e.g. "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
    let mode: GenerationMode
    let huggingFaceRepo: String
    let estimatedSizeBytes: Int
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
        TTSModel(
            id: "pro_custom",
            name: "Custom Voice",
            folder: "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
            mode: .custom,
            huggingFaceRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
            estimatedSizeBytes: 900_000_000
        ),
        TTSModel(
            id: "pro_design",
            name: "Voice Design",
            folder: "Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit",
            mode: .design,
            huggingFaceRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit",
            estimatedSizeBytes: 900_000_000
        ),
        TTSModel(
            id: "pro_clone",
            name: "Voice Cloning",
            folder: "Qwen3-TTS-12Hz-1.7B-Base-8bit",
            mode: .clone,
            huggingFaceRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit",
            estimatedSizeBytes: 930_000_000
        ),
    ]

    /// Find the model for a given generation mode
    static func model(for mode: GenerationMode) -> TTSModel? {
        all.first { $0.mode == mode }
    }

    /// Available English speakers
    static let speakers = ["ryan", "aiden", "serena", "vivian"]

    /// All available speakers
    static var allSpeakers: [String] { speakers }
}
