import Foundation
import XCTest
@testable import QwenVoiceCore

final class AudioPreparationHardeningTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioPreparationHardeningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
        try await super.tearDown()
    }

    func testRejectsOversizedInputBeforeDecode() async throws {
        let input = temporaryRoot.appendingPathComponent("oversized.wav")
        try Data(repeating: 0, count: 2_048).write(to: input)
        let service = NativeAudioPreparationService(
            preparedAudioDirectory: temporaryRoot,
            limits: AudioPreparationLimits(
                maxInputFileSizeBytes: 1_024,
                maxDecodedDurationSeconds: 120,
                trackLoadTimeoutSeconds: 60
            )
        )

        do {
            _ = try await service.normalizeAudio(AudioPreparationRequest(inputURL: input))
            XCTFail("Oversized input should be rejected.")
        } catch let error as AudioPreparationError {
            guard case .inputFileTooLarge(_, let maxBytes, let actualBytes) = error else {
                return XCTFail("Expected inputFileTooLarge, got \(error).")
            }
            XCTAssertEqual(maxBytes, 1_024)
            XCTAssertEqual(actualBytes, 2_048)
        }
    }

    func testRejectsOverDurationInputBeforeConversion() async throws {
        let input = temporaryRoot.appendingPathComponent("long.wav")
        try Self.writeCanonicalWAV(to: input, durationSeconds: 1.0)
        let service = NativeAudioPreparationService(
            preparedAudioDirectory: temporaryRoot,
            limits: AudioPreparationLimits(
                maxInputFileSizeBytes: 250 * 1_024 * 1_024,
                maxDecodedDurationSeconds: 0.25,
                trackLoadTimeoutSeconds: 60
            )
        )

        do {
            _ = try await service.normalizeAudio(AudioPreparationRequest(inputURL: input))
            XCTFail("Over-duration input should be rejected.")
        } catch let error as AudioPreparationError {
            guard case .inputDurationTooLong(let maxSeconds, let actualSeconds) = error else {
                return XCTFail("Expected inputDurationTooLong, got \(error).")
            }
            XCTAssertEqual(maxSeconds, 0.25)
            XCTAssertGreaterThan(actualSeconds, 0.9)
        }
    }

    func testDecodeTimeoutRemovesPartialOutput() async throws {
        let input = temporaryRoot.appendingPathComponent("timeout-source.wav")
        let output = temporaryRoot.appendingPathComponent("timeout-output.wav")
        try Self.writeCanonicalWAV(to: input, durationSeconds: 0.2)
        let service = NativeAudioPreparationService(
            preparedAudioDirectory: temporaryRoot,
            limits: AudioPreparationLimits(
                maxInputFileSizeBytes: 250 * 1_024 * 1_024,
                maxDecodedDurationSeconds: 120,
                trackLoadTimeoutSeconds: 0
            )
        )

        do {
            _ = try await service.normalizeAudio(AudioPreparationRequest(inputURL: input, outputURL: output))
            XCTFail("Zero timeout should reject conversion.")
        } catch let error as AudioPreparationError {
            guard case .decodeTimedOut = error else {
                return XCTFail("Expected decodeTimedOut, got \(error).")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCancelledTaskReportsCancellation() async throws {
        let input = temporaryRoot.appendingPathComponent("cancel-source.wav")
        try Self.writeCanonicalWAV(to: input, durationSeconds: 0.2)
        let service = NativeAudioPreparationService(preparedAudioDirectory: temporaryRoot)
        let task = Task<AudioNormalizationResult, Error> {
            try await service.normalizeAudio(AudioPreparationRequest(inputURL: input))
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled normalization should throw.")
        } catch let error as AudioPreparationError {
            XCTAssertEqual(error, .cancelled)
        } catch is CancellationError {
            // Accept the raw task cancellation shape if the cancellation wins
            // before the service can map it.
        }
    }

    private static func writeCanonicalWAV(to url: URL, durationSeconds: Double) throws {
        let sampleRate = 24_000
        let frameCount = Int(durationSeconds * Double(sampleRate))
        var data = Data()
        let pcmByteCount = frameCount * MemoryLayout<Int16>.size
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(UInt32(36 + pcmByteCount))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * MemoryLayout<Int16>.size))
        data.appendLittleEndian(UInt16(MemoryLayout<Int16>.size))
        data.appendLittleEndian(UInt16(16))
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(UInt32(pcmByteCount))
        data.append(Data(repeating: 0, count: pcmByteCount))
        try data.write(to: url)
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
