import Foundation
import Hub
import HuggingFace
@preconcurrency import MLX
import MLXAudioCore
@preconcurrency import MLXLMCommon
import MLXNN
import Tokenizers

private func qwen3TTSLog(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private final class CachedTokenizerBox: @unchecked Sendable {
    let tokenizer: Tokenizer

    init(tokenizer: Tokenizer) {
        self.tokenizer = tokenizer
    }
}

private final class CachedSpeechTokenizerBox: @unchecked Sendable {
    let speechTokenizer: Qwen3TTSSpeechTokenizer

    init(speechTokenizer: Qwen3TTSSpeechTokenizer) {
        self.speechTokenizer = speechTokenizer
    }
}

private struct LoadedTalkerComponents: @unchecked Sendable {
    let talker: Qwen3TTSTalkerForConditionalGeneration
    let speakerEncoder: Qwen3TTSSpeakerEncoder?
    let talkerWeightLoadMS: Int
    let timingsMS: [String: Int]
    let booleanFlags: [String: Bool]
}

private struct LoadedTokenizerComponent: Sendable {
    let tokenizer: (any Tokenizer)?
    let cacheHit: Bool
    let directConfigLoadUsed: Bool
    let directConfigFallbackUsed: Bool
    let loadMS: Int
}

private struct LoadedSpeechTokenizerComponent: @unchecked Sendable {
    let speechTokenizer: Qwen3TTSSpeechTokenizer?
    let cacheHit: Bool
    let loadMS: Int
    let booleanFlags: [String: Bool]
}

private struct QwenPreparedLoadOptions: Sendable {
    let trustPreparedCheckpoint: Bool
    let loadSpeakerEncoder: Bool?
    let loadSpeechTokenizerEncoder: Bool?
    let skipSpeechTokenizerEval: Bool
}

private let talkerEvalLayerBatchSize = 4
private let speechTokenizerEvalBatchSize = 8

private actor Qwen3TTSPreparedComponentCache {
    static let shared = Qwen3TTSPreparedComponentCache()

    private var tokenizersByPreparedKey: [String: CachedTokenizerBox] = [:]
    private var speechTokenizersByPreparedKey: [String: CachedSpeechTokenizerBox] = [:]

    func cachedTokenizer(for preparedKey: String) -> CachedTokenizerBox? {
        tokenizersByPreparedKey[preparedKey]
    }

    func cachedSpeechTokenizer(for preparedKey: String) -> CachedSpeechTokenizerBox? {
        if let box = speechTokenizersByPreparedKey[preparedKey] {
            box.speechTokenizer.decoder.resetStreamingState()
            return box
        }
        return nil
    }

    func storeTokenizer(_ tokenizer: Tokenizer, for preparedKey: String) {
        tokenizersByPreparedKey[preparedKey] = CachedTokenizerBox(tokenizer: tokenizer)
    }

    func storeSpeechTokenizer(_ speechTokenizer: Qwen3TTSSpeechTokenizer, for preparedKey: String) {
        speechTokenizer.decoder.resetStreamingState()
        speechTokenizersByPreparedKey[preparedKey] = CachedSpeechTokenizerBox(
            speechTokenizer: speechTokenizer
        )
    }

    func storeSpeechTokenizerAndReturn(
        _ speechTokenizer: Qwen3TTSSpeechTokenizer,
        for preparedKey: String
    ) -> CachedSpeechTokenizerBox {
        speechTokenizer.decoder.resetStreamingState()
        let box = CachedSpeechTokenizerBox(speechTokenizer: speechTokenizer)
        speechTokenizersByPreparedKey[preparedKey] = box
        return box
    }
}

public struct Qwen3TTSVoiceClonePrompt: @unchecked Sendable {
    public struct Manifest: Codable, Sendable {
        public let schemaVersion: Int
        public let refText: String?
        public let xVectorOnlyMode: Bool
        public let iclMode: Bool
    }

    public static let schemaVersion = 1
    public let refCodes: MLXArray?
    public let speakerEmbedding: MLXArray?
    public let refText: String?
    public let xVectorOnlyMode: Bool
    public let iclMode: Bool

    public init(
        refCodes: MLXArray?,
        speakerEmbedding: MLXArray?,
        refText: String?,
        xVectorOnlyMode: Bool,
        iclMode: Bool
    ) {
        self.refCodes = refCodes
        self.speakerEmbedding = speakerEmbedding
        self.refText = refText
        self.xVectorOnlyMode = xVectorOnlyMode
        self.iclMode = iclMode
    }

    public func write(to directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let manifest = Manifest(
            schemaVersion: Self.schemaVersion,
            refText: refText,
            xVectorOnlyMode: xVectorOnlyMode,
            iclMode: iclMode
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        let refCodesURL = directory.appendingPathComponent("ref_codes.safetensors")
        let speakerEmbeddingURL = directory.appendingPathComponent("speaker_embedding.safetensors")

        if let refCodes {
            try MLX.save(arrays: ["ref_codes": refCodes], url: refCodesURL)
        } else if fileManager.fileExists(atPath: refCodesURL.path) {
            try fileManager.removeItem(at: refCodesURL)
        }

        if let speakerEmbedding {
            try MLX.save(arrays: ["speaker_embedding": speakerEmbedding], url: speakerEmbeddingURL)
        } else if fileManager.fileExists(atPath: speakerEmbeddingURL.path) {
            try fileManager.removeItem(at: speakerEmbeddingURL)
        }
    }

    public static func load(from directory: URL) throws -> Qwen3TTSVoiceClonePrompt {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.schemaVersion == schemaVersion else {
            throw AudioGenerationError.modelNotInitialized(
                "Unsupported Qwen3 clone prompt artifact version: \(manifest.schemaVersion)"
            )
        }

        let refCodesURL = directory.appendingPathComponent("ref_codes.safetensors")
        let speakerEmbeddingURL = directory.appendingPathComponent("speaker_embedding.safetensors")

        let refCodes = try Self.loadSingleArray(named: "ref_codes", from: refCodesURL)
        let speakerEmbedding = try Self.loadSingleArray(
            named: "speaker_embedding",
            from: speakerEmbeddingURL
        )

        return Qwen3TTSVoiceClonePrompt(
            refCodes: refCodes,
            speakerEmbedding: speakerEmbedding,
            refText: manifest.refText,
            xVectorOnlyMode: manifest.xVectorOnlyMode,
            iclMode: manifest.iclMode
        )
    }

    private static func loadSingleArray(named key: String, from url: URL) throws -> MLXArray? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let arrays = try MLX.loadArrays(url: url)
        return arrays[key]
    }
}

private struct CachedConditioningPrefix: @unchecked Sendable {
    let inputPrefixEmbeds: MLXArray
    let codecLastEmbed: MLXArray
    let ttsEosEmbed: MLXArray
    let ttsPadEmbed: MLXArray
}

private final class CachedConditioningPrefixBox: @unchecked Sendable {
    let prefix: CachedConditioningPrefix

    init(prefix: CachedConditioningPrefix) {
        self.prefix = prefix
    }
}

private final class Qwen3TTSConditioningPrefixCache: @unchecked Sendable {
    static let shared = Qwen3TTSConditioningPrefixCache()

    private let lock = NSLock()
    private var prefixesByKey: [String: CachedConditioningPrefixBox] = [:]

    func cachedPrefix(for cacheKey: String) -> CachedConditioningPrefix? {
        lock.lock()
        defer { lock.unlock() }
        return prefixesByKey[cacheKey]?.prefix
    }

    func storePrefix(_ prefix: CachedConditioningPrefix, for cacheKey: String) {
        lock.lock()
        prefixesByKey[cacheKey] = CachedConditioningPrefixBox(prefix: prefix)
        lock.unlock()
    }
}

private final class Qwen3TTSStreamingDecoderBucketCache: @unchecked Sendable {
    static let shared = Qwen3TTSStreamingDecoderBucketCache()

    private let lock = NSLock()
    private var warmedKeys: Set<String> = []

    func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return warmedKeys.contains(key)
    }

    func insert(_ key: String) {
        lock.lock()
        warmedKeys.insert(key)
        lock.unlock()
    }
}

// MARK: - Qwen3TTS Model

public final class Qwen3TTSModel: Module, SpeechGenerationModel, Qwen3OptimizedSpeechGenerationModel, SpeechGenerationModelDiagnosticsProvider, @unchecked Sendable {
    let config: Qwen3TTSModelConfig
    let talker: Qwen3TTSTalkerForConditionalGeneration
    var speakerEncoder: Qwen3TTSSpeakerEncoder?
    var speechTokenizer: Qwen3TTSSpeechTokenizer?
    var tokenizer: Tokenizer?
    private var preparedKey: String?
    private let diagnosticsLock = NSLock()
    private var storedLoadTimingsMS: [String: Int] = [:]
    private var storedLoadBooleanFlags: [String: Bool] = [:]
    private var storedPreparationTimingsMS: [String: Int] = [:]
    private var storedPreparationBooleanFlags: [String: Bool] = [:]

    public var sampleRate: Int { config.sampleRate }
    public var loadTimingsMS: [String: Int] {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return storedLoadTimingsMS
    }

    public var loadBooleanFlags: [String: Bool] {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return storedLoadBooleanFlags
    }

    public var latestPreparationTimingsMS: [String: Int] {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return storedPreparationTimingsMS
    }

    public var latestPreparationBooleanFlags: [String: Bool] {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return storedPreparationBooleanFlags
    }

    public func resetPreparationDiagnostics() {
        diagnosticsLock.lock()
        storedPreparationTimingsMS = [:]
        storedPreparationBooleanFlags = [:]
        diagnosticsLock.unlock()
    }

    public var defaultGenerationParameters: GenerateParameters {
        GenerateParameters(
            maxTokens: 4096,
            temperature: 0.9,
            topP: 1.0,
            repetitionPenalty: 1.05
        )
    }

    private func trimmedInstruction(_ instruct: String?) -> String? {
        guard let instruct else { return nil }
        let trimmed = instruct.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedConditioningCacheKeyText(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func conditioningCacheKey(for mode: String) -> String? {
        guard let preparedKey else { return nil }
        return "\(preparedKey)|\(mode)"
    }

    private func decoderBucketCacheKey() -> String? {
        guard let preparedKey else { return nil }
        return "\(preparedKey)|decoder_buckets|4,1,2,3"
    }

    private func decoderBucketCacheHit() -> Bool {
        guard let cacheKey = decoderBucketCacheKey() else { return false }
        return Qwen3TTSStreamingDecoderBucketCache.shared.contains(cacheKey)
    }

    private func resolvedLanguageIdentifier(language: String, speaker: String? = nil) -> Int? {
        guard let talkerConfig = config.talkerConfig else { return nil }

        let normalizedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedSpeaker = speaker?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if (normalizedLanguage == "auto" || normalizedLanguage == "chinese"),
           let normalizedSpeaker,
           let dialect = talkerConfig.spkIsDialect?[normalizedSpeaker],
           let dialectLanguageID = talkerConfig.codecLanguageId?[dialect] {
            return dialectLanguageID
        }

        guard normalizedLanguage != "auto" else {
            return nil
        }
        return talkerConfig.codecLanguageId?[normalizedLanguage]
    }

    private func speakerTokenEmbeddings(for speaker: String?) throws -> MLXArray? {
        guard let talkerConfig = config.talkerConfig else { return nil }
        guard let speaker else { return nil }

        let normalizedSpeaker = speaker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedSpeaker.isEmpty else { return nil }
        guard let speakerIDs = talkerConfig.spkId?[normalizedSpeaker], !speakerIDs.isEmpty else {
            throw AudioGenerationError.modelNotInitialized(
                "Unsupported Qwen3 speaker '\(speaker)'"
            )
        }

        let tokenIDs = MLXArray(speakerIDs.map(Int32.init)).reshaped(1, -1)
        return talker.getInputEmbeddings()(tokenIDs)
    }

    private func prefixCacheKeyForCustomVoice(language: String, speaker: String, instruct: String?) -> String? {
        let normalizedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedSpeaker = speaker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedInstruction = trimmedInstruction(instruct)?.lowercased() ?? ""
        return conditioningCacheKey(
            for: "custom|\(normalizedLanguage)|\(normalizedSpeaker)|\(normalizedInstruction)"
        )
    }

    private func prefixCacheKeyForVoiceDesign(language: String, voiceDescription: String) -> String? {
        let normalizedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedDescription = normalizedConditioningCacheKeyText(voiceDescription)
        return conditioningCacheKey(
            for: "design|\(normalizedLanguage)|\(normalizedDescription)"
        )
    }

    private func buildConditioningPrefix(
        language: String,
        speaker: String?,
        instruct: String?,
        cacheKey: String?
    ) throws -> (CachedConditioningPrefix, Bool, Int, Int) {
        let prefixCache = Qwen3TTSConditioningPrefixCache.shared
        if let cacheKey,
           let cachedPrefix = prefixCache.cachedPrefix(for: cacheKey) {
            return (cachedPrefix, true, 0, 0)
        }

        guard let tokenizer, let talkerConfig = config.talkerConfig else {
            throw AudioGenerationError.modelNotInitialized("Tokenizer/config not loaded")
        }

        let prefixTokenizeStartedAt = ContinuousClock.now

        let ttsTokens = MLXArray(
            [Int32(config.ttsBosTokenId), Int32(config.ttsEosTokenId), Int32(config.ttsPadTokenId)]
        ).reshaped(1, 3)
        let ttsEmbeds = talker.textProjection(talker.getTextEmbeddings()(ttsTokens))
        let ttsBosEmbed = ttsEmbeds[0..., 0 ..< 1, 0...]
        let ttsEosEmbed = ttsEmbeds[0..., 1 ..< 2, 0...]
        let ttsPadEmbed = ttsEmbeds[0..., 2 ..< 3, 0...]

        let languageId = resolvedLanguageIdentifier(language: language, speaker: speaker)
        let codecPrefill: [Int32] = if let languageId {
            [
                Int32(talkerConfig.codecThinkId),
                Int32(talkerConfig.codecThinkBosId),
                Int32(languageId),
                Int32(talkerConfig.codecThinkEosId),
            ]
        } else {
            [
                Int32(talkerConfig.codecNothinkId),
                Int32(talkerConfig.codecThinkBosId),
                Int32(talkerConfig.codecThinkEosId),
            ]
        }

        var codecPrefixEmbed = talker.getInputEmbeddings()(MLXArray(codecPrefill).reshaped(1, -1))
        let codecPrefixSuffix = talker.getInputEmbeddings()(
            MLXArray([Int32(talkerConfig.codecPadId), Int32(talkerConfig.codecBosId)]).reshaped(1, 2)
        )
        if let speakerEmbeds = try speakerTokenEmbeddings(for: speaker) {
            codecPrefixEmbed = concatenated([codecPrefixEmbed, speakerEmbeds, codecPrefixSuffix], axis: 1)
        } else {
            codecPrefixEmbed = concatenated([codecPrefixEmbed, codecPrefixSuffix], axis: 1)
        }

        let assistantPrefix = "<|im_start|>assistant\n"
        let assistantPrefixIDs = MLXArray(tokenizer.encode(text: assistantPrefix).map(Int32.init)).reshaped(1, -1)
        let instructIDs: MLXArray?
        if let instruct = trimmedInstruction(instruct) {
            let instructText = "<|im_start|>user\n\(instruct)<|im_end|>\n"
            instructIDs = MLXArray(tokenizer.encode(text: instructText).map(Int32.init)).reshaped(1, -1)
        } else {
            instructIDs = nil
        }
        let prefixTokenizeMS = prefixTokenizeStartedAt.elapsedMilliseconds

        let prefixEmbedBuildStartedAt = ContinuousClock.now
        let roleEmbed = talker.textProjection(talker.getTextEmbeddings()(assistantPrefixIDs))

        let padCount = codecPrefixEmbed.dim(1) - 2
        let padEmbeds = broadcast(ttsPadEmbed, to: [1, padCount, ttsPadEmbed.dim(-1)])
        var combinedEmbed = concatenated([padEmbeds, ttsBosEmbed], axis: 1)
        combinedEmbed = combinedEmbed + codecPrefixEmbed[0..., ..<(-1), 0...]

        let instructEmbed: MLXArray?
        if let instructIDs {
            instructEmbed = talker.textProjection(talker.getTextEmbeddings()(instructIDs))
        } else {
            instructEmbed = nil
        }

        let inputPrefixEmbeds = if let instructEmbed {
            concatenated([instructEmbed, roleEmbed, combinedEmbed], axis: 1)
        } else {
            concatenated([roleEmbed, combinedEmbed], axis: 1)
        }
        let codecLastEmbed = codecPrefixEmbed[0..., (-1)..., 0...]
        let prefix = CachedConditioningPrefix(
            inputPrefixEmbeds: inputPrefixEmbeds,
            codecLastEmbed: codecLastEmbed,
            ttsEosEmbed: ttsEosEmbed,
            ttsPadEmbed: ttsPadEmbed
        )
        if let cacheKey {
            prefixCache.storePrefix(prefix, for: cacheKey)
        }
        return (prefix, false, prefixTokenizeMS, prefixEmbedBuildStartedAt.elapsedMilliseconds)
    }

    private func prepareInputs(
        text: String,
        prefix: CachedConditioningPrefix
    ) throws -> (MLXArray, MLXArray, MLXArray, Int) {
        guard let tokenizer else {
            throw AudioGenerationError.modelNotInitialized("Tokenizer not loaded")
        }

        let textPrepareStartedAt = ContinuousClock.now
        let chatText = "<|im_start|>assistant\n\(text)<|im_end|>\n<|im_start|>assistant\n"
        let inputIds = MLXArray(tokenizer.encode(text: chatText).map(Int32.init)).reshaped(1, -1)
        let textEmbed = talker.textProjection(talker.getTextEmbeddings()(inputIds))
        try validateOptimizedCustomVoiceTextEmbeddingLength(
            textTokenCount: textEmbed.dim(1),
            originalText: text
        )

        let firstTextEmbed = textEmbed[0..., 3 ..< 4, 0...] + prefix.codecLastEmbed
        let trailingTextHidden = concatenated(
            [textEmbed[0..., 4 ..< (textEmbed.dim(1) - 5), 0...], prefix.ttsEosEmbed],
            axis: 1
        )
        let inputEmbeds = concatenated([prefix.inputPrefixEmbeds, firstTextEmbed], axis: 1)
        return (inputEmbeds, trailingTextHidden, prefix.ttsPadEmbed, textPrepareStartedAt.elapsedMilliseconds)
    }

    private func prepareCustomVoiceInputs(
        text: String,
        language: String,
        speaker: String,
        instruct: String?
    ) throws -> (MLXArray, MLXArray, MLXArray, Bool, [String: Int]) {
        let prefixPrepareStartedAt = ContinuousClock.now
        let cacheKey = prefixCacheKeyForCustomVoice(
            language: language,
            speaker: speaker,
            instruct: instruct
        )
        let (prefix, cacheHit, prefixTokenizeMS, prefixEmbedBuildMS) = try buildConditioningPrefix(
            language: language,
            speaker: speaker,
            instruct: instruct,
            cacheKey: cacheKey
        )
        let prepared = try prepareInputs(text: text, prefix: prefix)
        let customTimingsMS = [
            "custom_prefix_prepare": prefixPrepareStartedAt.elapsedMilliseconds,
            "custom_prefix_tokenize_ms": prefixTokenizeMS,
            "custom_prefix_embed_build_ms": prefixEmbedBuildMS,
            "custom_text_prepare_ms": prepared.3,
        ]
        return (prepared.0, prepared.1, prepared.2, cacheHit, customTimingsMS)
    }

    private func prepareVoiceDesignInputs(
        text: String,
        language: String,
        voiceDescription: String
    ) throws -> (MLXArray, MLXArray, MLXArray, Bool, [String: Int]) {
        let prefixPrepareStartedAt = ContinuousClock.now
        let cacheKey = prefixCacheKeyForVoiceDesign(
            language: language,
            voiceDescription: voiceDescription
        )
        let (prefix, cacheHit, prefixTokenizeMS, prefixEmbedBuildMS) = try buildConditioningPrefix(
            language: language,
            speaker: nil,
            instruct: voiceDescription,
            cacheKey: cacheKey
        )
        let prepared = try prepareInputs(text: text, prefix: prefix)
        let designTimingsMS = [
            "design_prefix_prepare": prefixPrepareStartedAt.elapsedMilliseconds,
            "design_prefix_tokenize_ms": prefixTokenizeMS,
            "design_prefix_embed_build_ms": prefixEmbedBuildMS,
            "design_text_prepare_ms": prepared.3,
        ]
        return (
            prepared.0,
            prepared.1,
            prepared.2,
            cacheHit,
            designTimingsMS
        )
    }

    private func warmPreparedInputs(
        _ inputEmbedsInit: MLXArray,
        trailingTextHidden: MLXArray? = nil,
        ttsPadEmbed: MLXArray? = nil,
        inputPreparationMS: Int,
        booleanFlags: [String: Bool] = [:],
        additionalTimingsMS: [String: Int] = [:],
        preparationEvalTimingKey: String? = nil,
        streamStepEvalTimingKey: String? = nil,
        streamStepWarmBooleanFlag: String? = nil
    ) async throws {
        guard let speechTokenizer else {
            throw AudioGenerationError.modelNotInitialized("Speech tokenizer not loaded")
        }
        defer {
            Memory.clearCache()
        }

        let cache = talker.makeCache()
        let codeCache = talker.codePredictor.makeCache()
        let (logits, hidden) = talker(inputEmbedsInit, cache: cache)
        let nextToken = argMax(
            logits[0..., (-1)..., 0...].squeezed(axis: 1),
            axis: -1,
            keepDims: true
        )
        let talkerConfig = config.talkerConfig!
        let eosTokenArray = MLXArray([Int32(talkerConfig.codecEosTokenId)]).reshaped(1, 1)
        let isEOS = nextToken .== eosTokenArray

        let codeHidden = hidden[0..., (-1)..., 0...]
        var codeTokens = [nextToken]

        for layerCache in codeCache {
            _ = layerCache.trim(layerCache.offset)
        }

        if talkerConfig.numCodeGroups > 1 {
            for codeIdx in 0 ..< talkerConfig.numCodeGroups - 1 {
                let codeInput: MLXArray
                if codeIdx == 0 {
                    let code0Embed = talker.getInputEmbeddings()(nextToken)
                    codeInput = concatenated([codeHidden, code0Embed], axis: 1)
                } else {
                    codeInput = talker.codePredictor.codecEmbedding[codeIdx - 1](codeTokens.last!)
                }

                let (codeLogits, _, _) = talker.codePredictor(
                    codeInput,
                    cache: codeCache,
                    generationStep: codeIdx
                )
                let nextCode = argMax(
                    codeLogits[0..., (-1)..., 0...].squeezed(axis: 1),
                    axis: -1,
                    keepDims: true
                )
                codeTokens.append(nextCode)
            }
        }

        let allCodes = concatenated(codeTokens, axis: 1)
        let codesChunk = stacked([allCodes], axis: 1)
        let codesForDecoder = codesChunk.transposed(0, 2, 1)
        let decoderStartedAt = ContinuousClock.now
        let decoded = speechTokenizer.decoder.streamingStep(codesForDecoder).squeezed(axis: 1)
        let firstDecoderStepMS = decoderStartedAt.elapsedMilliseconds
        var preparationBooleanFlags = booleanFlags
        let decoderBucketWarmStartedAt = ContinuousClock.now
        let decoderBucketCacheHit = try precompileStreamingDecoderBuckets(with: codesForDecoder)
        let decoderBucketWarmMS = decoderBucketCacheHit ? 0 : decoderBucketWarmStartedAt.elapsedMilliseconds
        preparationBooleanFlags["decoder_bucket_cache_hit"] = decoderBucketCacheHit
        speechTokenizer.decoder.resetStreamingState()
        let preparationEvalStartedAt = ContinuousClock.now
        eval(logits, hidden, allCodes, codesForDecoder, decoded)
        var timingsMS = [
            "prepare_inputs": inputPreparationMS,
            "first_decoder_step": firstDecoderStepMS,
            "decoder_bucket_warm": decoderBucketWarmMS,
        ].merging(additionalTimingsMS) { _, rhs in rhs }
        if let preparationEvalTimingKey {
            timingsMS[preparationEvalTimingKey] = preparationEvalStartedAt.elapsedMilliseconds
        }
        if let streamStepEvalTimingKey,
           let trailingTextHidden,
           let ttsPadEmbed
        {
            let nextTextEmbed: MLXArray
            if trailingTextHidden.dim(1) > 0 {
                nextTextEmbed = trailingTextHidden[0..., 0 ..< 1, 0...]
            } else {
                nextTextEmbed = ttsPadEmbed
            }

            var codecEmbed = talker.getInputEmbeddings()(nextToken)
            for (index, code) in codeTokens.dropFirst().enumerated() {
                codecEmbed = codecEmbed + talker.codePredictor.codecEmbedding[index](code)
            }

            let nextInputEmbeds = nextTextEmbed + codecEmbed
            let streamStepWarmStartedAt = ContinuousClock.now
            eval(nextInputEmbeds, isEOS)
            timingsMS[streamStepEvalTimingKey] = streamStepWarmStartedAt.elapsedMilliseconds
            if let streamStepWarmBooleanFlag {
                preparationBooleanFlags[streamStepWarmBooleanFlag] = true
            }
        }
        storePreparationTimingsMS(timingsMS)
        mergePreparationBooleanFlags(preparationBooleanFlags)
    }

    @discardableResult
    private func precompileStreamingDecoderBuckets(with codesForDecoder: MLXArray) throws -> Bool {
        guard let speechTokenizer else {
            throw AudioGenerationError.modelNotInitialized("Speech tokenizer not loaded")
        }

        if let cacheKey = decoderBucketCacheKey(),
           Qwen3TTSStreamingDecoderBucketCache.shared.contains(cacheKey) {
            speechTokenizer.decoder.resetStreamingState()
            return true
        }

        for bucketSize in [4, 1, 2, 3] {
            speechTokenizer.decoder.resetStreamingState()
            let bucketCodes = concatenated(
                Array(repeating: codesForDecoder, count: bucketSize),
                axis: 2
            )
            let decoded = speechTokenizer.decoder.streamingStep(bucketCodes)
            eval(bucketCodes, decoded)
        }
        speechTokenizer.decoder.resetStreamingState()
        if let cacheKey = decoderBucketCacheKey() {
            Qwen3TTSStreamingDecoderBucketCache.shared.insert(cacheKey)
        }
        return false
    }

    public func prepareCustomVoice(
        text: String,
        language: String,
        speaker: String,
        instruct: String?,
        generationParameters _: GenerateParameters
    ) async throws {
        guard speechTokenizer != nil else {
            throw AudioGenerationError.modelNotInitialized("Speech tokenizer not loaded")
        }
        guard tokenizer != nil else {
            throw AudioGenerationError.modelNotInitialized("Text tokenizer not loaded")
        }

        let startedAt = ContinuousClock.now
        let (inputEmbedsInit, trailingTextHidden, ttsPadEmbed, prefixCacheHit, customPrefixPrepareMS) = try prepareCustomVoiceInputs(
            text: text,
            language: language,
            speaker: speaker,
            instruct: instruct
        )
        try await warmPreparedInputs(
            inputEmbedsInit,
            trailingTextHidden: trailingTextHidden,
            ttsPadEmbed: ttsPadEmbed,
            inputPreparationMS: startedAt.elapsedMilliseconds,
            booleanFlags: [
                "prefix_cache_hit": prefixCacheHit,
                "custom_prefix_cache_hit": prefixCacheHit,
                "custom_speaker_conditioning_used": true,
            ],
            additionalTimingsMS: customPrefixPrepareMS,
            preparationEvalTimingKey: "custom_prewarm_eval_ms",
            streamStepEvalTimingKey: "custom_stream_step_warm_ms",
            streamStepWarmBooleanFlag: "custom_stream_step_prewarmed"
        )
    }

    public func prepareVoiceDesign(
        text: String,
        language: String,
        voiceDescription: String,
        generationParameters _: GenerateParameters
    ) async throws {
        guard speechTokenizer != nil else {
            throw AudioGenerationError.modelNotInitialized("Speech tokenizer not loaded")
        }
        guard tokenizer != nil else {
            throw AudioGenerationError.modelNotInitialized("Text tokenizer not loaded")
        }

        let startedAt = ContinuousClock.now
        let (inputEmbedsInit, trailingTextHidden, ttsPadEmbed, prefixCacheHit, designPrefixPrepareMS) = try prepareVoiceDesignInputs(
            text: text,
            language: language,
            voiceDescription: voiceDescription
        )
        try await warmPreparedInputs(
            inputEmbedsInit,
            trailingTextHidden: trailingTextHidden,
            ttsPadEmbed: ttsPadEmbed,
            inputPreparationMS: startedAt.elapsedMilliseconds,
            booleanFlags: [
                "prefix_cache_hit": prefixCacheHit,
                "design_prefix_cache_hit": prefixCacheHit,
            ],
            additionalTimingsMS: designPrefixPrepareMS,
            preparationEvalTimingKey: "design_prewarm_eval_ms",
            streamStepEvalTimingKey: "design_stream_step_warm_ms",
            streamStepWarmBooleanFlag: "design_stream_step_prewarmed"
        )
    }

    public func createVoiceClonePrompt(
        refAudio: MLXArray,
        refText: String?,
        xVectorOnlyMode: Bool
    ) throws -> Qwen3TTSVoiceClonePrompt {
        guard config.ttsModelType == "base" else {
            throw AudioGenerationError.modelNotInitialized(
                "Qwen3 clone prompt creation requires the base model."
            )
        }

        let normalizedRefText = refText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let iclMode = !xVectorOnlyMode
        if iclMode, normalizedRefText?.isEmpty ?? true {
            throw AudioGenerationError.modelNotInitialized(
                "Qwen3 clone prompt creation requires a transcript when x_vector_only_mode is false."
            )
        }

        let speakerEmbedding = extractSpeakerEmbedding(refAudio)
        let refCodes: MLXArray?
        if iclMode {
            guard let speechTokenizer, speechTokenizer.hasEncoder else {
                throw AudioGenerationError.modelNotInitialized(
                    "Qwen3 clone prompt creation requires an initialized speech tokenizer encoder."
                )
            }
            var refAudioForEncoder = refAudio
            if refAudio.ndim == 1 {
                refAudioForEncoder = refAudio.reshaped(1, 1, refAudio.dim(0))
            } else if refAudio.ndim == 2 {
                refAudioForEncoder = refAudio.reshaped(1, refAudio.dim(0), refAudio.dim(1))
            }
            refCodes = speechTokenizer.encode(refAudioForEncoder)
        } else {
            refCodes = nil
        }

        return Qwen3TTSVoiceClonePrompt(
            refCodes: refCodes,
            speakerEmbedding: speakerEmbedding,
            refText: normalizedRefText,
            xVectorOnlyMode: xVectorOnlyMode,
            iclMode: iclMode
        )
    }

    public func prepareVoiceClone(
        text: String,
        language: String,
        voiceClonePrompt: Qwen3TTSVoiceClonePrompt,
        generationParameters _: GenerateParameters
    ) async throws {
        guard speechTokenizer != nil else {
            throw AudioGenerationError.modelNotInitialized("Speech tokenizer not loaded")
        }
        guard tokenizer != nil else {
            throw AudioGenerationError.modelNotInitialized("Text tokenizer not loaded")
        }

        let startedAt = ContinuousClock.now
        let inputEmbedsInit = try prepareVoiceCloneInputs(
            text: text,
            voiceClonePrompt: voiceClonePrompt,
            language: language
        ).0
        try await warmPreparedInputs(
            inputEmbedsInit,
            inputPreparationMS: startedAt.elapsedMilliseconds,
            booleanFlags: [
                "clone_prompt_used": true,
            ]
        )
    }

    public func prepareForGeneration(
        text: String,
        voice: String?,
        refAudio: MLXArray?,
        refText: String?,
        language: String?,
        generationParameters: GenerateParameters
    ) async throws {
        guard let speechTokenizer else {
            throw AudioGenerationError.modelNotInitialized("Speech tokenizer not loaded")
        }
        guard tokenizer != nil else {
            throw AudioGenerationError.modelNotInitialized("Text tokenizer not loaded")
        }

        let instruct = voice
        let lang = language ?? "auto"
        let inputPreparationStartedAt = ContinuousClock.now

        let inputEmbedsInit: MLXArray
        let preparationBooleanFlags: [String: Bool]
        let additionalPreparationTimingsMS: [String: Int]
        if let refAudio,
           let refText,
           speechTokenizer.hasEncoder
        {
            let speakerEmbedding = extractSpeakerEmbedding(refAudio)
            inputEmbedsInit = try prepareICLGenerationInputs(
                text: text,
                refAudio: refAudio,
                refText: refText,
                speakerEmbedding: speakerEmbedding,
                language: lang
            ).0
            preparationBooleanFlags = [:]
            additionalPreparationTimingsMS = [:]
        } else {
            let prepared = try prepareVoiceDesignInputs(
                text: text,
                language: lang,
                voiceDescription: instruct ?? ""
            )
            inputEmbedsInit = prepared.0
            preparationBooleanFlags = [
                "prefix_cache_hit": prepared.3,
                "design_prefix_cache_hit": prepared.3,
            ]
            additionalPreparationTimingsMS = prepared.4
        }

        try await warmPreparedInputs(
            inputEmbedsInit,
            inputPreparationMS: inputPreparationStartedAt.elapsedMilliseconds,
            booleanFlags: preparationBooleanFlags,
            additionalTimingsMS: additionalPreparationTimingsMS,
            preparationEvalTimingKey: preparationBooleanFlags["design_prefix_cache_hit"] == true || !additionalPreparationTimingsMS.isEmpty
                ? "design_prewarm_eval_ms"
                : nil
        )
    }

    convenience init(config: Qwen3TTSModelConfig) {
        let talkerConfig = config.talkerConfig ?? {
            let json = "{}".data(using: .utf8)!
            return try! JSONDecoder().decode(Qwen3TTSTalkerConfig.self, from: json)
        }()
        self.init(
            config: config,
            talker: Qwen3TTSTalkerForConditionalGeneration(config: talkerConfig),
            speakerEncoder: config.ttsModelType == "base"
                ? Qwen3TTSSpeakerEncoder(config: config.speakerEncoderConfig)
                : nil
        )
    }

    init(
        config: Qwen3TTSModelConfig,
        talker: Qwen3TTSTalkerForConditionalGeneration,
        speakerEncoder: Qwen3TTSSpeakerEncoder?
    ) {
        self.config = config
        self.talker = talker
        self.speakerEncoder = speakerEncoder
    }

    // MARK: - SpeechGenerationModel protocol

    public func generate(
        text: String,
        voice: String?,
        refAudio: MLXArray?,
        refText: String?,
        language: String?,
        generationParameters: GenerateParameters
    ) async throws -> MLXArray {
        guard speechTokenizer != nil else {
            throw AudioGenerationError.modelNotInitialized("Speech tokenizer not loaded")
        }
        guard tokenizer != nil else {
            throw AudioGenerationError.modelNotInitialized("Text tokenizer not loaded")
        }

        // VoiceDesign: voice parameter is the instruct (voice description)
        let instruct = voice

        let audio = try generateVoiceDesign(
            text: text,
            instruct: instruct,
            language: language ?? "auto",
            refAudio: refAudio,
            refText: refText,
            temperature: generationParameters.temperature,
            topK: 50,
            topP: generationParameters.topP,
            repetitionPenalty: generationParameters.repetitionPenalty ?? 1.05,
            minP: 0.0,
            maxTokens: generationParameters.maxTokens ?? 4096
        )
        return audio
    }

    public func generateStream(
        text: String,
        voice: String?,
        refAudio: MLXArray?,
        refText: String?,
        language: String?,
        generationParameters: GenerateParameters
    ) -> AsyncThrowingStream<AudioGeneration, Error> {
        generateStream(
            text: text,
            voice: voice,
            refAudio: refAudio,
            refText: refText,
            language: language,
            generationParameters: generationParameters,
            streamingInterval: 2.0
        )
    }

    public func generateStream(
        text: String,
        voice: String?,
        refAudio: MLXArray?,
        refText: String?,
        language: String?,
        generationParameters: GenerateParameters,
        streamingInterval: Double
    ) -> AsyncThrowingStream<AudioGeneration, Error> {
        let (stream, continuation) = AsyncThrowingStream<AudioGeneration, Error>.makeStream()
        Task { @Sendable [weak self] in
            guard let self else { return }
            do {
                guard speechTokenizer != nil else {
                    throw AudioGenerationError.modelNotInitialized("Speech tokenizer not loaded")
                }
                guard tokenizer != nil else {
                    throw AudioGenerationError.modelNotInitialized("Text tokenizer not loaded")
                }

                // VoiceDesign: voice parameter is the instruct (voice description)
                let instruct = voice
                let lang = language ?? "auto"
                let temp = generationParameters.temperature
                let topP = generationParameters.topP
                let repPenalty = generationParameters.repetitionPenalty ?? 1.05
                let maxTokens = generationParameters.maxTokens ?? 4096

                _ = try generateVoiceDesign(
                    text: text,
                    instruct: instruct,
                    language: lang,
                    refAudio: refAudio,
                    refText: refText,
                    temperature: temp,
                    topK: 50,
                    topP: topP,
                    repetitionPenalty: repPenalty,
                    minP: 0.0,
                    maxTokens: maxTokens,
                    streamingInterval: streamingInterval,
                    onToken: { tokenId in
                        continuation.yield(.token(tokenId))
                    },
                    onInfo: { info in
                        continuation.yield(.info(info))
                    },
                    onAudioChunk: { chunk in
                        continuation.yield(.audio(chunk))
                    }
                )
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    public func generateCustomVoiceStream(
        text: String,
        language: String,
        speaker: String,
        instruct: String?,
        generationParameters: GenerateParameters,
        streamingInterval: Double
    ) -> AsyncThrowingStream<AudioGeneration, Error> {
        let (stream, continuation) = AsyncThrowingStream<AudioGeneration, Error>.makeStream()
        Task { @Sendable [weak self] in
            guard let self else { return }
            do {
                _ = try generateVoiceDesign(
                    text: text,
                    instruct: instruct,
                    language: language,
                    speaker: speaker,
                    refAudio: nil,
                    refText: nil,
                    temperature: generationParameters.temperature,
                    topK: 50,
                    topP: generationParameters.topP,
                    repetitionPenalty: generationParameters.repetitionPenalty ?? 1.05,
                    minP: 0.0,
                    maxTokens: generationParameters.maxTokens ?? 4096,
                    streamingInterval: streamingInterval,
                    onToken: { continuation.yield(.token($0)) },
                    onInfo: { continuation.yield(.info($0)) },
                    onAudioChunk: { continuation.yield(.audio($0)) }
                )
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    public func generateVoiceDesignStream(
        text: String,
        language: String,
        voiceDescription: String,
        generationParameters: GenerateParameters,
        streamingInterval: Double
    ) -> AsyncThrowingStream<AudioGeneration, Error> {
        generateStream(
            text: text,
            voice: voiceDescription,
            refAudio: nil,
            refText: nil,
            language: language,
            generationParameters: generationParameters,
            streamingInterval: streamingInterval
        )
    }

    public func generateVoiceCloneStream(
        text: String,
        language: String,
        voiceClonePrompt: Qwen3TTSVoiceClonePrompt,
        generationParameters: GenerateParameters,
        streamingInterval: Double
    ) -> AsyncThrowingStream<AudioGeneration, Error> {
        let (stream, continuation) = AsyncThrowingStream<AudioGeneration, Error>.makeStream()
        Task { @Sendable [weak self] in
            guard let self else { return }
            do {
                _ = try generateVoiceDesign(
                    text: text,
                    instruct: nil,
                    language: language,
                    speaker: nil,
                    refAudio: nil,
                    refText: nil,
                    voiceClonePrompt: voiceClonePrompt,
                    temperature: generationParameters.temperature,
                    topK: 50,
                    topP: generationParameters.topP,
                    repetitionPenalty: generationParameters.repetitionPenalty ?? 1.05,
                    minP: 0.0,
                    maxTokens: generationParameters.maxTokens ?? 4096,
                    streamingInterval: streamingInterval,
                    onToken: { continuation.yield(.token($0)) },
                    onInfo: { continuation.yield(.info($0)) },
                    onAudioChunk: { continuation.yield(.audio($0)) }
                )
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    // MARK: - Decode chunk helper

    /// Decode a chunk of codec codes to audio waveform.
    /// - Parameters:
    ///   - codes: Codec codes [1, time, numCodeGroups]
    ///   - chunkTokens: Tokens per decode chunk (controls decode granularity)
    /// - Returns: Decoded audio waveform (1D)
    private func decodeChunk(_ codes: MLXArray, chunkTokens: Int = 300) -> MLXArray {
        guard let speechTokenizer else { return MLXArray.zeros([1]) }

        var audioChunks = [MLXArray]()
        for chunk in speechTokenizer.streamingDecode(codes, chunkTokens: chunkTokens) {
            audioChunks.append(chunk)
        }
        var audio = concatenated(audioChunks, axis: -1)[0]

        let validLen = Int((codes[0..., 0..., 0] .> 0).sum().item(Int32.self))
            * speechTokenizer.decodeUpsampleRate
        if validLen > 0, validLen < audio.dim(0) {
            audio = audio[..<validLen]
        }

        eval(audio)
        return audio
    }

    // MARK: - VoiceDesign generation

    func generateVoiceDesign(
        text: String,
        instruct: String?,
        language: String,
        speaker: String? = nil,
        refAudio: MLXArray?,
        refText: String?,
        voiceClonePrompt: Qwen3TTSVoiceClonePrompt? = nil,
        temperature: Float,
        topK: Int,
        topP: Float,
        repetitionPenalty: Float,
        minP: Float,
        maxTokens: Int,
        streamingInterval: Double = 2.0,
        onToken: ((Int) -> Void)? = nil,
        onInfo: ((AudioGenerationInfo) -> Void)? = nil,
        onAudioChunk: ((MLXArray) -> Void)? = nil
    ) throws -> MLXArray {
        guard let speechTokenizer, let tokenizer else {
            throw AudioGenerationError.modelNotInitialized("Speech tokenizer or text tokenizer not loaded")
        }

        let talkerConfig = config.talkerConfig!
        let isPureVoiceDesign = speaker == nil && refAudio == nil && voiceClonePrompt == nil

        // Prepare inputs
        let inputEmbedsInit: MLXArray
        let trailingTextHidden: MLXArray
        let ttsPadEmbed: MLXArray
        let refCodes: MLXArray?
        let preparationBooleanFlags: [String: Bool]
        let preparationTimingsMS: [String: Int]

        if let voiceClonePrompt {
            let prepared = try prepareVoiceCloneInputs(
                text: text,
                voiceClonePrompt: voiceClonePrompt,
                language: language
            )
            inputEmbedsInit = prepared.0
            trailingTextHidden = prepared.1
            ttsPadEmbed = prepared.2
            refCodes = prepared.3
            preparationBooleanFlags = [
                "clone_prompt_used": true,
                "decoder_bucket_cache_hit": decoderBucketCacheHit(),
            ]
            preparationTimingsMS = [:]
        } else if let refAudio,
           let refText,
           speechTokenizer.hasEncoder {
            let speakerEmbedding = extractSpeakerEmbedding(refAudio)
            let prepared = try prepareICLGenerationInputs(
                text: text,
                refAudio: refAudio,
                refText: refText,
                speakerEmbedding: speakerEmbedding,
                language: language
            )
            inputEmbedsInit = prepared.0
            trailingTextHidden = prepared.1
            ttsPadEmbed = prepared.2
            refCodes = prepared.3
            preparationBooleanFlags = [:]
            preparationTimingsMS = [:]
        } else if let speaker {
            let prepared = try prepareCustomVoiceInputs(
                text: text,
                language: language,
                speaker: speaker,
                instruct: instruct
            )
            inputEmbedsInit = prepared.0
            trailingTextHidden = prepared.1
            ttsPadEmbed = prepared.2
            refCodes = nil
            preparationBooleanFlags = [
                "prefix_cache_hit": prepared.3,
                "custom_prefix_cache_hit": prepared.3,
                "custom_speaker_conditioning_used": true,
                "decoder_bucket_cache_hit": decoderBucketCacheHit(),
            ]
            preparationTimingsMS = prepared.4
        } else {
            let prepared = try prepareVoiceDesignInputs(
                text: text,
                language: language,
                voiceDescription: instruct ?? ""
            )
            inputEmbedsInit = prepared.0
            trailingTextHidden = prepared.1
            ttsPadEmbed = prepared.2
            refCodes = nil
            preparationBooleanFlags = [
                "prefix_cache_hit": prepared.3,
                "design_prefix_cache_hit": prepared.3,
                "decoder_bucket_cache_hit": decoderBucketCacheHit(),
            ]
            preparationTimingsMS = prepared.4
        }
        storePreparationBooleanFlags(preparationBooleanFlags)
        mergePreparationTimingsMS(preparationTimingsMS)

        // Cap max tokens based on text length
        let targetTokenCount = tokenizer.encode(text: text).count
        let effectiveMaxTokens = min(maxTokens, max(75, targetTokenCount * 6))

        // Initialize cache and timing
        let startTime = Date()
        let cache = talker.makeCache()
        let isStreaming = onAudioChunk != nil
        var generatedCodes = [MLXArray]()
        if !isStreaming {
            generatedCodes.reserveCapacity(effectiveMaxTokens)
        }
        var pendingStreamCodes = [MLXArray]()
        var generatedCodebookTokens = [Int]()
        generatedCodebookTokens.reserveCapacity(effectiveMaxTokens)
        var generatedCodeCount = 0
        let eosTokenId = talkerConfig.codecEosTokenId

        // Suppress special tokens
        let suppressTokens = (talkerConfig.vocabSize - 1024 ..< talkerConfig.vocabSize)
            .filter { $0 != eosTokenId }

        // Streaming decode state
        let codecTokenRateHz = 12.5
        let streamingChunkSize = max(1, Int(streamingInterval * codecTokenRateHz))
        if isStreaming {
            pendingStreamCodes.reserveCapacity(streamingChunkSize)
        }
        var talkerForwardTotalMS = 0
        var codePredictorTotalMS = 0
        var streamingDecoderTotalMS = 0
        var streamingDecoderCallCount = 0
        var designStreamStepEvalTotalMS = 0
        var designAudioChunkEvalTotalMS = 0
        var designGenerationStepsBeforeFirstChunk: Int?
        var designFirstChunkDecoderTokens: Int?

        var trailingIdx = 0
        var inputEmbeds = inputEmbedsInit
        let eosTokenArray = MLXArray([Int32(eosTokenId)]).reshaped(1, 1)
        let codeCache = talker.codePredictor.makeCache()

        if onAudioChunk != nil {
            speechTokenizer.decoder.resetStreamingState()
        }
        defer {
            if onAudioChunk != nil {
                speechTokenizer.decoder.resetStreamingState()
            }
        }

        for _ in 0 ..< effectiveMaxTokens {
            // Forward pass through talker
            let talkerForwardStartedAt = ContinuousClock.now
            let (logits, hidden) = talker(inputEmbeds, cache: cache)
            talkerForwardTotalMS += talkerForwardStartedAt.elapsedMilliseconds

            // Sample first codebook token
            let nextToken = sampleToken(
                logits,
                temperature: temperature,
                topP: topP,
                topK: topK,
                repetitionPenalty: repetitionPenalty,
                generatedTokens: generatedCodebookTokens,
                suppressTokens: suppressTokens,
                eosTokenId: eosTokenId,
                minP: minP
            )

            // Defer sync to the eval boundary with inputEmbeds.
            let isEOS = nextToken .== eosTokenArray

            // Generate remaining codebook tokens with code predictor
            var codeTokens = [nextToken]
            let codeHidden = hidden[0..., (-1)..., 0...]
            for layerCache in codeCache {
                _ = layerCache.trim(layerCache.offset)
            }

            let codePredictorStartedAt = ContinuousClock.now
            for codeIdx in 0 ..< talkerConfig.numCodeGroups - 1 {
                let codeInput: MLXArray
                if codeIdx == 0 {
                    let code0Embed = talker.getInputEmbeddings()(nextToken)
                    codeInput = concatenated([codeHidden, code0Embed], axis: 1)
                } else {
                    codeInput = talker.codePredictor.codecEmbedding[codeIdx - 1](codeTokens.last!)
                }

                let (codeLogits, _, _) = talker.codePredictor(
                    codeInput, cache: codeCache, generationStep: codeIdx
                )

                let nextCode = sampleToken(
                    codeLogits,
                    temperature: temperature,
                    topP: topP,
                    topK: topK,
                    minP: minP
                )
                codeTokens.append(nextCode)
            }
            codePredictorTotalMS += codePredictorStartedAt.elapsedMilliseconds

            let allCodes = concatenated(codeTokens, axis: 1) // [1, num_code_groups]

            // Prepare next input
            let textEmbed: MLXArray
            if trailingIdx < trailingTextHidden.dim(1) {
                textEmbed = trailingTextHidden[0..., trailingIdx ..< (trailingIdx + 1), 0...]
                trailingIdx += 1
            } else {
                textEmbed = ttsPadEmbed
            }

            // Sum all code embeddings for next step
            var codecEmbed = talker.getInputEmbeddings()(nextToken)
            for (i, code) in codeTokens.dropFirst().enumerated() {
                codecEmbed = codecEmbed + talker.codePredictor.codecEmbedding[i](code)
            }

            inputEmbeds = textEmbed + codecEmbed
            let streamStepEvalStartedAt = ContinuousClock.now
            eval(inputEmbeds, isEOS)
            if isPureVoiceDesign {
                designStreamStepEvalTotalMS += streamStepEvalStartedAt.elapsedMilliseconds
            }

            let tokenId = Int(nextToken[0, 0].item(Int32.self))
            onToken?(tokenId)
            if isEOS.item(Bool.self) {
                break
            }
            generatedCodebookTokens.append(tokenId)
            generatedCodeCount += 1
            if isStreaming {
                pendingStreamCodes.append(allCodes)
            } else {
                generatedCodes.append(allCodes)
            }

            // Streaming: decode and yield audio chunks during generation
            if let onAudioChunk {
                if pendingStreamCodes.count >= streamingChunkSize {
                    let codesChunk = stacked(pendingStreamCodes, axis: 1)
                    let codesForDecoder = codesChunk.transposed(0, 2, 1)
                    if isPureVoiceDesign, designGenerationStepsBeforeFirstChunk == nil {
                        designGenerationStepsBeforeFirstChunk = generatedCodeCount
                        designFirstChunkDecoderTokens = codesForDecoder.dim(2)
                    }
                    let streamDecoderStartedAt = ContinuousClock.now
                    let decoded = speechTokenizer.decoder.streamingStep(codesForDecoder).squeezed(axis: 1)
                    streamingDecoderTotalMS += streamDecoderStartedAt.elapsedMilliseconds
                    streamingDecoderCallCount += 1
                    let audioChunk = decoded[0]
                    let audioChunkEvalStartedAt = ContinuousClock.now
                    eval(audioChunk)
                    if isPureVoiceDesign {
                        designAudioChunkEvalTotalMS += audioChunkEvalStartedAt.elapsedMilliseconds
                    }

                    pendingStreamCodes.removeAll(keepingCapacity: true)
                    onAudioChunk(audioChunk)
                    Memory.clearCache()
                }
            }

            if generatedCodeCount > 0, generatedCodeCount.isMultiple(of: 8) {
                Memory.clearCache()
            }

        }

        guard generatedCodeCount > 0 else {
            return MLXArray.zeros([1])
        }

        // Emit generation info
        let generateTime = Date().timeIntervalSince(startTime)
        let tokenCount = generatedCodeCount
        let info = AudioGenerationInfo(
            promptTokenCount: 0, // Not tracked for VoiceDesign
            generationTokenCount: tokenCount,
            prefillTime: 0, // Included in generateTime
            generateTime: generateTime,
            tokensPerSecond: Double(tokenCount) / generateTime,
            peakMemoryUsage: Double(Memory.peakMemory) / 1e9
        )
        onInfo?(info)

        // Streaming path: yield remaining tokens and return early
        if let onAudioChunk {
            if !pendingStreamCodes.isEmpty {
                let codesChunk = stacked(pendingStreamCodes, axis: 1)
                let codesForDecoder = codesChunk.transposed(0, 2, 1)
                let streamDecoderStartedAt = ContinuousClock.now
                let decoded = speechTokenizer.decoder.streamingStep(codesForDecoder).squeezed(axis: 1)
                streamingDecoderTotalMS += streamDecoderStartedAt.elapsedMilliseconds
                streamingDecoderCallCount += 1
                let audioChunk = decoded[0]
                if isPureVoiceDesign, designGenerationStepsBeforeFirstChunk == nil {
                    designGenerationStepsBeforeFirstChunk = generatedCodeCount
                    designFirstChunkDecoderTokens = codesForDecoder.dim(2)
                }
                let audioChunkEvalStartedAt = ContinuousClock.now
                eval(audioChunk)
                if isPureVoiceDesign {
                    designAudioChunkEvalTotalMS += audioChunkEvalStartedAt.elapsedMilliseconds
                }
                onAudioChunk(audioChunk)
                Memory.clearCache()
            }
            var mergedTimingsMS = [
                "qwen_talker_forward_total": talkerForwardTotalMS,
                "qwen_code_predictor_total": codePredictorTotalMS,
                "qwen_stream_decoder_total": streamingDecoderTotalMS,
                "qwen_stream_decoder_calls": streamingDecoderCallCount,
                "qwen_generated_code_count": generatedCodeCount,
            ].merging(preparationTimingsMS) { _, rhs in rhs }
            if isPureVoiceDesign {
                mergedTimingsMS["design_stream_step_eval_total_ms"] = designStreamStepEvalTotalMS
                mergedTimingsMS["design_audio_chunk_eval_total_ms"] = designAudioChunkEvalTotalMS
                if let designGenerationStepsBeforeFirstChunk {
                    mergedTimingsMS["design_generation_steps_before_first_chunk"] = designGenerationStepsBeforeFirstChunk
                }
                if let designFirstChunkDecoderTokens {
                    mergedTimingsMS["design_first_chunk_decoder_tokens"] = designFirstChunkDecoderTokens
                }
            }
            mergePreparationTimingsMS(mergedTimingsMS)
            // Streaming chunks already yielded; return empty (caller uses chunks)
            return MLXArray.zeros([1])
        }

        // Non-streaming path: full decode (existing behavior)
        let codes = stacked(generatedCodes, axis: 1) // [1, seq_len, num_code_groups]

        var decodeCodes = codes
        if let refCodes {
            let refCodesT = refCodes.transposed(0, 2, 1)
            decodeCodes = concatenated([refCodesT, codes], axis: 1)
        }

        var audio = decodeChunk(decodeCodes)

        if let refCodes {
            let refLen = refCodes.dim(2)
            let totalLen = decodeCodes.dim(1)
            let cut = Int(Double(refLen) / Double(max(totalLen, 1)) * Double(audio.dim(0)))
            if cut > 0, cut < audio.dim(0) {
                audio = audio[cut...]
            }
        }

        let finalDecodeEvalStartedAt = ContinuousClock.now
        eval(audio)
        Memory.clearCache()
        var mergedTimingsMS = [
            "qwen_talker_forward_total": talkerForwardTotalMS,
            "qwen_code_predictor_total": codePredictorTotalMS,
            "qwen_stream_decoder_total": streamingDecoderTotalMS,
            "qwen_stream_decoder_calls": streamingDecoderCallCount,
            "qwen_generated_code_count": generatedCodeCount,
        ].merging(preparationTimingsMS) { _, rhs in rhs }
        if isPureVoiceDesign {
            mergedTimingsMS["design_stream_step_eval_total_ms"] = designStreamStepEvalTotalMS
            mergedTimingsMS["design_final_decode_eval_ms"] = finalDecodeEvalStartedAt.elapsedMilliseconds
        }
        mergePreparationTimingsMS(mergedTimingsMS)
        return audio
    }

    // MARK: - Prepare generation inputs

    func prepareICLGenerationInputs(
        text: String,
        refAudio: MLXArray,
        refText: String,
        speakerEmbedding: MLXArray?,
        language: String
    ) throws -> (MLXArray, MLXArray, MLXArray, MLXArray) {
        var refAudioForEncoder = refAudio
        if refAudio.ndim == 1 {
            refAudioForEncoder = refAudio.reshaped(1, 1, refAudio.dim(0))
        } else if refAudio.ndim == 2 {
            refAudioForEncoder = refAudio.reshaped(1, refAudio.dim(0), refAudio.dim(1))
        }
        let refCodes = speechTokenizer!.encode(refAudioForEncoder) // [1, num_code_groups, ref_time]
        return try prepareICLGenerationInputs(
            text: text,
            refCodes: refCodes,
            refText: refText,
            speakerEmbedding: speakerEmbedding,
            language: language
        )
    }

    func prepareICLGenerationInputs(
        text: String,
        refCodes: MLXArray,
        refText: String,
        speakerEmbedding: MLXArray?,
        language: String
    ) throws -> (MLXArray, MLXArray, MLXArray, MLXArray) {
        guard let tokenizer, let talkerConfig = config.talkerConfig else {
            throw AudioGenerationError.modelNotInitialized("Tokenizer/config not loaded")
        }

        // Reference text and target text tokenization
        let refChatText = "<|im_start|>assistant\n\(refText)<|im_end|>\n"
        let refIds = MLXArray(tokenizer.encode(text: refChatText).map { Int32($0) }).reshaped(1, -1)
        let refCount = refIds.dim(1)
        let refStart = min(3, refCount)
        let refEnd = max(refStart, refCount - 2)
        let refTextIds = refIds[0..., refStart ..< refEnd]

        let targetChatText = "<|im_start|>assistant\n\(text)<|im_end|>\n<|im_start|>assistant\n"
        let targetIds = MLXArray(tokenizer.encode(text: targetChatText).map { Int32($0) }).reshaped(1, -1)
        let targetCount = targetIds.dim(1)
        let targetStart = min(3, targetCount)
        let targetEnd = max(targetStart, targetCount - 5)
        let targetTextIds = targetIds[0..., targetStart ..< targetEnd]

        // TTS special tokens
        let ttsTokens = MLXArray(
            [Int32(config.ttsBosTokenId), Int32(config.ttsEosTokenId), Int32(config.ttsPadTokenId)]
        ).reshaped(1, 3)
        let ttsEmbeds = talker.textProjection(talker.getTextEmbeddings()(ttsTokens))
        let ttsBosEmbed = ttsEmbeds[0..., 0 ..< 1, 0...]
        let ttsEosEmbed = ttsEmbeds[0..., 1 ..< 2, 0...]
        let ttsPadEmbed = ttsEmbeds[0..., 2 ..< 3, 0...]

        // Build text embeddings for ref+target
        let combinedTextIds = concatenated([refTextIds, targetTextIds], axis: 1)
        var textEmbed = talker.textProjection(talker.getTextEmbeddings()(combinedTextIds))
        textEmbed = concatenated([textEmbed, ttsEosEmbed], axis: 1)
        let textLen = textEmbed.dim(1)

        // Build codec embeddings from reference codes: codec_bos + sum of all codebook embeddings
        let firstCbCodes = refCodes[0..., 0, 0...]
        var refCodecEmbed = talker.getInputEmbeddings()(firstCbCodes)
        if talkerConfig.numCodeGroups > 1 {
            for i in 0 ..< (talkerConfig.numCodeGroups - 1) {
                let codeIdx = i + 1
                if codeIdx >= refCodes.dim(1) { break }
                let cbCodes = refCodes[0..., codeIdx, 0...]
                refCodecEmbed = refCodecEmbed + talker.codePredictor.codecEmbedding[i](cbCodes)
            }
        }

        let codecBosEmbed = talker.getInputEmbeddings()(
            MLXArray([Int32(talkerConfig.codecBosId)]).reshaped(1, 1)
        )
        let codecEmbedIcl = concatenated([codecBosEmbed, refCodecEmbed], axis: 1)

        // Non-streaming overlay of text and codec contexts
        let codecPadEmbed = talker.getInputEmbeddings()(MLXArray([Int32(talkerConfig.codecPadId)]).reshaped(1, 1))
        let textWithCodecPad = textEmbed + broadcast(
            codecPadEmbed,
            to: [1, textLen, codecPadEmbed.dim(-1)]
        )
        let codecWithTextPad = codecEmbedIcl + broadcast(
            ttsPadEmbed,
            to: [1, codecEmbedIcl.dim(1), ttsPadEmbed.dim(-1)]
        )

        let iclInputEmbed = concatenated([textWithCodecPad, codecWithTextPad], axis: 1)
        let trailingTextHidden = ttsPadEmbed

        // Language ID
        var languageId: Int?
        if language.lowercased() != "auto", let langMap = talkerConfig.codecLanguageId {
            languageId = langMap[language.lowercased()]
        }

        let codecPrefill: [Int32] = if let langId = languageId {
            [
                Int32(talkerConfig.codecThinkId),
                Int32(talkerConfig.codecThinkBosId),
                Int32(langId),
                Int32(talkerConfig.codecThinkEosId)
            ]
        } else {
            [
                Int32(talkerConfig.codecNothinkId),
                Int32(talkerConfig.codecThinkBosId),
                Int32(talkerConfig.codecThinkEosId)
            ]
        }

        var codecPrefixEmbed = talker.getInputEmbeddings()(MLXArray(codecPrefill).reshaped(1, -1))
        let codecPrefixSuffix = talker.getInputEmbeddings()(
            MLXArray([Int32(talkerConfig.codecPadId), Int32(talkerConfig.codecBosId)]).reshaped(1, 2)
        )
        if let speakerEmbedding {
            let speakerEmbed = speakerEmbedding.reshaped(1, 1, -1)
            codecPrefixEmbed = concatenated([codecPrefixEmbed, speakerEmbed, codecPrefixSuffix], axis: 1)
        } else {
            codecPrefixEmbed = concatenated([codecPrefixEmbed, codecPrefixSuffix], axis: 1)
        }

        // Role embedding
        let roleEmbed = talker.textProjection(talker.getTextEmbeddings()(targetIds[0..., 0 ..< 3]))

        // Build prefix: text side overlayed with codec prefix
        let padCount = codecPrefixEmbed.dim(1) - 2
        let padEmbeds = broadcast(ttsPadEmbed, to: [1, padCount, ttsPadEmbed.dim(-1)])
        var combinedPrefix = concatenated([padEmbeds, ttsBosEmbed], axis: 1)
        combinedPrefix = combinedPrefix + codecPrefixEmbed[0..., 0 ..< (codecPrefixEmbed.dim(1) - 1), 0...]

        // Full input embedding
        let inputEmbeds = concatenated([roleEmbed, combinedPrefix, iclInputEmbed], axis: 1)

        return (inputEmbeds, trailingTextHidden, ttsPadEmbed, refCodes)
    }

    func prepareVoiceCloneInputs(
        text: String,
        voiceClonePrompt: Qwen3TTSVoiceClonePrompt,
        language: String
    ) throws -> (MLXArray, MLXArray, MLXArray, MLXArray?) {
        if voiceClonePrompt.iclMode {
            guard let refCodes = voiceClonePrompt.refCodes,
                  let refText = voiceClonePrompt.refText,
                  !refText.isEmpty else {
                throw AudioGenerationError.modelNotInitialized(
                    "Qwen3 clone prompt in ICL mode is missing required reference codes or transcript."
                )
            }
            let prepared = try prepareICLGenerationInputs(
                text: text,
                refCodes: refCodes,
                refText: refText,
                speakerEmbedding: voiceClonePrompt.speakerEmbedding,
                language: language
            )
            return prepared
        }

        let (inputEmbeds, trailingTextHidden, ttsPadEmbed, _) = try prepareVoiceCloneFromSpeakerOnly(
            text: text,
            language: language,
            voiceClonePrompt: voiceClonePrompt
        )
        return (inputEmbeds, trailingTextHidden, ttsPadEmbed, nil)
    }

    private func prepareVoiceCloneFromSpeakerOnly(
        text: String,
        language: String,
        voiceClonePrompt: Qwen3TTSVoiceClonePrompt
    ) throws -> (MLXArray, MLXArray, MLXArray, Bool) {
        guard let speakerEmbedding = voiceClonePrompt.speakerEmbedding else {
            throw AudioGenerationError.modelNotInitialized(
                "Qwen3 speaker-only clone prompt is missing a speaker embedding."
            )
        }

        let (prefix, cacheHit) = try buildSpeakerConditioningPrefix(
            language: language,
            speakerEmbedding: speakerEmbedding
        )
        let prepared = try prepareInputs(text: text, prefix: prefix)
        return (prepared.0, prepared.1, prepared.2, cacheHit)
    }

    private func buildSpeakerConditioningPrefix(
        language: String,
        speakerEmbedding: MLXArray
    ) throws -> (CachedConditioningPrefix, Bool) {
        guard let tokenizer, let talkerConfig = config.talkerConfig else {
            throw AudioGenerationError.modelNotInitialized("Tokenizer/config not loaded")
        }

        let ttsTokens = MLXArray(
            [Int32(config.ttsBosTokenId), Int32(config.ttsEosTokenId), Int32(config.ttsPadTokenId)]
        ).reshaped(1, 3)
        let ttsEmbeds = talker.textProjection(talker.getTextEmbeddings()(ttsTokens))
        let ttsBosEmbed = ttsEmbeds[0..., 0 ..< 1, 0...]
        let ttsEosEmbed = ttsEmbeds[0..., 1 ..< 2, 0...]
        let ttsPadEmbed = ttsEmbeds[0..., 2 ..< 3, 0...]

        let languageId = resolvedLanguageIdentifier(language: language)
        let codecPrefill: [Int32] = if let languageId {
            [
                Int32(talkerConfig.codecThinkId),
                Int32(talkerConfig.codecThinkBosId),
                Int32(languageId),
                Int32(talkerConfig.codecThinkEosId),
            ]
        } else {
            [
                Int32(talkerConfig.codecNothinkId),
                Int32(talkerConfig.codecThinkBosId),
                Int32(talkerConfig.codecThinkEosId),
            ]
        }

        var codecPrefixEmbed = talker.getInputEmbeddings()(MLXArray(codecPrefill).reshaped(1, -1))
        let codecPrefixSuffix = talker.getInputEmbeddings()(
            MLXArray([Int32(talkerConfig.codecPadId), Int32(talkerConfig.codecBosId)]).reshaped(1, 2)
        )
        let reshapedSpeakerEmbedding: MLXArray
        if speakerEmbedding.ndim == 1 {
            reshapedSpeakerEmbedding = speakerEmbedding.reshaped(1, 1, speakerEmbedding.dim(0))
        } else if speakerEmbedding.ndim == 2 {
            reshapedSpeakerEmbedding = speakerEmbedding.reshaped(1, speakerEmbedding.dim(0), speakerEmbedding.dim(1))
        } else {
            reshapedSpeakerEmbedding = speakerEmbedding
        }
        codecPrefixEmbed = concatenated([codecPrefixEmbed, reshapedSpeakerEmbedding, codecPrefixSuffix], axis: 1)

        let assistantPrefix = "<|im_start|>assistant\n"
        let assistantPrefixIDs = MLXArray(tokenizer.encode(text: assistantPrefix).map(Int32.init)).reshaped(1, -1)
        let roleEmbed = talker.textProjection(talker.getTextEmbeddings()(assistantPrefixIDs))

        let padCount = codecPrefixEmbed.dim(1) - 2
        let padEmbeds = broadcast(ttsPadEmbed, to: [1, padCount, ttsPadEmbed.dim(-1)])
        var combinedEmbed = concatenated([padEmbeds, ttsBosEmbed], axis: 1)
        combinedEmbed = combinedEmbed + codecPrefixEmbed[0..., ..<(-1), 0...]

        let inputPrefixEmbeds = concatenated([roleEmbed, combinedEmbed], axis: 1)
        let codecLastEmbed = codecPrefixEmbed[0..., (-1)..., 0...]
        let prefix = CachedConditioningPrefix(
            inputPrefixEmbeds: inputPrefixEmbeds,
            codecLastEmbed: codecLastEmbed,
            ttsEosEmbed: ttsEosEmbed,
            ttsPadEmbed: ttsPadEmbed
        )
        return (prefix, false)
    }

    func extractSpeakerEmbedding(_ refAudio: MLXArray) -> MLXArray? {
        guard let speakerEncoder else { return nil }

        let rawAudio: MLXArray
        if refAudio.ndim == 1 {
            rawAudio = refAudio.reshaped(1, refAudio.dim(0))
        } else if refAudio.ndim == 2 {
            if refAudio.dim(0) == 1 {
                rawAudio = refAudio
            } else {
                rawAudio = refAudio[0 ..< 1]
            }
        } else if refAudio.ndim == 3, refAudio.dim(1) == 1 {
            let squeezed = refAudio[0..., 0...]
            if squeezed.dim(0) == 1 {
                rawAudio = squeezed
            } else {
                rawAudio = squeezed[0 ..< 1]
            }
        } else {
            return nil
        }

        let batchSize = rawAudio.dim(0)
        var mels = [MLXArray]()
        mels.reserveCapacity(batchSize)

        for batch in 0 ..< batchSize {
            let waveform = rawAudio[batch]
            let mel = computeMelSpectrogram(
                audio: waveform,
                sampleRate: speakerEncoder.config.sampleRate,
                nFft: 1024,
                hopLength: 256,
                nMels: 128
            )
            mels.append(mel)
        }

        let stackedMels = stacked(mels, axis: 0)
        let embedding = speakerEncoder(stackedMels)
        return embedding
    }

    func prepareGenerationInputs(
        text: String,
        language: String,
        instruct: String?
    ) throws -> (MLXArray, MLXArray, MLXArray) {
        guard let tokenizer, let talkerConfig = config.talkerConfig else {
            throw AudioGenerationError.modelNotInitialized("Tokenizer/config not loaded")
        }

        // Tokenize text with ChatML template
        let chatText = "<|im_start|>assistant\n\(text)<|im_end|>\n<|im_start|>assistant\n"
        let inputIds = MLXArray(tokenizer.encode(text: chatText).map { Int32($0) }).reshaped(1, -1)

        // Get text embeddings
        let textEmbed = talker.textProjection(talker.getTextEmbeddings()(inputIds))
        try validateOptimizedCustomVoiceTextEmbeddingLength(
            textTokenCount: textEmbed.dim(1),
            originalText: text
        )

        // TTS special tokens
        let ttsTokens = MLXArray(
            [Int32(config.ttsBosTokenId), Int32(config.ttsEosTokenId), Int32(config.ttsPadTokenId)]
        ).reshaped(1, 3)
        let ttsEmbeds = talker.textProjection(talker.getTextEmbeddings()(ttsTokens))
        let ttsBosEmbed = ttsEmbeds[0..., 0 ..< 1, 0...]
        let ttsEosEmbed = ttsEmbeds[0..., 1 ..< 2, 0...]
        let ttsPadEmbed = ttsEmbeds[0..., 2 ..< 3, 0...]

        // Language ID
        var languageId: Int?
        if language.lowercased() != "auto", let langMap = talkerConfig.codecLanguageId {
            languageId = langMap[language.lowercased()]
        }

        // Build codec prefix
        let codecPrefill: [Int32] = if let langId = languageId {
            [
                Int32(talkerConfig.codecThinkId),
                Int32(talkerConfig.codecThinkBosId),
                Int32(langId),
                Int32(talkerConfig.codecThinkEosId)
            ]
        } else {
            [
                Int32(talkerConfig.codecNothinkId),
                Int32(talkerConfig.codecThinkBosId),
                Int32(talkerConfig.codecThinkEosId)
            ]
        }

        var codecEmbed = talker.getInputEmbeddings()(MLXArray(codecPrefill).reshaped(1, -1))
        let codecEmbedSuffix = talker.getInputEmbeddings()(
            MLXArray([Int32(talkerConfig.codecPadId), Int32(talkerConfig.codecBosId)]).reshaped(1, 2)
        )
        codecEmbed = concatenated([codecEmbed, codecEmbedSuffix], axis: 1)

        // Instruct embedding
        var instructEmbed: MLXArray?
        if let instruct, !instruct.isEmpty {
            let instructText = "<|im_start|>user\n\(instruct)<|im_end|>\n"
            let instructIds = MLXArray(tokenizer.encode(text: instructText).map { Int32($0) }).reshaped(1, -1)
            instructEmbed = talker.textProjection(talker.getTextEmbeddings()(instructIds))
        }

        // Role embedding (first 3 tokens: <|im_start|>assistant\n)
        let roleEmbed = textEmbed[0..., ..<3, 0...]

        // Build pad/bos prefix
        let padCount = codecEmbed.dim(1) - 2
        let padEmbeds = broadcast(ttsPadEmbed, to: [1, padCount, ttsPadEmbed.dim(-1)])
        var combinedEmbed = concatenated([padEmbeds, ttsBosEmbed], axis: 1)
        combinedEmbed = combinedEmbed + codecEmbed[0..., ..<(-1), 0...]

        // Full input embedding
        var inputEmbeds: MLXArray = if let instructEmbed {
            concatenated([instructEmbed, roleEmbed, combinedEmbed], axis: 1)
        } else {
            concatenated([roleEmbed, combinedEmbed], axis: 1)
        }

        // Add first text token (index 3) + last codec embed
        let firstTextEmbed = textEmbed[0..., 3 ..< 4, 0...] + codecEmbed[0..., (-1)..., 0...]
        inputEmbeds = concatenated([inputEmbeds, firstTextEmbed], axis: 1)

        // Trailing text (tokens 4 to -5, plus EOS)
        let trailingTextHidden = concatenated(
            [textEmbed[0..., 4 ..< (textEmbed.dim(1) - 5), 0...], ttsEosEmbed],
            axis: 1
        )

        return (inputEmbeds, trailingTextHidden, ttsPadEmbed)
    }

    private func validateOptimizedCustomVoiceTextEmbeddingLength(
        textTokenCount: Int,
        originalText: String
    ) throws {
        guard textTokenCount >= 10 else {
            throw AudioGenerationError.invalidInput(
                "Optimized Qwen3 custom voice requires a longer tokenized prompt. " +
                "The current text produced only \(textTokenCount) chat tokens for '\(originalText)'."
            )
        }
    }

    // MARK: - Token sampling

    func sampleToken(
        _ logits: MLXArray,
        temperature: Float = 0.9,
        topP: Float = 1.0,
        topK: Int = 50,
        repetitionPenalty: Float = 1.0,
        generatedTokens: [Int]? = nil,
        suppressTokens: [Int]? = nil,
        eosTokenId: Int? = nil,
        minP: Float = 0.0
    ) -> MLXArray {
        var logitsSlice = logits[0..., (-1)..., 0...].squeezed(axis: 1) // [batch, vocab_size]

        // Suppress tokens by setting to -inf
        if let suppress = suppressTokens, !suppress.isEmpty {
            let suppressArr = MLXArray(suppress.map { Int32($0) }).reshaped(1, -1)
            let negInf = MLXArray.full([1, suppress.count], values: MLXArray(-Float.infinity), dtype: logitsSlice.dtype)
            logitsSlice = putAlong(logitsSlice, suppressArr, values: negInf, axis: -1)
        }

        // Repetition penalty
        if let tokens = generatedTokens, !tokens.isEmpty, repetitionPenalty != 1.0 {
            let unique = Array(Set(tokens)).filter { $0 < logitsSlice.dim(-1) }
            if !unique.isEmpty {
                let tokenIds = MLXArray(unique.map { Int32($0) }).reshaped(1, -1)
                let selected = takeAlong(logitsSlice, tokenIds, axis: -1)
                let penalized = which(
                    selected .< 0,
                    selected * repetitionPenalty,
                    selected / repetitionPenalty
                )
                logitsSlice = putAlong(logitsSlice, tokenIds, values: penalized, axis: -1)
            }
        }

        // Greedy if temperature 0
        if temperature <= 0 {
            return argMax(logitsSlice, axis: -1, keepDims: true)
        }

        // Preserve EOS logit so top-k/top-p/min-p do not permanently suppress it.
        let eosLogit: MLXArray? = if let eosTokenId, eosTokenId >= 0, eosTokenId < logitsSlice.dim(-1) {
            logitsSlice[0..., eosTokenId ..< (eosTokenId + 1)]
        } else {
            nil
        }

        // Apply top-k filtering (match mlx_lm.apply_top_k ordering and masking semantics)
        var filteredLogits = logitsSlice
        let vocabSize = logitsSlice.dim(-1)
        if topK > 0, topK < vocabSize {
            let kth = min(topK - 1, max(vocabSize - 1, 0))
            if kth >= 0 {
                let maskIdx = argPartition(-logitsSlice, kth: kth, axis: -1)[0..., topK...]
                let negInf = MLXArray.full(maskIdx.shape, values: MLXArray(-Float.infinity), dtype: logitsSlice.dtype)
                filteredLogits = putAlong(filteredLogits, maskIdx, values: negInf, axis: -1)
            }
        }

        // Apply top-p (nucleus) sampling
        if topP > 0, topP < 1.0 {
            let probs = softmax(filteredLogits, axis: -1)

            // Sort in ASCENDING order (like Python)
            let sortedIndices = argSort(filteredLogits, axis: -1)
            let sortedProbs = takeAlong(probs, sortedIndices, axis: -1)

            // Cumulative probabilities
            let cumProbs = cumsum(sortedProbs, axis: -1)

            // Rearrange cumulative probs back to original order
            // Create inverse index mapping using putAlong
            let vocabSize = sortedIndices.dim(-1)
            let arangeIndices = MLXArray(0 ..< vocabSize).reshaped(1, -1).asType(Int32.self)
            let zeros = MLXArray.zeros(sortedIndices.shape, type: Int32.self)
            let inverseIndices = putAlong(zeros, sortedIndices, values: arangeIndices, axis: -1)
            let cumProbsOrigOrder = takeAlong(cumProbs, inverseIndices, axis: -1)

            // Mask tokens where cumulative prob > (1 - top_p)
            // Keep tokens that are in the top_p nucleus
            let threshold = 1.0 - topP
            let mask = cumProbsOrigOrder .> threshold
            let negInf = MLXArray.full(filteredLogits.shape, values: MLXArray(-Float.infinity), dtype: filteredLogits.dtype)
            filteredLogits = which(mask, filteredLogits, negInf)
        }

        // Apply min-p sampling behavior (default kept at 0.0 for now)
        if minP > 0.0 {
            let scaledMinP = Float(log(Double(minP)))
            // Indices sorted in descending order (like Python `argsort(-logits)`)
            let sortedIndices = argSort(-filteredLogits, axis: -1)
            let sortedLogits = takeAlong(filteredLogits, sortedIndices, axis: -1)
            let topLogits = sortedLogits[0..., 0 ..< 1]
            let scaledMinPArray = MLXArray.full(
                topLogits.shape,
                values: MLXArray(scaledMinP),
                dtype: sortedLogits.dtype
            ) + topLogits
            let removeMask = sortedLogits .< scaledMinPArray
            let negInf = MLXArray.full(sortedLogits.shape, values: MLXArray(-Float.infinity), dtype: sortedLogits.dtype)
            let filteredSortedLogits = which(removeMask, negInf, sortedLogits)

            let invArange = MLXArray(0 ..< vocabSize).reshaped(1, -1).asType(Int32.self)
            let inverseIndices = putAlong(MLXArray.zeros(sortedIndices.shape, type: Int32.self), sortedIndices, values: invArange, axis: -1)
            filteredLogits = takeAlong(filteredSortedLogits, inverseIndices, axis: -1)
        }

        if let eosLogit, let eosTokenId {
            let eosIdx = MLXArray([Int32(eosTokenId)]).reshaped(1, 1)
            filteredLogits = putAlong(filteredLogits, eosIdx, values: eosLogit, axis: -1)
        }

        // Sample with temperature
        let token = categorical(filteredLogits / temperature)
        return token.reshaped(1, 1)
    }

    // MARK: - fromPretrained

    public static func preparePreparedDirectory(_ modelDir: URL) throws {
        try ensureTokenizerJSON(in: modelDir)
    }

    public static func fromPretrained(
        _ modelRepo: String,
        cache: HubCache = .default
    ) async throws -> Qwen3TTSModel {
        let repoID = Repo.ID(rawValue: modelRepo)!
        let modelDir = try await ModelUtils.resolveOrDownloadModel(
            repoID: repoID,
            requiredExtension: "safetensors",
            cache: cache
        )
        return try await fromPreparedDirectory(modelDir, modelRepo: modelRepo)
    }

    public static func fromPreparedDirectory(
        _ modelDir: URL,
        modelRepo _: String,
        loadBehavior: QwenPreparedLoadBehavior = .fullCapabilities,
        diagnosticEventSink: (@Sendable (String, [String: String]) async -> Void)? = nil
    ) async throws -> Qwen3TTSModel {
        await emitPreparedLoadDiagnostic(
            diagnosticEventSink,
            action: "qwen-load-before-prepare-prepared-directory",
            details: diagnosticDetails(
                modelDir: modelDir,
                loadOptions: QwenPreparedLoadOptions(
                    trustPreparedCheckpoint: loadBehavior.trustPreparedCheckpoint,
                    loadSpeakerEncoder: loadBehavior.loadSpeakerEncoder,
                    loadSpeechTokenizerEncoder: loadBehavior.loadSpeechTokenizerEncoder,
                    skipSpeechTokenizerEval: loadBehavior.skipSpeechTokenizerEval
                )
            )
        )
        try preparePreparedDirectory(modelDir)
        await emitPreparedLoadDiagnostic(
            diagnosticEventSink,
            action: "qwen-load-after-prepare-prepared-directory",
            details: diagnosticDetails(
                modelDir: modelDir,
                loadOptions: QwenPreparedLoadOptions(
                    trustPreparedCheckpoint: loadBehavior.trustPreparedCheckpoint,
                    loadSpeakerEncoder: loadBehavior.loadSpeakerEncoder,
                    loadSpeechTokenizerEncoder: loadBehavior.loadSpeechTokenizerEncoder,
                    skipSpeechTokenizerEval: loadBehavior.skipSpeechTokenizerEval
                )
            )
        )
        return try await loadModelContents(
            modelDir: modelDir,
            loadOptions: QwenPreparedLoadOptions(
                trustPreparedCheckpoint: loadBehavior.trustPreparedCheckpoint,
                loadSpeakerEncoder: loadBehavior.loadSpeakerEncoder,
                loadSpeechTokenizerEncoder: loadBehavior.loadSpeechTokenizerEncoder,
                skipSpeechTokenizerEval: loadBehavior.skipSpeechTokenizerEval
            ),
            diagnosticEventSink: diagnosticEventSink
        )
    }

    private static func loadModelContents(
        modelDir: URL,
        loadOptions: QwenPreparedLoadOptions,
        diagnosticEventSink: (@Sendable (String, [String: String]) async -> Void)?
    ) async throws -> Qwen3TTSModel {
        await emitPreparedLoadDiagnostic(
            diagnosticEventSink,
            action: "qwen-load-before-config-read",
            details: diagnosticDetails(
                modelDir: modelDir,
                loadOptions: loadOptions
            )
        )
        let configData = try Data(contentsOf: modelDir.appendingPathComponent("config.json"))
        let config = try JSONDecoder().decode(Qwen3TTSModelConfig.self, from: configData)
        await emitPreparedLoadDiagnostic(
            diagnosticEventSink,
            action: "qwen-load-after-config-read",
            details: diagnosticDetails(
                modelDir: modelDir,
                loadOptions: loadOptions,
                extra: [
                    "ttsModelType": config.ttsModelType,
                    "speakerCount": "\(config.talkerConfig?.spkId?.count ?? 0)",
                ]
            )
        )
        let preparedKey = preparedDirectoryKey(for: modelDir)

        let componentCache = Qwen3TTSPreparedComponentCache.shared
        async let tokenizerComponent = loadTokenizerComponent(
            modelDir: modelDir,
            preparedKey: preparedKey,
            componentCache: componentCache
        )
        await emitPreparedLoadDiagnostic(
            diagnosticEventSink,
            action: "qwen-load-before-talker",
            details: diagnosticDetails(
                modelDir: modelDir,
                loadOptions: loadOptions,
                extra: [
                    "ttsModelType": config.ttsModelType,
                    "preparedKey": preparedKey,
                ]
            )
        )
        let talkerComponents = try await loadTalkerComponents(
            modelDir: modelDir,
            config: config,
            loadOptions: loadOptions,
            diagnosticEventSink: diagnosticEventSink
        )
        await emitPreparedLoadDiagnostic(
            diagnosticEventSink,
            action: "qwen-load-after-talker",
            details: diagnosticDetails(
                modelDir: modelDir,
                loadOptions: loadOptions,
                extra: [
                    "ttsModelType": config.ttsModelType,
                    "preparedKey": preparedKey,
                    "speakerEncoderLoaded": talkerComponents.speakerEncoder == nil ? "false" : "true",
                ]
            )
        )

        let model = Qwen3TTSModel(
            config: config,
            talker: talkerComponents.talker,
            speakerEncoder: talkerComponents.speakerEncoder
        )
        model.preparedKey = preparedKey

        await emitPreparedLoadDiagnostic(
            diagnosticEventSink,
            action: "qwen-load-before-tokenizer-await",
            details: diagnosticDetails(
                modelDir: modelDir,
                loadOptions: loadOptions,
                extra: [
                    "ttsModelType": config.ttsModelType,
                    "preparedKey": preparedKey,
                ]
            )
        )
        let tokenizerResult = await tokenizerComponent
        await emitPreparedLoadDiagnostic(
            diagnosticEventSink,
            action: "qwen-load-after-tokenizer-await",
            details: diagnosticDetails(
                modelDir: modelDir,
                loadOptions: loadOptions,
                extra: [
                    "ttsModelType": config.ttsModelType,
                    "preparedKey": preparedKey,
                    "tokenizerCacheHit": tokenizerResult.cacheHit ? "true" : "false",
                    "tokenizerDirectConfigLoadUsed": tokenizerResult.directConfigLoadUsed ? "true" : "false",
                    "tokenizerDirectConfigFallbackUsed": tokenizerResult.directConfigFallbackUsed ? "true" : "false",
                    "tokenizerLoaded": tokenizerResult.tokenizer == nil ? "false" : "true",
                ]
            )
        )
        model.tokenizer = tokenizerResult.tokenizer
        Memory.clearCache()

        await emitPreparedLoadDiagnostic(
            diagnosticEventSink,
            action: "qwen-load-before-speech-tokenizer",
            details: diagnosticDetails(
                modelDir: modelDir,
                loadOptions: loadOptions,
                extra: [
                    "ttsModelType": config.ttsModelType,
                    "preparedKey": preparedKey,
                ]
            )
        )
        let speechTokenizerResult = try await loadSpeechTokenizerComponent(
            modelDir: modelDir,
            preparedKey: preparedKey,
            componentCache: componentCache,
            loadOptions: loadOptions,
            includeEncoder: loadOptions.loadSpeechTokenizerEncoder ?? (config.ttsModelType == "base"),
            diagnosticEventSink: diagnosticEventSink
        )
        await emitPreparedLoadDiagnostic(
            diagnosticEventSink,
            action: "qwen-load-after-speech-tokenizer",
            details: diagnosticDetails(
                modelDir: modelDir,
                loadOptions: loadOptions,
                extra: [
                    "ttsModelType": config.ttsModelType,
                    "preparedKey": preparedKey,
                    "speechTokenizerCacheHit": speechTokenizerResult.cacheHit ? "true" : "false",
                    "speechTokenizerDecoderLoaded": speechTokenizerResult.speechTokenizer == nil ? "false" : "true",
                    "speechTokenizerEncoderLoaded": (speechTokenizerResult.booleanFlags[
                        "speech_tokenizer_encoder_loaded"
                    ] ?? false) ? "true" : "false",
                ]
            )
        )
        model.speechTokenizer = speechTokenizerResult.speechTokenizer

        var loadTimingsMS = talkerComponents.timingsMS
        loadTimingsMS["talker_weight_load"] = talkerComponents.talkerWeightLoadMS
        loadTimingsMS["tokenizer_load"] = tokenizerResult.loadMS
        loadTimingsMS["speech_tokenizer_load"] = speechTokenizerResult.loadMS
        model.storeLoadTimingsMS(loadTimingsMS)

        var loadBooleanFlags = talkerComponents.booleanFlags
        loadBooleanFlags["trusted_prepared_checkpoint"] = loadOptions.trustPreparedCheckpoint
        loadBooleanFlags["tokenizer_cache_hit"] = tokenizerResult.cacheHit
        loadBooleanFlags["tokenizer_direct_config_load"] = tokenizerResult.directConfigLoadUsed
        loadBooleanFlags["tokenizer_direct_config_fallback"] = tokenizerResult.directConfigFallbackUsed
        loadBooleanFlags["speech_tokenizer_cache_hit"] = speechTokenizerResult.cacheHit
        loadBooleanFlags["speech_tokenizer_encoder_loaded"] = speechTokenizerResult.booleanFlags[
            "speech_tokenizer_encoder_loaded"
        ] ?? false
        loadBooleanFlags["speech_tokenizer_eval_skipped"] = loadOptions.skipSpeechTokenizerEval
        for (key, value) in speechTokenizerResult.booleanFlags {
            loadBooleanFlags[key] = value
        }
        model.storeLoadBooleanFlags(loadBooleanFlags)
        qwen3TTSLog("Loaded Qwen3-TTS model (\(config.ttsModelType))")
        return model
    }

    private static func loadTalkerComponents(
        modelDir: URL,
        config: Qwen3TTSModelConfig,
        loadOptions: QwenPreparedLoadOptions,
        diagnosticEventSink: (@Sendable (String, [String: String]) async -> Void)?
    ) async throws -> LoadedTalkerComponents {
        let talkerConfig = config.talkerConfig ?? {
            let json = "{}".data(using: .utf8)!
            return try! JSONDecoder().decode(Qwen3TTSTalkerConfig.self, from: json)
        }()
        let shouldLoadSpeakerEncoder = loadOptions.loadSpeakerEncoder ?? (config.ttsModelType == "base")
        await emitPreparedLoadDiagnostic(
            diagnosticEventSink,
            action: "qwen-talker-before-weight-load",
            details: diagnosticDetails(
                modelDir: modelDir,
                loadOptions: loadOptions,
                extra: [
                    "ttsModelType": config.ttsModelType,
                    "speakerCount": "\(talkerConfig.spkId?.count ?? 0)",
                    "speakerEncoderRequested": shouldLoadSpeakerEncoder ? "true" : "false",
                ]
            )
        )
        let talker = Qwen3TTSTalkerForConditionalGeneration(config: talkerConfig)
        let speakerEncoder = shouldLoadSpeakerEncoder
            ? Qwen3TTSSpeakerEncoder(config: config.speakerEncoderConfig)
            : nil

        let talkerWeightLoadStartedAt = ContinuousClock.now
        var talkerWeights = [String: MLXArray]()
        var talkerTimingsMS: [String: Int] = [:]

        let talkerIOStartedAt = ContinuousClock.now
        var talkerSourceWeights = try loadWeights(
            from: modelDir,
            directSafetensorsFileName: "model.safetensors"
        )
        await emitPreparedLoadDiagnostic(
            diagnosticEventSink,
            action: "qwen-talker-after-weight-load",
            details: diagnosticDetails(
                modelDir: modelDir,
                loadOptions: loadOptions,
                extra: [
                    "ttsModelType": config.ttsModelType,
                    "sourceWeightCount": "\(talkerSourceWeights.count)",
                ]
            )
        )
        talkerTimingsMS["talker_safetensors_io"] = talkerIOStartedAt.elapsedMilliseconds

        let talkerSanitizeStartedAt = ContinuousClock.now
        for (key, value) in talkerSourceWeights where key.hasPrefix("talker.") {
            let sanitizedKey = String(key.dropFirst("talker.".count))
            talkerWeights[sanitizedKey] = value
        }

        if talkerWeights.isEmpty {
            talkerWeights = Qwen3TTSTalkerForConditionalGeneration.sanitize(
                weights: talkerSourceWeights
            )
        }
        await emitPreparedLoadDiagnostic(
            diagnosticEventSink,
            action: "qwen-talker-after-sanitize",
            details: diagnosticDetails(
                modelDir: modelDir,
                loadOptions: loadOptions,
                extra: [
                    "ttsModelType": config.ttsModelType,
                    "talkerWeightCount": "\(talkerWeights.count)",
                    "speakerWeightCount": shouldLoadSpeakerEncoder ? "\(talkerSourceWeights.count)" : "0",
                ]
            )
        )
        talkerTimingsMS["talker_weight_sanitize"] = talkerSanitizeStartedAt.elapsedMilliseconds
        var talkerPairs = talkerWeights.map { ($0.key, $0.value) }

        let talkerQuantizeStartedAt = ContinuousClock.now
        if config.quantization != nil || config.perLayerQuantization != nil {
            quantize(model: talker) { path, _ in
                guard talkerWeights["\(path).scales"] != nil else {
                    return nil
                }

                if let perLayerQuant = config.perLayerQuantization,
                   let layerQuant = perLayerQuant.quantization(layer: path) {
                    return layerQuant.asTuple
                }

                return config.quantization?.asTuple
            }
        }
        talkerTimingsMS["talker_quantize_prepare"] = talkerQuantizeStartedAt.elapsedMilliseconds

        await emitPreparedLoadDiagnostic(
            diagnosticEventSink,
            action: "qwen-talker-before-update",
            details: diagnosticDetails(
                modelDir: modelDir,
                loadOptions: loadOptions,
                extra: [
                    "ttsModelType": config.ttsModelType,
                    "talkerPairCount": "\(talkerPairs.count)",
                    "verifyMode": loadOptions.trustPreparedCheckpoint ? "no_unused_keys" : "all",
                ]
            )
        )
        let talkerVerifyMode: Module.VerifyUpdate = loadOptions.trustPreparedCheckpoint
            ? .noUnusedKeys
            : .all

        let talkerUpdateStartedAt = ContinuousClock.now
        try talker.update(
            parameters: ModuleParameters.unflattened(talkerPairs),
            verify: talkerVerifyMode
        )
        await emitPreparedLoadDiagnostic(
            diagnosticEventSink,
            action: "qwen-talker-after-update",
            details: diagnosticDetails(
                modelDir: modelDir,
                loadOptions: loadOptions,
                extra: [
                    "ttsModelType": config.ttsModelType,
                    "talkerPairCount": "\(talkerPairs.count)",
                ]
            )
        )
        talkerTimingsMS["talker_parameter_update"] = talkerUpdateStartedAt.elapsedMilliseconds
        talkerPairs.removeAll(keepingCapacity: false)
        talkerWeights.removeAll(keepingCapacity: false)
        Memory.clearCache()

        await emitPreparedLoadDiagnostic(
            diagnosticEventSink,
            action: "qwen-talker-before-eval",
            details: diagnosticDetails(
                modelDir: modelDir,
                loadOptions: loadOptions,
                extra: [
                    "ttsModelType": config.ttsModelType,
                ]
            )
        )
        let talkerEvalStartedAt = ContinuousClock.now
        talkerTimingsMS.merge(
            evaluateTalkerParametersInBatches(talker),
            uniquingKeysWith: { _, rhs in rhs }
        )
        await emitPreparedLoadDiagnostic(
            diagnosticEventSink,
            action: "qwen-talker-after-eval",
            details: diagnosticDetails(
                modelDir: modelDir,
                loadOptions: loadOptions,
                extra: [
                    "ttsModelType": config.ttsModelType,
                ]
            )
        )
        talkerTimingsMS["talker_parameter_eval"] = talkerEvalStartedAt.elapsedMilliseconds

        let talkerBooleanFlags: [String: Bool] = [
            "talker_verify_relaxed": loadOptions.trustPreparedCheckpoint,
            "talker_eval_chunked": true,
            "speaker_encoder_requested": shouldLoadSpeakerEncoder,
        ]

        if let speakerEncoder, shouldLoadSpeakerEncoder {
            var speakerWeights = Qwen3TTSSpeakerEncoder.sanitize(weights: talkerSourceWeights)
            talkerSourceWeights.removeAll(keepingCapacity: false)
            Memory.clearCache()
            if !speakerWeights.isEmpty {
                var speakerPairs = speakerWeights.map { ($0.key, $0.value) }
                let speakerUpdateStartedAt = ContinuousClock.now
                try speakerEncoder.update(
                    parameters: ModuleParameters.unflattened(speakerPairs),
                    verify: .all
                )
                talkerTimingsMS["speaker_encoder_update"] = speakerUpdateStartedAt.elapsedMilliseconds
                speakerPairs.removeAll(keepingCapacity: false)
                speakerWeights.removeAll(keepingCapacity: false)
                Memory.clearCache()

                let speakerEvalStartedAt = ContinuousClock.now
                eval(speakerEncoder.parameters())
                talkerTimingsMS["speaker_encoder_eval"] = speakerEvalStartedAt.elapsedMilliseconds
                qwen3TTSLog("Loaded speaker encoder")
                Memory.clearCache()
            } else {
                speakerWeights.removeAll(keepingCapacity: false)
                Memory.clearCache()
                qwen3TTSLog("Warning: speaker encoder weights missing, skipping speaker encoder load")
            }
        } else if shouldLoadSpeakerEncoder {
            talkerSourceWeights.removeAll(keepingCapacity: false)
            Memory.clearCache()
            qwen3TTSLog("Warning: speaker encoder config missing, skipping speaker encoder load")
        } else {
            talkerSourceWeights.removeAll(keepingCapacity: false)
            Memory.clearCache()
        }

        return LoadedTalkerComponents(
            talker: talker,
            speakerEncoder: speakerEncoder,
            talkerWeightLoadMS: talkerWeightLoadStartedAt.elapsedMilliseconds,
            timingsMS: talkerTimingsMS,
            booleanFlags: talkerBooleanFlags
        )
    }

    private static func emitPreparedLoadDiagnostic(
        _ diagnosticEventSink: (@Sendable (String, [String: String]) async -> Void)?,
        action: String,
        details: [String: String]
    ) async {
        guard let diagnosticEventSink else {
            return
        }
        await diagnosticEventSink(action, details)
    }

    private static func diagnosticDetails(
        modelDir: URL,
        loadOptions: QwenPreparedLoadOptions,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var details: [String: String] = [
            "modelDirectory": modelDir.path,
            "trustPreparedCheckpoint": loadOptions.trustPreparedCheckpoint ? "true" : "false",
            "loadSpeakerEncoder": loadOptions.loadSpeakerEncoder.map { $0 ? "true" : "false" } ?? "auto",
            "loadSpeechTokenizerEncoder": loadOptions.loadSpeechTokenizerEncoder.map { $0 ? "true" : "false" } ?? "auto",
            "skipSpeechTokenizerEval": loadOptions.skipSpeechTokenizerEval ? "true" : "false",
        ]
        for (key, value) in extra {
            details[key] = value
        }
        return details
    }

    private static func evaluateTalkerParametersInBatches(
        _ talker: Qwen3TTSTalkerForConditionalGeneration
    ) -> [String: Int] {
        var timingsMS: [String: Int] = [:]

        let talkerCoreStartedAt = ContinuousClock.now
        var talkerCoreArrays: [MLXArray] = []
        talkerCoreArrays.append(
            contentsOf: flattenedParameterArrays(from: talker.model.codecEmbedding.parameters())
        )
        talkerCoreArrays.append(
            contentsOf: flattenedParameterArrays(from: talker.model.textEmbedding.parameters())
        )
        talkerCoreArrays.append(
            contentsOf: flattenedParameterArrays(from: talker.model.norm.parameters())
        )
        talkerCoreArrays.append(
            contentsOf: flattenedParameterArrays(from: talker.textProjection.parameters())
        )
        talkerCoreArrays.append(
            contentsOf: flattenedParameterArrays(from: talker.codecHead.parameters())
        )
        evalIfNeeded(talkerCoreArrays)
        timingsMS["talker_core_eval"] = talkerCoreStartedAt.elapsedMilliseconds

        let talkerLayerStartedAt = ContinuousClock.now
        evalLayerBatches(talker.model.layers, batchSize: talkerEvalLayerBatchSize)
        timingsMS["talker_decoder_layers_eval"] = talkerLayerStartedAt.elapsedMilliseconds

        let codePredictorCoreStartedAt = ContinuousClock.now
        var codePredictorCoreArrays: [MLXArray] = []
        if let projection = talker.codePredictor.projection {
            codePredictorCoreArrays.append(
                contentsOf: flattenedParameterArrays(from: projection.parameters())
            )
        }
        for embedding in talker.codePredictor.codecEmbedding {
            codePredictorCoreArrays.append(
                contentsOf: flattenedParameterArrays(from: embedding.parameters())
            )
        }
        codePredictorCoreArrays.append(
            contentsOf: flattenedParameterArrays(from: talker.codePredictor.model.norm.parameters())
        )
        for lmHead in talker.codePredictor.lmHead {
            codePredictorCoreArrays.append(
                contentsOf: flattenedParameterArrays(from: lmHead.parameters())
            )
        }
        evalIfNeeded(codePredictorCoreArrays)
        timingsMS["talker_code_predictor_core_eval"] = codePredictorCoreStartedAt.elapsedMilliseconds

        let codePredictorLayerStartedAt = ContinuousClock.now
        evalLayerBatches(talker.codePredictor.model.layers, batchSize: talkerEvalLayerBatchSize)
        timingsMS["talker_code_predictor_layers_eval"] = codePredictorLayerStartedAt.elapsedMilliseconds

        return timingsMS
    }

    private static func evalLayerBatches<Layer: Module>(
        _ layers: [Layer],
        batchSize: Int
    ) {
        guard batchSize > 0 else { return }

        for startIndex in stride(from: 0, to: layers.count, by: batchSize) {
            let endIndex = min(startIndex + batchSize, layers.count)
            var arrays: [MLXArray] = []
            for layer in layers[startIndex ..< endIndex] {
                arrays.append(contentsOf: flattenedParameterArrays(from: layer.parameters()))
            }
            evalIfNeeded(arrays)
        }
    }

    private static func flattenedParameterArrays(
        from parameters: ModuleParameters
    ) -> [MLXArray] {
        parameters.flattened().map(\.1)
    }

    private static func evalParameterArraysInBatches(
        _ arrays: [MLXArray],
        batchSize: Int
    ) {
        guard !arrays.isEmpty else { return }
        let resolvedBatchSize = max(batchSize, 1)
        var startIndex = 0
        while startIndex < arrays.count {
            let endIndex = min(startIndex + resolvedBatchSize, arrays.count)
            evalIfNeeded(Array(arrays[startIndex..<endIndex]))
            Memory.clearCache()
            startIndex = endIndex
        }
    }

    private static func evalIfNeeded(_ arrays: [MLXArray]) {
        guard !arrays.isEmpty else { return }
        eval(arrays)
    }

    private static func loadTokenizerComponent(
        modelDir: URL,
        preparedKey: String,
        componentCache: Qwen3TTSPreparedComponentCache
    ) async -> LoadedTokenizerComponent {
        let tokenizerLoadStartedAt = ContinuousClock.now
        var cacheHit = false
        var directConfigLoadUsed = false
        var directConfigFallbackUsed = false
        var tokenizer: (any Tokenizer)?

        do {
            if let cachedTokenizer = await componentCache.cachedTokenizer(for: preparedKey) {
                tokenizer = cachedTokenizer.tokenizer
                cacheHit = true
            } else {
                do {
                    tokenizer = try loadTokenizerDirectly(from: modelDir)
                    directConfigLoadUsed = true
                } catch {
                    directConfigFallbackUsed = true
                    tokenizer = try await AutoTokenizer.from(modelFolder: modelDir)
                }

                if let tokenizer {
                    await componentCache.storeTokenizer(tokenizer, for: preparedKey)
                }
            }
        } catch {
            qwen3TTSLog("Warning: Could not load tokenizer: \(error)")
        }

        return LoadedTokenizerComponent(
            tokenizer: tokenizer,
            cacheHit: cacheHit,
            directConfigLoadUsed: directConfigLoadUsed,
            directConfigFallbackUsed: directConfigFallbackUsed,
            loadMS: tokenizerLoadStartedAt.elapsedMilliseconds
        )
    }

    private static func loadTokenizerDirectly(from modelDir: URL) throws -> any Tokenizer {
        let tokenizerDataURL = modelDir.appendingPathComponent("tokenizer.json")
        let tokenizerConfigURL = modelDir.appendingPathComponent("tokenizer_config.json")
        guard FileManager.default.fileExists(atPath: tokenizerDataURL.path),
              FileManager.default.fileExists(atPath: tokenizerConfigURL.path) else {
            throw TokenizerError.missingConfig
        }

        let hub = HubApi.shared
        let tokenizerConfig = try hub.configuration(fileURL: tokenizerConfigURL)
        let tokenizerData = try hub.configuration(fileURL: tokenizerDataURL)
        return try PreTrainedTokenizer(
            tokenizerConfig: tokenizerConfig,
            tokenizerData: tokenizerData,
            strict: true
        )
    }

    private static func loadSpeechTokenizerComponent(
        modelDir: URL,
        preparedKey: String,
        componentCache: Qwen3TTSPreparedComponentCache,
        loadOptions: QwenPreparedLoadOptions,
        includeEncoder: Bool,
        diagnosticEventSink: (@Sendable (String, [String: String]) async -> Void)?
    ) async throws -> LoadedSpeechTokenizerComponent {
        let speechTokenizerPath = modelDir.appendingPathComponent("speech_tokenizer")
        var isDirectory: ObjCBool = false
        let speechTokenizerLoadStartedAt = ContinuousClock.now
        var cacheHit = false
        let fileManager = FileManager.default
        var speechTokenizer: Qwen3TTSSpeechTokenizer?
        let speechTokenizerCacheKey = speechTokenizerCacheKey(
            for: preparedKey,
            includeEncoder: includeEncoder
        )

        if fileManager.fileExists(atPath: speechTokenizerPath.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            if let cachedSpeechTokenizer = await componentCache.cachedSpeechTokenizer(
                for: speechTokenizerCacheKey
            ) {
                speechTokenizer = cachedSpeechTokenizer.speechTokenizer
                cacheHit = true
            } else {
                do {
                    await emitPreparedLoadDiagnostic(
                        diagnosticEventSink,
                        action: "qwen-speech-tokenizer-component-before-load",
                        details: diagnosticDetails(
                            modelDir: modelDir,
                            loadOptions: loadOptions,
                            extra: [
                                "preparedKey": preparedKey,
                                "includeEncoder": includeEncoder ? "true" : "false",
                            ]
                        )
                    )
                    let loadedSpeechTokenizer = try await loadSpeechTokenizer(
                        path: speechTokenizerPath,
                        trustPreparedCheckpoint: loadOptions.trustPreparedCheckpoint,
                        includeEncoder: includeEncoder,
                        skipSpeechTokenizerEval: loadOptions.skipSpeechTokenizerEval,
                        diagnosticEventSink: diagnosticEventSink
                    )
                    await emitPreparedLoadDiagnostic(
                        diagnosticEventSink,
                        action: "qwen-speech-tokenizer-component-after-load",
                        details: diagnosticDetails(
                            modelDir: modelDir,
                            loadOptions: loadOptions,
                            extra: [
                                "preparedKey": preparedKey,
                                "includeEncoder": includeEncoder ? "true" : "false",
                            ]
                        )
                    )
                    let storedSpeechTokenizer = await componentCache.storeSpeechTokenizerAndReturn(
                        loadedSpeechTokenizer,
                        for: speechTokenizerCacheKey
                    )
                    speechTokenizer = storedSpeechTokenizer.speechTokenizer
                } catch {
                    await emitPreparedLoadDiagnostic(
                        diagnosticEventSink,
                        action: "qwen-speech-tokenizer-component-load-failed",
                        details: diagnosticDetails(
                            modelDir: modelDir,
                            loadOptions: loadOptions,
                            extra: [
                                "preparedKey": preparedKey,
                                "includeEncoder": includeEncoder ? "true" : "false",
                                "error": String(reflecting: error),
                            ]
                        )
                    )
                    throw error
                }
            }
        } else if fileManager.fileExists(atPath: speechTokenizerPath.path) {
            qwen3TTSLog("speech_tokenizer is not a directory (stale cache), clearing model cache...")
            try? fileManager.removeItem(at: modelDir)
            throw AudioGenerationError.modelNotInitialized(
                "Model cache was corrupted (speech_tokenizer). It has been cleared. Please try loading again."
            )
        } else {
            qwen3TTSLog("Warning: speech_tokenizer directory not found, speech decoding unavailable")
        }

        return LoadedSpeechTokenizerComponent(
            speechTokenizer: speechTokenizer,
            cacheHit: cacheHit,
            loadMS: speechTokenizerLoadStartedAt.elapsedMilliseconds,
            booleanFlags: [
                "speech_tokenizer_verify_relaxed": loadOptions.trustPreparedCheckpoint,
                "speech_tokenizer_encoder_loaded": includeEncoder,
            ]
        )
    }

    private func storeLoadTimingsMS(_ timings: [String: Int]) {
        diagnosticsLock.lock()
        storedLoadTimingsMS = timings
        diagnosticsLock.unlock()
    }

    private func storeLoadBooleanFlags(_ flags: [String: Bool]) {
        diagnosticsLock.lock()
        storedLoadBooleanFlags = flags
        diagnosticsLock.unlock()
    }

    private func storePreparationTimingsMS(_ timings: [String: Int]) {
        diagnosticsLock.lock()
        storedPreparationTimingsMS = timings
        diagnosticsLock.unlock()
    }

    private func mergePreparationTimingsMS(_ timings: [String: Int]) {
        diagnosticsLock.lock()
        storedPreparationTimingsMS.merge(timings) { _, rhs in rhs }
        diagnosticsLock.unlock()
    }

    private func storePreparationBooleanFlags(_ flags: [String: Bool]) {
        diagnosticsLock.lock()
        storedPreparationBooleanFlags = flags
        diagnosticsLock.unlock()
    }

    private func mergePreparationBooleanFlags(_ flags: [String: Bool]) {
        diagnosticsLock.lock()
        storedPreparationBooleanFlags.merge(flags) { _, rhs in rhs }
        diagnosticsLock.unlock()
    }

    private static func ensureTokenizerJSON(in modelDir: URL) throws {
        let fm = FileManager.default
        let tokenizerJsonPath = modelDir.appendingPathComponent("tokenizer.json")
        guard !fm.fileExists(atPath: tokenizerJsonPath.path) else {
            return
        }

        let vocabPath = modelDir.appendingPathComponent("vocab.json")
        let mergesPath = modelDir.appendingPathComponent("merges.txt")
        let hasVocab = fm.fileExists(atPath: vocabPath.path)
        let hasMerges = fm.fileExists(atPath: mergesPath.path)

        guard hasVocab, hasMerges else {
            qwen3TTSLog("Warning: Cannot generate tokenizer.json — vocab.json: \(hasVocab), merges.txt: \(hasMerges)")
            return
        }

        do {
            try generateTokenizerJson(
                vocabPath: vocabPath,
                mergesPath: mergesPath,
                tokenizerConfigPath: modelDir.appendingPathComponent("tokenizer_config.json"),
                outputPath: tokenizerJsonPath
            )
            qwen3TTSLog("Generated tokenizer.json from vocab.json + merges.txt")
        } catch {
            qwen3TTSLog("Warning: Failed to generate tokenizer.json: \(error)")
        }
    }

    private static func preparedDirectoryKey(for modelDir: URL) -> String {
        modelDir.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func speechTokenizerCacheKey(
        for preparedKey: String,
        includeEncoder: Bool
    ) -> String {
        "\(preparedKey)|speechTokenizer:\(includeEncoder ? "full" : "decoderOnly")"
    }

    private static func loadWeights(
        from directory: URL,
        directSafetensorsFileName: String
    ) throws -> [String: MLXArray] {
        let directWeightsURL = directory.appendingPathComponent(directSafetensorsFileName)
        if FileManager.default.fileExists(atPath: directWeightsURL.path) {
            return try MLX.loadArrays(url: directWeightsURL)
        }

        var mergedWeights = [String: MLXArray]()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "safetensors" {
            let weights = try MLX.loadArrays(url: file)
            mergedWeights.merge(weights) { _, new in new }
        }
        return mergedWeights
    }

    private static func loadSpeechTokenizer(
        path: URL,
        trustPreparedCheckpoint: Bool,
        includeEncoder: Bool,
        skipSpeechTokenizerEval: Bool,
        diagnosticEventSink: (@Sendable (String, [String: String]) async -> Void)?
    ) async throws -> Qwen3TTSSpeechTokenizer {
        await emitPreparedLoadDiagnostic(
            diagnosticEventSink,
            action: "qwen-speech-tokenizer-load-start",
            details: [
                "path": path.path,
                "trustPreparedCheckpoint": trustPreparedCheckpoint ? "true" : "false",
                "includeEncoder": includeEncoder ? "true" : "false",
            ]
        )
        // Load config — fall back to defaults if config.json is missing
        let tokenizerConfig: Qwen3TTSTokenizerConfig
        let configPath = path.appendingPathComponent("config.json")
        if let configData = try? Data(contentsOf: configPath) {
            tokenizerConfig = try JSONDecoder().decode(Qwen3TTSTokenizerConfig.self, from: configData)
        } else {
            qwen3TTSLog("Warning: speech_tokenizer/config.json not found, using defaults")
            let defaultJson = "{}".data(using: .utf8)!
            tokenizerConfig = try JSONDecoder().decode(Qwen3TTSTokenizerConfig.self, from: defaultJson)
        }
        await emitPreparedLoadDiagnostic(
            diagnosticEventSink,
            action: "qwen-speech-tokenizer-after-config",
            details: [
                "path": path.path,
                "trustPreparedCheckpoint": trustPreparedCheckpoint ? "true" : "false",
                "includeEncoder": includeEncoder ? "true" : "false",
            ]
        )

        let speechTokenizer = Qwen3TTSSpeechTokenizer(
            config: tokenizerConfig,
            includeEncoder: includeEncoder
        )

        // Load weights
        var tokenizerWeights = try loadWeights(
            from: path,
            directSafetensorsFileName: "model.safetensors"
        )

        if !tokenizerWeights.isEmpty {
            var sanitized = Qwen3TTSSpeechTokenizer.sanitize(weights: tokenizerWeights)
            tokenizerWeights.removeAll(keepingCapacity: false)
            if !includeEncoder {
                sanitized = sanitized.filter { key, _ in
                    !key.hasPrefix("encoder_model.")
                }
            }
            var pairs = sanitized.map { ($0.key, $0.value) }
            try speechTokenizer.update(
                parameters: ModuleParameters.unflattened(pairs),
                verify: trustPreparedCheckpoint ? .noUnusedKeys : .all
            )
            pairs.removeAll(keepingCapacity: false)
            sanitized.removeAll(keepingCapacity: false)
            Memory.clearCache()
            await emitPreparedLoadDiagnostic(
                diagnosticEventSink,
                action: "qwen-speech-tokenizer-after-update",
                details: [
                    "path": path.path,
                    "trustPreparedCheckpoint": trustPreparedCheckpoint ? "true" : "false",
                    "includeEncoder": includeEncoder ? "true" : "false",
                    "parameterPairCount": "\(speechTokenizer.parameters().flattened().count)",
                ]
            )
            if skipSpeechTokenizerEval {
                await emitPreparedLoadDiagnostic(
                    diagnosticEventSink,
                    action: "qwen-speech-tokenizer-eval-skipped",
                    details: [
                        "path": path.path,
                        "includeEncoder": includeEncoder ? "true" : "false",
                        "parameterArrayCount": "0",
                        "reason": "skipSpeechTokenizerEval",
                    ]
                )
            } else {
                let parameterArrays = flattenedParameterArrays(from: speechTokenizer.parameters())
                await emitPreparedLoadDiagnostic(
                    diagnosticEventSink,
                    action: "qwen-speech-tokenizer-before-eval",
                    details: [
                        "path": path.path,
                        "includeEncoder": includeEncoder ? "true" : "false",
                        "parameterArrayCount": "\(parameterArrays.count)",
                        "evalBatchSize": "\(speechTokenizerEvalBatchSize)",
                    ]
                )
                evalParameterArraysInBatches(parameterArrays, batchSize: speechTokenizerEvalBatchSize)
                await emitPreparedLoadDiagnostic(
                    diagnosticEventSink,
                    action: "qwen-speech-tokenizer-after-eval",
                    details: [
                        "path": path.path,
                        "includeEncoder": includeEncoder ? "true" : "false",
                        "parameterArrayCount": "\(parameterArrays.count)",
                    ]
                )
            }
            Memory.clearCache()
        }

        speechTokenizer.decoder.resetStreamingState()
        qwen3TTSLog("Loaded speech tokenizer decoder")
        return speechTokenizer
    }

    // MARK: - Generate tokenizer.json from vocab.json + merges.txt

    /// Qwen3-TTS repos ship with a slow tokenizer (vocab.json + merges.txt) but
    /// swift-transformers requires tokenizer.json (fast tokenizer format). This
    /// generates the fast tokenizer JSON from the available files.
    private static func generateTokenizerJson(
        vocabPath: URL,
        mergesPath: URL,
        tokenizerConfigPath: URL,
        outputPath: URL
    ) throws {
        // Read vocab
        let vocabData = try Data(contentsOf: vocabPath)
        let vocabDict = try JSONSerialization.jsonObject(with: vocabData) as? [String: Int] ?? [:]

        // Read merges (skip header line "#version: ...")
        let mergesText = try String(contentsOf: mergesPath, encoding: .utf8)
        let mergeLines = mergesText.components(separatedBy: .newlines)
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        // Read added_tokens from tokenizer_config.json
        var addedTokens = [[String: Any]]()
        if let configData = try? Data(contentsOf: tokenizerConfigPath),
           let configDict = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
           let addedTokensDecoder = configDict["added_tokens_decoder"] as? [String: [String: Any]] {
            for (idStr, tokenInfo) in addedTokensDecoder {
                guard let tokenId = Int(idStr),
                      let content = tokenInfo["content"] as? String else { continue }
                let entry: [String: Any] = [
                    "id": tokenId,
                    "content": content,
                    "single_word": tokenInfo["single_word"] as? Bool ?? false,
                    "lstrip": tokenInfo["lstrip"] as? Bool ?? false,
                    "rstrip": tokenInfo["rstrip"] as? Bool ?? false,
                    "normalized": tokenInfo["normalized"] as? Bool ?? false,
                    "special": tokenInfo["special"] as? Bool ?? true
                ]
                addedTokens.append(entry)
            }
            addedTokens.sort { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }
        }

        // Build tokenizer.json
        // Qwen2 uses ByteLevel BPE with a GPT-2-style regex pre-tokenizer
        let tokenizerJson: [String: Any] = [
            "version": "1.0",
            "truncation": NSNull(),
            "padding": NSNull(),
            "added_tokens": addedTokens,
            "normalizer": NSNull(),
            "pre_tokenizer": [
                "type": "Sequence",
                "pretokenizers": [
                    [
                        "type": "Split",
                        "pattern": [
                            "Regex": "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"
                        ],
                        "behavior": "Isolated",
                        "invert": false
                    ] as [String: Any],
                    [
                        "type": "ByteLevel",
                        "add_prefix_space": false,
                        "trim_offsets": true,
                        "use_regex": false
                    ] as [String: Any]
                ] as [[String: Any]]
            ] as [String: Any],
            "post_processor": NSNull(),
            "decoder": [
                "type": "ByteLevel",
                "add_prefix_space": true,
                "trim_offsets": true,
                "use_regex": true
            ] as [String: Any],
            "model": [
                "type": "BPE",
                "dropout": NSNull(),
                "unk_token": NSNull(),
                "continuing_subword_prefix": "",
                "end_of_word_suffix": "",
                "fuse_unk": false,
                "byte_fallback": false,
                "ignore_merges": false,
                "vocab": vocabDict,
                "merges": mergeLines
            ] as [String: Any]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: tokenizerJson, options: [.sortedKeys])
        try jsonData.write(to: outputPath)
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
