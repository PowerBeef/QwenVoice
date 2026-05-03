import Foundation
@testable import QwenVoiceCore

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
