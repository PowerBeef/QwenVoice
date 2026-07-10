import CryptoKit
@preconcurrency import AVFoundation
import Foundation
@preconcurrency import MLX
import MLXAudioCore
@preconcurrency import MLXAudioTTS

enum ResolvedCloneTranscriptMode: String, Sendable {
    case inline
    case sidecar
    case none
}

struct ResolvedCloneConditioning: @unchecked Sendable {
    let uiIdentityKey: String
    let internalIdentityKey: String
    let normalizedReference: AudioNormalizationResult
    let resolvedTranscript: String?
    let transcriptMode: ResolvedCloneTranscriptMode
    let referenceAudio: MLXArray
    let preparedVoiceID: String?
    let voiceClonePrompt: Qwen3TTSVoiceClonePrompt?
    let preparedCloneUsed: Bool
    let cloneCacheHit: Bool?
    let clonePromptCacheHit: Bool?
    let cloneConditioningReused: Bool
    let usedTemporaryReference: Bool
    let reusedNormalizedReference: Bool
    let reusedDecodedReference: Bool
    let referenceQualityWarnings: [String]
    var timingsMS: [String: Int]

    func withVoiceClonePrompt(
        _ voiceClonePrompt: Qwen3TTSVoiceClonePrompt,
        cacheHit: Bool,
        conditioningReused: Bool,
        timingsMS additionalTimingsMS: [String: Int] = [:]
    ) -> ResolvedCloneConditioning {
        ResolvedCloneConditioning(
            uiIdentityKey: uiIdentityKey,
            internalIdentityKey: internalIdentityKey,
            normalizedReference: normalizedReference,
            resolvedTranscript: resolvedTranscript,
            transcriptMode: transcriptMode,
            referenceAudio: referenceAudio,
            preparedVoiceID: preparedVoiceID,
            voiceClonePrompt: voiceClonePrompt,
            preparedCloneUsed: true,
            cloneCacheHit: cloneCacheHit,
            clonePromptCacheHit: cacheHit,
            cloneConditioningReused: conditioningReused,
            usedTemporaryReference: usedTemporaryReference,
            reusedNormalizedReference: reusedNormalizedReference,
            reusedDecodedReference: reusedDecodedReference,
            referenceQualityWarnings: referenceQualityWarnings,
            timingsMS: timingsMS.merging(additionalTimingsMS) { _, rhs in rhs }
        )
    }
}

actor NativePreparedCloneConditioningCache {
    private let capacity: Int

    private struct NormalizedCloneReferenceOutcome {
        let result: AudioNormalizationResult
        let reusedExistingOutput: Bool
    }

    private struct DecodedReferenceAudio {
        let referenceAudio: MLXArray
    }

    private struct CachedVoiceClonePrompt {
        let prompt: Qwen3TTSVoiceClonePrompt
    }

    struct CachedConditioning {
        let internalIdentityKey: String
        let normalizedReference: AudioNormalizationResult
        let resolvedTranscript: String
        let transcriptMode: ResolvedCloneTranscriptMode
        let referenceAudio: MLXArray
    }

    private var cachedValues: [String: CachedConditioning] = [:]
    private var lruKeys: [String] = []
    private var normalizedReferenceCache: [String: AudioNormalizationResult] = [:]
    private var normalizedReferenceLRUKeys: [String] = []
    private var decodedReferenceAudioCache: [String: DecodedReferenceAudio] = [:]
    private var decodedReferenceAudioLRUKeys: [String] = []
    private var voiceClonePromptCache: [String: CachedVoiceClonePrompt] = [:]
    private var voiceClonePromptLRUKeys: [String] = []

    init(capacity: Int = NativeMemoryPolicyResolver.cloneCacheCapacity()) {
        self.capacity = max(capacity, 0)
    }

    func clear() {
        cachedValues.removeAll()
        lruKeys.removeAll()
        normalizedReferenceCache.removeAll()
        normalizedReferenceLRUKeys.removeAll()
        decodedReferenceAudioCache.removeAll()
        decodedReferenceAudioLRUKeys.removeAll()
        voiceClonePromptCache.removeAll()
        voiceClonePromptLRUKeys.removeAll()
        Memory.clearCache()
    }

    func softTrim(retainingMostRecent retainedCount: Int = 1) {
        let keepCount = max(retainedCount, 0)
        trimCache(
            &cachedValues,
            lruKeys: &lruKeys,
            retainingMostRecent: keepCount
        )
        trimCache(
            &decodedReferenceAudioCache,
            lruKeys: &decodedReferenceAudioLRUKeys,
            retainingMostRecent: keepCount
        )
        trimCache(
            &voiceClonePromptCache,
            lruKeys: &voiceClonePromptLRUKeys,
            retainingMostRecent: keepCount
        )
        trimCache(
            &normalizedReferenceCache,
            lruKeys: &normalizedReferenceLRUKeys,
            retainingMostRecent: keepCount
        )
        Memory.clearCache()
    }

    func resolve(
        modelID: String,
        reference: CloneReference,
        sampleRate: Int,
        audioPreparationService: any AudioPreparationService,
        normalizedCloneReferenceDirectory: URL
    ) async throws -> ResolvedCloneConditioning {
        let requestedTranscript = Self.normalizedTranscript(reference.transcript)
        let referenceFingerprint = try Self.stableCloneReferenceFingerprint(for: reference.audioURL)
        let normalizationStartedAt = ContinuousClock.now
        let normalizedReferenceOutcome = try await normalizeCloneReference(
            reference.audioURL,
            referenceFingerprint: referenceFingerprint,
            using: audioPreparationService,
            normalizedCloneReferenceDirectory: normalizedCloneReferenceDirectory
        )
        let normalizationDurationMS = normalizationStartedAt.elapsedMilliseconds
        let normalizedReference = normalizedReferenceOutcome.result
        let referenceQualityWarnings = Self.referenceQualityWarnings(for: normalizedReference)
        let transcriptResolution = try Self.resolveTranscript(
            requestedTranscript: requestedTranscript,
            normalizedAudioURL: normalizedReference.normalizedURL
        )
        let uiIdentityKey = GenerationSemantics.cloneReferenceIdentityKey(
            modelID: modelID,
            refAudio: reference.audioPath,
            refText: requestedTranscript
        )
        let internalIdentityKey = GenerationSemantics.cloneReferenceIdentityKey(
            modelID: modelID,
            refAudio: "\(normalizedReference.normalizedPath)#\(referenceFingerprint)",
            refText: transcriptResolution.transcript
        )

        if let resolvedTranscript = transcriptResolution.transcript {
            if let cached = cachedValues[internalIdentityKey] {
                touch(internalIdentityKey)
                return ResolvedCloneConditioning(
                    uiIdentityKey: uiIdentityKey,
                    internalIdentityKey: internalIdentityKey,
                    normalizedReference: cached.normalizedReference,
                    resolvedTranscript: cached.resolvedTranscript,
                    transcriptMode: cached.transcriptMode,
                    referenceAudio: cached.referenceAudio,
                    preparedVoiceID: reference.preparedVoiceID,
                    voiceClonePrompt: nil,
                    preparedCloneUsed: true,
                    cloneCacheHit: true,
                    clonePromptCacheHit: nil,
                    cloneConditioningReused: true,
                    usedTemporaryReference: cached.normalizedReference.normalizedPath
                        != cached.normalizedReference.sourcePath,
                    reusedNormalizedReference: normalizedReferenceOutcome.reusedExistingOutput,
                    reusedDecodedReference: true,
                    referenceQualityWarnings: referenceQualityWarnings,
                    timingsMS: [
                        "reference_normalize": normalizationDurationMS,
                        "reference_decode": 0,
                    ]
                )
            }

            let decodeStartedAt = ContinuousClock.now
            let (referenceAudio, reusedDecodedReference) = try resolveDecodedReferenceAudio(
                normalizedReference: normalizedReference,
                referenceFingerprint: referenceFingerprint,
                sampleRate: sampleRate
            )
            let decodeDurationMS = decodeStartedAt.elapsedMilliseconds
            let cached = CachedConditioning(
                internalIdentityKey: internalIdentityKey,
                normalizedReference: normalizedReference,
                resolvedTranscript: resolvedTranscript,
                transcriptMode: transcriptResolution.mode,
                referenceAudio: referenceAudio
            )
            insert(cached)
            return ResolvedCloneConditioning(
                uiIdentityKey: uiIdentityKey,
                internalIdentityKey: internalIdentityKey,
                normalizedReference: normalizedReference,
                resolvedTranscript: resolvedTranscript,
                transcriptMode: transcriptResolution.mode,
                referenceAudio: referenceAudio,
                preparedVoiceID: reference.preparedVoiceID,
                voiceClonePrompt: nil,
                preparedCloneUsed: true,
                cloneCacheHit: false,
                clonePromptCacheHit: nil,
                cloneConditioningReused: false,
                usedTemporaryReference: normalizedReference.normalizedPath != normalizedReference.sourcePath,
                reusedNormalizedReference: normalizedReferenceOutcome.reusedExistingOutput,
                reusedDecodedReference: reusedDecodedReference,
                referenceQualityWarnings: referenceQualityWarnings,
                timingsMS: [
                    "reference_normalize": normalizationDurationMS,
                    "reference_decode": decodeDurationMS,
                ]
            )
        }

        let decodeStartedAt = ContinuousClock.now
        let (referenceAudio, reusedDecodedReference) = try resolveDecodedReferenceAudio(
            normalizedReference: normalizedReference,
            referenceFingerprint: referenceFingerprint,
            sampleRate: sampleRate
        )
        let decodeDurationMS = decodeStartedAt.elapsedMilliseconds
        return ResolvedCloneConditioning(
            uiIdentityKey: uiIdentityKey,
            internalIdentityKey: internalIdentityKey,
            normalizedReference: normalizedReference,
            resolvedTranscript: nil,
            transcriptMode: .none,
            referenceAudio: referenceAudio,
            preparedVoiceID: reference.preparedVoiceID,
            voiceClonePrompt: nil,
            preparedCloneUsed: false,
            cloneCacheHit: nil,
            clonePromptCacheHit: nil,
            cloneConditioningReused: false,
            usedTemporaryReference: normalizedReference.normalizedPath != normalizedReference.sourcePath,
            reusedNormalizedReference: normalizedReferenceOutcome.reusedExistingOutput,
            reusedDecodedReference: reusedDecodedReference,
            referenceQualityWarnings: referenceQualityWarnings,
            timingsMS: [
                "reference_normalize": normalizationDurationMS,
                "reference_decode": decodeDurationMS,
            ]
        )
    }

    func resolveVoiceClonePrompt(
        for conditioning: ResolvedCloneConditioning,
        modelID: String,
        model: UnsafeSpeechGenerationModel,
        voicesDirectory: URL?,
        language: String? = nil,
        qwenRuntimeProfileSignature: String? = nil
    ) throws -> ResolvedCloneConditioning {
        guard model.supportsOptimizedVoiceClone,
              conditioning.voiceClonePrompt == nil,
              let transcript = conditioning.resolvedTranscript else {
            return conditioning
        }

        let cacheKey = conditioning.internalIdentityKey
        let artifactMetadata = clonePromptArtifactMetadata(
            modelID: modelID,
            conditioning: conditioning,
            language: language,
            xVectorOnlyMode: false,
            qwenRuntimeProfileSignature: qwenRuntimeProfileSignature
        )
        let artifactDirectory = clonePromptArtifactDirectory(
            voicesDirectory: voicesDirectory,
            preparedVoiceID: conditioning.preparedVoiceID,
            modelID: modelID,
            conditioning: conditioning,
            language: language
        )
        let resolveStartedAt = ContinuousClock.now
        if let artifactDirectory,
           FileManager.default.fileExists(atPath: artifactDirectory.path) {
            let artifactLoadStartedAt = ContinuousClock.now
            do {
                let prompt = try Qwen3TTSVoiceClonePrompt.load(
                    from: artifactDirectory,
                    expectedMetadata: artifactMetadata
                )
                cacheVoiceClonePrompt(prompt, for: cacheKey)
                return conditioning.withVoiceClonePrompt(
                    prompt,
                    cacheHit: true,
                    conditioningReused: true,
                    timingsMS: [
                        "clone_prompt_artifact_load": artifactLoadStartedAt.elapsedMilliseconds,
                        "clone_prompt_resolve": resolveStartedAt.elapsedMilliseconds,
                    ]
                )
            } catch {
                try? FileManager.default.removeItem(at: artifactDirectory)
            }
        }

        if let cached = voiceClonePromptCache[cacheKey] {
            touchVoiceClonePrompt(cacheKey)
            return conditioning.withVoiceClonePrompt(
                cached.prompt,
                cacheHit: true,
                conditioningReused: true,
                timingsMS: [
                    "clone_prompt_resolve": resolveStartedAt.elapsedMilliseconds,
                ]
            )
        }

        let promptBuildStartedAt = ContinuousClock.now
        guard let prompt = try model.createVoiceClonePrompt(
            refAudio: conditioning.referenceAudio,
            refText: transcript,
            xVectorOnlyMode: false
        ) else {
            return conditioning
        }
        let promptBuildMS = promptBuildStartedAt.elapsedMilliseconds
        let promptWithMetadata = prompt.withArtifactMetadata(
            artifactMetadata.fillingCreatedAtIfNeeded()
        )
        cacheVoiceClonePrompt(promptWithMetadata, for: cacheKey)
        if let artifactDirectory {
            try writeVoiceClonePrompt(promptWithMetadata, to: artifactDirectory)
        }
        return conditioning.withVoiceClonePrompt(
            promptWithMetadata,
            cacheHit: false,
            conditioningReused: conditioning.cloneConditioningReused,
            timingsMS: [
                "clone_prompt_build": promptBuildMS,
                "clone_prompt_resolve": resolveStartedAt.elapsedMilliseconds,
            ]
        )
    }

    private func insert(_ conditioning: CachedConditioning) {
        cachedValues[conditioning.internalIdentityKey] = conditioning
        touch(conditioning.internalIdentityKey)
        var evicted = false
        while lruKeys.count > capacity {
            let evictedKey = lruKeys.removeFirst()
            cachedValues.removeValue(forKey: evictedKey)
            evicted = true
        }
        if evicted {
            Memory.clearCache()
        }
    }

    private func touch(_ key: String) {
        lruKeys.removeAll { $0 == key }
        lruKeys.append(key)
    }

    private func normalizeCloneReference(
        _ sourceURL: URL,
        referenceFingerprint: String,
        using audioPreparationService: any AudioPreparationService,
        normalizedCloneReferenceDirectory: URL
    ) async throws -> NormalizedCloneReferenceOutcome {
        let cacheKey = normalizedReferenceCacheKey(referenceFingerprint: referenceFingerprint)
        if let cachedResult = normalizedReferenceCache[cacheKey],
           Self.canReuseCachedNormalizedReference(cachedResult, for: sourceURL) {
            touchNormalizedReference(cacheKey)
            try Self.mirrorTranscriptSidecarIfNeeded(from: sourceURL, to: cachedResult.normalizedURL)
            return NormalizedCloneReferenceOutcome(
                result: cachedResult,
                reusedExistingOutput: true
            )
        }

        let normalizationRequest: AudioPreparationRequest
        let reusedExistingOutput: Bool
        if NativeAudioPreparationService.isCanonicalWAV(at: sourceURL) {
            normalizationRequest = AudioPreparationRequest(inputURL: sourceURL)
            reusedExistingOutput = false
        } else {
            let outputURL = normalizedCloneReferenceDirectory.appendingPathComponent(
                Self.stableNormalizedCloneReferenceFileName(
                    for: sourceURL,
                    referenceFingerprint: referenceFingerprint
                )
            )
            normalizationRequest = AudioPreparationRequest(
                inputURL: sourceURL,
                outputURL: outputURL
            )
            reusedExistingOutput = NativeAudioPreparationService.canReuseExistingNormalizedOutput(
                at: outputURL,
                fingerprint: referenceFingerprint
            )
        }

        let result = try await audioPreparationService.normalizeAudio(normalizationRequest)
        try Self.mirrorTranscriptSidecarIfNeeded(from: sourceURL, to: result.normalizedURL)
        normalizedReferenceCache[cacheKey] = result
        touchNormalizedReference(cacheKey)
        while normalizedReferenceLRUKeys.count > capacity {
            let evictedKey = normalizedReferenceLRUKeys.removeFirst()
            normalizedReferenceCache.removeValue(forKey: evictedKey)
        }
        return NormalizedCloneReferenceOutcome(
            result: result,
            reusedExistingOutput: reusedExistingOutput
        )
    }

    private func touchNormalizedReference(_ key: String) {
        normalizedReferenceLRUKeys.removeAll { $0 == key }
        normalizedReferenceLRUKeys.append(key)
    }

    private func resolveDecodedReferenceAudio(
        normalizedReference: AudioNormalizationResult,
        referenceFingerprint: String,
        sampleRate: Int
    ) throws -> (referenceAudio: MLXArray, reusedDecodedReference: Bool) {
        let key = decodedReferenceAudioCacheKey(
            normalizedPath: normalizedReference.normalizedPath,
            referenceFingerprint: referenceFingerprint,
            sampleRate: sampleRate
        )
        if let cached = decodedReferenceAudioCache[key] {
            touchDecodedReferenceAudio(key)
            return (cached.referenceAudio, true)
        }

        let (_, referenceAudio) = try loadAudioArray(
            from: normalizedReference.normalizedURL,
            sampleRate: sampleRate
        )
        decodedReferenceAudioCache[key] = DecodedReferenceAudio(referenceAudio: referenceAudio)
        touchDecodedReferenceAudio(key)
        var evicted = false
        while decodedReferenceAudioLRUKeys.count > capacity {
            let evictedKey = decodedReferenceAudioLRUKeys.removeFirst()
            decodedReferenceAudioCache.removeValue(forKey: evictedKey)
            evicted = true
        }
        if evicted {
            Memory.clearCache()
        }
        return (referenceAudio, false)
    }

    private func touchDecodedReferenceAudio(_ key: String) {
        decodedReferenceAudioLRUKeys.removeAll { $0 == key }
        decodedReferenceAudioLRUKeys.append(key)
    }

    private func cacheVoiceClonePrompt(_ prompt: Qwen3TTSVoiceClonePrompt, for key: String) {
        voiceClonePromptCache[key] = CachedVoiceClonePrompt(prompt: prompt)
        touchVoiceClonePrompt(key)
        var evicted = false
        while voiceClonePromptLRUKeys.count > capacity {
            let evictedKey = voiceClonePromptLRUKeys.removeFirst()
            voiceClonePromptCache.removeValue(forKey: evictedKey)
            evicted = true
        }
        if evicted {
            Memory.clearCache()
        }
    }

    private func touchVoiceClonePrompt(_ key: String) {
        voiceClonePromptLRUKeys.removeAll { $0 == key }
        voiceClonePromptLRUKeys.append(key)
    }

    private func trimCache<Value>(
        _ cache: inout [String: Value],
        lruKeys: inout [String],
        retainingMostRecent retainedCount: Int
    ) {
        guard retainedCount < lruKeys.count else { return }
        let retainedKeys = Set(lruKeys.suffix(retainedCount))
        cache = cache.filter { retainedKeys.contains($0.key) }
        lruKeys = lruKeys.filter { retainedKeys.contains($0) }
    }

    private static func canReuseCachedNormalizedReference(
        _ result: AudioNormalizationResult,
        for sourceURL: URL
    ) -> Bool {
        guard result.sourceURL.standardizedFileURL == sourceURL.standardizedFileURL else {
            return false
        }
        if result.wasAlreadyCanonical {
            return NativeAudioPreparationService.isCanonicalWAV(at: sourceURL)
        }
        return NativeAudioPreparationService.canReuseExistingNormalizedOutput(
            at: result.normalizedURL,
            fingerprint: result.fingerprint
        )
    }

    static func referenceQualityWarnings(for result: AudioNormalizationResult) -> [String] {
        var warnings: [String] = []
        // Duration tiers (see PreparedVoiceQualityWarning.summary doc for
        // the source of these thresholds — Alibaba Cloud Model Studio's
        // hosted Qwen-TTS API guidance, not a documented Qwen3-TTS cliff):
        //   <10 s            → short (likely insufficient speaker info)
        //   10–30 s          → no warning (10–20 s is the sweet spot)
        //   30–60 s          → long (outside sweet spot, soft warn)
        //   >60 s            → excessive (hard cap, blocks Keep voice)
        if result.durationSeconds < 10 {
            warnings.append("reference_duration_short")
        } else if result.durationSeconds > 60 {
            warnings.append("reference_duration_excessive")
        } else if result.durationSeconds > 30 {
            warnings.append("reference_duration_long")
        }
        if abs(result.sampleRate - 24_000) > 0.001 {
            warnings.append("reference_sample_rate_noncanonical")
        }
        if result.channelCount != 1 {
            warnings.append("reference_channels_noncanonical")
        }

        guard let audioStats = try? referenceAudioStats(at: result.normalizedURL) else {
            warnings.append("reference_quality_unreadable")
            return warnings
        }
        if audioStats.rms < 0.0005 {
            warnings.append("reference_near_silence")
        }
        if audioStats.peak >= 0.98 {
            warnings.append("reference_possible_clipping")
        }
        return warnings
    }

    private static func referenceAudioStats(at url: URL) throws -> (peak: Float, rms: Float) {
        let file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: file.processingFormat.sampleRate,
            channels: file.processingFormat.channelCount,
            interleaved: false
        ) else {
            throw AudioPreparationError.conversionFailed("Could not create analysis format for clone reference.")
        }
        let maxFrames = min(file.length, AVAudioFramePosition(24_000 * 30))
        guard maxFrames > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(maxFrames)
              ) else {
            return (0, 0)
        }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(maxFrames))
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else {
            return (0, 0)
        }

        var peak: Float = 0
        var sumSquares: Double = 0
        var sampleCount = 0
        for channel in 0..<channels {
            guard let samples = buffer.floatChannelData?[channel] else { continue }
            for frame in 0..<frames {
                let value = samples[frame]
                let magnitude = abs(value)
                peak = max(peak, magnitude)
                sumSquares += Double(value * value)
                sampleCount += 1
            }
        }
        guard sampleCount > 0 else { return (0, 0) }
        return (peak, Float((sumSquares / Double(sampleCount)).squareRoot()))
    }

    private static func resolveTranscript(
        requestedTranscript: String?,
        normalizedAudioURL: URL
    ) throws -> (transcript: String?, mode: ResolvedCloneTranscriptMode) {
        if let requestedTranscript {
            return (requestedTranscript, .inline)
        }

        let sidecarURL = normalizedAudioURL.deletingPathExtension().appendingPathExtension("txt")
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
            return (nil, .none)
        }

        let text = try String(contentsOf: sidecarURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? (nil, .none) : (text, .sidecar)
    }

    private static func mirrorTranscriptSidecarIfNeeded(from sourceURL: URL, to normalizedURL: URL) throws {
        let fileManager = FileManager.default
        let sourceSidecarURL = sourceURL.deletingPathExtension().appendingPathExtension("txt")
        let normalizedSidecarURL = normalizedURL.deletingPathExtension().appendingPathExtension("txt")

        guard fileManager.fileExists(atPath: sourceSidecarURL.path) else {
            if normalizedSidecarURL.standardizedFileURL != sourceSidecarURL.standardizedFileURL,
               fileManager.fileExists(atPath: normalizedSidecarURL.path) {
                try? fileManager.removeItem(at: normalizedSidecarURL)
            }
            return
        }

        if normalizedSidecarURL.standardizedFileURL == sourceSidecarURL.standardizedFileURL {
            return
        }

        try fileManager.createDirectory(
            at: normalizedSidecarURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: normalizedSidecarURL.path) {
            try fileManager.removeItem(at: normalizedSidecarURL)
        }
        try fileManager.copyItem(at: sourceSidecarURL, to: normalizedSidecarURL)
    }

    static func normalizedTranscript(_ transcript: String?) -> String? {
        guard let transcript else { return nil }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func stableNormalizedCloneReferenceFileName(for sourceURL: URL) throws -> String {
        let fingerprint = try stableCloneReferenceFingerprint(for: sourceURL)
        return stableNormalizedCloneReferenceFileName(
            for: sourceURL,
            referenceFingerprint: fingerprint
        )
    }

    static func stableNormalizedCloneReferenceFileName(
        for sourceURL: URL,
        referenceFingerprint: String
    ) -> String {
        let stem = sanitizedStem(for: sourceURL)
        return "\(stem)_\(referenceFingerprint).wav"
    }

    private static func sanitizedStem(for sourceURL: URL) -> String {
        let raw = sourceURL.deletingPathExtension().lastPathComponent
        let sanitized = raw
            .replacingOccurrences(of: #"[^\w\s-]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        return sanitized.isEmpty ? "reference" : sanitized
    }

    static func stableCloneReferenceFingerprint(for sourceURL: URL) throws -> String {
        let resolvedURL = URL(fileURLWithPath: sourceURL.resolvingSymlinksInPath().path)
        let fileHandle = try FileHandle(forReadingFrom: resolvedURL)
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try fileHandle.read(upToCount: 1024 * 1024),
                  !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func decodedReferenceAudioCacheKey(
        normalizedPath: String,
        referenceFingerprint: String,
        sampleRate: Int
    ) -> String {
        "\(normalizedPath)|\(referenceFingerprint)|\(sampleRate)"
    }

    private func normalizedReferenceCacheKey(referenceFingerprint: String) -> String {
        referenceFingerprint
    }

    static func preparedVoiceClonePromptRootDirectory(
        in voicesDirectory: URL,
        voiceID: String
    ) -> URL {
        voicesDirectory.appendingPathComponent("\(voiceID).clone_prompt", isDirectory: true)
    }

    private func clonePromptArtifactDirectory(
        voicesDirectory: URL?,
        preparedVoiceID: String?,
        modelID: String,
        conditioning: ResolvedCloneConditioning? = nil,
        language: String? = nil
    ) -> URL? {
        guard let voicesDirectory else { return nil }
        if let preparedVoiceID {
            let root = Self.preparedVoiceClonePromptRootDirectory(
                in: voicesDirectory,
                voiceID: preparedVoiceID
            )
            let modelRoot = root.appendingPathComponent(modelID, isDirectory: true)
            guard let conditioning else { return modelRoot }
            return modelRoot.appendingPathComponent(
                clonePromptArtifactDigest(
                    modelID: modelID,
                    conditioning: conditioning,
                    language: language
                ),
                isDirectory: true
            )
        }
        guard let conditioning else { return nil }
        let digest = clonePromptArtifactDigest(
            modelID: modelID,
            conditioning: conditioning,
            language: language
        )
        return voicesDirectory
            .appendingPathComponent(".qvoice_clone_prompts", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
    }

    private func clonePromptArtifactDigest(
        modelID: String,
        conditioning: ResolvedCloneConditioning,
        language: String?
    ) -> String {
        let normalizedLanguage = (language ?? "auto")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let identity = [
            modelID,
            conditioning.internalIdentityKey,
            normalizedLanguage.isEmpty ? "auto" : normalizedLanguage,
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        return digest
    }

    private func clonePromptArtifactMetadata(
        modelID: String,
        conditioning: ResolvedCloneConditioning,
        language: String?,
        xVectorOnlyMode: Bool,
        qwenRuntimeProfileSignature: String?
    ) -> Qwen3TTSVoiceClonePrompt.ArtifactMetadata {
        let normalizedLanguage = Self.normalizedClonePromptLanguage(language)
        return Qwen3TTSVoiceClonePrompt.ArtifactMetadata(
            modelID: modelID,
            language: normalizedLanguage,
            sourceAudioFingerprint: conditioning.normalizedReference.fingerprint,
            transcriptHash: conditioning.resolvedTranscript.map(Self.sha256Hex(text:)),
            hasTranscript: conditioning.resolvedTranscript != nil,
            xVectorOnlyMode: xVectorOnlyMode,
            qwen3RuntimeProfileSignature: qwenRuntimeProfileSignature
        )
    }

    private static func normalizedClonePromptLanguage(_ language: String?) -> String {
        let normalized = (language ?? "auto")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? "auto" : normalized
    }

    private static func sha256Hex(text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func writeVoiceClonePrompt(
        _ prompt: Qwen3TTSVoiceClonePrompt,
        to directory: URL
    ) throws {
        try prompt.writeAtomically(to: directory)
    }
}

enum NativeSavedVoiceNaming {
    static func normalizedName(_ rawName: String) -> String {
        rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"[\\/:*?"<>|\p{Cc}]"#,
                with: "",
                options: .regularExpression
            )
    }
}
