import AVFoundation
import XCTest

/// Regression test for:
///
///     "Live audio preview could not decode the latest chunk."
///
/// The producer writes per-chunk WAV files via `AVAudioFile(forWriting:)`,
/// then posts a chunk event pointing at the file. The UI process then opens
/// that file via `AVAudioFile(forReading:)` and slots it into an
/// `AVAudioPCMBuffer(pcmFormat:, frameCapacity:)`.
///
/// `AVAudioFile` writes the final WAV/RIFF `data`-chunk size field when the
/// writer object is *deallocated*, not when `write(from:)` returns. When the
/// deallocation timing slipped under load, cross-process readers saw
/// `audioFile.length == 0` and the `AVAudioPCMBuffer(..., frameCapacity: 0)`
/// allocation returned `nil`, surfacing as the user-facing error above.
///
/// This test asserts the finalization technique used by the fixed writer:
///
///   1. Hold the `AVAudioFile` in a narrow `do { }` scope so ARC releases it
///      deterministically at `}` and its deinit writes the WAV header.
///   2. Immediately after the scope exits, call `FileHandle.synchronize()` on
///      the written URL to force the kernel to commit the bytes so
///      cross-process readers observe a finalized file.
///
/// The production code paths covered by this technique live in:
///   - `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift`
///     (`PCM16ChunkFileWriter.write`)
///   - `Sources/QwenVoiceNativeRuntime/NativeStreamingSynthesisSession.swift`
///     (same pattern in the retained-compat copy)
///
/// If either copy regresses to the old `let file = … write … <implicit scope exit>`
/// pattern without `synchronize`, the decoded-back `audioFile.length == 0`
/// failure mode can return.
final class StreamingChunkFinalizationTests: XCTestCase {

    private let sampleRate: Double = 24000
    private let frameCount: AVAudioFrameCount = 1024
    private let iterations = 50

    // MARK: - Finalized writer (the fix under test)

    /// Mirrors the fixed `PCM16ChunkFileWriter.write` pattern: explicit inner
    /// scope so ARC calls AVAudioFile's deinit at the closing brace, then
    /// FileHandle.synchronize() to force kernel commit before returning.
    private func writeFinalizedChunk(
        buffer: AVAudioPCMBuffer,
        format: AVAudioFormat,
        to url: URL
    ) throws {
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            try file.write(from: buffer)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.synchronize()
            try? handle.close()
        }
    }

    // MARK: - Helpers

    private func makeFormat() throws -> AVAudioFormat {
        try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ),
            "could not allocate Int16 PCM format"
        )
    }

    private func makeFilledBuffer(format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
            "could not allocate source PCM buffer"
        )
        buffer.frameLength = frameCount

        let channel = try XCTUnwrap(buffer.int16ChannelData?[0])
        for frame in 0..<Int(frameCount) {
            // Simple triangle wave to produce non-zero, non-constant audio.
            let magnitude = Int16((frame % 32) * 512)
            channel[frame] = frame.isMultiple(of: 2) ? magnitude : -magnitude
        }
        return buffer
    }

    // MARK: - Tests

    /// End-to-end: write a chunk using the finalized-writer pattern, then
    /// immediately attempt the exact consumer-side decode the UI performs in
    /// `AudioPlayerViewModel.loadPCMBuffer(from:)`. Every iteration must see a
    /// non-zero-length file with the expected frame count.
    func testChunkIsReadableImmediatelyAfterFinalizedWrite() throws {
        let format = try makeFormat()
        let sourceBuffer = try makeFilledBuffer(format: format)

        for iteration in 0..<iterations {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("chunk_finalization_\(iteration)_\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }

            try autoreleasepool {
                try writeFinalizedChunk(buffer: sourceBuffer, format: format, to: url)
            }

            // Mirror AudioPlayerViewModel.loadPCMBuffer(from:) exactly.
            let readFile = try AVAudioFile(forReading: url)
            XCTAssertGreaterThan(
                readFile.length,
                0,
                "iteration \(iteration): audioFile.length must be > 0 immediately after finalized write"
            )
            XCTAssertEqual(
                readFile.length,
                Int64(frameCount),
                "iteration \(iteration): readback frame count must match write"
            )

            let readFormat = readFile.processingFormat
            let readCapacity = AVAudioFrameCount(readFile.length)
            XCTAssertGreaterThan(
                readCapacity,
                0,
                "iteration \(iteration): AVAudioPCMBuffer frameCapacity must be > 0 for consumer allocation"
            )

            let readBuffer = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: readCapacity),
                "iteration \(iteration): AVAudioPCMBuffer allocation returned nil — consumer would emit 'could not decode the latest chunk'"
            )
            try readFile.read(into: readBuffer)
            XCTAssertEqual(
                readBuffer.frameLength,
                frameCount,
                "iteration \(iteration): read-back frameLength must match source"
            )
        }
    }

    /// Under rapid back-to-back writes (closer to the production streaming
    /// pattern, where many chunks arrive per second), each write must still
    /// produce an independently readable file with the correct frame count.
    func testBackToBackChunkWritesAreAllIndependentlyReadable() throws {
        let format = try makeFormat()
        let sourceBuffer = try makeFilledBuffer(format: format)

        var urls: [URL] = []
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        // Write phase — back-to-back, no artificial delay.
        for iteration in 0..<iterations {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("chunk_backtoback_\(iteration)_\(UUID().uuidString).wav")
            try autoreleasepool {
                try writeFinalizedChunk(buffer: sourceBuffer, format: format, to: url)
            }
            urls.append(url)
        }

        // Read phase — validate every file in write order.
        for (iteration, url) in urls.enumerated() {
            let readFile = try AVAudioFile(forReading: url)
            XCTAssertEqual(
                readFile.length,
                Int64(frameCount),
                "back-to-back chunk \(iteration): readback frame count must match write"
            )
            let readCapacity = AVAudioFrameCount(readFile.length)
            XCTAssertNotNil(
                AVAudioPCMBuffer(pcmFormat: readFile.processingFormat, frameCapacity: readCapacity),
                "back-to-back chunk \(iteration): consumer-side buffer allocation returned nil"
            )
        }
    }
}
