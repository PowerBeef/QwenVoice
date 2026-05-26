import AVFoundation
import Foundation
import MLX
import MLXAudioCore
@preconcurrency import MLXAudioTTS
@preconcurrency import QwenVoiceBackendCore
import OSLog

// MARK: - QwenVoiceCore Runtime Ownership
//
// `NativeStreamingSynthesisSession` is now owned by `QwenVoiceCore` and is
// shared by the active macOS XPC service and iPhone engine-extension paths.
// Keep behavior changes here aligned with the platform host adapters.

protocol NativeStreamingSessionRunning {
    func run(eventSink: @escaping @MainActor @Sendable (GenerationEvent) -> Void) async throws -> GenerationResult
}

private enum NativeStreamingSignposts {
    static let signposter = OSSignposter(
        subsystem: "com.qwenvoice.engine",
        category: "generation"
    )

    /// Used to surface model/runtime instability (NaN/Inf samples) caught
    /// by `PCM16StreamLimiter` before it could poison PCM output or derived
    /// numeric metadata. Anything non-zero indicates the upstream MLX
    /// generation produced unstable samples that the limiter scrubbed.
    static let logger = Logger(
        subsystem: "com.qwenvoice.engine",
        category: "generation"
    )
}

final class NativeStreamingSynthesisSession: NativeStreamingSessionRunning, @unchecked Sendable {
    private let generationID: UUID
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
    private let qwen3Capabilities: Qwen3TTSModelCapabilities
    private let memoryPolicy: NativeMemoryPolicy
    private let initialMLXMemorySnapshots: [String: NativeMLXMemorySnapshot]
    private let pcmScratchBuffer: PCM16ScratchBuffer?

    init(
        generationID: UUID,
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
        qwen3Capabilities: Qwen3TTSModelCapabilities,
        memoryPolicy: NativeMemoryPolicy,
        mlxMemorySnapshots: [String: NativeMLXMemorySnapshot],
        pcmScratchBuffer: PCM16ScratchBuffer? = nil
    ) {
        self.generationID = generationID
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
        self.qwen3Capabilities = qwen3Capabilities
        self.memoryPolicy = memoryPolicy
        self.initialMLXMemorySnapshots = mlxMemorySnapshots
        self.pcmScratchBuffer = pcmScratchBuffer
    }

    func run(eventSink: @escaping @MainActor @Sendable (GenerationEvent) -> Void) async throws -> GenerationResult {
        if !request.shouldStream {
            let sessionDirectory = try makeSessionDirectory()
            let execution = StreamingExecutionContext(
                requestID: requestID,
                generationID: generationID,
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
                qwen3Capabilities: qwen3Capabilities,
                memoryPolicy: memoryPolicy,
                initialMLXMemorySnapshots: initialMLXMemorySnapshots,
                pcmScratchBuffer: pcmScratchBuffer
            )
            let task = Task.detached(priority: .userInitiated) {
                try await execution.runQualityFirstFinalAudio()
            }
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            await eventSink(.completed(result))
            return result
        }

        let sessionDirectory = try makeSessionDirectory()
        let execution = StreamingExecutionContext(
            requestID: requestID,
            generationID: generationID,
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
            qwen3Capabilities: qwen3Capabilities,
            memoryPolicy: memoryPolicy,
            initialMLXMemorySnapshots: initialMLXMemorySnapshots,
            pcmScratchBuffer: pcmScratchBuffer
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
        qwen3Capabilities: Qwen3TTSModelCapabilities,
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
            guard let voiceClonePrompt = cloneConditioning.voiceClonePrompt else {
                throw MLXTTSEngineError.unsupportedRequest(
                    "Voice Cloning requires optimized Qwen3 clone conditioning."
                )
            }
            return model.generateVoiceCloneStream(
                text: request.text,
                language: language,
                voiceClonePrompt: voiceClonePrompt,
                streamingInterval: streamingInterval
            )
        case .custom:
            let prompt = GenerationSemantics.qwen3PromptAssembly(
                for: request,
                capabilities: qwen3Capabilities
            )
            let speaker = prompt.speakerID ?? GenerationSemantics.canonicalCustomWarmSpeaker
            return model.generateCustomVoiceStream(
                text: request.text,
                language: prompt.language,
                speaker: speaker,
                instruct: prompt.instruct,
                streamingInterval: streamingInterval
            )
        case .design:
            let prompt = GenerationSemantics.qwen3PromptAssembly(
                for: request,
                capabilities: qwen3Capabilities
            )
            return model.generateVoiceDesignStream(
                text: request.text,
                language: prompt.language,
                voiceDescription: prompt.instruct ?? "",
                streamingInterval: streamingInterval
            )
        }
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
            // NaN/Inf survive `max/min` comparisons (NaN comparisons always
            // return false), so without an explicit isFinite guard the Int16
            // conversion below would trap or produce undefined output and
            // also taint any derived numeric metadata (RMS, peak, duration)
            // that flows over IPC and breaks JSON-based encoders.
            let finiteSample = sample.isFinite ? sample : 0
            let clamped = max(-1.0, min(1.0, finiteSample))
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

private enum AtomicFilePublisher {
    static func temporaryURL(for finalURL: URL) -> URL {
        let filename = finalURL.lastPathComponent
        return finalURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(filename).\(UUID().uuidString).tmp")
    }

    static func publishAtomically(temporaryURL: URL, finalURL: URL) throws {
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

private enum AtomicPCM16WAVWriter {
    static func write(
        pcmSamples: [Int16],
        sampleRate: Int,
        outputURL: URL
    ) throws {
        let temporaryURL = AtomicFilePublisher.temporaryURL(for: outputURL)
        try? FileManager.default.removeItem(at: temporaryURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        let header: Data = try {
            let headerSignpost = NativeStreamingSignposts.signposter.beginInterval(
                "Native Final WAV Manual Header Build"
            )
            defer {
                NativeStreamingSignposts.signposter.endInterval(
                    "Native Final WAV Manual Header Build",
                    headerSignpost
                )
            }
            return try makeHeader(sampleRate: sampleRate, frameCount: pcmSamples.count)
        }()

        try {
            let fileWriteSignpost = NativeStreamingSignposts.signposter.beginInterval(
                "Native Final WAV Manual File Write",
            )
            defer {
                NativeStreamingSignposts.signposter.endInterval(
                    "Native Final WAV Manual File Write",
                    fileWriteSignpost
                )
            }
            try write(header: header, pcmSamples: pcmSamples, to: temporaryURL)
        }()

        try {
            let publishSignpost = NativeStreamingSignposts.signposter.beginInterval(
                "Native Final WAV Manual Publish",
            )
            defer {
                NativeStreamingSignposts.signposter.endInterval(
                    "Native Final WAV Manual Publish",
                    publishSignpost
                )
            }
            try AtomicFilePublisher.publishAtomically(
                temporaryURL: temporaryURL,
                finalURL: outputURL
            )
        }()
    }

    private static func makeHeader(sampleRate: Int, frameCount: Int) throws -> Data {
        guard sampleRate > 0 else {
            throw MLXTTSEngineError.generationFailed("The native WAV writer received an invalid sample rate.")
        }
        let bytesPerSample = 2
        let dataByteCount = frameCount * bytesPerSample
        guard dataByteCount <= Int(UInt32.max) - 36 else {
            throw MLXTTSEngineError.generationFailed("The native WAV writer output is too large for RIFF/WAVE.")
        }

        var data = Data()
        data.reserveCapacity(44)
        appendASCII("RIFF", to: &data)
        appendUInt32LE(UInt32(36 + dataByteCount), to: &data)
        appendASCII("WAVE", to: &data)
        appendASCII("fmt ", to: &data)
        appendUInt32LE(16, to: &data)
        appendUInt16LE(1, to: &data) // PCM
        appendUInt16LE(1, to: &data) // mono
        appendUInt32LE(UInt32(sampleRate), to: &data)
        appendUInt32LE(UInt32(sampleRate * bytesPerSample), to: &data)
        appendUInt16LE(UInt16(bytesPerSample), to: &data)
        appendUInt16LE(16, to: &data)
        appendASCII("data", to: &data)
        appendUInt32LE(UInt32(dataByteCount), to: &data)
        return data
    }

    private static func write(
        header: Data,
        pcmSamples: [Int16],
        to url: URL
    ) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw MLXTTSEngineError.generationFailed("Could not create the native WAV output file.")
        }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.write(contentsOf: header)
            let pcmData = pcmSamples.withUnsafeBufferPointer { pointer -> Data in
                guard let baseAddress = pointer.baseAddress else { return Data() }
                return Data(
                    bytes: UnsafeRawPointer(baseAddress),
                    count: pointer.count * MemoryLayout<Int16>.stride
                )
            }
            try handle.write(contentsOf: pcmData)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private static func appendASCII(_ value: String, to data: inout Data) {
        data.append(contentsOf: value.utf8)
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
        ])
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ])
    }
}

/// Per-session PCM16 conversion scratch space + limiter state. Lives as a
/// reference type so callers higher up the stack can choose to pool it
/// across generations (the underlying `[Int16]` capacity is the largest
/// per-generation allocation). Within a single session, `convertLimited`
/// reuses `storage` via `removeAll(keepingCapacity: true)`. `reset()` is
/// what pool callers should invoke between leases — it clears storage AND
/// the limiter so two different audio streams don't inherit each other's
/// gain state.
/// `@unchecked Sendable`: this is a reference type with mutable state, but
/// the contract is that a single session/execution owns it at a time —
/// callers serialize access via the session lifecycle. When pooled across
/// sessions, the pool itself (e.g. the engine) is responsible for
/// returning a buffer to the pool only after the lease has finished.
final class PCM16ScratchBuffer: @unchecked Sendable {
    private var storage: [Int16] = []
    private var limiter = PCM16StreamLimiter()

    init() {}

    var limiterMetrics: PCM16StreamLimiter.Metrics {
        limiter.metrics
    }

    func convertLimited(_ samples: [Float]) -> [Int16] {
        storage.removeAll(keepingCapacity: true)
        storage.reserveCapacity(samples.count)
        limiter.append(samples, into: &storage)
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

    /// Clear storage length-to-zero (preserving capacity) and rebuild the
    /// limiter from scratch. Callers pooling this buffer across sessions
    /// must call this before each new lease — otherwise the limiter's
    /// `currentGain` / `previousOutput` from the previous generation
    /// would carry into the next, producing audible discontinuities at
    /// the start of the new audio.
    func reset() {
        storage.removeAll(keepingCapacity: true)
        limiter = PCM16StreamLimiter()
    }
}

struct PCM16StreamLimiter: Sendable {
    struct Metrics: Equatable, Sendable {
        var rawPeak: Float = 0
        var limitedPeak: Float = 0
        var samplesAboveCeiling = 0
        var samplesOutsideUnitRange = 0
        var slewLimitedSamples = 0
        var processedSamples = 0
        // Count of non-finite (NaN/Inf) samples observed at the limiter's
        // input. These are replaced with `0` before any gain math runs —
        // otherwise NaN propagates through the `max/min` clamps (NaN
        // comparisons always return false) and turns into undefined Int16
        // output plus non-finite derived metadata that breaks JSON-encoded
        // IPC payloads downstream.
        var nonFiniteSamples = 0
        var minimumAppliedGain: Float = 1

        private static func partsPerMillion(_ value: Float) -> Int {
            Int((Double(value) * 1_000_000).rounded())
        }
    }

    static let ceiling: Float = 0.965
    static let maxSingleSampleStep: Float = 0.42
    static let releaseStepPerSample: Float = 0.002

    private var currentGain: Float = 1
    private var previousOutput: Float?
    private(set) var metrics = Metrics()

    mutating func append(_ samples: [Float], into destination: inout [Int16]) {
        for rawSample in samples {
            // Sanitize NaN/Inf at the source. Anything past this guard is
            // safe to feed into gain/limiter math without poisoning the
            // derived metrics or the Int16 conversion below.
            let sample: Float
            if rawSample.isFinite {
                sample = rawSample
            } else {
                metrics.nonFiniteSamples += 1
                sample = 0
            }
            let rawMagnitude = abs(sample)
            metrics.rawPeak = max(metrics.rawPeak, rawMagnitude)
            metrics.processedSamples += 1
            if rawMagnitude > Self.ceiling {
                metrics.samplesAboveCeiling += 1
            }
            if rawMagnitude > 1 {
                metrics.samplesOutsideUnitRange += 1
            }

            let targetGain = rawMagnitude > Self.ceiling
                ? Self.ceiling / max(rawMagnitude, .leastNonzeroMagnitude)
                : 1
            if targetGain < currentGain {
                currentGain = targetGain
            } else {
                currentGain = min(targetGain, currentGain + Self.releaseStepPerSample)
            }
            metrics.minimumAppliedGain = min(metrics.minimumAppliedGain, currentGain)

            var limited = sample * currentGain
            if let previousOutput {
                let delta = limited - previousOutput
                if delta > Self.maxSingleSampleStep {
                    limited = previousOutput + Self.maxSingleSampleStep
                    metrics.slewLimitedSamples += 1
                } else if delta < -Self.maxSingleSampleStep {
                    limited = previousOutput - Self.maxSingleSampleStep
                    metrics.slewLimitedSamples += 1
                }
            }

            limited = max(-Self.ceiling, min(Self.ceiling, limited))
            previousOutput = limited
            metrics.limitedPeak = max(metrics.limitedPeak, abs(limited))
            destination.append(Int16((limited * Float(Int16.max)).rounded()))
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
        AtomicFilePublisher.temporaryURL(for: finalURL)
    }

    private static func publishAtomically(temporaryURL: URL, finalURL: URL) throws {
        try AtomicFilePublisher.publishAtomically(
            temporaryURL: temporaryURL,
            finalURL: finalURL
        )
    }
}

private final class IncrementalPCM16WAVFileWriter {
    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private var reusableBuffer: AVAudioPCMBuffer?

    init(sampleRate: Int, outputURL: URL) throws {
        let createSignpost = NativeStreamingSignposts.signposter.beginInterval(
            "Native Final WAV Writer Create"
        )
        defer {
            NativeStreamingSignposts.signposter.endInterval(
                "Native Final WAV Writer Create",
                createSignpost
            )
        }
        self.format = try PCM16WAVWriter.makeFormat(sampleRate: sampleRate)
        self.file = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    func append(pcmSamples: [Int16]) throws {
        let bufferSignpost = NativeStreamingSignposts.signposter.beginInterval(
            "Native Final WAV Buffer Build"
        )
        let buffer = try PCM16WAVWriter.makePCMBuffer(
            pcmSamples: pcmSamples,
            format: format,
            reusableBuffer: &reusableBuffer
        )
        NativeStreamingSignposts.signposter.endInterval(
            "Native Final WAV Buffer Build",
            bufferSignpost
        )

        guard let file else {
            throw MLXTTSEngineError.generationFailed("The native WAV writer was already finalized.")
        }
        let writeSignpost = NativeStreamingSignposts.signposter.beginInterval(
            "Native Final WAV AVAudioFile Write"
        )
        try file.write(from: buffer)
        NativeStreamingSignposts.signposter.endInterval(
            "Native Final WAV AVAudioFile Write",
            writeSignpost
        )
    }

    func finish() {
        let finalizeSignpost = NativeStreamingSignposts.signposter.beginInterval(
            "Native Final WAV AVAudioFile Finalize"
        )
        reusableBuffer = nil
        file = nil
        NativeStreamingSignposts.signposter.endInterval(
            "Native Final WAV AVAudioFile Finalize",
            finalizeSignpost
        )
    }
}

private struct StreamingExecutionContext: Sendable {
    let requestID: Int
    let generationID: UUID
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
    let qwen3Capabilities: Qwen3TTSModelCapabilities
    let memoryPolicy: NativeMemoryPolicy
    let initialMLXMemorySnapshots: [String: NativeMLXMemorySnapshot]
    /// Optional pooled scratch buffer shared with the parent session.
    /// When provided, the execution context calls `reset()` and reuses
    /// it instead of allocating a fresh `PCM16ScratchBuffer`. Saves the
    /// per-generation Int16-array allocation (~1-2 MB for a typical
    /// medium-length output) and lets the underlying capacity grow once
    /// to high-water mark and stay there across generations.
    let pcmScratchBuffer: PCM16ScratchBuffer?

    private func scratchBuffer() -> PCM16ScratchBuffer {
        if let pooled = pcmScratchBuffer {
            pooled.reset()
            return pooled
        }
        return PCM16ScratchBuffer()
    }

    var previewTitle: String {
        String(request.text.prefix(40))
    }

    func runQualityFirstFinalAudio() async throws -> GenerationResult {
        let generationSignpost = NativeStreamingSignposts.signposter.beginInterval("Native Quality-First Generation")
        defer {
            NativeStreamingSignposts.signposter.endInterval("Native Quality-First Generation", generationSignpost)
        }

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

        var shouldRetainOutput = false
        defer {
            if !shouldRetainOutput {
                try? FileManager.default.removeItem(at: sessionDirectory)
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        var mlxMemorySnapshots = initialMLXMemorySnapshots
        mlxMemorySnapshots["before_quality_generation"] = NativeMemoryPolicyResolver.snapshot()
        let completion: AudioGenerationCompletion
        do {
            completion = try await generateQualityFirstAudio()
        } catch {
            await telemetryRecorder?.mark(
                stage: .streamFailed,
                metadata: ["message": error.localizedDescription]
            )
            _ = await Self.stopTelemetrySampler(
                telemetrySampler,
                stageMarks: await telemetryRecorder?.snapshot() ?? []
            )
            Memory.clearCache()
            throw error
        }

        let finishReason = Self.mapFinishReason(completion.finishReason)
        if finishReason != .eos {
            await telemetryRecorder?.mark(
                stage: .streamFailed,
                metadata: ["finish_reason": finishReason.rawValue]
            )
            _ = await Self.stopTelemetrySampler(
                telemetrySampler,
                stageMarks: await telemetryRecorder?.snapshot() ?? []
            )
            Memory.clearCache()
            throw Self.error(for: finishReason)
        }

        let materializeSignpost = NativeStreamingSignposts.signposter.beginInterval(
            "Native Final Audio Materialize"
        )
        let samples = completion.audio.asArray(Float.self)
        NativeStreamingSignposts.signposter.endInterval(
            "Native Final Audio Materialize",
            materializeSignpost
        )
        guard !samples.isEmpty else {
            Memory.clearCache()
            throw MLXTTSEngineError.generationFailed("The native engine did not produce final audio.")
        }

        let scratchBuffer = self.scratchBuffer()
        let limiterSignpost = NativeStreamingSignposts.signposter.beginInterval(
            "Native PCM Limiter Convert"
        )
        let pcmSamples = scratchBuffer.convertLimited(samples)
        NativeStreamingSignposts.signposter.endInterval(
            "Native PCM Limiter Convert",
            limiterSignpost
        )
        Self.warnIfNonFiniteSamplesObserved(
            metrics: scratchBuffer.limiterMetrics,
            context: "quality-first final audio"
        )
        do {
            let finalWriteSignpost = NativeStreamingSignposts.signposter.beginInterval(
                "Native Final WAV Write"
            )
            defer {
                NativeStreamingSignposts.signposter.endInterval(
                    "Native Final WAV Write",
                    finalWriteSignpost
                )
            }
            try AtomicPCM16WAVWriter.write(
                pcmSamples: pcmSamples,
                sampleRate: sampleRate,
                outputURL: outputURL
            )
        } catch {
            Memory.clearCache()
            throw error
        }
        mlxMemorySnapshots["after_final_write"] = NativeMemoryPolicyResolver.snapshot()
        let postRequestCacheClearApplied = memoryPolicy.clearCacheAfterGeneration
        if postRequestCacheClearApplied {
            Memory.clearCache()
            mlxMemorySnapshots["after_generation_trim"] = NativeMemoryPolicyResolver.snapshot()
        }

        let durationSeconds = Double(pcmSamples.count) / Double(sampleRate)
        _ = await Self.stopTelemetrySampler(
            telemetrySampler,
            stageMarks: await telemetryRecorder?.snapshot() ?? []
        )
        await telemetryRecorder?.mark(stage: .streamCompleted)

        shouldRetainOutput = true
        try? FileManager.default.removeItem(at: sessionDirectory)
        return GenerationResult(
            audioPath: outputURL.path,
            durationSeconds: durationSeconds,
            streamSessionDirectory: nil,
            usedStreaming: false,
            finishReason: finishReason,
            diagnosticTimingsMS: timingOverridesMS,
            diagnosticBooleanFlags: booleanFlags,
            diagnosticStringFlags: stringFlags
        )
    }

    private func generateQualityFirstAudio() async throws -> AudioGenerationCompletion {
        switch request.payload {
        case .clone:
            guard let cloneConditioning else {
                throw MLXTTSEngineError.generationFailed(
                    "Voice Cloning needs resolved native clone conditioning before generation."
                )
            }
            guard let voiceClonePrompt = cloneConditioning.voiceClonePrompt else {
                throw MLXTTSEngineError.unsupportedRequest(
                    "Voice Cloning requires Qwen3 clone conditioning."
                )
            }
            let language = GenerationSemantics.qwenLanguageHint(
                for: request,
                resolvedCloneTranscript: cloneConditioning.resolvedTranscript
            )
            return try await model.generateVoiceClone(
                text: request.text,
                language: language,
                voiceClonePrompt: voiceClonePrompt
            )
        case .custom:
            let prompt = GenerationSemantics.qwen3PromptAssembly(
                for: request,
                capabilities: qwen3Capabilities
            )
            return try await model.generateCustomVoice(
                text: request.text,
                language: prompt.language,
                speaker: prompt.speakerID ?? GenerationSemantics.canonicalCustomWarmSpeaker,
                instruct: prompt.instruct
            )
        case .design:
            let prompt = GenerationSemantics.qwen3PromptAssembly(
                for: request,
                capabilities: qwen3Capabilities
            )
            return try await model.generateVoiceDesign(
                text: request.text,
                language: prompt.language,
                voiceDescription: prompt.instruct ?? ""
            )
        }
    }

    private static func mapFinishReason(_ reason: AudioGenerationFinishReason) -> GenerationFinishReason {
        switch reason {
        case .eos:
            return .eos
        case .maxTokens:
            return .maxTokens
        case .cancelled:
            return .cancelled
        case .failed:
            return .failed
        }
    }

    private static func error(for finishReason: GenerationFinishReason) -> Error {
        switch finishReason {
        case .eos:
            return MLXTTSEngineError.generationFailed("Unexpected EOS finish reason error.")
        case .maxTokens:
            return MLXTTSEngineError.generationFailed(
                "Qwen3-TTS reached maxNewTokens before EOS. The output was discarded to avoid a truncated generation."
            )
        case .cancelled:
            return CancellationError()
        case .failed:
            return MLXTTSEngineError.generationFailed(
                "Qwen3-TTS failed before producing a complete final audio result."
            )
        }
    }

    /// Logs a warning when the PCM limiter had to scrub NaN/Inf samples
    /// from the model output. Non-zero counts here are a signal that the
    /// upstream MLX runtime produced unstable values — the limiter
    /// replaced them with `0` so they couldn't corrupt the PCM output
    /// or downstream IPC-encoded numeric metadata, but the underlying
    /// instability is worth surfacing.
    private static func warnIfNonFiniteSamplesObserved(
        metrics: PCM16StreamLimiter.Metrics,
        context: String
    ) {
        let nonFinite = metrics.nonFiniteSamples
        guard nonFinite > 0 else { return }
        let total = metrics.processedSamples
        NativeStreamingSignposts.logger.warning(
            "PCM limiter scrubbed \(nonFinite, privacy: .public) non-finite sample(s) out of \(total, privacy: .public) (\(context, privacy: .public)). Upstream MLX generation produced NaN/Inf values."
        )
    }

    func run(eventSink: @escaping @MainActor @Sendable (GenerationEvent) -> Void) async throws -> GenerationResult {
        let generationSignpost = NativeStreamingSignposts.signposter.beginInterval("Native Generation Stream")
        defer {
            NativeStreamingSignposts.signposter.endInterval("Native Generation Stream", generationSignpost)
        }
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

        var chunkIndex = 0
        var totalFramesWritten: Int64 = 0
        var mlxMemorySnapshots = initialMLXMemorySnapshots
        mlxMemorySnapshots["before_stream"] = NativeMemoryPolicyResolver.snapshot()
        let streamingOutputPolicy = NativeStreamingOutputPolicy.current()
        let previewDataPolicy = NativeStreamingPreviewDataPolicy.current()
        let chunkWriter = streamingOutputPolicy == .pcmPreviewAndFileArtifacts
            ? try PCM16ChunkFileWriter(sampleRate: sampleRate)
            : nil
        let scratchBuffer = self.scratchBuffer()
        let finalWriter = try IncrementalPCM16WAVFileWriter(
            sampleRate: sampleRate,
            outputURL: outputURL
        )
        defer {
            finalWriter.finish()
        }

        let streamingInterval = NativeMemoryPolicyResolver.effectiveStreamingInterval(
            requested: request.streamingInterval,
            request: request,
            policy: memoryPolicy
        )
        let stream = try NativeStreamingSynthesisSession.buildStream(
            request: request,
            model: model,
            qwen3Capabilities: qwen3Capabilities,
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
                case .chunkTimings:
                    continue
                case .info:
                    continue
                case .audio(let samples):
                    let chunkSamples = samples.asArray(Float.self)
                    guard !chunkSamples.isEmpty else { continue }

                    if chunkIndex == 0 {
                        NativeStreamingSignposts.signposter.emitEvent("Native First Audio Chunk")
                        await telemetryRecorder?.mark(
                            stage: .firstChunk,
                            metadata: ["chunk_index": String(chunkIndex)]
                        )
                        mlxMemorySnapshots["first_chunk"] = NativeMemoryPolicyResolver.snapshot()
                    }

                    let pcmSamples = scratchBuffer.convertLimited(chunkSamples)
                    let frameOffset = totalFramesWritten
                    let previewAudio: StreamingAudioChunk?
                    if previewDataPolicy == .skip {
                        previewAudio = nil
                    } else {
                        previewAudio = StreamingAudioChunk(
                            generationID: generationID,
                            requestID: requestID,
                            sampleRate: sampleRate,
                            frameOffset: frameOffset,
                            frameCount: pcmSamples.count,
                            pcm16LE: scratchBuffer.pcm16LittleEndianData(from: pcmSamples),
                            isFinal: false
                        )
                    }
                    var chunkPath: String?

                    if let chunkWriter {
                        let chunkURL = NativeStreamingSynthesisSession.chunkURL(
                            in: sessionDirectory,
                            chunkIndex: chunkIndex
                        )
                        try autoreleasepool {
                            try chunkWriter.write(
                                pcmSamples: pcmSamples,
                                to: chunkURL
                            )
                        }
                        chunkPath = chunkURL.path
                    }

                    try autoreleasepool {
                        try finalWriter.append(pcmSamples: pcmSamples)
                    }

                    chunkIndex += 1
                    totalFramesWritten += Int64(pcmSamples.count)

                    let chunkDurationSeconds = Double(pcmSamples.count) / Double(sampleRate)
                    let cumulativeDurationSeconds = Double(totalFramesWritten) / Double(sampleRate)

                    let chunkEvent = GenerationEvent.chunk(
                        GenerationChunk(
                            generationID: generationID,
                            requestID: requestID,
                            mode: request.modeIdentifier,
                            title: previewTitle,
                            chunkPath: chunkPath,
                            isFinal: false,
                            chunkDurationSeconds: chunkDurationSeconds,
                            cumulativeDurationSeconds: cumulativeDurationSeconds,
                            streamSessionDirectory: sessionDirectory.path,
                            previewAudio: previewAudio
                        )
                    )

                    await eventSink(chunkEvent)
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
            Memory.clearCache()
            throw error
        }

        Self.warnIfNonFiniteSamplesObserved(
            metrics: scratchBuffer.limiterMetrics,
            context: "streaming chunks"
        )

        guard totalFramesWritten > 0 else {
            throw MLXTTSEngineError.generationFailed("The native engine did not emit any audio chunks.")
        }
        if model.latestPreparationStringFlags["generation_end_reason"] == "token_cap" {
            throw MLXTTSEngineError.generationFailed(
                "Qwen3-TTS reached maxNewTokens before EOS. The output was discarded to avoid a truncated generation."
            )
        }

        let finalWriteSignpost = NativeStreamingSignposts.signposter.beginInterval("Native Final WAV Finish")
        finalWriter.finish()
        NativeStreamingSignposts.signposter.endInterval("Native Final WAV Finish", finalWriteSignpost)
        mlxMemorySnapshots["after_final_write"] = NativeMemoryPolicyResolver.snapshot()

        let durationSeconds = Double(totalFramesWritten) / Double(sampleRate)
        let stageMarks = await telemetryRecorder?.snapshot() ?? []
        _ = await Self.stopTelemetrySampler(
            telemetrySampler,
            stageMarks: stageMarks
        )
        mlxMemorySnapshots["after_stream"] = NativeMemoryPolicyResolver.snapshot()
        let postRequestCacheClearApplied = memoryPolicy.clearCacheAfterGeneration
        if postRequestCacheClearApplied {
            Memory.clearCache()
            mlxMemorySnapshots["after_generation_trim"] = NativeMemoryPolicyResolver.snapshot()
        }
        await telemetryRecorder?.mark(stage: .streamCompleted)

        shouldRetainSession = true
        return GenerationResult(
            audioPath: outputURL.path,
            durationSeconds: durationSeconds,
            streamSessionDirectory: sessionDirectory.path,
            usedStreaming: true,
            finishReason: model.latestPreparationStringFlags["generation_end_reason"] == "token_cap"
                ? .maxTokens
                : .eos,
            diagnosticTimingsMS: timingOverridesMS,
            diagnosticBooleanFlags: booleanFlags,
            diagnosticStringFlags: stringFlags
        )
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
