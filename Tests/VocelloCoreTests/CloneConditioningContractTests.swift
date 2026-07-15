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
