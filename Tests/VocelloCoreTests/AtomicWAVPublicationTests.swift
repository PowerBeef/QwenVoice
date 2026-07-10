import AVFoundation
import Foundation
@testable import QwenVoiceCore
import XCTest

final class AtomicWAVPublicationTests: XCTestCase {
    func testOneShotWriterPublishesReadableFrameAccurateWAV() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocello-atomic-wav-\(UUID().uuidString)", isDirectory: true)
        let output = directory.appendingPathComponent("take.wav")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = (0..<480).map { Int16(($0 % 31) * 100) }

        try AtomicPCM16WAVWriter.write(pcmSamples: samples, sampleRate: 24_000, outputURL: output)

        let audio = try AVAudioFile(forReading: output)
        XCTAssertEqual(audio.length, AVAudioFramePosition(samples.count))
        XCTAssertEqual(audio.fileFormat.sampleRate, 24_000)
        try assertRIFFWAVE(output)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["take.wav"])
    }

    func testStreamingWriterKeepsPartialOutputHiddenUntilTerminalBarrier() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocello-stream-wav-\(UUID().uuidString)", isDirectory: true)
        let output = directory.appendingPathComponent("take.wav")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Array(repeating: Int16(200), count: 240)
        let second = Array(repeating: Int16(-200), count: 240)

        let writer = try IncrementalPCM16WAVFileWriter(sampleRate: 24_000, outputURL: output)
        try writer.append(pcmSamples: first)
        try writer.append(pcmSamples: second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        try writer.finish()

        let audio = try AVAudioFile(forReading: output)
        XCTAssertEqual(audio.length, 480)
        XCTAssertEqual(audio.fileFormat.sampleRate, 24_000)
        try assertRIFFWAVE(output)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["take.wav"])
    }

    private func assertRIFFWAVE(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        XCTAssertGreaterThanOrEqual(data.count, 12)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data.dropFirst(8).prefix(4), as: UTF8.self), "WAVE")
    }
}
