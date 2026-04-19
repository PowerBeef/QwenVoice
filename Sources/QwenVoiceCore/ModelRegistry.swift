import Foundation

public protocol ModelRegistry: Sendable {
    var models: [ModelDescriptor] { get }
    var defaultSpeaker: SpeakerDescriptor { get }
    var groupedSpeakers: [String: [SpeakerDescriptor]] { get }
    var allSpeakers: [SpeakerDescriptor] { get }

    func model(for mode: GenerationMode) -> ModelDescriptor?
    func model(id: String) -> ModelDescriptor?
}
