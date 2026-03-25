struct CustomVoiceDraft: Equatable {
    var selectedSpeaker = TTSModel.defaultSpeaker
    var emotion = "Normal tone"
    var text = ""
}

struct VoiceDesignDraft: Equatable {
    var voiceDescription = ""
    var emotion = "Normal tone"
    var text = ""
}

struct VoiceCloningDraft: Equatable {
    var selectedSavedVoiceID: String?
    var referenceAudioPath: String?
    var referenceTranscript = ""
    var text = ""

    mutating func clearReference() {
        selectedSavedVoiceID = nil
        referenceAudioPath = nil
        referenceTranscript = ""
    }
}
