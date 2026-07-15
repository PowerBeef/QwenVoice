import Foundation
import VocelloQwen3Core

extension ModelAssetDescriptor {
    func vocelloQwen3PreparedBundle(
        directory: URL,
        modelType: String?,
        trustedPreparedCheckpoint: Bool
    ) -> VocelloQwen3PreparedModelBundle {
        var capabilities: [VocelloQwen3Capability] = [.streaming, .typedDiagnostics]
        switch model.mode {
        case .custom:
            capabilities.append(.customVoice)
        case .design:
            capabilities.append(.voiceDesign)
        case .clone:
            capabilities.append(.voiceClone)
        }
        if model.qwen3Capabilities?.supportsInstructionControl == true {
            capabilities.append(.instructionControl)
        }
        if model.qwen3Capabilities?.supportsXVectorOnlyClone == true {
            capabilities.append(.audioOnlyClone)
        }

        return VocelloQwen3PreparedModelBundle(
            identity: VocelloQwen3ModelIdentity(
                modelID: model.id,
                repositoryID: model.huggingFaceRepo,
                revision: model.huggingFaceRevision ?? "main",
                artifactVersion: version
            ),
            preparedDirectory: directory,
            modelType: modelType,
            trustedPreparedCheckpoint: trustedPreparedCheckpoint,
            capabilities: VocelloQwen3CapabilitySet(capabilities)
        )
    }
}
