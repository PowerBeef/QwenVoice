import Foundation
import HuggingFace
import MLXAudioTTS

/// First-party cache selection for the owned runtime.
///
/// Hugging Face's concrete cache type remains an implementation detail. The
/// default case preserves the package's existing environment-aware cache
/// behavior; callers that own a fixed cache root can select it explicitly.
public enum VocelloQwen3CachePolicy: Hashable, Sendable {
    case systemDefault
    case directory(URL)

    var compatibilityValue: HubCache {
        switch self {
        case .systemDefault:
            return .default
        case .directory(let directory):
            return HubCache(cacheDirectory: directory)
        }
    }
}

/// Stable first-party entry point over the compatibility-preserved runtime
/// implementation modules.
public enum VocelloQwen3Runtime {
    public static func prepareModelBundle(_ bundle: VocelloQwen3PreparedModelBundle) throws {
        try prepareModelDirectory(
            at: bundle.preparedDirectory,
            repositoryID: bundle.identity.repositoryID,
            modelType: bundle.modelType
        )
    }

    public static func prepareModelDirectory(
        at directory: URL,
        repositoryID: String,
        modelType: String?
    ) throws {
        try TTS.preparePreparedDirectory(
            directory,
            modelRepo: repositoryID,
            modelType: modelType
        )
    }

    public static func loadPreparedModel(
        _ bundle: VocelloQwen3PreparedModelBundle,
        loadBehavior: VocelloQwen3LoadBehavior? = nil,
        cachePolicy: VocelloQwen3CachePolicy = .systemDefault,
        diagnosticSink: VocelloQwen3DiagnosticSink? = nil
    ) async throws -> VocelloQwen3LoadedModel {
        let compatibilitySink: (@Sendable (String, [String: String]) async -> Void)?
        if let diagnosticSink {
            compatibilitySink = { action, _ in
                await diagnosticSink(typedDiagnosticEvent(forCompatibilityAction: action))
            }
        } else {
            compatibilitySink = nil
        }

        let compatibilityModel = try await TTS.loadModel(
            fromPreparedDirectory: bundle.preparedDirectory,
            modelRepo: bundle.identity.repositoryID,
            modelType: bundle.modelType,
            trustPreparedCheckpoint: bundle.trustedPreparedCheckpoint,
            qwenPreparedLoadBehavior: loadBehavior?.compatibilityValue,
            diagnosticEventSink: compatibilitySink,
            cache: cachePolicy.compatibilityValue
        )
        return try VocelloQwen3LoadedModel(
            compatibilityModel: compatibilityModel,
            identity: bundle.identity,
            capabilities: bundle.capabilities
        )
    }

    /// Transitional adapter for existing detailed telemetry. New facade clients
    /// should use the typed overload above; arbitrary details never become part
    /// of the stable facade contract.
    public static func loadPreparedModel(
        _ bundle: VocelloQwen3PreparedModelBundle,
        loadBehavior: VocelloQwen3LoadBehavior? = nil,
        cachePolicy: VocelloQwen3CachePolicy = .systemDefault,
        compatibilityDiagnosticSink: (@Sendable (String, [String: String]) async -> Void)?
    ) async throws -> VocelloQwen3LoadedModel {
        let compatibilityModel = try await TTS.loadModel(
            fromPreparedDirectory: bundle.preparedDirectory,
            modelRepo: bundle.identity.repositoryID,
            modelType: bundle.modelType,
            trustPreparedCheckpoint: bundle.trustedPreparedCheckpoint,
            qwenPreparedLoadBehavior: loadBehavior?.compatibilityValue,
            diagnosticEventSink: compatibilityDiagnosticSink,
            cache: cachePolicy.compatibilityValue
        )
        return try VocelloQwen3LoadedModel(
            compatibilityModel: compatibilityModel,
            identity: bundle.identity,
            capabilities: bundle.capabilities
        )
    }

    public static func apply(memoryConfiguration: VocelloQwen3MemoryConfiguration) throws {
        let configuration = try memoryConfiguration.validated()
        Qwen3StreamingMemoryTuning.apply(
            clearOnStreamChunk: configuration.clearCacheOnStreamChunk,
            tokenCadence: configuration.tokenMemoryClearCadence
        )
        Qwen3StreamingMemoryTuning.applyTalkerKVWindow(configuration.talkerKVGeneratedWindow)
    }

    /// Clears Qwen3-owned prepared, conditioning, and decoder caches after the
    /// host has proven that active generation terminated. The product controls
    /// when this lifecycle boundary is safe; cache implementation stays here.
    public static func clearRuntimeCaches() async {
        await Qwen3TTSMemoryCaches.clearAll()
    }

    static func typedDiagnosticEvent(
        forCompatibilityAction action: String
    ) -> VocelloQwen3DiagnosticEvent {
        let lowercased = action.lowercased()
        let phase: VocelloQwen3DiagnosticPhase
        if lowercased.contains("load") {
            phase = .modelLoad
        } else if lowercased.contains("prepare") || lowercased.contains("tokenizer") {
            phase = .modelPreparation
        } else if lowercased.contains("prewarm") {
            phase = .prewarm
        } else if lowercased.contains("decode") || lowercased.contains("codec") {
            phase = .decode
        } else if lowercased.contains("final") || lowercased.contains("complete") {
            phase = .finalization
        } else {
            phase = .synthesis
        }

        let disposition: VocelloQwen3DiagnosticDisposition
        if lowercased.contains("before") || lowercased.contains("begin") || lowercased.contains("start") {
            disposition = .began
        } else if lowercased.contains("cancel") {
            disposition = .cancelled
        } else if lowercased.contains("fail") || lowercased.contains("error") {
            disposition = .failed
        } else if lowercased.contains("after") || lowercased.contains("complete") || lowercased.contains("finish") {
            disposition = .completed
        } else {
            disposition = .observed
        }

        return VocelloQwen3DiagnosticEvent(
            phase: phase,
            disposition: disposition,
            failureCode: disposition == .failed ? .runtime : nil
        )
    }
}
