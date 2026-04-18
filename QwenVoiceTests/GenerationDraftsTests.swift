import XCTest
@testable import QwenVoice

final class GenerationDraftsTests: XCTestCase {
    func testVoiceCloningDraftApplySavedVoiceKeepsScriptAndLoadsTranscript() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let wavURL = tempDirectory.appendingPathComponent("DesignedVoice.wav")
        let txtURL = tempDirectory.appendingPathComponent("DesignedVoice.txt")
        FileManager.default.createFile(atPath: wavURL.path, contents: Data(), attributes: nil)
        try "Reference transcript".write(to: txtURL, atomically: true, encoding: .utf8)

        let voice = Voice(name: "DesignedVoice", wavPath: wavURL.path, hasTranscript: true)
        let transcript = try SavedVoiceCloneHydration.loadTranscript(for: voice)
        var draft = VoiceCloningDraft(text: "Keep this clone script")

        draft.applySavedVoice(voice, transcript: transcript)

        XCTAssertEqual(draft.selectedSavedVoiceID, voice.id)
        XCTAssertEqual(draft.referenceAudioPath, voice.wavPath)
        XCTAssertEqual(draft.referenceTranscript, "Reference transcript")
        XCTAssertEqual(draft.text, "Keep this clone script")
    }

    func testVoiceCloningDraftApplySavedVoiceSelectionKeepsScript() {
        var draft = VoiceCloningDraft(text: "Keep this clone script")

        draft.applySavedVoiceSelection(
            id: "DesignedVoice",
            wavPath: "/tmp/DesignedVoice.wav",
            transcript: "Reference transcript"
        )

        XCTAssertEqual(draft.selectedSavedVoiceID, "DesignedVoice")
        XCTAssertEqual(draft.referenceAudioPath, "/tmp/DesignedVoice.wav")
        XCTAssertEqual(draft.referenceTranscript, "Reference transcript")
        XCTAssertEqual(draft.text, "Keep this clone script")
    }

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

    func testCustomVoiceDraftIdlePrewarmRequiresNonEmptyScript() {
        XCTAssertFalse(CustomVoiceDraft().shouldIdlePrewarm)
        XCTAssertTrue(
            CustomVoiceDraft(
                selectedSpeaker: TTSModel.defaultSpeaker,
                emotion: "Normal tone",
                text: "Hello there"
            ).shouldIdlePrewarm
        )
    }

    func testCustomVoiceDraftIdlePrewarmDebounceKeyTracksTypingState() {
        XCTAssertNil(CustomVoiceDraft().idlePrewarmDebounceKey)

        let shortDraft = CustomVoiceDraft(
            selectedSpeaker: "Vivian",
            emotion: "Normal tone",
            text: "H"
        )
        let longerDraft = CustomVoiceDraft(
            selectedSpeaker: "Vivian",
            emotion: "Normal tone",
            text: "Hello"
        )

        XCTAssertNotNil(shortDraft.idlePrewarmDebounceKey)
        XCTAssertNotEqual(shortDraft.idlePrewarmDebounceKey, longerDraft.idlePrewarmDebounceKey)
    }

    func testVoiceDesignDraftIdlePrewarmRequiresBriefAndScript() {
        XCTAssertFalse(
            VoiceDesignDraft(
                voiceDescription: "",
                emotion: "Normal tone",
                text: "Hello there"
            ).shouldIdlePrewarm
        )
        XCTAssertFalse(
            VoiceDesignDraft(
                voiceDescription: "Warm narrator",
                emotion: "Normal tone",
                text: ""
            ).shouldIdlePrewarm
        )
        XCTAssertTrue(
            VoiceDesignDraft(
                voiceDescription: "Warm narrator",
                emotion: "Normal tone",
                text: "Hello there"
            ).shouldIdlePrewarm
        )
    }

    func testVoiceDesignDraftIdlePrewarmDebounceKeyRequiresBriefAndScriptAndTracksTyping() {
        XCTAssertNil(VoiceDesignDraft().idlePrewarmDebounceKey)

        let baseDraft = VoiceDesignDraft(
            voiceDescription: "Warm narrator",
            emotion: "Normal tone",
            text: "H"
        )
        let editedDraft = VoiceDesignDraft(
            voiceDescription: "Warm narrator",
            emotion: "Normal tone",
            text: "Hello"
        )

        XCTAssertNotNil(baseDraft.idlePrewarmDebounceKey)
        XCTAssertNotEqual(baseDraft.idlePrewarmDebounceKey, editedDraft.idlePrewarmDebounceKey)
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

    func testSavedVoiceCloneHydrationAcceptsCurrentDraftWithoutOverwritingEditedTranscript() {
        let voice = Voice(name: "DesignedVoice", wavPath: "/tmp/designed.wav", hasTranscript: true)
        let draft = VoiceCloningDraft(
            selectedSavedVoiceID: voice.id,
            referenceAudioPath: voice.wavPath,
            referenceTranscript: "Edited by the user",
            text: "Keep this clone script"
        )

        let action = SavedVoiceCloneHydration.action(
            draft: draft,
            voice: voice,
            hydratedVoiceID: nil,
            transcriptLoadError: nil
        )

        XCTAssertEqual(action, .acceptCurrentDraft)
    }

    func testSavedVoiceCloneHydrationAcceptsAudioOnlySavedVoiceWithoutTranscript() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let wavURL = tempDirectory.appendingPathComponent("SavedVoice.wav")
        FileManager.default.createFile(atPath: wavURL.path, contents: Data(), attributes: nil)

        let voice = Voice(name: "SavedVoice", wavPath: wavURL.path, hasTranscript: false)
        XCTAssertEqual(try SavedVoiceCloneHydration.loadTranscript(for: voice), "")

        let draft = VoiceCloningDraft(
            selectedSavedVoiceID: voice.id,
            referenceAudioPath: voice.wavPath,
            referenceTranscript: "",
            text: "Keep this clone script"
        )

        let action = SavedVoiceCloneHydration.action(
            draft: draft,
            voice: voice,
            hydratedVoiceID: nil,
            transcriptLoadError: nil
        )

        XCTAssertEqual(action, .acceptCurrentDraft)
    }

    func testVoiceCloningReadinessShowsPreparingStateBeforeClonePrimingCompletes() {
        let descriptor = VoiceCloningReadiness.describe(
            engineReady: true,
            isModelAvailable: true,
            modelDisplayName: "Qwen3-TTS Pro Clone",
            referenceAudioPath: "/tmp/reference.wav",
            text: "Clone this line",
            contextStatus: .preparing
        )

        XCTAssertFalse(descriptor.noteIsReady)
        XCTAssertEqual(descriptor.title, "Preparing voice context")
        XCTAssertEqual(descriptor.trailingText, nil)
    }

    func testVoiceCloningReadinessBecomesReadyAfterClonePrimingCompletes() {
        let descriptor = VoiceCloningReadiness.describe(
            engineReady: true,
            isModelAvailable: true,
            modelDisplayName: "Qwen3-TTS Pro Clone",
            referenceAudioPath: "/tmp/reference.wav",
            text: "Clone this line",
            contextStatus: .primed
        )

        XCTAssertTrue(descriptor.noteIsReady)
        XCTAssertEqual(descriptor.title, "Ready to generate")
        XCTAssertEqual(descriptor.trailingText, "Ready")
    }
}
