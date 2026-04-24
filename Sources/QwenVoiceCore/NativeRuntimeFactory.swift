import Foundation

public enum NativeCustomPrewarmPolicy: Sendable {
    case eager
    case skipDedicatedCustomPrewarm
}

public enum NativeQwenPreparedLoadProfile: Sendable {
    case fullCapabilities
    case streamingOnly

    public init(capabilityProfile: NativeLoadCapabilityProfile) {
        switch capabilityProfile {
        case .cloneOnly, .fullCapabilities:
            self = .fullCapabilities
        case .customOnly, .designOnly:
            self = .streamingOnly
        }
    }
}

public struct NativeRuntimePaths: Sendable {
    public let runtimeRootDirectory: URL
    public let modelsDirectory: URL
    public let preparedAudioDirectory: URL
    public let importedReferenceDirectory: URL
    public let hubCacheDirectory: URL
    public let streamSessionsDirectory: URL

    public init(
        runtimeRootDirectory: URL,
        modelsDirectory: URL,
        preparedAudioDirectory: URL,
        importedReferenceDirectory: URL,
        hubCacheDirectory: URL,
        streamSessionsDirectory: URL
    ) {
        self.runtimeRootDirectory = runtimeRootDirectory
        self.modelsDirectory = modelsDirectory
        self.preparedAudioDirectory = preparedAudioDirectory
        self.importedReferenceDirectory = importedReferenceDirectory
        self.hubCacheDirectory = hubCacheDirectory
        self.streamSessionsDirectory = streamSessionsDirectory
    }

    public static func rooted(at runtimeRootDirectory: URL) -> NativeRuntimePaths {
        NativeRuntimePaths(
            runtimeRootDirectory: runtimeRootDirectory,
            modelsDirectory: runtimeRootDirectory.appendingPathComponent("models", isDirectory: true),
            preparedAudioDirectory: runtimeRootDirectory.appendingPathComponent("cache/prepared_audio", isDirectory: true),
            importedReferenceDirectory: runtimeRootDirectory.appendingPathComponent("cache/imported_references", isDirectory: true),
            hubCacheDirectory: runtimeRootDirectory.appendingPathComponent("cache/native_mlx", isDirectory: true),
            streamSessionsDirectory: runtimeRootDirectory.appendingPathComponent("cache/stream_sessions", isDirectory: true)
        )
    }
}

@MainActor
public struct NativeRuntimeComponents {
    public let modelRegistry: ContractBackedModelRegistry
    public let modelAssetStore: LocalModelAssetStore
    public let audioPreparationService: NativeAudioPreparationService
    public let documentIO: LocalDocumentIO
    public let engine: MLXTTSEngine
}

@MainActor
public enum NativeRuntimeFactory {
    public static func make(
        manifestURL: URL,
        paths: NativeRuntimePaths,
        storeVersionSeed: String,
        telemetryRecorder: NativeTelemetryRecorder? = nil,
        customPrewarmPolicy: NativeCustomPrewarmPolicy = .eager,
        qwenPreparedLoadProfile: NativeQwenPreparedLoadProfile = .fullCapabilities
    ) throws -> NativeRuntimeComponents {
        let registry = try ContractBackedModelRegistry(manifestURL: manifestURL)
        return try make(
            registry: registry,
            paths: paths,
            storeVersionSeed: storeVersionSeed,
            telemetryRecorder: telemetryRecorder,
            customPrewarmPolicy: customPrewarmPolicy,
            qwenPreparedLoadProfile: qwenPreparedLoadProfile
        )
    }

    public static func make(
        registry: ContractBackedModelRegistry,
        paths: NativeRuntimePaths,
        storeVersionSeed: String,
        telemetryRecorder: NativeTelemetryRecorder? = nil,
        customPrewarmPolicy: NativeCustomPrewarmPolicy = .eager,
        qwenPreparedLoadProfile: NativeQwenPreparedLoadProfile = .fullCapabilities
    ) throws -> NativeRuntimeComponents {
        let modelAssetStore = LocalModelAssetStore(
            modelRegistry: registry,
            rootDirectory: paths.modelsDirectory,
            storeVersionSeed: storeVersionSeed
        )
        let audioPreparationService = NativeAudioPreparationService(
            preparedAudioDirectory: paths.preparedAudioDirectory
        )
        let documentIO = LocalDocumentIO(
            importedReferenceDirectory: paths.importedReferenceDirectory
        )
        let engine = MLXTTSEngine(
            modelRegistry: registry,
            modelAssetStore: modelAssetStore,
            audioPreparationService: audioPreparationService,
            documentIO: documentIO,
            hubCacheDirectory: paths.hubCacheDirectory,
            streamSessionsDirectory: paths.streamSessionsDirectory,
            telemetryRecorder: telemetryRecorder,
            customPrewarmPolicy: customPrewarmPolicy,
            qwenPreparedLoadProfile: qwenPreparedLoadProfile
        )
        return NativeRuntimeComponents(
            modelRegistry: registry,
            modelAssetStore: modelAssetStore,
            audioPreparationService: audioPreparationService,
            documentIO: documentIO,
            engine: engine
        )
    }
}
