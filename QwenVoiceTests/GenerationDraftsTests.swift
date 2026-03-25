import XCTest
@testable import QwenVoice

final class GenerationDraftsTests: XCTestCase {
    func testCustomVoiceDraftDefaultsMatchGenerationInputs() {
        let draft = CustomVoiceDraft()

        XCTAssertEqual(draft.selectedSpeaker, TTSModel.defaultSpeaker)
        XCTAssertEqual(draft.emotion, "Normal tone")
        XCTAssertEqual(draft.text, "")
    }

    func testVoiceDesignDraftCarriesBriefEmotionAndText() {
        let draft = VoiceDesignDraft(
            voiceDescription: "Warm narrator",
            emotion: "Conversational",
            text: "Keep this script"
        )

        XCTAssertEqual(draft.voiceDescription, "Warm narrator")
        XCTAssertEqual(draft.emotion, "Conversational")
        XCTAssertEqual(draft.text, "Keep this script")
    }

    func testDesignResultNameSuggestionSanitizesAndTruncatesBrief() {
        let suggestedName = SavedVoiceNameSuggestion.designResultName(
            from: "Warm, deep narrator with a subtle British accent and soft radio finish."
        )

        XCTAssertEqual(suggestedName, "Warm_deep_narrator_with_a_subtle")
    }

    func testDesignResultNameSuggestionFallsBackWhenBriefIsEmpty() {
        XCTAssertEqual(
            SavedVoiceNameSuggestion.designResultName(from: "   "),
            SavedVoiceNameSuggestion.designedVoiceFallback
        )
    }

    func testVoiceDesignSavedVoiceCandidateTracksDraftMatchAndSavedState() {
        var candidate = VoiceDesignSavedVoiceCandidate(
            audioPath: "/tmp/design.wav",
            transcript: "Keep this script",
            suggestedName: "Warm_narrator",
            voiceDescription: "Warm narrator",
            emotion: "Conversational",
            text: "Keep this script"
        )

        XCTAssertTrue(candidate.matches(
            draft: VoiceDesignDraft(
                voiceDescription: "Warm narrator",
                emotion: "Conversational",
                text: "Keep this script"
            )
        ))
        XCTAssertFalse(candidate.isSaved)

        candidate.markSaved(as: "Warm_narrator")

        XCTAssertTrue(candidate.isSaved)
        XCTAssertFalse(candidate.matches(
            draft: VoiceDesignDraft(
                voiceDescription: "Warm narrator",
                emotion: "Dramatic",
                text: "Keep this script"
            )
        ))
    }

    func testVoiceCloningDraftClearReferenceKeepsScript() {
        var draft = VoiceCloningDraft(
            selectedSavedVoiceID: "voice-123",
            referenceAudioPath: "/tmp/reference.wav",
            referenceTranscript: "Reference transcript",
            text: "Keep this clone script"
        )

        draft.clearReference()

        XCTAssertNil(draft.selectedSavedVoiceID)
        XCTAssertNil(draft.referenceAudioPath)
        XCTAssertEqual(draft.referenceTranscript, "")
        XCTAssertEqual(draft.text, "Keep this clone script")
    }
}
