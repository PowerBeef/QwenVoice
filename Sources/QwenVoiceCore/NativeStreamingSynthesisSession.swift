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
// shared by the active macOS XPC service and the iPhone in-process engine.
// Keep behavior changes here aligned with the platform host adapters.

protocol NativeStreamingSessionRunning {
    func run(chunkSink: @escaping @Sendable (GenerationEvent) -> Void) async throws -> GenerationResult
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
    /// Sendable holder for the engine process's app-support directory; read at
    /// telemetry-write time so the rescued `TelemetrySummary` lands under
    /// `diagnostics/engine/generations.jsonl`. `nil` for callers that don't supply it.
    private let diagnosticAppSupportBox: DiagnosticAppSupportBox?

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
        pcmScratchBuffer: PCM16ScratchBuffer? = nil,
        diagnosticAppSupportBox: DiagnosticAppSupportBox? = nil
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
        self.diagnosticAppSupportBox = diagnosticAppSupportBox
    }

    func run(chunkSink: @escaping @Sendable (GenerationEvent) -> Void) async throws -> GenerationResult {
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
                pcmScratchBuffer: pcmScratchBuffer,
                diagnosticAppSupportBox: diagnosticAppSupportBox
            )
            let task = Task.detached(priority: .userInitiated) {
                try await execution.runQualityFirstFinalAudio()
            }
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            chunkSink(.completed(result))
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
            pcmScratchBuffer: pcmScratchBuffer,
            diagnosticAppSupportBox: diagnosticAppSupportBox
        )
        // `Task.detached` does not inherit the parent's cancellation, so we
        // explicitly forward cancellation through `withTaskCancellationHandler`.
        // Without this, cancelling the outer generation task leaves the
        // detached streaming task running and bypasses the retention-flag
        // `defer` cleanup (Tier 1.5).
        let task = Task.detached(priority: .userInitiated) {
            try await execution.run(chunkSink: chunkSink)
        }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        chunkSink(.completed(result))
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
        let extensionName = finalURL.pathExtension
        let stem = finalURL.deletingPathExtension().lastPathComponent
        let temporaryName: String
        if extensionName.isEmpty {
            temporaryName = ".\(stem).\(UUID().uuidString).tmp"
        } else {
            // AVAudioFile chooses its container from the filename extension.
            // Keep `.wav` last so an atomic staging file cannot silently become
            // CAF bytes that are later published under a misleading WAV name.
            temporaryName = ".\(stem).\(UUID().uuidString).tmp.\(extensionName)"
        }
        return finalURL
            .deletingLastPathComponent()
            .appendingPathComponent(temporaryName)
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

enum AtomicPCM16WAVWriter {
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

    func convertLimited(_ samples: [Float], into destination: inout [Int16]) {
        destination.removeAll(keepingCapacity: true)
        destination.reserveCapacity(samples.count)
        limiter.append(samples, into: &destination)
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
        // Absolute sample index (0-based) of the first non-finite input sample.
        // nil when no non-finite sample was observed. Used for defect localization.
        var firstNonFiniteSample: Int? = nil
        var minimumAppliedGain: Float = 1
        // Audio-QC accumulators (observational — do not affect limiting).
        // Sum of squared input magnitudes → whole-clip RMS (dead/near-silent
        // output detection). Longest *interior* near-silent run in samples (a
        // run bracketed by audio = a mid-utterance dropout; trailing/leading
        // silence is excluded). sampleRate-agnostic here; converted to ms at
        // report build.
        var sumOfSquares: Double = 0
        var longestInteriorSilentRunSamples = 0
        // Absolute sample index where the longest interior silent run started.
        // nil when no interior silent run has closed. Used for dropout localization.
        var longestInteriorSilentRunStartSample: Int? = nil
        // Lengths (samples) of interior near-silent runs at/above the record
        // floor, in close order. Converted to ms and counted against the text's
        // pause budget at report build (punctuation-aware dropout calibration —
        // the model emits a prosodic pause at each sentence/clause boundary, so a
        // single long silence is normal; an EXCESS of them, or one egregious gap,
        // is the real tripwire). Bounded; far more entries than the cap means
        // pathological output, already caught by near_silent.
        var interiorSilentRunSamples: [Int] = []
        // Absolute sample index of the first input sample whose magnitude exceeds
        // the digital unit range (|x| > 1). nil when no clip was observed.
        var firstClipSample: Int? = nil

        private static func partsPerMillion(_ value: Float) -> Int {
            Int((Double(value) * 1_000_000).rounded())
        }
    }

    static let ceiling: Float = 0.965
    static let maxSingleSampleStep: Float = 0.42
    static let releaseStepPerSample: Float = 0.002
    /// Below this absolute input magnitude a sample counts as silence for
    /// interior-dropout detection.
    static let silenceFloor: Float = 0.001
    /// Don't record interior runs below this length (noise filter; well under any
    /// ms threshold the report applies, even at low sample rates). Recorded only
    /// when a run closes (audio resumes), so leading/trailing silence is excluded.
    static let interiorRunRecordFloorSamples = 2_400
    /// Cap on recorded interior runs — a long clip has a handful; this guards a
    /// pathological all-silence output from unbounded array growth.
    static let interiorRunRecordCap = 256

    private var currentGain: Float = 1
    private var previousOutput: Float?
    // Cross-`append` silence-run state (a dropout can span chunk boundaries).
    private var sawAudio = false
    private var currentSilentRun = 0
    private(set) var metrics = Metrics()

    mutating func append(_ samples: [Float], into destination: inout [Int16]) {
        guard !samples.isEmpty else { return }
        destination.reserveCapacity(destination.count + samples.count)

        var localGain = currentGain
        var localPreviousOutput = previousOutput
        var localMetrics = metrics
        var localSawAudio = sawAudio
        var localSilentRun = currentSilentRun
        var localSilentRunStart: Int? = nil

        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let count = buffer.count
            for index in 0 ..< count {
                let absoluteIndex = localMetrics.processedSamples
                let rawSample = base[index]
                let sample: Float
                if rawSample.isFinite {
                    sample = rawSample
                } else {
                    localMetrics.nonFiniteSamples += 1
                    if localMetrics.firstNonFiniteSample == nil {
                        localMetrics.firstNonFiniteSample = absoluteIndex
                    }
                    sample = 0
                }
                let rawMagnitude = abs(sample)
                localMetrics.rawPeak = max(localMetrics.rawPeak, rawMagnitude)
                localMetrics.processedSamples += 1
                localMetrics.sumOfSquares += Double(rawMagnitude) * Double(rawMagnitude)
                // Interior-dropout tracking: count near-silent runs only after
                // the first audible sample; close a run (recording its length)
                // when audio resumes, so leading/trailing silence is excluded.
                if rawMagnitude < Self.silenceFloor {
                    if localSawAudio {
                        if localSilentRun == 0 {
                            localSilentRunStart = absoluteIndex
                        }
                        localSilentRun += 1
                    }
                } else {
                    if localSilentRun > 0 {
                        if localSilentRun > localMetrics.longestInteriorSilentRunSamples,
                           let start = localSilentRunStart {
                            localMetrics.longestInteriorSilentRunSamples = localSilentRun
                            localMetrics.longestInteriorSilentRunStartSample = start
                        }
                        if localSilentRun >= Self.interiorRunRecordFloorSamples,
                           localMetrics.interiorSilentRunSamples.count < Self.interiorRunRecordCap {
                            localMetrics.interiorSilentRunSamples.append(localSilentRun)
                        }
                        localSilentRun = 0
                        localSilentRunStart = nil
                    }
                    localSawAudio = true
                }
                if rawMagnitude > Self.ceiling {
                    localMetrics.samplesAboveCeiling += 1
                }
                if rawMagnitude > 1 {
                    localMetrics.samplesOutsideUnitRange += 1
                    if localMetrics.firstClipSample == nil {
                        localMetrics.firstClipSample = absoluteIndex
                    }
                }

                let targetGain = rawMagnitude > Self.ceiling
                    ? Self.ceiling / max(rawMagnitude, .leastNonzeroMagnitude)
                    : 1
                if targetGain < localGain {
                    localGain = targetGain
                } else {
                    localGain = min(targetGain, localGain + Self.releaseStepPerSample)
                }
                localMetrics.minimumAppliedGain = min(localMetrics.minimumAppliedGain, localGain)

                var limited = sample * localGain
                if let localPreviousOutput {
                    let delta = limited - localPreviousOutput
                    if delta > Self.maxSingleSampleStep {
                        limited = localPreviousOutput + Self.maxSingleSampleStep
                        localMetrics.slewLimitedSamples += 1
                    } else if delta < -Self.maxSingleSampleStep {
                        limited = localPreviousOutput - Self.maxSingleSampleStep
                        localMetrics.slewLimitedSamples += 1
                    }
                }

                limited = max(-Self.ceiling, min(Self.ceiling, limited))
                localPreviousOutput = limited
                localMetrics.limitedPeak = max(localMetrics.limitedPeak, abs(limited))
                destination.append(Int16((limited * Float(Int16.max)).rounded()))
            }
        }

        currentGain = localGain
        previousOutput = localPreviousOutput
        sawAudio = localSawAudio
        currentSilentRun = localSilentRun
        metrics = localMetrics
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

final class IncrementalPCM16WAVFileWriter {
    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private var reusableBuffer: AVAudioPCMBuffer?
    private let finalURL: URL
    private let temporaryURL: URL
    private var published = false

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
        self.finalURL = outputURL
        self.temporaryURL = AtomicFilePublisher.temporaryURL(for: outputURL)
        try? FileManager.default.removeItem(at: temporaryURL)
        self.file = try AVAudioFile(
            forWriting: temporaryURL,
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

    func finish() throws {
        let finalizeSignpost = NativeStreamingSignposts.signposter.beginInterval(
            "Native Final WAV AVAudioFile Finalize"
        )
        reusableBuffer = nil
        file = nil
        try AtomicFilePublisher.publishAtomically(
            temporaryURL: temporaryURL,
            finalURL: finalURL
        )
        published = true
        NativeStreamingSignposts.signposter.endInterval(
            "Native Final WAV AVAudioFile Finalize",
            finalizeSignpost
        )
    }

    func discard() {
        reusableBuffer = nil
        file = nil
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    deinit {
        if !published {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
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
    let diagnosticAppSupportBox: DiagnosticAppSupportBox?

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
        let qualityFirstGenerationStartedAt = ContinuousClock.now
        defer {
            NativeStreamingSignposts.signposter.endInterval("Native Quality-First Generation", generationSignpost)
        }
        var signpostTimingsMS: [String: Int] = [:]

        let outputURL = URL(fileURLWithPath: request.outputPath)
        let sampleRate = model.sampleRate
        let telemetryMode = NativeTelemetryMode.current()
        let telemetrySampleInterval = telemetryMode.sampleIntervalMS(for: memoryPolicy.deviceClass)
        let telemetryWorkPlan = NativeTelemetryWorkPlan(
            mode: telemetryMode,
            recorderPresent: telemetryRecorder != nil,
            sampleIntervalAvailable: telemetrySampleInterval != nil
        )
        let telemetryActive = telemetryWorkPlan.computesDerivedDiagnostics
        let telemetrySampler: NativeTelemetrySampler? = {
            guard telemetryWorkPlan.constructsSampler,
                  let clock = telemetryRecorder?.clock,
                  let sampleIntervalMS = telemetrySampleInterval
            else { return nil }
            return NativeTelemetrySampler(
                // Share the stage recorder's clock so samples and marks join on both
                // the millisecond and nanosecond timelines.
                clock: clock,
                sampleIntervalMS: sampleIntervalMS
            )
        }()
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
            GenerationFailureDiagnosticLogger.shared.log(
                surfacedMessage: "Quality-first generation failed",
                stage: NativeRuntimeStage.streamFailed.description,
                underlyingError: error,
                request: request
            )
            await telemetryRecorder?.mark(
                metadata: StreamFailureMessageMetadata(message: error.localizedDescription)
            )
            let stageMarks = await telemetryRecorder?.snapshot() ?? []
            let (summary, _) = await Self.stopTelemetrySampler(
                telemetrySampler,
                stageMarks: stageMarks
            )
            await writeEngineTelemetryRecord(
                summary: summary,
                stageMarks: stageMarks,
                usedStreaming: false,
                finishReason: "failed",
                counters: [:],
                notes: TelemetryGate.resolvedEnabled
                    ? GenerationTelemetryPrivacy.failureNotes(message: error.localizedDescription)
                    : [:]
            )
            Memory.clearCache()
            throw error
        }

        let finishReason = Self.mapFinishReason(completion.finishReason)
        if finishReason != .eos {
            await telemetryRecorder?.mark(
                metadata: StreamFailureFinishReasonMetadata(finishReason: finishReason)
            )
            let stageMarks = await telemetryRecorder?.snapshot() ?? []
            let (summary, _) = await Self.stopTelemetrySampler(
                telemetrySampler,
                stageMarks: stageMarks
            )
            await writeEngineTelemetryRecord(
                summary: summary,
                stageMarks: stageMarks,
                usedStreaming: false,
                finishReason: finishReason.rawValue,
                counters: [:],
                notes: [:]
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
            guard Self.isReadableWAV(at: outputURL) else {
                throw MLXTTSEngineError.generationFailed("The finalized WAV could not be reopened for reading.")
            }
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
        await telemetryRecorder?.mark(stage: .streamCompleted)
        let stageMarks = await telemetryRecorder?.snapshot() ?? []
        let (summary, rawSamples) = await Self.stopTelemetrySampler(
            telemetrySampler,
            stageMarks: stageMarks
        )

        // Re-read the model's diagnostics post-generation so the finalized MLX
        // decode-stage totals and counters are surfaced (same rationale as the
        // streaming path). Quality-first is non-streaming → no per-chunk timeline.
        signpostTimingsMS["native_quality_first_generation_ms"] = qualityFirstGenerationStartedAt.elapsedMilliseconds
        let finalTimingsMS = telemetryActive
            ? timingOverridesMS.merging(model.latestPreparationTimingsMS) { _, new in new }.merging(signpostTimingsMS) { _, new in new }
            : timingOverridesMS.merging(signpostTimingsMS) { _, new in new }
        let finalBooleanFlags = booleanFlags.merging(model.latestPreparationBooleanFlags) { _, new in new }
        let finalStringFlags = stringFlags.merging(model.latestPreparationStringFlags) { _, new in new }
        let derivedMetrics: [String: Double]? = telemetryActive
            ? Self.computeDerivedMetrics(
                audioSeconds: durationSeconds,
                stageMarks: stageMarks,
                info: nil,
                modelTimingsMS: finalTimingsMS
            )
            : nil

        await writeEngineTelemetryRecord(
            summary: summary,
            stageMarks: stageMarks,
            usedStreaming: false,
            finishReason: finishReason.rawValue,
            counters: [:],
            notes: [
                "outputReadableWAV": "true",
                "outputAtomicallyPublished": "true",
            ],
            timingsMS: finalTimingsMS,
            derivedMetrics: derivedMetrics,
            mlxMemoryByStage: telemetryActive ? mlxMemorySnapshots : nil,
            chunkTimeline: nil,
            audioQC: telemetryActive ? Self.makeAudioQCReport(
                metrics: scratchBuffer.limiterMetrics,
                sampleRate: sampleRate,
                durationSeconds: durationSeconds,
                expectedPauseCount: Self.expectedPauseCount(in: request.text)
            ) : nil,
            rawSamples: telemetryMode.persistsRawSamples ? rawSamples : nil
        )

        shouldRetainOutput = true
        try? FileManager.default.removeItem(at: sessionDirectory)
        return GenerationResult(
            audioPath: outputURL.path,
            durationSeconds: durationSeconds,
            streamSessionDirectory: nil,
            usedStreaming: false,
            finishReason: finishReason,
            diagnosticTimingsMS: finalTimingsMS,
            diagnosticBooleanFlags: finalBooleanFlags,
            diagnosticStringFlags: finalStringFlags,
            telemetrySummary: summary
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

    func run(chunkSink: @escaping @Sendable (GenerationEvent) -> Void) async throws -> GenerationResult {
        let generationSignpost = NativeStreamingSignposts.signposter.beginInterval("Native Generation Stream")
        let generationStreamStartedAt = ContinuousClock.now
        defer {
            NativeStreamingSignposts.signposter.endInterval("Native Generation Stream", generationSignpost)
        }
        var signpostTimingsMS: [String: Int] = [:]
        let outputURL = URL(fileURLWithPath: request.outputPath)
        let sampleRate = model.sampleRate
        let telemetryMode = NativeTelemetryMode.current()
        let telemetryClock = telemetryRecorder?.clock
        let telemetrySampleInterval = telemetryMode.sampleIntervalMS(for: memoryPolicy.deviceClass)
        let telemetryWorkPlan = NativeTelemetryWorkPlan(
            mode: telemetryMode,
            recorderPresent: telemetryRecorder != nil,
            sampleIntervalAvailable: telemetrySampleInterval != nil
        )
        let telemetrySampler: NativeTelemetrySampler? = {
            guard telemetryWorkPlan.constructsSampler,
                  let clock = telemetryClock,
                  let sampleIntervalMS = telemetrySampleInterval
            else { return nil }
            return NativeTelemetrySampler(
                // Share the stage recorder's clock so samples and marks join on both
                // the millisecond and nanosecond timelines.
                clock: clock,
                sampleIntervalMS: sampleIntervalMS
            )
        }()
        // Per-chunk decode timeline + final stats. Only populated when telemetry is
        // on (recorder non-nil), so there is zero per-chunk cost when gated off.
        let telemetryActive = telemetryWorkPlan.computesDerivedDiagnostics
        let chunkQCActive = telemetryWorkPlan.computesChunkQC
        var chunkTimeline: [GenerationChunkTelemetry] = []
        var chunkQCReports: [AudioQCChunkReport] = []
        var pendingChunkTimings: ChunkSubstageTimings?
        var latestInfo: AudioGenerationInfo?
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
        var pcmSamples = [Int16]()
        let finalWriter = try IncrementalPCM16WAVFileWriter(
            sampleRate: sampleRate,
            outputURL: outputURL
        )
        defer {
            finalWriter.discard()
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
                case .chunkTimings(let timings):
                    // Stash the per-chunk decode breakdown; bound to the next
                    // `.audio` event below. Free when telemetry is off.
                    if telemetryActive { pendingChunkTimings = timings }
                    continue
                case .info(let info):
                    if telemetryActive { latestInfo = info }
                    continue
                case .audio(let samples):
                    let chunkSamples = samples.asArray(Float.self)
                    guard !chunkSamples.isEmpty else { continue }

                    if chunkQCActive {
                        chunkQCReports.append(
                            Self.makeAudioQCChunkReport(
                                chunkIndex: chunkIndex,
                                frameOffset: Int(totalFramesWritten),
                                samples: chunkSamples,
                                sampleRate: sampleRate
                            )
                        )
                    }

                    if chunkIndex == 0 {
                        NativeStreamingSignposts.signposter.emitEvent("Native First Audio Chunk")
                        await telemetryRecorder?.mark(
                            metadata: FirstChunkMetadata(chunkIndex: chunkIndex)
                        )
                        mlxMemorySnapshots["first_chunk"] = NativeMemoryPolicyResolver.snapshot()
                    }

                    scratchBuffer.convertLimited(chunkSamples, into: &pcmSamples)
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

                    // Bind the stashed decode-substage breakdown to this chunk.
                    if telemetryActive, let timings = pendingChunkTimings {
                        chunkTimeline.append(
                            makeChunkTelemetry(
                                chunkIndex: chunkIndex - 1,
                                timings: timings,
                                clock: telemetryClock
                            )
                        )
                        pendingChunkTimings = nil
                    }

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
                            previewAudio: previewAudio,
                            // Transport sequencing is zero-based: the first
                            // emitted chunk is index 0, matching the XPC gap
                            // detector and accumulator contract.
                            chunkSequence: UInt64(chunkIndex - 1)
                        )
                    )

                    chunkSink(chunkEvent)
                }
            }
        } catch {
            GenerationFailureDiagnosticLogger.shared.log(
                surfacedMessage: "Streaming execution failed",
                stage: NativeRuntimeStage.streamFailed.description,
                underlyingError: error,
                request: request
            )
            await telemetryRecorder?.mark(
                metadata: StreamFailureMessageMetadata(message: error.localizedDescription)
            )
            let stageMarks = await telemetryRecorder?.snapshot() ?? []
            let (summary, _) = await Self.stopTelemetrySampler(
                telemetrySampler,
                stageMarks: stageMarks
            )
            await writeEngineTelemetryRecord(
                summary: summary,
                stageMarks: stageMarks,
                usedStreaming: true,
                finishReason: "failed",
                counters: ["chunkCount": chunkIndex],
                notes: TelemetryGate.resolvedEnabled
                    ? GenerationTelemetryPrivacy.failureNotes(message: error.localizedDescription)
                    : [:]
            )
            finalWriter.discard()
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

        // Token loop + pipelined decoder drain finished; post-stream work (WAV
        // finalize, telemetry marks) is tracked separately from decodeWallSeconds.
        await telemetryRecorder?.mark(stage: .streamGenerationEnded)

        let finalWriteSignpost = NativeStreamingSignposts.signposter.beginInterval("Native Final WAV Finish")
        let finalWAVFinishStartedAt = ContinuousClock.now
        try finalWriter.finish()
        guard Self.isReadableWAV(at: outputURL) else {
            throw MLXTTSEngineError.generationFailed("The finalized streaming WAV could not be reopened for reading.")
        }
        NativeStreamingSignposts.signposter.endInterval("Native Final WAV Finish", finalWriteSignpost)
        signpostTimingsMS["native_final_wav_finish_ms"] = finalWAVFinishStartedAt.elapsedMilliseconds
        mlxMemorySnapshots["after_final_write"] = NativeMemoryPolicyResolver.snapshot()

        let durationSeconds = Double(totalFramesWritten) / Double(sampleRate)
        await telemetryRecorder?.mark(stage: .streamCompleted)
        let stageMarks = await telemetryRecorder?.snapshot() ?? []
        let (summary, rawSamples) = await Self.stopTelemetrySampler(
            telemetrySampler,
            stageMarks: stageMarks
        )
        mlxMemorySnapshots["after_stream"] = NativeMemoryPolicyResolver.snapshot()
        let postRequestCacheClearApplied = memoryPolicy.clearCacheAfterGeneration
        if postRequestCacheClearApplied {
            Memory.clearCache()
            mlxMemorySnapshots["after_generation_trim"] = NativeMemoryPolicyResolver.snapshot()
        }

        let resolvedFinishReason: GenerationFinishReason =
            model.latestPreparationStringFlags["generation_end_reason"] == "token_cap"
                ? .maxTokens
                : .eos

        // Re-read the model's diagnostics AFTER the decode loop: the MLX hot-loop
        // totals (talker forward, code predictor, decoder, stream-step eval/EOS,
        // token-loop total, generated-code count) are only finalized post-loop, so
        // the pre-loop `timingOverridesMS` snapshot misses them entirely.
        signpostTimingsMS["native_generation_stream_ms"] = generationStreamStartedAt.elapsedMilliseconds
        var finalTimingsMS = telemetryActive
            ? timingOverridesMS.merging(model.latestPreparationTimingsMS) { _, new in new }.merging(signpostTimingsMS) { _, new in new }
            : timingOverridesMS.merging(signpostTimingsMS) { _, new in new }
        if telemetryActive,
           let info = latestInfo,
           let tokenLoopMS = finalTimingsMS["qwen_token_loop_total"],
           tokenLoopMS > 0 {
            let infoMS = Int((info.generateTime * 1_000).rounded())
            let drainMS = max(0, tokenLoopMS - infoMS)
            if drainMS > 0 {
                finalTimingsMS["qwen_stream_decoder_drain_ms"] = drainMS
            }
        }
        let finalBooleanFlags = booleanFlags.merging(model.latestPreparationBooleanFlags) { _, new in new }
        let finalStringFlags = stringFlags.merging(model.latestPreparationStringFlags) { _, new in new }

        let derivedMetrics: [String: Double]? = telemetryActive
            ? Self.computeDerivedMetrics(
                audioSeconds: durationSeconds,
                stageMarks: stageMarks,
                info: latestInfo,
                modelTimingsMS: finalTimingsMS
            )
            : nil

        await writeEngineTelemetryRecord(
            summary: summary,
            stageMarks: stageMarks,
            usedStreaming: true,
            finishReason: resolvedFinishReason.rawValue,
            counters: ["chunkCount": chunkIndex],
            notes: [
                "finalChunkBarrierObserved": "true",
                "outputReadableWAV": "true",
                "outputAtomicallyPublished": "true",
            ],
            timingsMS: finalTimingsMS,
            derivedMetrics: derivedMetrics,
            mlxMemoryByStage: telemetryActive ? mlxMemorySnapshots : nil,
            chunkTimeline: chunkTimeline.isEmpty ? nil : chunkTimeline,
            audioQC: telemetryActive ? Self.makeAudioQCReport(
                metrics: scratchBuffer.limiterMetrics,
                sampleRate: sampleRate,
                durationSeconds: durationSeconds,
                expectedPauseCount: Self.expectedPauseCount(in: request.text),
                chunkQC: chunkQCActive && !chunkQCReports.isEmpty ? chunkQCReports : nil
            ) : nil,
            rawSamples: telemetryMode.persistsRawSamples ? rawSamples : nil
        )

        shouldRetainSession = true
        return GenerationResult(
            audioPath: outputURL.path,
            durationSeconds: durationSeconds,
            streamSessionDirectory: sessionDirectory.path,
            usedStreaming: true,
            finishReason: resolvedFinishReason,
            diagnosticTimingsMS: finalTimingsMS,
            diagnosticBooleanFlags: finalBooleanFlags,
            diagnosticStringFlags: finalStringFlags,
            telemetrySummary: summary
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

    private static func isReadableWAV(at url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.fileFormat.sampleRate > 0 && file.length > 0
    }

    /// Persists the rescued sampler `TelemetrySummary` + stage timeline as the
    /// engine-layer row of the unified telemetry artifact. Runtime-gated and a
    /// no-op when the gate is off or the app-support directory is unknown — so it
    /// is safe to call on every terminal path (success, failure, non-EOS finish).
    private func writeEngineTelemetryRecord(
        summary: TelemetrySummary,
        stageMarks: [NativeTelemetryStageMark],
        usedStreaming: Bool,
        finishReason: String?,
        counters: [String: Int],
        notes: [String: String],
        timingsMS: [String: Int]? = nil,
        derivedMetrics: [String: Double]? = nil,
        mlxMemoryByStage: [String: NativeMLXMemorySnapshot]? = nil,
        chunkTimeline: [GenerationChunkTelemetry]? = nil,
        audioQC: AudioQCReport? = nil,
        rawSamples: [TelemetrySample]? = nil
    ) async {
        guard TelemetryGate.resolvedEnabled else { return }
        guard let appSupportDirectory = diagnosticAppSupportBox?.url else { return }
        // Stamp the resolved device-memory tier so each row self-identifies which
        // policy it ran under — confirms a forced-tier benchmark took effect.
        // Reuses the free-form notes field; a caller-supplied key wins on collision.
        var tierNotes = [
            "deviceClass": NativeMemoryPolicyResolver.deviceClass().rawValue,
            // Whether the tier was forced (QWENVOICE_FORCE_MEMORY_CLASS) vs the
            // native, physical-memory-derived tier — so the summarizer doesn't
            // mislabel a real floor_8gb_mac (8 GB Mac) as "forced".
            "deviceClassForced": NativeDeviceClassGate.resolvedForcedClass != nil ? "true" : "false",
            // Input script length (characters) so the benchmark summarizer can
            // break results out by prompt length (short / medium / long) — RTF,
            // decode time, and KV-cache memory all scale with it.
            "promptChars": String(request.text.count),
            // Resolved Qwen3 language for this generation (explicit hint or
            // text-detected) — verifies Auto-language resolution (incl. the
            // Latin-script NLLanguageRecognizer path) and gives delivery
            // benchmarks the language variable. Clone rows may differ when a
            // resolved transcript later refines the detection.
            "languageHint": GenerationSemantics.qwenLanguageHint(for: request),
        ]
        if let simLimit = IOSMemorySnapshot.simulatedProcessLimitBytes {
            // Restriction-simulation rows must self-identify — a simulated
            // iPhone-15-Pro run must never read as a real-device proof.
            tierNotes["simulatedProcessLimitMB"] = String(simLimit / 1_048_576)
            if let profile = ProcessInfo.processInfo.environment["QVOICE_IOS_SIM_DEVICE"] {
                tierNotes["simulatedDevice"] = profile
            }
        }
        // Bench delivery cells (vocello bench --delivery) stamp the preset id so
        // the summarizer can segregate instruct-bearing takes from the plain matrix.
        // Read via getenv (not ProcessInfo) because the in-process CLI updates it per
        // take; only the id is recorded, never user text.
        if let rawDelivery = getenv("QWENVOICE_BENCH_DELIVERY") {
            let delivery = String(cString: rawDelivery)
            if !delivery.isEmpty { tierNotes["delivery"] = delivery }
        }
        // MLX/Metal memory policy notes so each row self-identifies the substrate
        // it ran under (cache limit, memory limit, clear cadence, KV window).
        let policyNotes = NativeMemoryPolicyResolver.currentPolicyNotes(for: memoryPolicy)
        tierNotes.merge(policyNotes) { _, policy in policy }

        // Worst memory pressure band over the generation (audit P1-6): derived from
        // the sampler summary extremes with the shipping policy thresholds, so
        // Jetsam-adjacent runs are visible directly on the row.
        if let worstBand = IOSMemoryBudgetPolicy.iPhoneShippingDefault.worstBand(
            headroomMinMB: summary.headroomMinMB,
            physFootprintPeakMB: summary.physFootprintPeakMB,
            gpuWorkingSetUsageRatioPeak: summary.gpuWorkingSetUsageRatioPeak
        ) {
            tierNotes["memoryPressureBandWorst"] = worstBand.rawValue
        }

        // Row-level KV-cache footprint (audit P1-2): the per-chunk diagnostics carry
        // an estimated footprint; surface the peak as a headline derived metric so
        // regression tooling doesn't need to walk the chunk timeline.
        var derivedWithKV = derivedMetrics
        if let kvPeakMB = chunkTimeline?
            .compactMap({ $0.kvCacheDiagnostics?.estimatedFootprintMB })
            .max() {
            derivedWithKV = (derivedWithKV ?? [:]).merging(
                ["kvCacheEstimatedPeakMB": kvPeakMB]
            ) { current, _ in current }
        }

        // Adherence ground-truth for bench analysis (dev-gated diagnostics only —
        // this whole writer is behind TelemetryGate; never ships). These notes let
        // post-processing scripts pair instruct/design takes with their expected
        // voice description + delivery instruction; acoustic audioQC can't see adherence.
        switch request.payload {
        case .design(let voiceDescription, let deliveryStyle):
            let desc = voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !desc.isEmpty { tierNotes["voiceDescriptionChars"] = String(desc.count) }
            if let d = deliveryStyle?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                tierNotes["deliveryInstructionChars"] = String(d.count)
            }
        case .custom(_, let deliveryStyle):
            if let d = deliveryStyle?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                tierNotes["deliveryInstructionChars"] = String(d.count)
            }
        case .clone:
            break
        }
        let notesWithTier = tierNotes
            .merging(notes) { _, caller in caller }
            .merging(currentTaskQOSNotes()) { current, _ in current }
            .merging(BenchRunContext.telemetryNotes(intendedWarmState: warmState.rawValue)) { current, _ in current }
        let record = GenerationTelemetryRecord(
            generationID: generationID.uuidString,
            layer: .engine,
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            mode: request.modeIdentifier,
            modelID: request.modelID,
            warmState: warmState,
            usedStreaming: usedStreaming,
            finishReason: finishReason,
            stageMarks: stageMarks,
            summary: summary,
            thermalState: summary.thermalState,
            timingsMS: timingsMS ?? timingOverridesMS,
            counters: counters,
            notes: notesWithTier,
            derivedMetrics: derivedWithKV,
            mlxMemoryByStage: mlxMemoryByStage,
            chunkTimeline: chunkTimeline,
            audioQC: audioQC
        )
        await GenerationTelemetryJSONLSink.shared.write(
            record: record,
            appSupportDirectory: appSupportDirectory,
            subdirectory: "engine"
        )
        // Opt-in verbose: persist the raw per-sample memory/timing series to a
        // per-generation sidecar for deep memory-curve analysis. Off by default.
        if let rawSamples, !rawSamples.isEmpty {
            await GenerationTelemetryJSONLSink.shared.writeRawSamples(
                rawSamples,
                generationID: generationID.uuidString,
                appSupportDirectory: appSupportDirectory,
                subdirectory: "engine"
            )
        }
    }

    /// Build the reference-free `AudioQCReport` from the limiter's per-sample
    /// metrics. Thresholds are conservative + tunable here — they exist to catch
    /// GROSS defects (regression tripwire), not to judge subtle perceptual quality
    /// (that's the listening pass). Fractions are relative to processed samples.
    static func makeAudioQCReport(
        metrics: PCM16StreamLimiter.Metrics,
        sampleRate: Int,
        durationSeconds: Double,
        expectedPauseCount: Int,
        chunkQC: [AudioQCChunkReport]? = nil
    ) -> AudioQCReport {
        let n = metrics.processedSamples
        let rms = n > 0 ? (metrics.sumOfSquares / Double(n)).squareRoot() : 0
        let rmsDBFS: Double? = rms > 0 ? 20 * log10(rms) : nil
        let longestSilenceMS = sampleRate > 0
            ? Int(Double(metrics.longestInteriorSilentRunSamples) * 1000 / Double(sampleRate))
            : 0
        let longestSilenceStartMS: Int? = {
            guard let startSample = metrics.longestInteriorSilentRunStartSample, sampleRate > 0 else { return nil }
            return Int(Double(startSample) * 1000 / Double(sampleRate))
        }()
        // Every interior silence run (≥ record floor), in ms — for the
        // punctuation-aware dropout check below.
        let interiorSilencesMS: [Int] = sampleRate > 0
            ? metrics.interiorSilentRunSamples.map { Int(Double($0) * 1000 / Double(sampleRate)) }
            : []
        let clipped = metrics.samplesOutsideUnitRange
        let hot = metrics.samplesAboveCeiling
        let clicks = metrics.slewLimitedSamples
        let denom = max(n, 1)
        let clippedFrac = Double(clipped) / Double(denom)
        let clickFrac = Double(clicks) / Double(denom)
        let hotFrac = Double(hot) / Double(denom)

        // Conservative thresholds (documented; tune as the corpus dictates).
        let silentFailDBFS = -60.0, lowLevelWarnDBFS = -45.0
        let clipFailFrac = 0.001, clickFailFrac = 0.005
        let clickWarnFrac = 0.0005, hotWarnFrac = 0.02
        // Dropout (punctuation-aware). The model emits a prosodic pause at each
        // sentence/clause boundary; on long, slow content these legitimately reach
        // ~800 ms — verified that EVERY long-content interior silence maps to a
        // punctuation mark, so the old fixed 400 ms fail line cried wolf on natural
        // delivery. Instead: count "long pauses" against the text's pause budget
        // (punctuation boundaries) and flag only an EXCESS beyond it, or a single
        // EGREGIOUS gap no natural pause reaches. A real mid-phrase gap that merely
        // replaces a punctuation pause (same count, same ballpark length) is
        // ear-only — the listening pass stays the perceptual gate (telemetry doc).
        let longPauseMS = 350        // "sentence/long-comma" scale pause
        let egregiousMS = 1200       // no natural pause reaches this → always a defect
        let suspiciousSingleMS = 900 // above the observed natural max (~810 ms)
        let longPauseCount = interiorSilencesMS.filter { $0 >= longPauseMS }.count
        let excessLongPauses = max(0, longPauseCount - max(0, expectedPauseCount))

        var flags: [String] = []
        var verdict: AudioQCReport.Verdict = .pass
        func raise(_ to: AudioQCReport.Verdict) {
            if to == .fail { verdict = .fail }
            else if to == .warn, verdict != .fail { verdict = .warn }
        }

        if metrics.nonFiniteSamples > 0 { flags.append("nonfinite"); raise(.fail) }
        if n == 0 { flags.append("empty"); raise(.fail) }
        if let db = rmsDBFS {
            if db < silentFailDBFS { flags.append("near_silent"); raise(.fail) }
            else if db < lowLevelWarnDBFS { flags.append("low_level"); raise(.warn) }
        } else if n > 0 { flags.append("silent"); raise(.fail) }
        if longestSilenceMS >= egregiousMS {
            flags.append("dropout:\(longestSilenceMS)ms"); raise(.fail)
        } else if excessLongPauses >= 2 {
            flags.append("dropout:excess\(excessLongPauses)(\(longPauseCount)/\(expectedPauseCount))"); raise(.fail)
        } else if excessLongPauses == 1 {
            flags.append("dropout:excess1(\(longPauseCount)/\(expectedPauseCount))"); raise(.warn)
        } else if longestSilenceMS >= suspiciousSingleMS {
            flags.append("dropout:\(longestSilenceMS)ms"); raise(.warn)
        }
        if clippedFrac > clipFailFrac { flags.append("clipping"); raise(.fail) }
        else if clipped > 0 { flags.append("clipping"); raise(.warn) }
        if clickFrac > clickFailFrac { flags.append("clicks"); raise(.fail) }
        else if clickFrac > clickWarnFrac { flags.append("clicks"); raise(.warn) }
        if hotFrac > hotWarnFrac { flags.append("hot"); raise(.warn) }

        return AudioQCReport(
            verdict: verdict,
            flags: flags,
            rmsDBFS: rmsDBFS,
            peak: Double(metrics.rawPeak),
            clippedSamples: clipped,
            hotSamples: hot,
            nonFiniteSamples: metrics.nonFiniteSamples,
            clickEvents: clicks,
            longestSilenceMS: longestSilenceMS,
            durationSeconds: durationSeconds,
            firstNonFiniteSample: metrics.firstNonFiniteSample,
            firstClipSample: metrics.firstClipSample,
            longestSilenceStartMS: longestSilenceStartMS,
            chunkQC: chunkQC
        )
    }

    /// Build a per-chunk audio-QC snapshot from raw float samples. Uses a private
    /// limiter instance so the global session limiter's state is untouched. Sample
    /// indices in the report are absolute from the start of the generation.
    private static func makeAudioQCChunkReport(
        chunkIndex: Int,
        frameOffset: Int,
        samples: [Float],
        sampleRate: Int
    ) -> AudioQCChunkReport {
        var limiter = PCM16StreamLimiter()
        var destination: [Int16] = []
        limiter.append(samples, into: &destination)
        let metrics = limiter.metrics
        let durationSeconds = sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
        let report = Self.makeAudioQCReport(
            metrics: metrics,
            sampleRate: sampleRate,
            durationSeconds: durationSeconds,
            expectedPauseCount: 0
        )
        let frameOffsetMS = sampleRate > 0
            ? Int(Double(frameOffset) * 1000 / Double(sampleRate))
            : 0
        return AudioQCChunkReport(
            chunkIndex: chunkIndex,
            frameOffset: frameOffset,
            frameCount: samples.count,
            verdict: report.verdict,
            flags: report.flags,
            rmsDBFS: report.rmsDBFS,
            peak: report.peak,
            clippedSamples: report.clippedSamples,
            hotSamples: report.hotSamples,
            nonFiniteSamples: report.nonFiniteSamples,
            clickEvents: report.clickEvents,
            longestSilenceMS: report.longestSilenceMS,
            durationSeconds: durationSeconds,
            firstNonFiniteSample: report.firstNonFiniteSample.map { $0 + frameOffset },
            firstClipSample: report.firstClipSample.map { $0 + frameOffset },
            longestSilenceStartMS: report.longestSilenceStartMS.map { $0 + frameOffsetMS }
        )
    }

    /// The text's *interior* pause budget for the punctuation-aware dropout check:
    /// the number of sentence/clause boundaries (maximal runs of pause punctuation,
    /// so "..." or ", " count once), excluding a trailing terminal — that final
    /// mark ends the clip and produces no interior silence. The model emits a
    /// prosodic pause at each interior boundary, so this is the count of long
    /// interior silences that is *expected* and benign. Short text with no interior
    /// punctuation gets a budget of 0, so any long interior pause there is flagged.
    static func expectedPauseCount(in text: String) -> Int {
        let pausePunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "…", "—"]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var count = 0
        var inRun = false
        for character in trimmed {
            if pausePunctuation.contains(character) {
                if !inRun { count += 1; inRun = true }
            } else {
                inRun = false
            }
        }
        // Drop the trailing terminal boundary (no interior silence follows it).
        if let last = trimmed.last, pausePunctuation.contains(last), count > 0 {
            count -= 1
        }
        return count
    }

    /// Maps the vendored per-chunk `ChunkSubstageTimings` into the Codable
    /// `GenerationChunkTelemetry`, stamping the chunk index and the wall-clock
    /// arrival (ms and ns since the shared telemetry start clock).
    private func makeChunkTelemetry(
        chunkIndex: Int,
        timings: ChunkSubstageTimings,
        clock: NativeTelemetryClock?
    ) -> GenerationChunkTelemetry {
        let (arrivalMS, arrivalNS) = clock?.now() ?? (0, 0)
        return GenerationChunkTelemetry(
            chunkIndex: chunkIndex,
            arrivalMS: max(0, arrivalMS),
            arrivalNS: arrivalNS,
            talkerForwardMS: timings.talkerForwardMS,
            codePredictorMS: timings.codePredictorMS,
            audioDecoderMS: timings.audioDecoderMS,
            streamStepEvalMS: timings.streamStepEvalMS,
            streamStepEvalEnqueueMS: timings.streamStepEvalEnqueueMS,
            streamStepEvalWaitMS: timings.streamStepEvalWaitMS,
            streamStepEOSReadMS: timings.streamStepEOSReadMS,
            audioChunkEvalMS: timings.audioChunkEvalMS,
            kvCacheDiagnostics: timings.kvCacheDiagnostics,
            mimiDecoderBreakdownMS: timings.mimiDecoderBreakdownMS
        )
    }

    /// Headline backend throughput KPIs derived from data already gathered:
    /// audio duration, decode wall time (preferring the model's `.info` event,
    /// falling back to the stream stage-mark span), the realtime ratio, and
    /// tokens/sec. Computed once at generation end — no hot-path cost.
    private static func computeDerivedMetrics(
        audioSeconds: Double,
        stageMarks: [NativeTelemetryStageMark],
        info: AudioGenerationInfo?,
        modelTimingsMS: [String: Int]
    ) -> [String: Double] {
        var metrics: [String: Double] = ["audioSeconds": audioSeconds]

        // Decode wall time: prefer the model's finalized token-loop total (includes
        // pipelined decoder drain after the `.info` event), else `.info.generateTime`,
        // else the streamStartup→streamGenerationEnded span (excludes WAV finalize).
        let decodeWallSeconds: Double
        if let tokenLoopMS = modelTimingsMS["qwen_token_loop_total"], tokenLoopMS > 0 {
            decodeWallSeconds = Double(tokenLoopMS) / 1_000
        } else if let info, info.generateTime > 0 {
            decodeWallSeconds = info.generateTime
        } else {
            let startMS = stageMarks.first { $0.stage == NativeRuntimeStage.streamStartup.rawValue }?.tMS
            let endMS = stageMarks.first {
                $0.stage == NativeRuntimeStage.streamGenerationEnded.rawValue
                    || $0.stage == NativeRuntimeStage.streamCompleted.rawValue
            }?.tMS
            if let startMS, let endMS, endMS > startMS {
                decodeWallSeconds = Double(endMS - startMS) / 1_000
            } else {
                decodeWallSeconds = 0
            }
        }
        if decodeWallSeconds > 0 {
            metrics["decodeWallSeconds"] = decodeWallSeconds
            metrics["audioSecondsPerWallSecond"] = audioSeconds / decodeWallSeconds
        }

        if let info {
            metrics["generatedTokenCount"] = Double(info.generationTokenCount)
            metrics["tokensPerSecond"] = info.tokensPerSecond
        } else if let codeCount = modelTimingsMS["qwen_generated_code_count"] {
            metrics["generatedTokenCount"] = Double(codeCount)
            if decodeWallSeconds > 0 {
                metrics["tokensPerSecond"] = Double(codeCount) / decodeWallSeconds
            }
        }
        return metrics
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
                    gpuWorkingSetUsageRatioPeak: nil,
                    timeToPeakMS: nil,
                    sampleCount: 0,
                    stageMarks: stageMarks,
                    thermalState: nil
                ),
                []
            )
        }
        return await telemetrySampler.stop(stageMarks: stageMarks)
    }
}
