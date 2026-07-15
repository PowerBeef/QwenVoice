import Foundation
@testable import QwenVoiceCore
import XCTest

final class GenerationFailureDiagnosticLoggerTests: XCTestCase {
    func testLogStoresOnlyAllowlistedPrivacySafeEnvelope() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocello-failure-log-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("generation-failures.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let logger = GenerationFailureDiagnosticLogger(
            fileURL: fileURL,
            ignoresTelemetryGate: true
        )
        let secretPrompt = "Private transcript for secret@example.com"
        let secretPath = "/" + "Users/private-user/Documents/reference.wav"
        let request = GenerationRequest(
            mode: .clone,
            modelID: secretPath,
            text: secretPrompt,
            outputPath: "/tmp/private-output.wav",
            shouldStream: true,
            payload: .clone(reference: CloneReference(audioPath: secretPath, transcript: secretPrompt))
        )

        logger.log(
            surfacedMessage: "Failed while reading \(secretPrompt)",
            stage: "generation failure",
            underlyingError: AudioPreparationError.missingInputFile(secretPath),
            request: request
        )

        let data = try Data(contentsOf: fileURL)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains(secretPrompt))
        XCTAssertFalse(text.contains(secretPath))
        XCTAssertFalse(text.contains("secret@example.com"))
        XCTAssertFalse(text.contains("surfacedMessage"))
        XCTAssertFalse(text.contains("underlyingError"))
        XCTAssertFalse(text.contains("stack"))

        let line = try XCTUnwrap(text.split(separator: "\n").first)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertEqual(object["errorCode"] as? String, "audio.input_missing")
        XCTAssertEqual(object["classification"] as? String, "audio")
        XCTAssertEqual(object["stage"] as? String, "stream_failed")
        XCTAssertEqual(object["requestMode"] as? String, "clone")
        XCTAssertNil(object["modelID"])
        XCTAssertEqual(object["textLength"] as? Int, secretPrompt.count)
        XCTAssertEqual(object["shouldStream"] as? Bool, true)
    }

    func testLogRetentionIsEntryAndByteBoundedAndClearable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocello-failure-log-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("generation-failures.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let logger = GenerationFailureDiagnosticLogger(
            fileURL: fileURL,
            maxBytes: 2_048,
            maxEntries: 3,
            ignoresTelemetryGate: true
        )
        for index in 0..<20 {
            logger.log(
                surfacedMessage: "private \(index)",
                stage: "generation startup",
                underlyingError: TTSEngineError.generationFailed("private \(index)")
            )
        }

        let data = try Data(contentsOf: fileURL)
        XCTAssertLessThanOrEqual(data.count, 2_048)
        XCTAssertLessThanOrEqual(
            [UInt8](data).split(separator: 0x0A, omittingEmptySubsequences: true).count,
            3
        )

        logger.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testUnknownStageAndErrorDoNotReflectSourceText() throws {
        struct PrivateError: LocalizedError {
            let errorDescription: String? =
                "token=https://example.invalid/private /" + "Users/person/private"
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocello-failure-log-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("generation-failures.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = GenerationFailureDiagnosticLogger(fileURL: fileURL, ignoresTelemetryGate: true)

        logger.log(
            surfacedMessage: "private surfaced text",
            stage: "private stage /" + "Users/person",
            underlyingError: PrivateError()
        )

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"stage\":\"unknown\""))
        XCTAssertTrue(text.contains("\"errorCode\":\"generation.unknown\""))
        XCTAssertFalse(text.contains("example.invalid"))
        XCTAssertFalse(text.contains("/" + "Users/person"))
        XCTAssertFalse(text.contains("private surfaced text"))
    }

    func testDefaultLogLivesUnderGovernedAppSupportDiagnosticsAndIsExcludedFromBackup() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocello-app-support-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let logger = GenerationFailureDiagnosticLogger(
            maxEntries: 1,
            ignoresTelemetryGate: true
        )

        logger.log(
            surfacedMessage: "fixture",
            stage: "generation failure",
            underlyingError: TTSEngineError.generationFailed("private"),
            appSupportDirectory: appSupport
        )
        logger.log(
            surfacedMessage: "fixture-two",
            stage: "generation failure",
            underlyingError: TTSEngineError.generationFailed("private"),
            appSupportDirectory: appSupport
        )

        let fileURL = appSupport
            .appendingPathComponent("diagnostics/engine", isDirectory: true)
            .appendingPathComponent("generation-failures.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(
            try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
            true
        )
    }
}
