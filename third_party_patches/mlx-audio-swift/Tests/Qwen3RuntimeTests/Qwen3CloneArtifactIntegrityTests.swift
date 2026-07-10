import Foundation
@testable import MLXAudioTTS
import XCTest

final class Qwen3CloneArtifactIntegrityTests: XCTestCase {
    func testRoundTripWritesVersionedIntegrityManifest() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let prompt = Qwen3TTSVoiceClonePrompt(
            refCodes: nil,
            speakerEmbedding: nil,
            refText: "fixture",
            xVectorOnlyMode: true,
            iclMode: false
        )

        try prompt.write(to: directory)
        let loaded = try Qwen3TTSVoiceClonePrompt.load(from: directory)

        XCTAssertEqual(loaded.refText, "fixture")
        XCTAssertNil(loaded.refCodes)
        XCTAssertNil(loaded.speakerEmbedding)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("integrity.json").path))
    }

    func testTamperedArtifactFailsClosed() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let prompt = Qwen3TTSVoiceClonePrompt(
            refCodes: nil,
            speakerEmbedding: nil,
            refText: "fixture",
            xVectorOnlyMode: true,
            iclMode: false
        )
        try prompt.write(to: directory)
        try Data("tampered".utf8).write(to: directory.appendingPathComponent("manifest.json"))

        XCTAssertThrowsError(try Qwen3TTSVoiceClonePrompt.load(from: directory))
    }

    func testUnexpectedArtifactFileFailsClosed() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let prompt = Qwen3TTSVoiceClonePrompt(
            refCodes: nil,
            speakerEmbedding: nil,
            refText: nil,
            xVectorOnlyMode: true,
            iclMode: false
        )
        try prompt.write(to: directory)
        try Data([0]).write(to: directory.appendingPathComponent("unexpected.bin"))

        XCTAssertThrowsError(try Qwen3TTSVoiceClonePrompt.load(from: directory))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen3-clone-integrity-\(UUID().uuidString)", isDirectory: true)
    }
}
