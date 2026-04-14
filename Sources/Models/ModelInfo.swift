import Foundation

struct ModelInfo: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let folder: String
    let mode: GenerationMode
    let tier: String
    let outputSubfolder: String
    let huggingFaceRepo: String
    let requiredRelativePaths: [String]
    let resolvedPath: String?
    let downloaded: Bool
    let complete: Bool
    let repairable: Bool
    let missingRequiredPaths: [String]
    let sizeBytes: Int
    let mlxAudioVersion: String?
    let supportsStreaming: Bool
    let supportsPreparedClone: Bool
    let supportsCloneStreaming: Bool
    let supportsBatch: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case folder
        case mode
        case tier
        case outputSubfolder = "output_subfolder"
        case huggingFaceRepo = "hugging_face_repo"
        case requiredRelativePaths = "required_relative_paths"
        case resolvedPath = "resolved_path"
        case downloaded
        case complete
        case repairable
        case missingRequiredPaths = "missing_required_paths"
        case sizeBytes = "size_bytes"
        case mlxAudioVersion = "mlx_audio_version"
        case supportsStreaming = "supports_streaming"
        case supportsPreparedClone = "supports_prepared_clone"
        case supportsCloneStreaming = "supports_clone_streaming"
        case supportsBatch = "supports_batch"
    }

    var isAvailable: Bool {
        complete
    }

    var requiresRepair: Bool {
        repairable && !complete
    }
}
