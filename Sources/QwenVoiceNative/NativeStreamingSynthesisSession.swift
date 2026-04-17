import AVFoundation
import Foundation

protocol NativeStreamingSessionRunning {
    func run(
        eventSink: @escaping @MainActor @Sendable (GenerationEvent) -> Void
    ) async throws -> GenerationResult
}

enum NativeStreamingSessionError: LocalizedError {
    case unsupportedRequest(String)
    case noAudioGenerated
    case couldNotCreatePCMBuffer

    var errorDescription: String? {
        switch self {
        case .unsupportedRequest(let message):
            return message
        case .noAudioGenerated:
            return "The native MLX engine did not produce any audio samples."
        case .couldNotCreatePCMBuffer:
            return "The native MLX engine could not allocate an audio buffer."
        }
    }
}

final class NativeStreamingSynthesisSession: NativeStreamingSessionRunning {
    private let requestID: Int
    private let request: GenerationRequest
    private let model: NativeSpeechGenerationModel
    private let streamSessionsDirectory: URL
    private let warmState: EngineWarmState
    private let timingOverridesMS: [String: Int]
    private let booleanFlags: [String: Bool]
    private let stringFlags: [String: String]
    private let telemetryRecorder: NativeTelemetryRecorder

    init(
        requestID: Int,
        request: GenerationRequest,
        model: NativeSpeechGenerationModel,
        streamSessionsDirectory: URL,
        warmState: EngineWarmState,
        timingOverridesMS: [String: Int] = [:],
        booleanFlags: [String: Bool] = [:],
        stringFlags: [String: String] = [:],
        telemetryRecorder: NativeTelemetryRecorder = NativeTelemetryRecorder()
    ) {
        self.requestID = requestID
        self.request = request
        self.model = model
        self.streamSessionsDirectory = streamSessionsDirectory
        self.warmState = warmState
        self.timingOverridesMS = timingOverridesMS
        self.booleanFlags = booleanFlags
        self.stringFlags = stringFlags
        self.telemetryRecorder = telemetryRecorder
    }

    func run(
        eventSink: @escaping @MainActor @Sendable (GenerationEvent) -> Void
    ) async throws -> GenerationResult {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let sessionDirectory = try makeSessionDirectory()
        let telemetrySampler = NativeTelemetrySampler(startUptimeSeconds: startedAt)
        await telemetryRecorder.reset()
        await telemetryRecorder.mark(stage: .streamStartup)

        var allSamples: [Float] = []
        var pendingSamples: [Float]?
        var chunkIndex = 0
        var cumulativeDuration = 0.0
        var firstChunkMS: Int?
        var info: NativeSpeechGenerationInfo?
        var lastChunkPath: String?

        do {
            let stream = try buildStream()

            for try await event in stream {
                switch event {
                case .audio(let samples):
                    if let pendingSamples {
                        let emitted = try await emitChunk(
                            samples: pendingSamples,
                            isFinal: false,
                            chunkIndex: chunkIndex,
                            sessionDirectory: sessionDirectory,
                            startedAt: startedAt,
                            cumulativeDuration: &cumulativeDuration,
                            allSamples: &allSamples,
                            firstChunkMS: &firstChunkMS,
                            eventSink: eventSink
                        )
                        lastChunkPath = emitted.path
                        chunkIndex += 1
                    }
                    pendingSamples = samples
                case .info(let generationInfo):
                    info = generationInfo
                }
            }

            if let pendingSamples {
                let emitted = try await emitChunk(
                    samples: pendingSamples,
                    isFinal: true,
                    chunkIndex: chunkIndex,
                    sessionDirectory: sessionDirectory,
                    startedAt: startedAt,
                    cumulativeDuration: &cumulativeDuration,
                    allSamples: &allSamples,
                    firstChunkMS: &firstChunkMS,
                    eventSink: eventSink
                )
                lastChunkPath = emitted.path
            }

            guard !allSamples.isEmpty else {
                throw NativeStreamingSessionError.noAudioGenerated
            }

            try Self.writeWAV(
                samples: allSamples,
                sampleRate: model.sampleRate,
                to: URL(fileURLWithPath: request.outputPath)
            )

            await telemetryRecorder.mark(stage: .streamCompleted)
            let stageMarks = await telemetryRecorder.snapshot()
            let telemetrySummary = await telemetrySampler.stop(stageMarks: stageMarks)

            var timingsMS = timingOverridesMS
            timingsMS["generation_total_ms"] = telemetrySummary.totalTimeMS
            if let firstChunkMS {
                timingsMS["first_chunk_ms"] = firstChunkMS
            }

            var resolvedBooleanFlags = booleanFlags
            resolvedBooleanFlags["custom_dedicated_handler_used"] = model.supportsDedicatedCustomVoice
            resolvedBooleanFlags["warm_state_warm"] = warmState == .warm
            resolvedBooleanFlags["warm_state_cold"] = warmState == .cold

            let benchmarkSample = BenchmarkSample(
                tokenCount: info?.generationTokenCount,
                processingTimeSeconds: info.map { $0.prefillTime + $0.generateTime },
                peakMemoryUsage: info?.peakMemoryUsage,
                streamingUsed: request.shouldStream,
                firstChunkMs: firstChunkMS,
                timingsMS: timingsMS,
                booleanFlags: resolvedBooleanFlags,
                stringFlags: stringFlags,
                telemetryStageMarks: telemetrySummary.stageMarks
            )

            _ = lastChunkPath
            return GenerationResult(
                audioPath: request.outputPath,
                durationSeconds: cumulativeDuration,
                streamSessionDirectory: sessionDirectory.path,
                benchmarkSample: benchmarkSample
            )
        } catch {
            await telemetryRecorder.mark(
                stage: .streamFailed,
                metadata: ["error": error.localizedDescription]
            )
            throw error
        }
    }

    private func buildStream() throws -> AsyncThrowingStream<NativeSpeechGenerationEvent, Error> {
        switch request.payload {
        case .custom(let speakerID, let deliveryStyle):
            return model.generateCustomVoiceStream(
                text: request.text,
                language: GenerationSemantics.qwenLanguageHint(for: request),
                speaker: speakerID.trimmingCharacters(in: .whitespacesAndNewlines),
                instruct: GenerationSemantics.customInstruction(deliveryStyle: deliveryStyle),
                streamingInterval: GenerationSemantics.appStreamingInterval
            )
        case .design(let voiceDescription, let deliveryStyle):
            let resolvedVoiceDescription = GenerationSemantics.designInstruction(
                voiceDescription: voiceDescription,
                emotion: deliveryStyle ?? ""
            )
            return model.generateVoiceDesignStream(
                text: request.text,
                language: GenerationSemantics.qwenLanguageHint(for: request),
                voiceDescription: resolvedVoiceDescription,
                streamingInterval: GenerationSemantics.appStreamingInterval
            )
        case .clone:
            throw NativeStreamingSessionError.unsupportedRequest(
                "Native Voice Cloning is not implemented yet."
            )
        }
    }

    private func makeSessionDirectory() throws -> URL {
        try FileManager.default.createDirectory(
            at: streamSessionsDirectory,
            withIntermediateDirectories: true
        )

        let directory = Self.sessionDirectoryURL(
            in: streamSessionsDirectory,
            requestID: requestID
        )
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func emitChunk(
        samples: [Float],
        isFinal: Bool,
        chunkIndex: Int,
        sessionDirectory: URL,
        startedAt: TimeInterval,
        cumulativeDuration: inout Double,
        allSamples: inout [Float],
        firstChunkMS: inout Int?,
        eventSink: @escaping @MainActor @Sendable (GenerationEvent) -> Void
    ) async throws -> (path: String, duration: Double) {
        let chunkURL = Self.chunkURL(in: sessionDirectory, chunkIndex: chunkIndex)
        try Self.writeWAV(
            samples: samples,
            sampleRate: model.sampleRate,
            to: chunkURL
        )

        allSamples.append(contentsOf: samples)
        let chunkDuration = Double(samples.count) / Double(model.sampleRate)
        cumulativeDuration += chunkDuration

        if firstChunkMS == nil {
            firstChunkMS = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
            await telemetryRecorder.mark(
                stage: .firstChunk,
                metadata: ["chunk_index": "\(chunkIndex)"]
            )
        }

        if request.shouldStream {
            await eventSink(
                GenerationEvent(
                    kind: .streamChunk,
                    requestID: requestID,
                    mode: request.modeIdentifier,
                    title: request.streamingTitle ?? String(request.text.prefix(40)),
                    chunkPath: chunkURL.path,
                    isFinal: isFinal,
                    chunkDurationSeconds: chunkDuration,
                    cumulativeDurationSeconds: cumulativeDuration,
                    streamSessionDirectory: sessionDirectory.path
                )
            )
        }

        return (chunkURL.path, chunkDuration)
    }

    nonisolated static func sessionDirectoryURL(in rootDirectory: URL, requestID: Int) -> URL {
        rootDirectory.appendingPathComponent(
            String(format: "session_%04d", requestID),
            isDirectory: true
        )
    }

    nonisolated static func chunkURL(in sessionDirectory: URL, chunkIndex: Int) -> URL {
        sessionDirectory.appendingPathComponent(
            String(format: "chunk_%04d.wav", chunkIndex)
        )
    }

    private static func writeWAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        )

        guard let format else {
            throw NativeStreamingSessionError.couldNotCreatePCMBuffer
        }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ), let channelData = buffer.floatChannelData?[0] else {
            throw NativeStreamingSessionError.couldNotCreatePCMBuffer
        }

        buffer.frameLength = frameCount
        for (index, sample) in samples.enumerated() {
            channelData[index] = sample
        }

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
