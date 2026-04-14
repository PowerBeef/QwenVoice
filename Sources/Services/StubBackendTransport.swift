import Foundation

@MainActor
final class StubBackendTransport {
    private var stubRequestSeed = 10_000

    func initialize() async throws {
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    func loadModel(id: String) async throws -> [String: RPCValue] {
        guard let model = TTSModel.model(id: id) else {
            throw PythonBridgeError.rpcError(code: -32001, message: "Unknown model '\(id)'")
        }
        guard model.isAvailable(in: QwenVoiceApp.modelsDir) else {
            throw PythonBridgeError.rpcError(code: -32010, message: "Model '\(model.name)' is unavailable or incomplete.")
        }

        try? await Task.sleep(nanoseconds: 120_000_000)
        return stubModelLoadResult(for: model, cached: false)
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
            throw PythonBridgeError.rpcError(code: -32020, message: "Reference audio file not found.")
        }

        try FileManager.default.createDirectory(at: AppPaths.voicesDir, withIntermediateDirectories: true)
        let safeName = SavedVoiceNameSanitizer.normalizedName(name)
        guard !safeName.isEmpty else {
            throw PythonBridgeError.rpcError(code: -32022, message: "Invalid saved voice name.")
        }

        let destination = AppPaths.voicesDir.appendingPathComponent("\(safeName).wav")
        let transcriptDestination = AppPaths.voicesDir.appendingPathComponent("\(safeName).txt")

        if FileManager.default.fileExists(atPath: destination.path)
            || FileManager.default.fileExists(atPath: transcriptDestination.path) {
            throw PythonBridgeError.rpcError(
                code: -32023,
                message: "A saved voice named \"\(safeName)\" already exists. Choose a different name."
            )
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
            throw PythonBridgeError.rpcError(code: -32021, message: "Voice '\(name)' does not exist.")
        }

        try FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: transcriptURL)
    }

    func modelInfo() -> [ModelInfo] {
        TTSModel.all.map { model in
            let modelDirectory = model.installDirectory(in: QwenVoiceApp.modelsDir)
            let rootExists = FileManager.default.fileExists(atPath: modelDirectory.path)
            let missingRequiredPaths = rootExists
                ? model.requiredRelativePaths.filter {
                    !FileManager.default.fileExists(
                        atPath: modelDirectory.appendingPathComponent($0).path
                    )
                }
                : []
            let complete = rootExists && missingRequiredPaths.isEmpty
            let size = rootExists ? Self.directorySize(url: modelDirectory) : 0

            return ModelInfo(
                id: model.id,
                name: model.name,
                folder: model.folder,
                mode: model.mode,
                tier: model.tier,
                outputSubfolder: model.outputSubfolder,
                huggingFaceRepo: model.huggingFaceRepo,
                requiredRelativePaths: model.requiredRelativePaths,
                resolvedPath: rootExists ? modelDirectory.path : nil,
                downloaded: rootExists,
                complete: complete,
                repairable: rootExists && !complete,
                missingRequiredPaths: missingRequiredPaths,
                sizeBytes: size,
                mlxAudioVersion: "0.4.2",
                supportsStreaming: true,
                supportsPreparedClone: model.mode == .clone,
                supportsCloneStreaming: model.mode == .clone,
                supportsBatch: true
            )
        }
    }

    func speakers() -> [String: [String]] {
        TTSModel.speakerGroups
    }

    func generate(
        mode: GenerationMode,
        text: String,
        outputPath: String,
        stream: Bool,
        streamingContext: StreamingRequestContext?
    ) async throws -> GenerationResult {
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
                NotificationCenter.default.post(
                    name: .generationChunkReceived,
                    object: nil,
                    userInfo: [
                        "requestID": requestID,
                        "mode": streamingContext.mode.rawValue,
                        "title": streamingContext.title,
                        "chunkPath": chunkURL.path,
                        "isFinal": index == chunkDurations.count - 1,
                        "chunkDurationSeconds": durationSeconds,
                        "cumulativeDurationSeconds": chunkDurations.prefix(index + 1).reduce(0.0, +),
                        "streamSessionDirectory": streamSessionDirectory.path,
                    ]
                )
            }
        }

        try Self.writeStubWAV(to: finalURL, samples: combinedSamples, sampleRate: sampleRate)

        return GenerationResult(
            audioPath: finalURL.path,
            durationSeconds: chunkDurations.reduce(0, +),
            streamSessionDirectory: stream ? streamSessionDirectory.path : nil,
            metrics: .init(
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
    ) async throws -> [GenerationResult] {
        var results: [GenerationResult] = []
        for (text, outputPath) in zip(texts, outputPaths) {
            let result = try await generate(
                mode: .clone,
                text: text,
                outputPath: outputPath,
                stream: false,
                streamingContext: nil
            )
            results.append(result)
        }
        return results
    }

    private func nextStubRequestID() -> Int {
        stubRequestSeed += 1
        return stubRequestSeed
    }

    private func stubModelLoadResult(for model: TTSModel, cached: Bool) -> [String: RPCValue] {
        [
            "success": .bool(true),
            "cached": .bool(cached),
            "model_id": .string(model.id),
            "mlx_audio_version": .string("0.4.2"),
            "supports_streaming": .bool(true),
            "supports_prepared_clone": .bool(model.mode == .clone),
            "supports_clone_streaming": .bool(model.mode == .clone),
            "supports_batch": .bool(true),
        ]
    }

    private static func directorySize(url: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += size
            }
        }
        return total
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
