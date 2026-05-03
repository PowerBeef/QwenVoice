import Foundation
@preconcurrency import MLXAudioCore
@testable import QwenVoiceCore

extension UnsafeSpeechGenerationModel {
    /// Builds an `UnsafeSpeechGenerationModel` whose handlers all succeed
    /// as no-ops and whose stream handlers return an immediately-empty
    /// `AsyncThrowingStream`. Reports `supportsDedicatedCustomVoice` /
    /// `supportsOptimizedVoiceDesign` / `supportsOptimizedVoiceClone` as
    /// `true` so the runtime's prepare paths take the optimized branches
    /// without throwing "the active native model does not support …".
    ///
    /// Suitable for tests that mock the streaming session via
    /// `streamingSessionFactory`: the prewarm and stream handlers below
    /// satisfy the runtime's pre-streaming calls but their stream output
    /// is never consumed (the mock session takes over).
    ///
    /// Built for Session 5c of the QwenVoiceNativeRuntime retirement.
    static func makeFullySupportingForTesting(sampleRate: Int = 24_000) -> UnsafeSpeechGenerationModel {
        let emptyStream: @Sendable () -> AsyncThrowingStream<AudioGeneration, Error> = {
            AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }
        return UnsafeSpeechGenerationModel(
            sampleRate: sampleRate,
            prewarmHandler: { _, _ in },
            streamHandler: { _, _, _ in emptyStream() },
            customPrewarmHandler: { _, _, _, _ in },
            customStreamHandler: { _, _, _, _, _ in emptyStream() },
            designPrewarmHandler: { _, _, _ in },
            designStreamHandler: { _, _, _, _ in emptyStream() },
            clonePromptCreator: nil,
            clonePrewarmHandler: { _, _, _ in },
            cloneStreamHandler: { _, _, _, _ in emptyStream() }
        )
    }
}

extension NativeModelLoadResult {
    /// Builds a `NativeModelLoadResult` whose model is a default closure-
    /// initialized `UnsafeSpeechGenerationModel`. Suitable for tests that
    /// don't actually exercise generation — load-state, prewarm, and
    /// snapshot-state tests.
    ///
    /// Built for Session 5c of the QwenVoiceNativeRuntime retirement.
    @MainActor
    static func makeForTesting(
        model: UnsafeSpeechGenerationModel = UnsafeSpeechGenerationModel(),
        didLoad: Bool = true,
        capabilityProfile: NativeLoadCapabilityProfile = .fullCapabilities,
        timingsMS: [String: Int] = [:],
        booleanFlags: [String: Bool] = [:],
        stringFlags: [String: String] = [:]
    ) -> NativeModelLoadResult {
        NativeModelLoadResult(
            model: model,
            didLoad: didLoad,
            capabilityProfile: capabilityProfile,
            timingsMS: timingsMS,
            booleanFlags: booleanFlags,
            stringFlags: stringFlags
        )
    }
}

extension MLXTTSEngine {
    /// Test-only factory that constructs an `MLXTTSEngine` with a caller-
    /// supplied `MLXModelCoordinating` and an optional streaming-session
    /// factory. Bundles the boilerplate of building a
    /// `LocalModelAssetStore` + `NativeAudioPreparationService` +
    /// `LocalDocumentIO` from a temporary root directory so tests don't
    /// have to repeat that wiring.
    ///
    /// Defaults `streamingSessionFactory` to a fail-fast factory that
    /// `fatalError`s if a generation is invoked — tests that don't
    /// exercise generation can ignore it; tests that do should pass a
    /// `MockNativeStreamingSession`-backed factory.
    ///
    /// Built for Session 5b of the QwenVoiceNativeRuntime retirement.
    @MainActor
    static func makeForTesting(
        modelRegistry: any ModelRegistry,
        rootDirectory: URL,
        loadCoordinator: any MLXModelCoordinating,
        streamingSessionFactory: StreamingSessionFactory? = nil,
        storeVersionSeed: String = "tests-mock"
    ) -> MLXTTSEngine {
        let modelAssetStore = LocalModelAssetStore(
            modelRegistry: modelRegistry,
            rootDirectory: rootDirectory.appendingPathComponent("models", isDirectory: true),
            storeVersionSeed: storeVersionSeed
        )
        let audioPreparationService = NativeAudioPreparationService(
            preparedAudioDirectory: rootDirectory.appendingPathComponent("cache/prepared_audio", isDirectory: true)
        )
        let documentIO = LocalDocumentIO(
            importedReferenceDirectory: rootDirectory.appendingPathComponent("cache/imported_references", isDirectory: true)
        )
        let streamSessionsDirectory = rootDirectory.appendingPathComponent("cache/stream_sessions", isDirectory: true)
        let factory: StreamingSessionFactory = streamingSessionFactory ?? { _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
            fatalError("MLXTTSEngine.makeForTesting was constructed without a streamingSessionFactory but generation was invoked.")
        }
        return MLXTTSEngine(
            modelRegistry: modelRegistry,
            modelAssetStore: modelAssetStore,
            audioPreparationService: audioPreparationService,
            documentIO: documentIO,
            streamSessionsDirectory: streamSessionsDirectory,
            loadCoordinator: loadCoordinator,
            streamingSessionFactory: factory
        )
    }
}
