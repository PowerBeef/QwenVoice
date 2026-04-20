import CryptoKit
import Foundation
@preconcurrency import MLX
import MLXAudioCore
@preconcurrency import MLXAudioTTS
import QwenVoiceEngineSupport

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
    let timingsMS: [String: Int]

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
            timingsMS: timingsMS.merging(additionalTimingsMS) { _, rhs in rhs }
        )
    }
}

actor NativePreparedCloneConditioningCache {
    static let capacity = 16

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
            &decodedReferenceAudioCache,
            lruKeys: &decodedReferenceAudioLRUKeys,
            retainingMostRecent: keepCount
        )
        trimCache(
            &voiceClonePromptCache,
            lruKeys: &voiceClonePromptLRUKeys,
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
        let normalizationStartedAt = ContinuousClock.now
        let normalizedReferenceOutcome = try await normalizeCloneReference(
            reference.audioURL,
            using: audioPreparationService,
            normalizedCloneReferenceDirectory: normalizedCloneReferenceDirectory
        )
        let normalizationDurationMS = normalizationStartedAt.elapsedMilliseconds
        let normalizedReference = normalizedReferenceOutcome.result
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
            refAudio: normalizedReference.normalizedPath,
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
                    preparedCloneUsed: false,
                    cloneCacheHit: true,
                    clonePromptCacheHit: nil,
                    cloneConditioningReused: true,
                    usedTemporaryReference: cached.normalizedReference.normalizedPath
                        != cached.normalizedReference.sourcePath,
                    reusedNormalizedReference: normalizedReferenceOutcome.reusedExistingOutput,
                    reusedDecodedReference: true,
                    timingsMS: [
                        "reference_normalize": normalizationDurationMS,
                        "reference_decode": 0,
                    ]
                )
            }

            let decodeStartedAt = ContinuousClock.now
            let (referenceAudio, reusedDecodedReference) = try resolveDecodedReferenceAudio(
                normalizedReference: normalizedReference,
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
                preparedCloneUsed: false,
                cloneCacheHit: false,
                clonePromptCacheHit: nil,
                cloneConditioningReused: false,
                usedTemporaryReference: normalizedReference.normalizedPath != normalizedReference.sourcePath,
                reusedNormalizedReference: normalizedReferenceOutcome.reusedExistingOutput,
                reusedDecodedReference: reusedDecodedReference,
                timingsMS: [
                    "reference_normalize": normalizationDurationMS,
                    "reference_decode": decodeDurationMS,
                ]
            )
        }

        let decodeStartedAt = ContinuousClock.now
        let (referenceAudio, reusedDecodedReference) = try resolveDecodedReferenceAudio(
            normalizedReference: normalizedReference,
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
            timingsMS: [
                "reference_normalize": normalizationDurationMS,
                "reference_decode": decodeDurationMS,
            ]
        )
    }

    func resolveVoiceClonePrompt(
        for conditioning: ResolvedCloneConditioning,
        modelID: String,
        model: NativeSpeechGenerationModel,
        voicesDirectory: URL?
    ) throws -> ResolvedCloneConditioning {
        guard model.supportsOptimizedVoiceClone,
              conditioning.voiceClonePrompt == nil,
              let transcript = conditioning.resolvedTranscript else {
            return conditioning
        }

        let cacheKey = conditioning.internalIdentityKey
        let artifactDirectory = clonePromptArtifactDirectory(
            voicesDirectory: voicesDirectory,
            preparedVoiceID: conditioning.preparedVoiceID,
            modelID: modelID
        )
        let resolveStartedAt = ContinuousClock.now
        if let artifactDirectory,
           FileManager.default.fileExists(atPath: artifactDirectory.path) {
            let artifactLoadStartedAt = ContinuousClock.now
            do {
                let prompt = try Qwen3TTSVoiceClonePrompt.load(from: artifactDirectory)
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
        cacheVoiceClonePrompt(prompt, for: cacheKey)
        if let artifactDirectory {
            try writeVoiceClonePrompt(prompt, to: artifactDirectory)
        }
        return conditioning.withVoiceClonePrompt(
            prompt,
            cacheHit: false,
            conditioningReused: conditioning.cloneConditioningReused,
            timingsMS: [
                "clone_prompt_build": promptBuildMS,
                "clone_prompt_resolve": resolveStartedAt.elapsedMilliseconds,
            ]
        )
    }

    func hasPersistedVoiceClonePromptArtifact(
        modelID: String,
        preparedVoiceID: String,
        voicesDirectory: URL?
    ) -> Bool {
        guard let directory = clonePromptArtifactDirectory(
            voicesDirectory: voicesDirectory,
            preparedVoiceID: preparedVoiceID,
            modelID: modelID
        ) else {
            return false
        }
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return false
        }

        do {
            _ = try Qwen3TTSVoiceClonePrompt.load(from: directory)
            return true
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return false
        }
    }

    private func insert(_ conditioning: CachedConditioning) {
        cachedValues[conditioning.internalIdentityKey] = conditioning
        touch(conditioning.internalIdentityKey)
        var evicted = false
        while lruKeys.count > Self.capacity {
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
        using audioPreparationService: any AudioPreparationService,
        normalizedCloneReferenceDirectory: URL
    ) async throws -> NormalizedCloneReferenceOutcome {
        let cacheKey = normalizedReferenceCacheKey(for: sourceURL)
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
                Self.stableNormalizedCloneReferenceFileName(for: sourceURL)
            )
            normalizationRequest = AudioPreparationRequest(
                inputURL: sourceURL,
                outputURL: outputURL
            )
            reusedExistingOutput = NativeAudioPreparationService.canReuseExistingNormalizedOutput(
                at: outputURL,
                fingerprint: Self.stableCloneReferenceFingerprint(for: sourceURL)
            )
        }

        let result = try await audioPreparationService.normalizeAudio(normalizationRequest)
        try Self.mirrorTranscriptSidecarIfNeeded(from: sourceURL, to: result.normalizedURL)
        normalizedReferenceCache[cacheKey] = result
        touchNormalizedReference(cacheKey)
        while normalizedReferenceLRUKeys.count > Self.capacity {
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
        sampleRate: Int
    ) throws -> (referenceAudio: MLXArray, reusedDecodedReference: Bool) {
        let key = decodedReferenceAudioCacheKey(
            normalizedPath: normalizedReference.normalizedPath,
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
        while decodedReferenceAudioLRUKeys.count > Self.capacity {
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
        while voiceClonePromptLRUKeys.count > Self.capacity {
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

    static func stableNormalizedCloneReferenceFileName(for sourceURL: URL) -> String {
        let fingerprint = stableCloneReferenceFingerprint(for: sourceURL)
        let stem = sanitizedStem(for: sourceURL)
        return "\(stem)_\(fingerprint).wav"
    }

    private static func sanitizedStem(for sourceURL: URL) -> String {
        let raw = sourceURL.deletingPathExtension().lastPathComponent
        let sanitized = raw
            .replacingOccurrences(of: #"[^\w\s-]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        return sanitized.isEmpty ? "reference" : sanitized
    }

    private static func stableCloneReferenceFingerprint(for sourceURL: URL) -> String {
        let resolvedPath = sourceURL.resolvingSymlinksInPath().path
        let attributes = (try? FileManager.default.attributesOfItem(atPath: resolvedPath)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(resolvedPath)|\(size)|\(modified)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func decodedReferenceAudioCacheKey(
        normalizedPath: String,
        sampleRate: Int
    ) -> String {
        "\(normalizedPath)|\(sampleRate)"
    }

    private func normalizedReferenceCacheKey(for sourceURL: URL) -> String {
        Self.stableCloneReferenceFingerprint(for: sourceURL)
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
        modelID: String
    ) -> URL? {
        guard let voicesDirectory, let preparedVoiceID else { return nil }
        let root = Self.preparedVoiceClonePromptRootDirectory(
            in: voicesDirectory,
            voiceID: preparedVoiceID
        )
        return root.appendingPathComponent(modelID, isDirectory: true)
    }

    private func writeVoiceClonePrompt(
        _ prompt: Qwen3TTSVoiceClonePrompt,
        to directory: URL
    ) throws {
        let fileManager = FileManager.default
        let temporaryDirectory = directory
            .deletingLastPathComponent()
            .appendingPathComponent("\(directory.lastPathComponent).tmp.\(UUID().uuidString)", isDirectory: true)

        if fileManager.fileExists(atPath: temporaryDirectory.path) {
            try? fileManager.removeItem(at: temporaryDirectory)
        }
        defer {
            if fileManager.fileExists(atPath: temporaryDirectory.path) {
                try? fileManager.removeItem(at: temporaryDirectory)
            }
        }

        try prompt.write(to: temporaryDirectory)
        if fileManager.fileExists(atPath: directory.path) {
            _ = try fileManager.replaceItemAt(
                directory,
                withItemAt: temporaryDirectory,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.createDirectory(
                at: directory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: temporaryDirectory, to: directory)
        }
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

extension CloneReference {
    var audioURL: URL {
        URL(fileURLWithPath: audioPath)
    }
}

private extension ContinuousClock.Instant {
    var elapsedMilliseconds: Int {
        duration(to: .now).roundedMilliseconds
    }
}

private extension Duration {
    var roundedMilliseconds: Int {
        let components = components
        let secondsMS = Double(components.seconds) * 1_000
        let attosecondsMS = Double(components.attoseconds) / 1_000_000_000_000_000
        return Int((secondsMS + attosecondsMS).rounded())
    }
}
