import Foundation
import QwenVoiceCore

typealias TTSModel = ModelDescriptor
typealias Voice = PreparedVoice
typealias ActivityStatus = EngineActivity
typealias SidebarStatus = EngineLoadState
typealias GenerationResult = QwenVoiceCore.GenerationResult

extension ModelDescriptor {
    static var all: [ModelDescriptor] { TTSContract.models }

    static func model(for mode: GenerationMode) -> ModelDescriptor? {
        TTSContract.model(for: mode)
    }

    static func model(id: String) -> ModelDescriptor? {
        TTSContract.model(id: id)
    }

    static var speakerGroups: [String: [String]] { TTSContract.groupedSpeakers }

    static var defaultSpeaker: String { TTSContract.defaultSpeaker }

    static var speakers: [String] { TTSContract.allSpeakers }

    static var allSpeakers: [String] { TTSContract.allSpeakers }
}
