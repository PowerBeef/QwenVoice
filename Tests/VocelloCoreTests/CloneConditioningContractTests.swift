import Foundation
@testable import QwenVoiceCore
import XCTest

final class CloneConditioningContractTests: XCTestCase {
    func testMissingEmptyAndWhitespaceTranscriptsUseXVectorOnly() {
        for transcript in [nil, "", "  \n\t"] as [String?] {
            let reference = CloneReference(
                audioPath: "reference.wav",
                transcript: transcript
            )
            XCTAssertEqual(reference.conditioningMode, .xVectorOnly)
            XCTAssertNil(reference.transcript)
        }
    }

    func testTranscriptBackedModeNormalizesText() {
        let reference = CloneReference(
            audioPath: "reference.wav",
            conditioningMode: .transcriptBacked("  Reference words. \n")
        )

        XCTAssertEqual(
            reference.conditioningMode,
            .transcriptBacked("Reference words.")
        )
        XCTAssertEqual(reference.transcript, "Reference words.")
    }

    func testCloneReferenceCodablePreservesModernAndLegacyWireForms() throws {
        let modern = CloneReference(
            audioPath: "reference.wav",
            conditioningMode: .xVectorOnly,
            preparedVoiceID: "fixture-voice"
        )
        let modernData = try JSONEncoder().encode(modern)
        XCTAssertEqual(try JSONDecoder().decode(CloneReference.self, from: modernData), modern)

        let legacyData = try XCTUnwrap(
            """
            {
              "audioPath": "reference.wav",
              "transcript": "Legacy transcript.",
              "preparedVoiceID": "fixture-voice"
            }
            """.data(using: .utf8)
        )
        let legacy = try JSONDecoder().decode(CloneReference.self, from: legacyData)
        XCTAssertEqual(legacy.conditioningMode, .transcriptBacked("Legacy transcript."))
    }

    func testConflictingLegacyAndTypedConditioningFailsClosed() throws {
        let data = try XCTUnwrap(
            """
            {
              "audioPath": "reference.wav",
              "transcript": "Contradictory transcript.",
              "conditioningMode": { "kind": "x_vector_only" }
            }
            """.data(using: .utf8)
        )

        XCTAssertThrowsError(try JSONDecoder().decode(CloneReference.self, from: data))
    }

    func testCloneCacheIdentityIncludesConditioningMode() {
        let xVectorKey = GenerationSemantics.cloneReferenceIdentityKey(
            modelID: "pro_clone_speed",
            refAudio: "reference.wav",
            refText: nil
        )
        let transcriptKey = GenerationSemantics.cloneReferenceIdentityKey(
            modelID: "pro_clone_speed",
            refAudio: "reference.wav",
            refText: "Reference words."
        )

        XCTAssertNotEqual(xVectorKey, transcriptKey)
        XCTAssertTrue(xVectorKey.contains("|x_vector_only|"))
        XCTAssertTrue(transcriptKey.contains("|transcript_backed|"))
    }

    func testCloneIdentityCannotAliasWhenInputsContainLegacySeparators() {
        let left = GenerationSemantics.cloneReferenceIdentity(
            modelID: "pro_clone_speed",
            refAudio: "reference|part.wav",
            refText: "spoken words"
        )
        let right = GenerationSemantics.cloneReferenceIdentity(
            modelID: "pro_clone_speed",
            refAudio: "reference",
            refText: "part.wav|spoken words"
        )

        XCTAssertEqual(left.legacyKey, right.legacyKey)
        XCTAssertNotEqual(left, right)
        XCTAssertNotEqual(left.canonicalSerialization, right.canonicalSerialization)
        XCTAssertNotEqual(left.digest, right.digest)
        XCTAssertEqual(Set([left, right]).count, 2)
    }

    func testInternalCloneIdentityKeepsPathAndFingerprintSeparate() {
        let left = GenerationSemantics.internalCloneReferenceIdentity(
            modelID: "pro_clone_speed",
            normalizedReferencePath: "reference#part.wav",
            referenceFingerprint: "abc",
            conditioningMode: .xVectorOnly
        )
        let right = GenerationSemantics.internalCloneReferenceIdentity(
            modelID: "pro_clone_speed",
            normalizedReferencePath: "reference",
            referenceFingerprint: "part.wav#abc",
            conditioningMode: .xVectorOnly
        )

        XCTAssertEqual(left.legacyKey, right.legacyKey)
        XCTAssertNotEqual(left, right)
        XCTAssertNotEqual(left.canonicalSerialization, right.canonicalSerialization)
        XCTAssertNotEqual(left.cacheKey, right.cacheKey)
    }

    func testClonePromptIdentityInvalidatesForSpeakerFrontendAndRuntimeChanges() throws {
        let reference = GenerationSemantics.internalCloneReferenceIdentity(
            modelID: "pro_clone_speed",
            normalizedReferencePath: "reference.wav",
            referenceFingerprint: "audio-digest",
            conditioningMode: .xVectorOnly
        )
        let baseline = GenerationSemantics.ClonePromptIdentity(
            referenceIdentity: reference,
            language: "English",
            modelArtifactIdentity: try clonePromptModelArtifactIdentity(),
            qwenRuntimeProfileSignature: "runtime-a",
            speakerFeatureVersion: "qwen-speaker-mel-v1"
        )
        let changedFrontend = GenerationSemantics.ClonePromptIdentity(
            referenceIdentity: reference,
            language: "English",
            modelArtifactIdentity: try clonePromptModelArtifactIdentity(),
            qwenRuntimeProfileSignature: "runtime-a",
            speakerFeatureVersion: "qwen-speaker-mel-v2"
        )
        let changedRuntime = GenerationSemantics.ClonePromptIdentity(
            referenceIdentity: reference,
            language: "English",
            modelArtifactIdentity: try clonePromptModelArtifactIdentity(),
            qwenRuntimeProfileSignature: "runtime-b",
            speakerFeatureVersion: "qwen-speaker-mel-v1"
        )

        XCTAssertNotEqual(baseline.runtimeContractSignature, changedFrontend.runtimeContractSignature)
        XCTAssertNotEqual(baseline.runtimeContractSignature, changedRuntime.runtimeContractSignature)
        XCTAssertNotEqual(baseline.cacheKey, changedFrontend.cacheKey)
        XCTAssertNotEqual(baseline.cacheKey, changedRuntime.cacheKey)
    }

    func testClonePromptIdentityInvalidatesForEachModelArtifactField() throws {
        let reference = GenerationSemantics.internalCloneReferenceIdentity(
            modelID: "pro_clone_speed",
            normalizedReferencePath: "reference.wav",
            referenceFingerprint: "audio-digest",
            conditioningMode: .xVectorOnly
        )
        let baselineArtifact = try clonePromptModelArtifactIdentity()
        let changedArtifacts = [
            try clonePromptModelArtifactIdentity(repository: "other/model"),
            try clonePromptModelArtifactIdentity(revision: String(repeating: "b", count: 40)),
            try clonePromptModelArtifactIdentity(artifactVersion: "artifact-v2"),
            try clonePromptModelArtifactIdentity(integrityDigest: String(repeating: "b", count: 64)),
        ]
        let baseline = GenerationSemantics.ClonePromptIdentity(
            referenceIdentity: reference,
            language: "english",
            modelArtifactIdentity: baselineArtifact,
            qwenRuntimeProfileSignature: "runtime",
            speakerFeatureVersion: "qwen-speaker-mel-v1"
        )

        for changedArtifact in changedArtifacts {
            let changed = GenerationSemantics.ClonePromptIdentity(
                referenceIdentity: reference,
                language: "english",
                modelArtifactIdentity: changedArtifact,
                qwenRuntimeProfileSignature: "runtime",
                speakerFeatureVersion: "qwen-speaker-mel-v1"
            )
            XCTAssertNotEqual(baseline.runtimeContractSignature, changed.runtimeContractSignature)
            XCTAssertNotEqual(baseline.cacheKey, changed.cacheKey)
        }
    }

    func testClonePromptModelArtifactIdentityFailsClosedWithoutImmutableFields() {
        XCTAssertNil(GenerationSemantics.ClonePromptModelArtifactIdentity(
            repository: "mlx-community/model",
            revision: "main",
            artifactVersion: "artifact-v1",
            integrityManifestDigest: String(repeating: "a", count: 64)
        ))
        XCTAssertNil(GenerationSemantics.ClonePromptModelArtifactIdentity(
            repository: "mlx-community/model",
            revision: String(repeating: "a", count: 40),
            artifactVersion: "artifact-v1",
            integrityManifestDigest: nil
        ))
    }

    func testClonePromptIdentityNormalizesLanguageAndEmptyRuntimeSignature() throws {
        let reference = GenerationSemantics.internalCloneReferenceIdentity(
            modelID: "pro_clone_speed",
            normalizedReferencePath: "reference.wav",
            referenceFingerprint: "audio-digest",
            conditioningMode: .transcriptBacked("Reference words.")
        )
        let normalized = GenerationSemantics.ClonePromptIdentity(
            referenceIdentity: reference,
            language: " English ",
            modelArtifactIdentity: try clonePromptModelArtifactIdentity(),
            qwenRuntimeProfileSignature: " ",
            speakerFeatureVersion: " qwen-speaker-mel-v1 "
        )
        let canonical = GenerationSemantics.ClonePromptIdentity(
            referenceIdentity: reference,
            language: "english",
            modelArtifactIdentity: try clonePromptModelArtifactIdentity(),
            qwenRuntimeProfileSignature: nil,
            speakerFeatureVersion: "qwen-speaker-mel-v1"
        )

        XCTAssertEqual(normalized, canonical)
        XCTAssertEqual(normalized.cacheKey, canonical.cacheKey)
        XCTAssertTrue(normalized.runtimeContractSignature.hasPrefix("qv-clone-prompt-runtime-v2-"))
    }

    func testClonePromptIdentityIncludesLanguage() throws {
        let reference = GenerationSemantics.internalCloneReferenceIdentity(
            modelID: "pro_clone_speed",
            normalizedReferencePath: "reference.wav",
            referenceFingerprint: "audio-digest",
            conditioningMode: .xVectorOnly
        )
        let english = GenerationSemantics.ClonePromptIdentity(
            referenceIdentity: reference,
            language: "english",
            modelArtifactIdentity: try clonePromptModelArtifactIdentity(),
            qwenRuntimeProfileSignature: "runtime",
            speakerFeatureVersion: "qwen-speaker-mel-v1"
        )
        let french = GenerationSemantics.ClonePromptIdentity(
            referenceIdentity: reference,
            language: "french",
            modelArtifactIdentity: try clonePromptModelArtifactIdentity(),
            qwenRuntimeProfileSignature: "runtime",
            speakerFeatureVersion: "qwen-speaker-mel-v1"
        )

        XCTAssertNotEqual(english.cacheKey, french.cacheKey)
        XCTAssertEqual(english.runtimeContractSignature, french.runtimeContractSignature)
    }

    private func clonePromptModelArtifactIdentity(
        repository: String = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit",
        revision: String = String(repeating: "a", count: 40),
        artifactVersion: String = "artifact-v1",
        integrityDigest: String = String(repeating: "a", count: 64)
    ) throws -> GenerationSemantics.ClonePromptModelArtifactIdentity {
        try XCTUnwrap(GenerationSemantics.ClonePromptModelArtifactIdentity(
            repository: repository,
            revision: revision,
            artifactVersion: artifactVersion,
            integrityManifestDigest: integrityDigest
        ))
    }

    func testPrewarmIdentityCannotAliasAcrossDelimiterContainingFields() {
        let left = GenerationSemantics.PrewarmIdentity.customRequest(
            modelID: "model|custom",
            language: "english",
            speakerID: "speaker",
            instruction: "calm"
        )
        let right = GenerationSemantics.PrewarmIdentity.customRequest(
            modelID: "model",
            language: "custom|english",
            speakerID: "speaker",
            instruction: "calm"
        )

        XCTAssertEqual(left.legacyKey, right.legacyKey)
        XCTAssertNotEqual(left, right)
        XCTAssertNotEqual(left.canonicalSerialization, right.canonicalSerialization)
        XCTAssertNotEqual(left.cacheKey, right.cacheKey)
    }

    func testDesignConditioningIdentityCannotAliasAcrossNestedLegacyKey() {
        let left = GenerationSemantics.DesignConditioningIdentity(
            modelID: "pro_design_speed",
            language: "english|steady",
            instruction: "narrator",
            bucket: .short
        )
        let right = GenerationSemantics.DesignConditioningIdentity(
            modelID: "pro_design_speed",
            language: "english",
            instruction: "steady|narrator",
            bucket: .short
        )

        XCTAssertEqual(left.legacyKey, right.legacyKey)
        XCTAssertNotEqual(left, right)
        XCTAssertNotEqual(left.canonicalSerialization, right.canonicalSerialization)
        XCTAssertNotEqual(left.cacheKey, right.cacheKey)
    }

    func testGenerationSessionIdentityCannotAliasCustomDelimiterFields() {
        let left = GenerationSemantics.GenerationSessionIdentity.custom(
            modelID: "pro_custom_speed",
            language: "english",
            speakerID: "speaker|calm",
            deliveryStyle: "clear"
        )
        let right = GenerationSemantics.GenerationSessionIdentity.custom(
            modelID: "pro_custom_speed",
            language: "english",
            speakerID: "speaker",
            deliveryStyle: "calm|clear"
        )

        XCTAssertNotEqual(left, right)
        XCTAssertNotEqual(left.canonicalSerialization, right.canonicalSerialization)
        XCTAssertNotEqual(left.digest, right.digest)
        XCTAssertNotEqual(left.sessionKey, right.sessionKey)
        XCTAssertEqual(left.digest.count, 64)
    }

    func testGenerationSessionIdentityCannotAliasCloneDelimiterFields() {
        let left = GenerationSemantics.GenerationSessionIdentity.clone(
            modelID: "pro_clone_speed",
            language: "english",
            audioPath: "reference|words.wav",
            conditioningMode: .transcriptBacked("hello"),
            preparedVoiceID: "voice"
        )
        let right = GenerationSemantics.GenerationSessionIdentity.clone(
            modelID: "pro_clone_speed",
            language: "english",
            audioPath: "reference",
            conditioningMode: .transcriptBacked("words.wav|hello"),
            preparedVoiceID: "voice"
        )

        XCTAssertNotEqual(left, right)
        XCTAssertNotEqual(left.canonicalSerialization, right.canonicalSerialization)
        XCTAssertNotEqual(left.digest, right.digest)
        XCTAssertNotEqual(left.sessionKey, right.sessionKey)
    }

    func testGenerationSessionIdentityPreservesOptionalPresence() {
        let absent = GenerationSemantics.GenerationSessionIdentity.custom(
            modelID: "pro_custom_speed",
            language: "english",
            speakerID: "aiden",
            deliveryStyle: nil
        )
        let presentButEmpty = GenerationSemantics.GenerationSessionIdentity.custom(
            modelID: "pro_custom_speed",
            language: "english",
            speakerID: "aiden",
            deliveryStyle: ""
        )

        XCTAssertNotEqual(absent.canonicalSerialization, presentButEmpty.canonicalSerialization)
        XCTAssertNotEqual(absent.digest, presentButEmpty.digest)
        XCTAssertNotEqual(absent.sessionKey, presentButEmpty.sessionKey)
    }

    func testPromptCreationContractRoutesBothModesWithoutFallback() {
        let xVector = NativeClonePromptCreationContract(conditioningMode: .xVectorOnly)
        XCTAssertNil(xVector.refText)
        XCTAssertTrue(xVector.xVectorOnlyMode)

        let transcriptBacked = NativeClonePromptCreationContract(
            conditioningMode: .transcriptBacked("Reference words.")
        )
        XCTAssertEqual(transcriptBacked.refText, "Reference words.")
        XCTAssertFalse(transcriptBacked.xVectorOnlyMode)
    }

    func testContractExplicitlyDeclaresXVectorSupportOnlyForCloneModels() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let registry = try ContractBackedModelRegistry(
            manifestURL: root.appendingPathComponent("Sources/Resources/qwenvoice_contract.json")
        )

        for model in registry.models {
            let capabilities = try XCTUnwrap(model.qwen3Capabilities)
            XCTAssertEqual(
                capabilities.supportsXVectorOnlyClone,
                model.mode == .clone,
                "unexpected x-vector-only capability for \(model.id)"
            )
            for variant in model.variants {
                let variantCapabilities = try XCTUnwrap(variant.qwen3Capabilities)
                XCTAssertEqual(
                    variantCapabilities.supportsXVectorOnlyClone,
                    model.mode == .clone,
                    "unexpected x-vector-only capability for \(model.id)/\(variant.id)"
                )
            }
        }
    }
}
