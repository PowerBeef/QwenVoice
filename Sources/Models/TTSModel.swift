import Foundation

/// Represents a TTS model that can be downloaded and used for generation.
struct TTSModel: Identifiable, Hashable, Sendable, Codable {
    let id: String          // e.g. "pro_custom"
    let name: String        // e.g. "Custom Voice"
    let tier: String        // e.g. "pro"
    let folder: String      // e.g. "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
    let mode: GenerationMode
    let huggingFaceRepo: String
    let outputSubfolder: String
    let requiredRelativePaths: [String]
}

enum GenerationMode: String, CaseIterable, Codable, Hashable, Sendable {
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
        case .design: return "text.bubble"
        case .clone: return "waveform.badge.plus"
        }
    }
}

// MARK: - Model Registry

extension TTSModel {
    static var all: [TTSModel] { TTSContract.models }

    /// Find the model for a given generation mode
    static func model(for mode: GenerationMode) -> TTSModel? {
        TTSContract.model(for: mode)
    }

    static func model(id: String) -> TTSModel? {
        TTSContract.model(id: id)
    }

    func installDirectory(in modelsDirectory: URL) -> URL {
        modelsDirectory.appendingPathComponent(folder, isDirectory: true)
    }

    func isAvailable(in modelsDirectory: URL, fileManager: FileManager = .default) -> Bool {
        let installDirectory = installDirectory(in: modelsDirectory)
        return requiredRelativePaths.allSatisfy { relativePath in
            let fileURL = installDirectory.appendingPathComponent(relativePath)
            return fileManager.fileExists(atPath: fileURL.path)
        }
    }

    static var speakerGroups: [String: [String]] { TTSContract.groupedSpeakers }

    static var defaultSpeaker: String { TTSContract.defaultSpeaker }

    static var speakers: [String] { TTSContract.allSpeakers }

    static var allSpeakers: [String] { TTSContract.allSpeakers }
}
