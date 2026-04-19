import Foundation

struct CustomVoiceDraft: Equatable {
    var selectedSpeaker = TTSModel.defaultSpeaker
    var emotion = "Normal tone"
    var text = ""

    var shouldIdlePrewarm: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var idlePrewarmDebounceKey: String? {
        guard shouldIdlePrewarm else { return nil }
        return [
            selectedSpeaker,
            emotion,
            text,
        ].joined(separator: "|")
    }
}

struct VoiceDesignDraft: Equatable {
    var voiceDescription = ""
    var emotion = "Normal tone"
    var text = ""

    var shouldIdlePrewarm: Bool {
        !voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var idlePrewarmDebounceKey: String? {
        guard shouldIdlePrewarm else { return nil }
        return [
            voiceDescription,
            emotion,
            text,
        ].joined(separator: "|")
    }
}

struct VoiceCloningDraft: Equatable {
    var selectedSavedVoiceID: String?
    var referenceAudioPath: String?
    var referenceTranscript = ""
    var text = ""

    mutating func applySavedVoice(_ voice: Voice, transcript: String) {
        selectedSavedVoiceID = voice.id
        referenceAudioPath = voice.wavPath
        referenceTranscript = transcript
    }

    mutating func applySavedVoiceSelection(
        id: String,
        wavPath: String,
        transcript: String
    ) {
        selectedSavedVoiceID = id
        referenceAudioPath = wavPath
        referenceTranscript = transcript
    }

    func referencesSavedVoice(_ voice: Voice) -> Bool {
        selectedSavedVoiceID == voice.id && referenceAudioPath == voice.wavPath
    }

    mutating func clearReference() {
        selectedSavedVoiceID = nil
        referenceAudioPath = nil
        referenceTranscript = ""
    }
}

struct PendingVoiceCloningHandoff: Equatable {
    let savedVoiceID: String
    let wavPath: String
    let transcript: String
    let transcriptLoadError: String?
}

enum SavedVoiceCloneHydrationAction: Equatable {
    case none
    case acceptCurrentDraft
    case applyFromDisk
    case clearStaleSelection
}

enum SavedVoiceCloneHydration {
    static func loadTranscript(for voice: Voice, fileManager: FileManager = .default) throws -> String {
        try voice.loadTranscript(fileManager: fileManager) ?? ""
    }

    static func action(
        draft: VoiceCloningDraft,
        voice: Voice?,
        hydratedVoiceID: String?,
        transcriptLoadError: String?
    ) -> SavedVoiceCloneHydrationAction {
        guard draft.selectedSavedVoiceID != nil else { return .none }
        guard let voice else { return .clearStaleSelection }

        guard draft.referencesSavedVoice(voice) else {
            return .applyFromDisk
        }

        if hydratedVoiceID == voice.id {
            return .none
        }

        if !draft.referenceTranscript.isEmpty || !voice.hasTranscript || transcriptLoadError != nil {
            return .acceptCurrentDraft
        }

        return .applyFromDisk
    }
}

enum VoiceCloningContextStatus: Equatable {
    case waitingForHydration
    case preparing
    case primed
    case fallback(String)
}

struct VoiceCloningReadinessDescriptor: Equatable {
    let noteIsReady: Bool
    let title: String
    let detail: String
    let trailingText: String?
}

enum VoiceCloningReadiness {
    static func describe(
        engineReady: Bool,
        isModelAvailable: Bool,
        modelDisplayName: String,
        referenceAudioPath: String?,
        text: String,
        contextStatus: VoiceCloningContextStatus?
    ) -> VoiceCloningReadinessDescriptor {
        if !engineReady {
            return VoiceCloningReadinessDescriptor(
                noteIsReady: false,
                title: "Engine starting",
                detail: "Vocello is still starting the native generation engine.",
                trailingText: nil
            )
        }

        if !isModelAvailable {
            return VoiceCloningReadinessDescriptor(
                noteIsReady: false,
                title: "Install the active model",
                detail: "Install \(modelDisplayName) in Models to enable generation.",
                trailingText: nil
            )
        }

        guard referenceAudioPath != nil else {
            return VoiceCloningReadinessDescriptor(
                noteIsReady: false,
                title: "Add a reference",
                detail: "Saved voices or imported clips both work here. Choose one before writing the final line.",
                trailingText: nil
            )
        }

        if case .waitingForHydration = contextStatus {
            return VoiceCloningReadinessDescriptor(
                noteIsReady: false,
                title: "Preparing saved voice",
                detail: "Vocello is loading the saved transcript and voice context for cloning.",
                trailingText: nil
            )
        }

        if case .preparing = contextStatus {
            return VoiceCloningReadinessDescriptor(
                noteIsReady: false,
                title: "Preparing voice context",
                detail: "Vocello is priming this reference so the first live preview starts quickly.",
                trailingText: nil
            )
        }

        if text.isEmpty {
            return VoiceCloningReadinessDescriptor(
                noteIsReady: false,
                title: "Add a script",
                detail: "Your reference voice context is ready. Add the line you want the cloned voice to perform.",
                trailingText: nil
            )
        }

        if case .fallback(let message) = contextStatus {
            return VoiceCloningReadinessDescriptor(
                noteIsReady: false,
                title: "Generate is available",
                detail: message,
                trailingText: nil
            )
        }

        return VoiceCloningReadinessDescriptor(
            noteIsReady: true,
            title: "Ready to generate",
            detail: "Everything is in place for a live preview and a saved clone.",
            trailingText: "Ready"
        )
    }
}
