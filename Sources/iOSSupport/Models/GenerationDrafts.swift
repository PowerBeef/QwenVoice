import Foundation

private let appDisplayName = "Vocello"

enum DeliveryInputMode: String, Equatable {
    case preset
    case custom
}

struct DeliveryInputState: Equatable {
    private static let neutralPresetID = "neutral"

    var mode: DeliveryInputMode = .preset
    var selectedPresetID = DeliveryInputState.neutralPresetID
    var customText = ""

    init(
        mode: DeliveryInputMode = .preset,
        selectedPresetID: String = DeliveryInputState.neutralPresetID,
        customText: String = ""
    ) {
        self.mode = mode
        self.selectedPresetID = selectedPresetID
        self.customText = customText
    }

    init(legacyEmotion: String) {
        let trimmedEmotion = legacyEmotion.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedEmotion.isEmpty || trimmedEmotion.caseInsensitiveCompare("Normal tone") == .orderedSame {
            self.init()
            return
        }

        if let preset = EmotionPreset.all.first(where: {
            $0.instruction(for: .normal).caseInsensitiveCompare(trimmedEmotion) == .orderedSame
        }) {
            self.init(mode: .preset, selectedPresetID: preset.id)
            return
        }

        self.init(mode: .custom, customText: trimmedEmotion)
    }

    var resolvedDeliveryProfile: DeliveryProfile {
        switch mode {
        case .preset:
            guard let preset = EmotionPreset.preset(id: selectedPresetID) else {
                return .neutral
            }
            return DeliveryProfile.preset(preset, intensity: .normal)
        case .custom:
            guard let trimmedCustomText = customText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                return .neutral
            }
            return DeliveryProfile.custom(trimmedCustomText)
        }
    }

    var resolvedDeliveryInstruction: String {
        resolvedDeliveryProfile.finalInstruction
    }

    var selectedPresetLabel: String {
        guard let preset = EmotionPreset.preset(id: selectedPresetID) else {
            return "Normal tone"
        }
        return preset.id == DeliveryInputState.neutralPresetID ? "Normal tone" : preset.label
    }
}

struct CustomVoiceDraft: Equatable {
    var selectedSpeaker = TTSModel.defaultSpeaker
    var delivery = DeliveryInputState()
    var text = ""

    var resolvedDeliveryProfile: DeliveryProfile {
        delivery.resolvedDeliveryProfile
    }

    var resolvedDeliveryInstruction: String {
        delivery.resolvedDeliveryInstruction
    }

    var emotion: String {
        get { resolvedDeliveryInstruction }
        set { delivery = DeliveryInputState(legacyEmotion: newValue) }
    }
}

struct VoiceDesignDraft: Equatable {
    var voiceDescription = ""
    var delivery = DeliveryInputState()
    var text = ""

    var resolvedDeliveryProfile: DeliveryProfile {
        delivery.resolvedDeliveryProfile
    }

    var resolvedDeliveryInstruction: String {
        delivery.resolvedDeliveryInstruction
    }

    var emotion: String {
        get { resolvedDeliveryInstruction }
        set { delivery = DeliveryInputState(legacyEmotion: newValue) }
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
        pythonReady: Bool,
        isModelAvailable: Bool,
        modelDisplayName: String,
        referenceAudioPath: String?,
        text: String,
        contextStatus: VoiceCloningContextStatus?
    ) -> VoiceCloningReadinessDescriptor {
        if !pythonReady {
            return VoiceCloningReadinessDescriptor(
                noteIsReady: false,
                title: "Engine starting",
                detail: "\(appDisplayName) is still preparing the native generation engine.",
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
                detail: "\(appDisplayName) is loading the saved transcript and voice context for cloning.",
                trailingText: nil
            )
        }

        if case .preparing = contextStatus {
            return VoiceCloningReadinessDescriptor(
                noteIsReady: false,
                title: "Preparing voice context",
                detail: "\(appDisplayName) is priming this reference so the first live preview starts quickly.",
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
