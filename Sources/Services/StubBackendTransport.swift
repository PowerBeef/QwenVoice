import Foundation
import QwenVoiceNative

enum StubEngineError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}

struct StreamingRequestContext {
    let mode: GenerationMode
    let title: String
}

struct StubGenerationMetrics {
    let tokenCount: Int?
    let processingTimeSeconds: Double?
    let peakMemoryUsage: Double?
    let streamingUsed: Bool
    let preparedCloneUsed: Bool?
    let cloneCacheHit: Bool?
    let firstChunkMs: Int?
}

struct StubGenerationResult {
    let audioPath: String
    let durationSeconds: Double
    let streamSessionDirectory: String?
    let metrics: StubGenerationMetrics?
}

@MainActor
final class StubBackendTransport {
    private var stubRequestSeed = 10_000

    func initialize() async throws {
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    func loadModel(id: String) async throws {
        guard let model = TTSModel.model(id: id) else {
            throw StubEngineError.message("Unknown model '\(id)'")
        }
        guard model.isAvailable(in: QwenVoiceApp.modelsDir) else {
            throw StubEngineError.message("Model '\(model.name)' is unavailable or incomplete.")
        }

        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    func listVoices() throws -> [Voice] {
        let voicesDir = AppPaths.voicesDir
        guard let enumerator = FileManager.default.enumerator(at: voicesDir, includingPropertiesForKeys: nil) else {
            return []
        }

        var voices: [Voice] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "wav" else { continue }
            let transcriptURL = fileURL.deletingPathExtension().appendingPathExtension("txt")
            voices.append(
                Voice(
                    name: fileURL.deletingPathExtension().lastPathComponent,
                    wavPath: fileURL.path,
                    hasTranscript: FileManager.default.fileExists(atPath: transcriptURL.path)
                )
            )
        }

        return voices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func enrollVoice(name: String, audioPath: String, transcript: String?) throws -> Voice {
        let sourcePath = audioPath.isEmpty ? (UITestAutomationSupport.enrollAudioURL?.path ?? "") : audioPath
        guard !sourcePath.isEmpty, FileManager.default.fileExists(atPath: sourcePath) else {
            throw StubEngineError.message("Reference audio file not found.")
        }

        try FileManager.default.createDirectory(at: AppPaths.voicesDir, withIntermediateDirectories: true)
        let safeName = SavedVoiceNameSanitizer.normalizedName(name)
        guard !safeName.isEmpty else {
            throw StubEngineError.message("Invalid saved voice name.")
        }

        let destination = AppPaths.voicesDir.appendingPathComponent("\(safeName).wav")
        let transcriptDestination = AppPaths.voicesDir.appendingPathComponent("\(safeName).txt")

        if FileManager.default.fileExists(atPath: destination.path)
            || FileManager.default.fileExists(atPath: transcriptDestination.path) {
            throw StubEngineError.message("A saved voice named \"\(safeName)\" already exists. Choose a different name.")
        }

        try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: destination)

        if let transcript, !transcript.isEmpty {
            try transcript.write(to: transcriptDestination, atomically: true, encoding: .utf8)
        }

        return Voice(
            name: safeName,
            wavPath: destination.path,
            hasTranscript: !(transcript?.isEmpty ?? true)
        )
    }

    func deleteVoice(name: String) throws {
        let wavURL = AppPaths.voicesDir.appendingPathComponent("\(name).wav")
        let transcriptURL = AppPaths.voicesDir.appendingPathComponent("\(name).txt")

        guard FileManager.default.fileExists(atPath: wavURL.path) else {
            throw StubEngineError.message("Voice '\(name)' does not exist.")
        }

        try FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: transcriptURL)
    }

    func generate(
        mode: GenerationMode,
        text: String,
        outputPath: String,
        stream: Bool,
        streamingContext: StreamingRequestContext?,
        chunkHandler: ((GenerationEvent) -> Void)? = nil
    ) async throws -> StubGenerationResult {
        let requestID = nextStubRequestID()
        let finalURL = URL(fileURLWithPath: outputPath)
        let finalDirectory = finalURL.deletingLastPathComponent()
        let streamSessionDirectory = AppPaths.appSupportDir
            .appendingPathComponent("cache/stream_sessions", isDirectory: true)
            .appendingPathComponent("stub-\(requestID)", isDirectory: true)

        try FileManager.default.createDirectory(at: finalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: streamSessionDirectory, withIntermediateDirectories: true)

        let sampleRate = 24_000
        let chunkDurations = [0.28, 0.32, 0.36]
        var combinedSamples: [Int16] = []
        let startedAt = Date()
        var firstChunkMs: Int?

        for (index, durationSeconds) in chunkDurations.enumerated() {
            try? await Task.sleep(nanoseconds: 250_000_000)

            let samples = Self.stubSineWave(
                sampleRate: sampleRate,
                durationSeconds: durationSeconds,
                frequency: 220 + (index * 45)
            )
            combinedSamples.append(contentsOf: samples)

            let chunkURL = streamSessionDirectory.appendingPathComponent("chunk_\(index).wav")
            try Self.writeStubWAV(
                to: chunkURL,
                samples: samples,
                sampleRate: sampleRate
            )

            if firstChunkMs == nil {
                firstChunkMs = max(1, Int(Date().timeIntervalSince(startedAt) * 1000))
            }

            if stream, let streamingContext {
                chunkHandler?(
                    GenerationEvent(
                        kind: .streamChunk,
                        requestID: requestID,
                        mode: streamingContext.mode.rawValue,
                        title: streamingContext.title,
                        chunkPath: chunkURL.path,
                        isFinal: index == chunkDurations.count - 1,
                        chunkDurationSeconds: durationSeconds,
                        cumulativeDurationSeconds: chunkDurations.prefix(index + 1).reduce(0.0, +),
                        streamSessionDirectory: streamSessionDirectory.path
                    )
                )
            }
        }

        try Self.writeStubWAV(to: finalURL, samples: combinedSamples, sampleRate: sampleRate)

        return StubGenerationResult(
            audioPath: finalURL.path,
            durationSeconds: chunkDurations.reduce(0, +),
            streamSessionDirectory: stream ? streamSessionDirectory.path : nil,
            metrics: StubGenerationMetrics(
                tokenCount: 96,
                processingTimeSeconds: Date().timeIntervalSince(startedAt),
                peakMemoryUsage: 0.12,
                streamingUsed: stream,
                preparedCloneUsed: mode == .clone,
                cloneCacheHit: mode == .clone,
                firstChunkMs: stream ? firstChunkMs : nil
            )
        )
    }

    func generateCloneBatch(
        texts: [String],
        outputPaths: [String]
    ) async throws -> [StubGenerationResult] {
        var results: [StubGenerationResult] = []
        for (text, outputPath) in zip(texts, outputPaths) {
            let result = try await generate(
                mode: .clone,
                text: text,
                outputPath: outputPath,
                stream: false,
                streamingContext: nil,
                chunkHandler: nil
            )
            results.append(result)
        }
        return results
    }

    private func nextStubRequestID() -> Int {
        stubRequestSeed += 1
        return stubRequestSeed
    }

    private static func stubSineWave(sampleRate: Int, durationSeconds: Double, frequency: Int) -> [Int16] {
        let frameCount = max(1, Int(Double(sampleRate) * durationSeconds))
        let amplitude = 0.28
        let angularFrequency = 2.0 * Double.pi * Double(frequency)

        return (0..<frameCount).map { frame in
            let time = Double(frame) / Double(sampleRate)
            let value = sin(angularFrequency * time) * amplitude
            return Int16(max(-32767, min(32767, Int(value * Double(Int16.max)))))
        }
    }

    private static func writeStubWAV(to url: URL, samples: [Int16], sampleRate: Int) throws {
        var data = Data()
        let bytesPerSample = 2
        let dataSize = UInt32(samples.count * bytesPerSample)
        let chunkSize = UInt32(36) + dataSize

        data.append("RIFF".data(using: .ascii)!)
        data.append(littleEndianBytes(chunkSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(littleEndianBytes(UInt32(16)))
        data.append(littleEndianBytes(UInt16(1)))
        data.append(littleEndianBytes(UInt16(1)))
        data.append(littleEndianBytes(UInt32(sampleRate)))
        data.append(littleEndianBytes(UInt32(sampleRate * bytesPerSample)))
        data.append(littleEndianBytes(UInt16(bytesPerSample)))
        data.append(littleEndianBytes(UInt16(16)))
        data.append("data".data(using: .ascii)!)
        data.append(littleEndianBytes(dataSize))

        for sample in samples {
            data.append(littleEndianBytes(UInt16(bitPattern: sample)))
        }

        try data.write(to: url, options: .atomic)
    }

    private static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
        var littleEndian = value.littleEndian
        return Data(bytes: &littleEndian, count: MemoryLayout<T>.size)
    }
}
