import Foundation
import QwenVoiceNative

struct BatchGenerationSheetConfiguration: Identifiable, Equatable {
    let id = UUID()
    let mode: GenerationMode
    let voice: String?
    let emotion: String?
    let voiceDescription: String?
    let refAudio: String?
    let refText: String?

    static func custom(draft: CustomVoiceDraft) -> BatchGenerationSheetConfiguration {
        BatchGenerationSheetConfiguration(
            mode: .custom,
            voice: draft.selectedSpeaker,
            emotion: draft.emotion,
            voiceDescription: nil,
            refAudio: nil,
            refText: nil
        )
    }

    static func design(draft: VoiceDesignDraft) -> BatchGenerationSheetConfiguration {
        BatchGenerationSheetConfiguration(
            mode: .design,
            voice: nil,
            emotion: draft.emotion,
            voiceDescription: draft.voiceDescription,
            refAudio: nil,
            refText: nil
        )
    }

    static func clone(draft: VoiceCloningDraft) -> BatchGenerationSheetConfiguration {
        BatchGenerationSheetConfiguration(
            mode: .clone,
            voice: nil,
            emotion: nil,
            voiceDescription: nil,
            refAudio: draft.referenceAudioPath,
            refText: draft.referenceTranscript.isEmpty ? nil : draft.referenceTranscript
        )
    }
}

enum CustomVoicePresentedSheet: Identifiable {
    case batch(BatchGenerationSheetConfiguration)

    var id: UUID {
        switch self {
        case .batch(let configuration):
            return configuration.id
        }
    }
}

enum VoiceDesignPresentedSheet: Identifiable {
    case batch(BatchGenerationSheetConfiguration)
    case saveVoice(SavedVoiceSheetConfiguration)

    var id: UUID {
        switch self {
        case .batch(let configuration):
            return configuration.id
        case .saveVoice(let configuration):
            return configuration.id
        }
    }
}

enum VoiceCloningPresentedSheet: Identifiable {
    case batch(BatchGenerationSheetConfiguration)

    var id: UUID {
        switch self {
        case .batch(let configuration):
            return configuration.id
        }
    }
}
