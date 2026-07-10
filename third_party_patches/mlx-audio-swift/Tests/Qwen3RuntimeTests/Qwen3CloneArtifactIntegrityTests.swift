import Foundation
import MLX
@testable import MLXAudioTTS
import XCTest

final class Qwen3CloneArtifactIntegrityTests: XCTestCase {
    func testNonEmptyTensorRoundTripPreservesShapeDTypeAndValues() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let prompt = tensorPrompt(refText: "fixture")

        try prompt.write(to: directory)
        let loaded = try Qwen3TTSVoiceClonePrompt.load(from: directory)

        XCTAssertEqual(loaded.refCodes?.shape, [1, 2, 2])
        XCTAssertEqual(loaded.refCodes?.dtype, .int32)
        XCTAssertEqual(loaded.refCodes?.asArray(Int32.self), [1, 2, 3, 4])
        XCTAssertEqual(loaded.speakerEmbedding?.shape, [1, 3])
        XCTAssertEqual(loaded.speakerEmbedding?.dtype, .float32)
        XCTAssertEqual(loaded.speakerEmbedding?.asArray(Float.self), [0.25, -0.5, 0.75])
    }

    func testAtomicReplacementPublishesOnlyCompleteNewArtifact() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try tensorPrompt(refText: "old").writeAtomically(to: directory)
        try tensorPrompt(refText: "new").writeAtomically(to: directory)

        let loaded = try Qwen3TTSVoiceClonePrompt.load(from: directory)
        XCTAssertEqual(loaded.refText, "new")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), Set([
            "manifest.json", "ref_codes.safetensors", "speaker_embedding.safetensors", "integrity.json",
        ]))
    }

    func testInterruptedStagingPreservesPriorArtifactAndRemovesStaging() throws {
        enum FixtureError: Error { case interrupt }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try tensorPrompt(refText: "old").writeAtomically(to: directory)

        XCTAssertThrowsError(
            try tensorPrompt(refText: "new").writeAtomically(to: directory) {
                throw FixtureError.interrupt
            }
        )
        XCTAssertEqual(try Qwen3TTSVoiceClonePrompt.load(from: directory).refText, "old")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.deletingLastPathComponent().path)
        XCTAssertFalse(siblings.contains { $0.hasPrefix(".\(directory.lastPathComponent).staging.") })
    }

    func testDigestCorruptionFailsClosed() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try tensorPrompt(refText: "fixture").write(to: directory)
        try Data("tampered".utf8).write(to: directory.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try Qwen3TTSVoiceClonePrompt.load(from: directory))
    }

    func testMissingAndExtraFilesFailClosed() throws {
        let missing = temporaryDirectory()
        let extra = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: missing)
            try? FileManager.default.removeItem(at: extra)
        }
        try tensorPrompt(refText: "missing").write(to: missing)
        try FileManager.default.removeItem(at: missing.appendingPathComponent("ref_codes.safetensors"))
        XCTAssertThrowsError(try Qwen3TTSVoiceClonePrompt.load(from: missing))

        try tensorPrompt(refText: "extra").write(to: extra)
        try Data([0]).write(to: extra.appendingPathComponent("unexpected.bin"))
        XCTAssertThrowsError(try Qwen3TTSVoiceClonePrompt.load(from: extra))
    }

    func testShapeAndDTypeMetadataMismatchFailsClosed() throws {
        let directory = temporaryDirectory()
        let alternate = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: alternate)
        }
        try tensorPrompt(refText: "fixture").write(to: directory)
        let alternatePrompt = Qwen3TTSVoiceClonePrompt(
            refCodes: MLXArray([Float(1), 2, 3, 4]).reshaped(1, 4),
            speakerEmbedding: MLXArray([Float(1)]).reshaped(1, 1),
            refText: "alternate",
            xVectorOnlyMode: false,
            iclMode: true
        )
        try alternatePrompt.write(to: alternate)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("ref_codes.safetensors"))
        try FileManager.default.copyItem(
            at: alternate.appendingPathComponent("ref_codes.safetensors"),
            to: directory.appendingPathComponent("ref_codes.safetensors")
        )

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let original = try decoder.decode(
            Qwen3TTSVoiceClonePrompt.IntegrityManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("integrity.json"))
        )
        let replacement = try decoder.decode(
            Qwen3TTSVoiceClonePrompt.IntegrityManifest.self,
            from: Data(contentsOf: alternate.appendingPathComponent("integrity.json"))
        )
        var files = original.files
        let newFile = try XCTUnwrap(replacement.files["ref_codes.safetensors"])
        let oldFile = try XCTUnwrap(original.files["ref_codes.safetensors"])
        files["ref_codes.safetensors"] = .init(
            byteCount: newFile.byteCount,
            sha256: newFile.sha256,
            tensorKey: oldFile.tensorKey,
            shape: oldFile.shape,
            dataType: oldFile.dataType
        )
        try encoder.encode(
            Qwen3TTSVoiceClonePrompt.IntegrityManifest(schemaVersion: 1, files: files)
        ).write(to: directory.appendingPathComponent("integrity.json"))

        XCTAssertThrowsError(try Qwen3TTSVoiceClonePrompt.load(from: directory))
    }

    func testModeRequirementsRejectIncompleteArtifacts() throws {
        let xVector = temporaryDirectory()
        let icl = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: xVector)
            try? FileManager.default.removeItem(at: icl)
        }
        try Qwen3TTSVoiceClonePrompt(
            refCodes: nil, speakerEmbedding: nil, refText: nil,
            xVectorOnlyMode: true, iclMode: false
        ).write(to: xVector)
        try Qwen3TTSVoiceClonePrompt(
            refCodes: nil, speakerEmbedding: MLXArray([Float(1)]), refText: nil,
            xVectorOnlyMode: false, iclMode: true
        ).write(to: icl)
        XCTAssertThrowsError(try Qwen3TTSVoiceClonePrompt.load(from: xVector))
        XCTAssertThrowsError(try Qwen3TTSVoiceClonePrompt.load(from: icl))
    }

    private func tensorPrompt(refText: String) -> Qwen3TTSVoiceClonePrompt {
        Qwen3TTSVoiceClonePrompt(
            refCodes: MLXArray([Int32(1), 2, 3, 4]).reshaped(1, 2, 2),
            speakerEmbedding: MLXArray([Float(0.25), -0.5, 0.75]).reshaped(1, 3),
            refText: refText,
            xVectorOnlyMode: false,
            iclMode: true
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen3-clone-integrity-\(UUID().uuidString)", isDirectory: true)
    }
}
