import XCTest
@preconcurrency import MLX
@preconcurrency import MLXAudioTTS
@testable import QwenVoiceNative

final class NativeCloneSupportTests: XCTestCase {
    func testResolveCloneConditioningPrefersInlineTranscriptThenSidecarThenNone() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("reference.wav")
        try NativeRuntimeTestSupport.writeTestWAV(to: sourceURL, sampleRate: 24_000, channels: 1)
        let sidecarURL = sourceURL.deletingPathExtension().appendingPathExtension("txt")
        try "Sidecar transcript".write(to: sidecarURL, atomically: true, encoding: .utf8)

        let normalizedDirectory = root.appendingPathComponent("cache/normalized", isDirectory: true)
        let service = NativeAudioPreparationService()

        let inlineCache = NativePreparedCloneConditioningCache()
        let inline = try await inlineCache.resolve(
            modelID: "pro_clone",
            reference: CloneReference(
                audioPath: sourceURL.path,
                transcript: "Inline transcript",
                preparedVoiceID: nil
            ),
            sampleRate: 24_000,
            audioPreparationService: service,
            normalizedCloneReferenceDirectory: normalizedDirectory
        )
        XCTAssertEqual(inline.resolvedTranscript, "Inline transcript")
        XCTAssertEqual(inline.transcriptMode, .inline)

        let sidecarCache = NativePreparedCloneConditioningCache()
        let sidecar = try await sidecarCache.resolve(
            modelID: "pro_clone",
            reference: CloneReference(audioPath: sourceURL.path, transcript: nil, preparedVoiceID: nil),
            sampleRate: 24_000,
            audioPreparationService: service,
            normalizedCloneReferenceDirectory: normalizedDirectory
        )
        XCTAssertEqual(sidecar.resolvedTranscript, "Sidecar transcript")
        XCTAssertEqual(sidecar.transcriptMode, .sidecar)

        try FileManager.default.removeItem(at: sidecarURL)
        let noneCache = NativePreparedCloneConditioningCache()
        let none = try await noneCache.resolve(
            modelID: "pro_clone",
            reference: CloneReference(audioPath: sourceURL.path, transcript: nil, preparedVoiceID: nil),
            sampleRate: 24_000,
            audioPreparationService: service,
            normalizedCloneReferenceDirectory: normalizedDirectory
        )
        XCTAssertNil(none.resolvedTranscript)
        XCTAssertEqual(none.transcriptMode, .none)
    }

    func testResolveVoiceClonePromptPersistsAndReusesSavedVoiceArtifacts() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("reference.wav")
        try NativeRuntimeTestSupport.writeTestWAV(to: sourceURL, sampleRate: 24_000, channels: 1)
        let normalizedDirectory = root.appendingPathComponent("cache/normalized", isDirectory: true)
        let voicesDirectory = root.appendingPathComponent("voices", isDirectory: true)
        try FileManager.default.createDirectory(at: voicesDirectory, withIntermediateDirectories: true)

        let model = NativeSpeechGenerationModel(
            sampleRate: 24_000,
            clonePromptCreator: { _, refText, xVectorOnlyMode in
                Qwen3TTSVoiceClonePrompt(
                    refCodes: MLXArray([Int32(1), Int32(2), Int32(3)]),
                    speakerEmbedding: MLXArray([Float32(0.25), Float32(0.5)]),
                    refText: refText,
                    xVectorOnlyMode: xVectorOnlyMode,
                    iclMode: false
                )
            },
            clonePrewarmHandler: { _, _, _ in },
            cloneStreamHandler: { _, _, _, _ in
                AsyncThrowingStream { continuation in
                    continuation.finish()
                }
            }
        )

        let firstCache = NativePreparedCloneConditioningCache()
        let service = NativeAudioPreparationService()
        let firstConditioning = try await firstCache.resolve(
            modelID: "pro_clone",
            reference: CloneReference(
                audioPath: sourceURL.path,
                transcript: "Prompt transcript",
                preparedVoiceID: "SavedVoice"
            ),
            sampleRate: 24_000,
            audioPreparationService: service,
            normalizedCloneReferenceDirectory: normalizedDirectory
        )
        let resolvedFirst = try await firstCache.resolveVoiceClonePrompt(
            for: firstConditioning,
            modelID: "pro_clone",
            model: model,
            voicesDirectory: voicesDirectory
        )

        XCTAssertTrue(resolvedFirst.preparedCloneUsed)
        XCTAssertEqual(resolvedFirst.clonePromptCacheHit, false)
        XCTAssertNotNil(resolvedFirst.voiceClonePrompt)

        let secondCache = NativePreparedCloneConditioningCache()
        let secondConditioning = try await secondCache.resolve(
            modelID: "pro_clone",
            reference: CloneReference(
                audioPath: sourceURL.path,
                transcript: "Prompt transcript",
                preparedVoiceID: "SavedVoice"
            ),
            sampleRate: 24_000,
            audioPreparationService: service,
            normalizedCloneReferenceDirectory: normalizedDirectory
        )
        let resolvedSecond = try await secondCache.resolveVoiceClonePrompt(
            for: secondConditioning,
            modelID: "pro_clone",
            model: model,
            voicesDirectory: voicesDirectory
        )

        XCTAssertTrue(resolvedSecond.preparedCloneUsed)
        XCTAssertEqual(resolvedSecond.clonePromptCacheHit, true)
        let hasArtifact = await secondCache.hasPersistedVoiceClonePromptArtifact(
            modelID: "pro_clone",
            preparedVoiceID: "SavedVoice",
            voicesDirectory: voicesDirectory
        )
        XCTAssertTrue(hasArtifact)
    }
}
