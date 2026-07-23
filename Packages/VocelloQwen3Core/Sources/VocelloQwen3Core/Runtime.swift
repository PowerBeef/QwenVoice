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

    static func loadPreparedModel(
        _ bundle: VocelloQwen3PreparedModelBundle,
        loadBehavior: VocelloQwen3LoadBehavior? = nil,
        cachePolicy: VocelloQwen3CachePolicy = .systemDefault,
        diagnosticSink: VocelloQwen3DiagnosticSink? = nil,
        verboseDiagnosticSink: VocelloQwen3VerboseLoadDiagnosticSink? = nil,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> VocelloQwen3LoadedModel {
        let compatibilitySink: (@Sendable (String, [String: String]) async -> Void)?
        if diagnosticSink != nil || verboseDiagnosticSink != nil {
            compatibilitySink = { action, details in
                if let verboseDiagnosticSink {
                    await verboseDiagnosticSink(action, details)
                }
                if let diagnosticSink {
                    await diagnosticSink(typedDiagnosticEvent(forCompatibilityAction: action))
                }
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
            cache: cachePolicy.compatibilityValue,
            isolation: isolation
        )
        return try VocelloQwen3LoadedModel(
            compatibilityModel: compatibilityModel,
            identity: bundle.identity,
            capabilities: bundle.capabilities
        )
    }

    /// Clears Qwen3-owned prepared, conditioning, and decoder caches after the
    /// host has proven that active generation terminated. The product controls
    /// when this lifecycle boundary is safe; cache implementation stays here.
    public static func clearRuntimeCaches(
        isolation: isolated (any Actor)? = #isolation
    ) async {
        await Qwen3TTSMemoryCaches.clearAll(isolation: isolation)
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
