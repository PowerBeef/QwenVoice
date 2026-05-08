import Foundation

enum TTSModelVariantKind: String, CaseIterable, Codable, Hashable, Sendable {
    case speed
    case quality

    var displayName: String {
        switch self {
        case .speed: return "Speed"
        case .quality: return "Quality"
        }
    }

    var bitDepthLabel: String {
        switch self {
        case .speed: return "4-bit"
        case .quality: return "8-bit"
        }
    }

    var variantLabel: String {
        "\(displayName) variant"
    }
}

/// Represents a TTS model that can be downloaded and used for generation.
struct TTSModel: Identifiable, Hashable, Sendable, Codable {
    let id: String          // e.g. "pro_custom"
    let name: String        // e.g. "Custom Voice"
    let tier: String        // e.g. "pro"
    let folder: String      // e.g. "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
    let mode: GenerationMode
    let huggingFaceRepo: String
    let huggingFaceRevision: String?
    let outputSubfolder: String
    let requiredRelativePaths: [String]
    let baseModelID: String
    let variantID: String?
    let variantKind: TTSModelVariantKind?
    let estimatedDownloadBytes: Int64?
    let isHardwareRecommended: Bool

    init(
        id: String,
        name: String,
        tier: String,
        folder: String,
        mode: GenerationMode,
        huggingFaceRepo: String,
        huggingFaceRevision: String? = nil,
        outputSubfolder: String,
        requiredRelativePaths: [String],
        baseModelID: String? = nil,
        variantID: String? = nil,
        variantKind: TTSModelVariantKind? = nil,
        estimatedDownloadBytes: Int64? = nil,
        isHardwareRecommended: Bool = false
    ) {
        self.id = id
        self.name = name
        self.tier = tier
        self.folder = folder
        self.mode = mode
        self.huggingFaceRepo = huggingFaceRepo
        self.huggingFaceRevision = huggingFaceRevision
        self.outputSubfolder = outputSubfolder
        self.requiredRelativePaths = requiredRelativePaths
        self.baseModelID = baseModelID ?? id
        self.variantID = variantID
        self.variantKind = variantKind
        self.estimatedDownloadBytes = estimatedDownloadBytes
        self.isHardwareRecommended = isHardwareRecommended
    }
}

enum MacModelVariantPreferences {
    private static let keyPrefix = "QwenVoice.MacModelVariantPreference."

    static func key(for mode: GenerationMode) -> String {
        keyPrefix + mode.rawValue
    }

    static func selectedVariantID(
        for mode: GenerationMode,
        defaultVariantID: String?,
        defaults: UserDefaults = .standard
    ) -> String? {
        let stored = defaults.string(forKey: key(for: mode))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else {
            return defaultVariantID
        }
        return stored
    }

    static func setSelectedVariantID(
        _ variantID: String,
        for mode: GenerationMode,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(variantID, forKey: key(for: mode))
    }

    static func clearSelectedVariantID(
        for mode: GenerationMode,
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: key(for: mode))
    }
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
