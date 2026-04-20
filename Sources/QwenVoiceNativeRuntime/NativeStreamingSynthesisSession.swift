import AVFoundation
import Foundation
import QwenVoiceCore
import QwenVoiceEngineSupport

protocol NativeStreamingSessionRunning {
    func run(
        eventSink: @escaping @Sendable (GenerationEvent) -> Void
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
    private let cloneConditioning: ResolvedCloneConditioning?
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
        cloneConditioning: ResolvedCloneConditioning? = nil,
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
        self.cloneConditioning = cloneConditioning
        self.telemetryRecorder = telemetryRecorder
    }

    func run(
        eventSink: @escaping @Sendable (GenerationEvent) -> Void
    ) async throws -> GenerationResult {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let sessionDirectory = try makeSessionDirectory()
        let outputURL = URL(fileURLWithPath: request.outputPath)
        let telemetrySampler = NativeTelemetrySampler(
            startUptimeSeconds: startedAt,
            sampleIntervalMS: 50
        )
        await telemetryRecorder.reset()
        await telemetryRecorder.mark(stage: "stream_startup")

        var allSamples: [Float] = []
        var pendingSamples: [Float]?
        var chunkIndex = 0
        var cumulativeDuration = 0.0
        var firstChunkMS: Int?
        var info: NativeSpeechGenerationInfo?
        var lastChunkPath: String?

        do {
            try Task.checkCancellation()
            let stream = try buildStream()

            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .audio(let samples):
                    if let pendingSamples {
                        try Task.checkCancellation()
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
                try Task.checkCancellation()
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

            try Task.checkCancellation()
            guard !allSamples.isEmpty else {
                throw NativeStreamingSessionError.noAudioGenerated
            }

            try Task.checkCancellation()
            try Self.writeWAV(
                samples: allSamples,
                sampleRate: model.sampleRate,
                to: outputURL
            )

            await telemetryRecorder.mark(stage: "stream_completed")
            let stageMarks = await telemetryRecorder.snapshot()
            let telemetryCapture = await telemetrySampler.stop(stageMarks: stageMarks)

            var timingsMS = timingOverridesMS
            timingsMS["generation_total_ms"] = telemetryCapture.samples.last?.tMS ?? 0
            if let firstChunkMS {
                timingsMS["first_chunk_ms"] = firstChunkMS
            }

            var resolvedBooleanFlags = booleanFlags
            resolvedBooleanFlags["custom_dedicated_handler_used"] = model.supportsDedicatedCustomVoice
            resolvedBooleanFlags["warm_state_warm"] = warmState == .warm
            resolvedBooleanFlags["warm_state_cold"] = warmState == .cold
            if let cloneConditioning {
                resolvedBooleanFlags["clone_conditioning_reused"] =
                    (resolvedBooleanFlags["clone_conditioning_reused"] ?? false)
                    || cloneConditioning.cloneConditioningReused
                resolvedBooleanFlags["used_temp_reference"] = cloneConditioning.usedTemporaryReference
                resolvedBooleanFlags["reused_normalized_reference"] = cloneConditioning.reusedNormalizedReference
                resolvedBooleanFlags["reused_decoded_reference"] = cloneConditioning.reusedDecodedReference
                if let cloneCacheHit = cloneConditioning.cloneCacheHit {
                    resolvedBooleanFlags["prepared_clone_cache_hit"] = cloneCacheHit
                }
                if let clonePromptCacheHit = cloneConditioning.clonePromptCacheHit {
                    resolvedBooleanFlags["clone_prompt_cache_hit"] = clonePromptCacheHit
                }
            }

            var resolvedStringFlags = stringFlags
            if let cloneConditioning {
                resolvedStringFlags["clone_transcript_mode"] = cloneConditioning.transcriptMode.rawValue
            }

            let benchmarkSample = BenchmarkSample(
                tokenCount: info?.generationTokenCount,
                processingTimeSeconds: info.map { $0.prefillTime + $0.generateTime },
                peakMemoryUsage: info?.peakMemoryUsage,
                streamingUsed: request.shouldStream,
                preparedCloneUsed: cloneConditioning?.preparedCloneUsed,
                cloneCacheHit: cloneConditioning?.cloneCacheHit,
                firstChunkMs: firstChunkMS,
                telemetryStageMarks: telemetryCapture.summary.stageMarks,
                timingsMS: timingsMS,
                booleanFlags: resolvedBooleanFlags,
                stringFlags: resolvedStringFlags
            )

            _ = lastChunkPath
            return GenerationResult(
                audioPath: request.outputPath,
                durationSeconds: cumulativeDuration,
                streamSessionDirectory: sessionDirectory.path,
                benchmarkSample: benchmarkSample
            )
        } catch is CancellationError {
            try? Self.removeFileIfPresent(at: outputURL)
            await telemetryRecorder.mark(
                stage: "stream_failed",
                metadata: ["error": "cancelled"]
            )
            throw CancellationError()
        } catch {
            await telemetryRecorder.mark(
                stage: "stream_failed",
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
                language: QwenVoiceCore.GenerationSemantics.qwenLanguageHint(for: request),
                speaker: speakerID.trimmingCharacters(in: .whitespacesAndNewlines),
                instruct: QwenVoiceCore.GenerationSemantics.customInstruction(deliveryStyle: deliveryStyle),
                streamingInterval: QwenVoiceCore.GenerationSemantics.appStreamingInterval
            )
        case .design(let voiceDescription, let deliveryStyle):
            let resolvedVoiceDescription = QwenVoiceCore.GenerationSemantics.designInstruction(
                voiceDescription: voiceDescription,
                emotion: deliveryStyle ?? ""
            )
            return model.generateVoiceDesignStream(
                text: request.text,
                language: QwenVoiceCore.GenerationSemantics.qwenLanguageHint(for: request),
                voiceDescription: resolvedVoiceDescription,
                streamingInterval: QwenVoiceCore.GenerationSemantics.appStreamingInterval
            )
        case .clone:
            guard let cloneConditioning else {
                throw NativeStreamingSessionError.unsupportedRequest(
                    "Native Voice Cloning needs resolved native clone conditioning."
                )
            }
            let language = QwenVoiceCore.GenerationSemantics.qwenLanguageHint(
                for: request,
                resolvedCloneTranscript: cloneConditioning.resolvedTranscript
            )
            if let voiceClonePrompt = cloneConditioning.voiceClonePrompt,
               model.supportsOptimizedVoiceClone {
                return model.generateVoiceCloneStream(
                    text: request.text,
                    language: language,
                    voiceClonePrompt: voiceClonePrompt,
                    streamingInterval: QwenVoiceCore.GenerationSemantics.appStreamingInterval
                )
            }
            return model.generateStream(
                text: request.text,
                voice: nil,
                refAudio: cloneConditioning.referenceAudio,
                refText: cloneConditioning.resolvedTranscript,
                language: language,
                streamingInterval: QwenVoiceCore.GenerationSemantics.appStreamingInterval
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
        eventSink: @escaping @Sendable (GenerationEvent) -> Void
    ) async throws -> (path: String, duration: Double) {
        try Task.checkCancellation()
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
                stage: "first_chunk",
                metadata: ["chunk_index": "\(chunkIndex)"]
            )
        }

        if request.shouldStream {
            try Task.checkCancellation()
            eventSink(
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

    private static func removeFileIfPresent(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
