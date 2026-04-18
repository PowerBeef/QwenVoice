@preconcurrency import AVFoundation
import XCTest
@testable import QwenVoiceNativeRuntime

final class NativeAudioPreparationTests: XCTestCase {
    func testNormalizeAudioConvertsToCanonicalMono24kWAV() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.wav")
        let outputURL = root.appendingPathComponent("normalized.wav")
        try NativeRuntimeTestSupport.writeTestWAV(
            to: sourceURL,
            sampleRate: 44_100,
            channels: 2,
            frameCount: 882
        )

        let service = NativeAudioPreparationService()
        let result = try await service.normalizeAudio(
            AudioPreparationRequest(inputURL: sourceURL, outputURL: outputURL)
        )

        XCTAssertEqual(result.sourceURL, sourceURL)
        XCTAssertEqual(result.normalizedURL, outputURL)
        XCTAssertFalse(result.wasAlreadyCanonical)
        XCTAssertTrue(NativeAudioPreparationService.isCanonicalWAV(at: outputURL))

        let normalizedFile = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(normalizedFile.processingFormat.sampleRate, 24_000, accuracy: 0.001)
        XCTAssertEqual(normalizedFile.processingFormat.channelCount, 1)
        XCTAssertGreaterThan(result.frameCount, 0)
        XCTAssertGreaterThan(result.durationSeconds, 0)
    }

    func testNormalizeAudioReusesCanonicalInputWhenNoOutputPathProvided() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("canonical.wav")
        try NativeRuntimeTestSupport.writeCanonicalPCM16WAV(
            to: sourceURL,
            sampleRate: 24_000,
            channels: 1,
            frameCount: 480
        )

        let service = NativeAudioPreparationService()
        let result = try await service.normalizeAudio(AudioPreparationRequest(inputURL: sourceURL))

        XCTAssertEqual(result.sourceURL, sourceURL)
        XCTAssertEqual(result.normalizedURL, sourceURL)
        XCTAssertTrue(result.wasAlreadyCanonical)
        XCTAssertTrue(NativeAudioPreparationService.isCanonicalWAV(at: sourceURL))
    }
}
