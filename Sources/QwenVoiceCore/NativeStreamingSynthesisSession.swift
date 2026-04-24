import AVFoundation
import Foundation
import MLX
import MLXAudioCore
@preconcurrency import MLXAudioTTS

protocol NativeStreamingSessionRunning {
    func run(eventSink: @escaping @MainActor @Sendable (GenerationEvent) -> Void) async throws -> GenerationResult
}

final class NativeStreamingSynthesisSession: NativeStreamingSessionRunning {
    private let requestID: Int
    private let request: GenerationRequest
    private let model: UnsafeSpeechGenerationModel
    private let streamSessionsDirectory: URL
    private let warmState: EngineWarmState
    private let timingOverridesMS: [String: Int]
    private let booleanFlags: [String: Bool]
    private let stringFlags: [String: String]
    private let cloneConditioning: ResolvedCloneConditioning?
    private let wasPrimed: Bool
    private let telemetryRecorder: NativeTelemetryRecorder?
    private let loadCapabilityProfile: NativeLoadCapabilityProfile
    private let memoryPolicy: NativeMemoryPolicy
    private let initialMLXMemorySnapshots: [String: NativeMLXMemorySnapshot]

    init(
        requestID: Int,
        request: GenerationRequest,
        model: UnsafeSpeechGenerationModel,
        streamSessionsDirectory: URL,
        warmState: EngineWarmState,
        timingOverridesMS: [String: Int] = [:],
        booleanFlags: [String: Bool] = [:],
        stringFlags: [String: String] = [:],
        cloneConditioning: ResolvedCloneConditioning? = nil,
        wasPrimed: Bool = false,
        telemetryRecorder: NativeTelemetryRecorder? = nil,
        loadCapabilityProfile: NativeLoadCapabilityProfile,
        memoryPolicy: NativeMemoryPolicy,
        mlxMemorySnapshots: [String: NativeMLXMemorySnapshot]
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
        self.wasPrimed = wasPrimed
        self.telemetryRecorder = telemetryRecorder
        self.loadCapabilityProfile = loadCapabilityProfile
        self.memoryPolicy = memoryPolicy
        self.initialMLXMemorySnapshots = mlxMemorySnapshots
    }

    func run(eventSink: @escaping @MainActor @Sendable (GenerationEvent) -> Void) async throws -> GenerationResult {
        let sessionDirectory = try makeSessionDirectory()
        let execution = StreamingExecutionContext(
            requestID: requestID,
            request: request,
            model: model,
            sessionDirectory: sessionDirectory,
            warmState: warmState,
            timingOverridesMS: timingOverridesMS,
            booleanFlags: booleanFlags,
            stringFlags: stringFlags,
            cloneConditioning: cloneConditioning,
            wasPrimed: wasPrimed,
            telemetryRecorder: telemetryRecorder,
            loadCapabilityProfile: loadCapabilityProfile,
            memoryPolicy: memoryPolicy,
            initialMLXMemorySnapshots: initialMLXMemorySnapshots
        )
        // `Task.detached` does not inherit the parent's cancellation, so we
        // explicitly forward cancellation through `withTaskCancellationHandler`.
        // Without this, cancelling the outer generation task leaves the
        // detached streaming task running and bypasses the retention-flag
        // `defer` cleanup (Tier 1.5).
        let task = Task.detached(priority: .userInitiated) {
            try await execution.run(eventSink: eventSink)
        }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        await eventSink(.completed(result))
        return result
    }

    private var previewTitle: String {
        String(request.text.prefix(40))
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

    nonisolated static func sessionDirectoryURL(in rootDirectory: URL, requestID: Int) -> URL {
        rootDirectory.appendingPathComponent(
            String(format: "session_%04d", requestID),
            isDirectory: true
        )
    }

    nonisolated static func chunkFileName(for chunkIndex: Int) -> String {
        String(format: "chunk_%04d.wav", chunkIndex)
    }

    nonisolated static func chunkURL(in sessionDirectory: URL, chunkIndex: Int) -> URL {
        sessionDirectory.appendingPathComponent(chunkFileName(for: chunkIndex))
    }

    nonisolated fileprivate static func buildStream(
        request: GenerationRequest,
        model: UnsafeSpeechGenerationModel,
        cloneConditioning: ResolvedCloneConditioning?,
        streamingInterval: Double
    ) throws -> AsyncThrowingStream<AudioGeneration, Error> {
        switch request.payload {
        case .clone:
            guard let cloneConditioning else {
                throw MLXTTSEngineError.generationFailed(
                    "Voice Cloning needs resolved native clone conditioning before generation."
                )
            }
            let language = GenerationSemantics.qwenLanguageHint(
                for: request,
                resolvedCloneTranscript: cloneConditioning.resolvedTranscript
            )
            if let voiceClonePrompt = cloneConditioning.voiceClonePrompt,
               model.supportsOptimizedVoiceClone {
                return model.generateVoiceCloneStream(
                    text: request.text,
                    language: language,
                    voiceClonePrompt: voiceClonePrompt,
                    streamingInterval: streamingInterval
                )
            }
            return model.generateStream(
                text: request.text,
                voice: nil,
                refAudio: cloneConditioning.referenceAudio,
                refText: cloneConditioning.resolvedTranscript,
                streamingInterval: streamingInterval
            )
        case .custom(let speakerID, let deliveryStyle):
            let language = GenerationSemantics.qwenLanguageHint(for: request)
            let speaker = speakerID.trimmingCharacters(in: .whitespacesAndNewlines)
            let instruct = GenerationSemantics.customInstruction(deliveryStyle: deliveryStyle)
            if model.supportsDedicatedCustomVoice {
                return model.generateCustomVoiceStream(
                    text: request.text,
                    language: language,
                    speaker: speaker,
                    instruct: instruct,
                    streamingInterval: streamingInterval
                )
            }
            return model.generateStream(
                text: request.text,
                voice: Self.fallbackCustomVoice(speaker: speaker, instruct: instruct),
                streamingInterval: streamingInterval
            )
        case .design(let voiceDescription, let deliveryStyle):
            let language = GenerationSemantics.qwenLanguageHint(for: request)
            let resolvedVoiceDescription = GenerationSemantics.designInstruction(
                voiceDescription: voiceDescription,
                emotion: deliveryStyle ?? ""
            )
            if model.supportsOptimizedVoiceDesign {
                return model.generateVoiceDesignStream(
                    text: request.text,
                    language: language,
                    voiceDescription: resolvedVoiceDescription,
                    streamingInterval: streamingInterval
                )
            }
            return model.generateStream(
                text: request.text,
                voice: resolvedVoiceDescription,
                streamingInterval: streamingInterval
            )
        }
    }

    nonisolated fileprivate static func conditioningVoice(for request: GenerationRequest) throws -> String {
        switch request.payload {
        case .custom(let speakerID, let deliveryStyle):
            let base = speakerID.capitalized
            guard let deliveryStyle,
                  GenerationSemantics.hasMeaningfulDeliveryInstruction(deliveryStyle) else {
                return base
            }
            return "\(base), \(deliveryStyle.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .design(let voiceDescription, let deliveryStyle):
            return GenerationSemantics.designInstruction(
                voiceDescription: voiceDescription,
                emotion: deliveryStyle ?? ""
            )
        case .clone:
            throw MLXTTSEngineError.generationFailed(
                "Voice Cloning should not request a direct voice string in the native session."
            )
        }
    }

    nonisolated fileprivate static func fallbackCustomVoice(
        speaker: String,
        instruct: String?
    ) -> String {
        let trimmedInstruction = instruct?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedInstruction.isEmpty else {
            return speaker
        }
        return "\(speaker), \(trimmedInstruction)"
    }
}

private enum PCM16WAVWriter {
    static func makeFormat(sampleRate: Int) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw MLXTTSEngineError.generationFailed("Could not allocate the native PCM output format.")
        }
        return format
    }

    static func pcmSamples(from samples: [Float]) -> [Int16] {
        samples.map { sample in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16((clamped * Float(Int16.max)).rounded())
        }
    }

    static func makePCMBuffer(
        pcmSamples: [Int16],
        format: AVAudioFormat,
        reusableBuffer: inout AVAudioPCMBuffer?
    ) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(pcmSamples.count)
        if reusableBuffer?.frameCapacity ?? 0 < frameCount {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            ) else {
                throw MLXTTSEngineError.generationFailed("Could not allocate the native PCM output buffer.")
            }
            reusableBuffer = buffer
        }

        guard let buffer = reusableBuffer,
              let channelData = buffer.int16ChannelData?[0] else {
            throw MLXTTSEngineError.generationFailed("Could not allocate the native PCM output buffer.")
        }

        buffer.frameLength = frameCount
        pcmSamples.withUnsafeBufferPointer { pointer in
            channelData.update(from: pointer.baseAddress!, count: pcmSamples.count)
        }
        return buffer
    }
}

private final class PCM16ScratchBuffer {
    private var storage: [Int16] = []

    func convertClamped(_ samples: [Float]) -> [Int16] {
        storage.removeAll(keepingCapacity: true)
        storage.reserveCapacity(samples.count)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            storage.append(Int16((clamped * Float(Int16.max)).rounded()))
        }
        return storage
    }

    func pcm16LittleEndianData(from pcmSamples: [Int16]) -> Data {
        pcmSamples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return Data() }
            return Data(
                bytes: UnsafeRawPointer(baseAddress),
                count: pointer.count * MemoryLayout<Int16>.stride
            )
        }
    }
}

private final class PCM16ChunkFileWriter {
    private let format: AVAudioFormat
    private var reusableBuffer: AVAudioPCMBuffer?

    init(sampleRate: Int) throws {
        self.format = try PCM16WAVWriter.makeFormat(sampleRate: sampleRate)
    }

    func write(pcmSamples: [Int16], to url: URL) throws {
        let buffer = try PCM16WAVWriter.makePCMBuffer(
            pcmSamples: pcmSamples,
            format: format,
            reusableBuffer: &reusableBuffer
        )
        let temporaryURL = Self.temporaryURL(for: url)
        try? FileManager.default.removeItem(at: temporaryURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        // Hold AVAudioFile in a narrow scope so ARC guarantees its deinit
        // fires at the closing brace. AVAudioFile writes the final WAV/RIFF
        // `data`-chunk size field on deinit, not on write(from:), so this
        // deterministic teardown is the first half of correct finalization.
        do {
            let file = try AVAudioFile(
                forWriting: temporaryURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            try file.write(from: buffer)
        }
        // Force the kernel to commit the completed WAV so cross-process
        // readers (the UI's AVAudioFile(forReading:) in
        // AudioPlayerViewModel.loadPCMBuffer) observe a non-zero-length file.
        // Without this, chunk consumers intermittently saw audioFile.length
        // == 0 and the UI surfaced "Live audio preview could not decode the
        // latest chunk." even though the file eventually finalized correctly.
        if let handle = try? FileHandle(forWritingTo: temporaryURL) {
            try? handle.synchronize()
            try? handle.close()
        }
        try Self.publishAtomically(temporaryURL: temporaryURL, finalURL: url)
    }

    private static func temporaryURL(for finalURL: URL) -> URL {
        let filename = finalURL.lastPathComponent
        return finalURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(filename).\(UUID().uuidString).tmp")
    }

    private static func publishAtomically(temporaryURL: URL, finalURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: finalURL.path) {
            _ = try fileManager.replaceItemAt(
                finalURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
        }
    }
}

private final class IncrementalPCM16WAVFileWriter {
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private var reusableBuffer: AVAudioPCMBuffer?

    init(sampleRate: Int, outputURL: URL) throws {
        self.format = try PCM16WAVWriter.makeFormat(sampleRate: sampleRate)
        self.file = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    func append(pcmSamples: [Int16]) throws {
        let buffer = try PCM16WAVWriter.makePCMBuffer(
            pcmSamples: pcmSamples,
            format: format,
            reusableBuffer: &reusableBuffer
        )
        try file.write(from: buffer)
    }

    func finish() {
        reusableBuffer = nil
    }
}

private struct StreamingExecutionContext: Sendable {
    let requestID: Int
    let request: GenerationRequest
    let model: UnsafeSpeechGenerationModel
    let sessionDirectory: URL
    let warmState: EngineWarmState
    let timingOverridesMS: [String: Int]
    let booleanFlags: [String: Bool]
    let stringFlags: [String: String]
    let cloneConditioning: ResolvedCloneConditioning?
    let wasPrimed: Bool
    let telemetryRecorder: NativeTelemetryRecorder?
    let loadCapabilityProfile: NativeLoadCapabilityProfile
    let memoryPolicy: NativeMemoryPolicy
    let initialMLXMemorySnapshots: [String: NativeMLXMemorySnapshot]

    var previewTitle: String {
        String(request.text.prefix(40))
    }

    func run(eventSink: @escaping @MainActor @Sendable (GenerationEvent) -> Void) async throws -> GenerationResult {
        let startedAt = ContinuousClock.now
        let outputURL = URL(fileURLWithPath: request.outputPath)
        let sampleRate = model.sampleRate
        let telemetryMode = NativeTelemetryMode.current()
        let telemetrySampler = telemetryMode.sampleIntervalMS.map {
            NativeTelemetrySampler(
                startUptimeSeconds: ProcessInfo.processInfo.systemUptime,
                sampleIntervalMS: $0
            )
        }
        await telemetrySampler?.start()
        await telemetryRecorder?.mark(stage: .streamStartup)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Retention flag flipped to true only on the successful-return path.
        // Any error or cancellation between directory creation and successful
        // return cleans up the session directory and the partially-written
        // output file so they cannot leak (Tier 1.5).
        var shouldRetainSession = false
        defer {
            if !shouldRetainSession {
                try? FileManager.default.removeItem(at: sessionDirectory)
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        var generationInfo: AudioGenerationInfo?
        var chunkIndex = 0
        var firstAudioReadyMS: Int?
        var totalFramesWritten: Int64 = 0
        var totalChunkFrames = 0
        var maxChunkFrames = 0
        var chunkWriteTotalMS = 0
        var chunkWriteMaxMS = 0
        var finalWriteMS = 0
        var eventDispatchMS = 0
        var mlxMemorySnapshots = initialMLXMemorySnapshots
        mlxMemorySnapshots["before_stream"] = NativeMemoryPolicyResolver.snapshot()
        let streamingOutputPolicy = NativeStreamingOutputPolicy.current()
        let chunkWriter = streamingOutputPolicy == .pcmPreviewAndFileArtifacts
            ? try PCM16ChunkFileWriter(sampleRate: sampleRate)
            : nil
        let scratchBuffer = PCM16ScratchBuffer()
        let finalWriter = try IncrementalPCM16WAVFileWriter(
            sampleRate: sampleRate,
            outputURL: outputURL
        )
        defer {
            finalWriter.finish()
        }

        let streamingInterval = request.streamingInterval ?? Self.adaptiveStreamingInterval(
            for: request,
            memoryPolicy: memoryPolicy
        )
        let stream = try NativeStreamingSynthesisSession.buildStream(
            request: request,
            model: model,
            cloneConditioning: cloneConditioning,
            streamingInterval: streamingInterval
        )

        do {
            for try await event in stream {
                // AsyncThrowingStream iterators do not automatically observe
                // cancellation of the consuming task when the producer is
                // running in its own independent Task. Check explicitly so
                // the detached streaming task exits promptly when the outer
                // generate() task is cancelled (Tier 1.5 / 4.3).
                try Task.checkCancellation()

                switch event {
                case .token:
                    continue
                case .info(let info):
                    generationInfo = info
                case .audio(let samples):
                    let chunkSamples = samples.asArray(Float.self)
                    guard !chunkSamples.isEmpty else { continue }

                    if firstAudioReadyMS == nil {
                        firstAudioReadyMS = startedAt.duration(to: .now).roundedMilliseconds
                        await telemetryRecorder?.mark(
                            stage: .firstChunk,
                            metadata: ["chunk_index": String(chunkIndex)]
                        )
                        mlxMemorySnapshots["first_chunk"] = NativeMemoryPolicyResolver.snapshot()
                    }

                    let pcmSamples = scratchBuffer.convertClamped(chunkSamples)
                    let frameOffset = totalFramesWritten
                    let previewData = scratchBuffer.pcm16LittleEndianData(from: pcmSamples)
                    var chunkPath: String?

                    if let chunkWriter {
                        let chunkURL = NativeStreamingSynthesisSession.chunkURL(
                            in: sessionDirectory,
                            chunkIndex: chunkIndex
                        )
                        let chunkWriteMS = try autoreleasepool { () throws -> Int in
                            let chunkWriteStartedAt = ContinuousClock.now
                            try chunkWriter.write(
                                pcmSamples: pcmSamples,
                                to: chunkURL
                            )
                            return chunkWriteStartedAt.elapsedMilliseconds
                        }
                        chunkPath = chunkURL.path
                        chunkWriteTotalMS += chunkWriteMS
                        chunkWriteMaxMS = max(chunkWriteMaxMS, chunkWriteMS)
                    }

                    let appendMS = try autoreleasepool { () throws -> Int in
                        let finalAppendStartedAt = ContinuousClock.now
                        try finalWriter.append(pcmSamples: pcmSamples)
                        return finalAppendStartedAt.elapsedMilliseconds
                    }
                    finalWriteMS += appendMS

                    chunkIndex += 1
                    totalFramesWritten += Int64(pcmSamples.count)
                    totalChunkFrames += pcmSamples.count
                    maxChunkFrames = max(maxChunkFrames, pcmSamples.count)

                    let chunkDurationSeconds = Double(pcmSamples.count) / Double(sampleRate)
                    let cumulativeDurationSeconds = Double(totalFramesWritten) / Double(sampleRate)
                    let chunkEvent = GenerationEvent.chunk(
                        GenerationChunk(
                            requestID: requestID,
                            mode: request.modeIdentifier,
                            title: previewTitle,
                            chunkPath: chunkPath,
                            isFinal: false,
                            chunkDurationSeconds: chunkDurationSeconds,
                            cumulativeDurationSeconds: cumulativeDurationSeconds,
                            streamSessionDirectory: sessionDirectory.path,
                            previewAudio: StreamingAudioChunk(
                                requestID: requestID,
                                sampleRate: sampleRate,
                                frameOffset: frameOffset,
                                frameCount: pcmSamples.count,
                                pcm16LE: previewData,
                                isFinal: false
                            )
                        )
                    )

                    let dispatchStartedAt = ContinuousClock.now
                    await eventSink(chunkEvent)
                    eventDispatchMS += dispatchStartedAt.elapsedMilliseconds
                }
            }
        } catch {
            await telemetryRecorder?.mark(
                stage: .streamFailed,
                metadata: ["message": error.localizedDescription]
            )
            _ = await Self.stopTelemetrySampler(
                telemetrySampler,
                stageMarks: await telemetryRecorder?.snapshot() ?? []
            )
            finalWriter.finish()
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: sessionDirectory)
            throw error
        }

        guard totalFramesWritten > 0 else {
            throw MLXTTSEngineError.generationFailed("The native engine did not emit any audio chunks.")
        }

        let finalizeStartedAt = ContinuousClock.now
        finalWriter.finish()
        finalWriteMS += finalizeStartedAt.elapsedMilliseconds
        mlxMemorySnapshots["after_final_write"] = NativeMemoryPolicyResolver.snapshot()

        let generationMS = startedAt.duration(to: .now).roundedMilliseconds
        let durationSeconds = Double(totalFramesWritten) / Double(sampleRate)
        let stageMarks = await telemetryRecorder?.snapshot() ?? []
        let telemetryCapture = await Self.stopTelemetrySampler(
            telemetrySampler,
            stageMarks: stageMarks
        )
        let telemetrySummary = telemetryCapture.summary
        mlxMemorySnapshots["after_stream"] = NativeMemoryPolicyResolver.snapshot()
        if memoryPolicy.clearCacheAfterGeneration {
            Memory.clearCache()
            mlxMemorySnapshots["after_generation_trim"] = NativeMemoryPolicyResolver.snapshot()
        }
        let benchmarkSample = makeBenchmarkSample(
            generationInfo: generationInfo,
            firstAudioReadyMS: firstAudioReadyMS,
            generationMS: generationMS,
            finalWriteMS: finalWriteMS,
            chunkWriteTotalMS: chunkWriteTotalMS,
            chunkWriteMaxMS: chunkWriteMaxMS,
            eventDispatchMS: eventDispatchMS,
            streamChunkCount: chunkIndex,
            averageChunkFrames: chunkIndex > 0 ? (totalChunkFrames / chunkIndex) : 0,
            maxChunkFrames: maxChunkFrames,
            telemetrySummary: telemetrySummary,
            telemetrySamples: telemetryCapture.samples,
            telemetryStageMarks: stageMarks,
            mlxMemorySnapshots: mlxMemorySnapshots,
            telemetryMode: telemetryMode,
            streamingOutputPolicy: streamingOutputPolicy,
            durationSeconds: durationSeconds
        )
        await telemetryRecorder?.mark(stage: .streamCompleted)

        shouldRetainSession = true
        return GenerationResult(
            audioPath: outputURL.path,
            durationSeconds: durationSeconds,
            streamSessionDirectory: sessionDirectory.path,
            benchmarkSample: benchmarkSample
        )
    }

    private func makeBenchmarkSample(
        generationInfo: AudioGenerationInfo?,
        firstAudioReadyMS: Int?,
        generationMS: Int,
        finalWriteMS: Int,
        chunkWriteTotalMS: Int,
        chunkWriteMaxMS: Int,
        eventDispatchMS: Int,
        streamChunkCount: Int,
        averageChunkFrames: Int,
        maxChunkFrames: Int,
        telemetrySummary: TelemetrySummary,
        telemetrySamples: [TelemetrySample],
        telemetryStageMarks: [NativeTelemetryStageMark],
        mlxMemorySnapshots: [String: NativeMLXMemorySnapshot],
        telemetryMode: NativeTelemetryMode,
        streamingOutputPolicy: NativeStreamingOutputPolicy,
        durationSeconds: Double
    ) -> BenchmarkSample {
        var timingsMS = timingOverridesMS
        for (key, value) in model.latestPreparationTimingsMS {
            timingsMS[key] = value
        }
        timingsMS["generation"] = generationMS
        timingsMS["final_write"] = finalWriteMS
        timingsMS["chunk_write_total"] = chunkWriteTotalMS
        timingsMS["chunk_write_max"] = chunkWriteMaxMS
        timingsMS["event_dispatch_ms"] = eventDispatchMS
        timingsMS["stream_chunk_count"] = streamChunkCount
        timingsMS["avg_chunk_frames"] = averageChunkFrames
        timingsMS["max_chunk_frames"] = maxChunkFrames
        if let firstAudioReadyMS {
            timingsMS["first_audio_ready"] = firstAudioReadyMS
            timingsMS["first_stream_chunk"] = firstAudioReadyMS
        }

        let tokenCount = generationInfo.map { $0.promptTokenCount + $0.generationTokenCount }
        let processingTimeSeconds = generationInfo.map { $0.prefillTime + $0.generateTime }
        let audioSecondsPerWallSecond = generationMS > 0
            ? durationSeconds / (Double(generationMS) / 1_000)
            : nil

        return BenchmarkSample(
            engineKind: .nativeMLX,
            warmState: warmState,
            tokenCount: tokenCount,
            processingTimeSeconds: processingTimeSeconds,
            peakMemoryUsage: generationInfo?.peakMemoryUsage,
            streamingUsed: true,
            preparedCloneUsed: cloneConditioning?.preparedCloneUsed,
            cloneCacheHit: cloneConditioning?.cloneCacheHit,
            firstChunkMs: firstAudioReadyMS,
            peakResidentMB: telemetrySummary.residentPeakMB,
            peakPhysFootprintMB: telemetrySummary.physFootprintPeakMB,
            residentStartMB: telemetrySummary.residentStartMB,
            residentEndMB: telemetrySummary.residentEndMB,
            compressedPeakMB: telemetrySummary.compressedPeakMB,
            headroomStartMB: telemetrySummary.headroomStartMB,
            headroomEndMB: telemetrySummary.headroomEndMB,
            headroomMinMB: telemetrySummary.headroomMinMB,
            gpuAllocatedPeakMB: telemetrySummary.gpuAllocatedPeakMB,
            gpuRecommendedWorkingSetMB: telemetrySummary.gpuRecommendedWorkingSetMB,
            telemetryEnabled: telemetryMode != .off,
            telemetrySamples: telemetrySamples,
            telemetryStageMarks: telemetryStageMarks,
            timingsMS: timingsMS,
            booleanFlags: mergedBooleanFlags(),
            stringFlags: mergedStringFlags(
                telemetryMode: telemetryMode,
                streamingOutputPolicy: streamingOutputPolicy
            ),
            backendPerformance: NativeBackendPerformanceSample(
                coldLoadMS: timingsMS["load_model"],
                warmGenerationMS: generationMS,
                timeToFirstAudioMS: firstAudioReadyMS,
                audioSecondsPerWallSecond: audioSecondsPerWallSecond,
                chunkWriteTotalMS: chunkWriteTotalMS,
                chunkWriteMaxMS: chunkWriteMaxMS,
                eventDispatchMS: eventDispatchMS,
                finalWriteMS: finalWriteMS,
                mlxMemoryByStage: mlxMemorySnapshots,
                loadCapabilityProfile: loadCapabilityProfile.rawValue,
                memoryPolicyName: memoryPolicy.name,
                streamingTransport: streamingOutputPolicy.rawValue,
                telemetryMode: telemetryMode.rawValue
            )
        )
    }

    private func mergedBooleanFlags() -> [String: Bool] {
        var merged = booleanFlags
        for (key, value) in model.latestPreparationBooleanFlags {
            merged[key] = value
        }
        if let cloneConditioning {
            merged["used_temp_reference"] = cloneConditioning.usedTemporaryReference
            merged["primed"] = wasPrimed
            merged["clone_conditioning_reused"] =
                (merged["clone_conditioning_reused"] ?? false)
                || cloneConditioning.cloneConditioningReused
            merged["reused_normalized_reference"] = cloneConditioning.reusedNormalizedReference
            merged["reused_decoded_reference"] = cloneConditioning.reusedDecodedReference
            merged["normalized_reference_reused"] = cloneConditioning.reusedNormalizedReference
            merged["decoded_reference_reused"] = cloneConditioning.reusedDecodedReference
            if let cloneCacheHit = cloneConditioning.cloneCacheHit {
                merged["prepared_clone_cache_hit"] = cloneCacheHit
            }
            if let clonePromptCacheHit = cloneConditioning.clonePromptCacheHit {
                merged["clone_prompt_cache_hit"] = clonePromptCacheHit
            }
            if cloneConditioning.voiceClonePrompt != nil {
                merged["clone_prompt_used"] = true
            }
        }
        return merged
    }

    private func mergedStringFlags(
        telemetryMode: NativeTelemetryMode,
        streamingOutputPolicy: NativeStreamingOutputPolicy
    ) -> [String: String] {
        var merged = stringFlags
        merged["native_load_capability_profile"] = loadCapabilityProfile.rawValue
        merged["memory_policy"] = memoryPolicy.name
        merged["streaming_transport"] = streamingOutputPolicy.rawValue
        merged["telemetry_mode"] = telemetryMode.rawValue
        if let cloneConditioning {
            merged["resolved_transcript_mode"] = cloneConditioning.transcriptMode.rawValue
        }
        return merged
    }

    private static func adaptiveStreamingInterval(
        for request: GenerationRequest,
        memoryPolicy: NativeMemoryPolicy
    ) -> Double {
        if request.batchTotal != nil {
            return 0.8
        }
        switch memoryPolicy.deviceClass {
        case .floor8GBMac, .iPhonePro:
            return 0.6
        case .mid16GBMac, .highMemoryMac:
            return 0.4
        }
    }

    private static func stopTelemetrySampler(
        _ telemetrySampler: NativeTelemetrySampler?,
        stageMarks: [NativeTelemetryStageMark]
    ) async -> (summary: TelemetrySummary, samples: [TelemetrySample]) {
        guard let telemetrySampler else {
            return (
                TelemetrySummary(
                    residentStartMB: nil,
                    residentEndMB: nil,
                    residentPeakMB: nil,
                    physFootprintPeakMB: nil,
                    compressedPeakMB: nil,
                    headroomStartMB: nil,
                    headroomEndMB: nil,
                    headroomMinMB: nil,
                    gpuAllocatedPeakMB: nil,
                    gpuRecommendedWorkingSetMB: nil,
                    timeToPeakMS: nil,
                    sampleCount: 0,
                    stageMarks: stageMarks
                ),
                []
            )
        }
        return await telemetrySampler.stop(stageMarks: stageMarks)
    }
}
