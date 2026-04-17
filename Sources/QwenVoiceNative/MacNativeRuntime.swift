import Foundation
@preconcurrency import MLXAudioTTS

enum EngineWarmState: String, Sendable {
    case cold
    case warm
}

struct NativePreparedGeneration: Sendable {
    let requestID: Int
    let request: GenerationRequest
    let model: NativeSpeechGenerationModel
    let streamSessionsDirectory: URL
    let warmState: EngineWarmState
    let timingOverridesMS: [String: Int]
    let booleanFlags: [String: Bool]
    let stringFlags: [String: String]
}

public actor MacNativeRuntime {
    public struct Paths: Sendable, Equatable {
        public let appSupportDirectory: URL
        public let modelsDirectory: URL
        public let downloadsStagingDirectory: URL
        public let nativeMLXCacheDirectory: URL
        public let preparedAudioCacheDirectory: URL
        public let normalizedCloneReferencesDirectory: URL
        public let streamSessionsDirectory: URL
        public let outputsDirectory: URL
        public let voicesDirectory: URL
    }

    public enum RuntimeError: LocalizedError {
        case notInitialized
        case unknownModel(String)
        case modelUnavailable(id: String, missingRequiredPaths: [String])
        case noLoadedModel(String)
        case unsupportedGenerationMode(String)
        case sourceAudioMissing(String)
        case duplicatePreparedVoice(String)
        case preparedVoiceNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .notInitialized:
                return "The native engine runtime is not initialized yet."
            case .unknownModel(let id):
                return "The native engine could not find model '\(id)' in the bundled contract."
            case .modelUnavailable(let id, let missingRequiredPaths):
                let details = missingRequiredPaths.joined(separator: ", ")
                return "Model '\(id)' is unavailable or incomplete. Missing required paths: \(details)"
            case .noLoadedModel(let id):
                return "The native engine expected model '\(id)' to be loaded, but no loaded model handle is available."
            case .unsupportedGenerationMode(let mode):
                return "Native generation for '\(mode)' is not implemented yet."
            case .sourceAudioMissing(let path):
                return "Couldn't find the source audio file at \(path)."
            case .duplicatePreparedVoice(let id):
                return "A saved voice named \"\(id)\" already exists."
            case .preparedVoiceNotFound(let id):
                return "Couldn't find the saved voice \"\(id)\"."
            }
        }
    }

    typealias ModelLoader = @Sendable (NativeModelDescriptor, URL) async throws -> NativeSpeechGenerationModel

    private enum DesignWarmSource: Sendable {
        case prefetch
        case generation
    }

    private struct DesignConditioningWarmState: Sendable {
        let bucket: GenerationSemantics.DesignWarmBucket
        let requestKey: String
        let reused: Bool
        let prefetchHit: Bool
        let prewarmed: Bool
        let streamStepPrewarmed: Bool
    }

    private let fileManager: FileManager
    private let registryFactory: @Sendable () throws -> NativeModelRegistry
    private let loadOperation: @Sendable (NativeModelDescriptor) async throws -> Void
    private let modelLoader: ModelLoader
    private let loadCoordinator: NativeModelLoadCoordinator

    private var initializedPaths: Paths?
    private var modelRegistry: NativeModelRegistry?
    private var loadedModel: NativeSpeechGenerationModel?
    private var nextRequestID = 1
    private var activeDesignConditioningWarmKey: String?
    private var activeDesignConditioningWarmSource: DesignWarmSource?
    private var activeDesignStreamStepWarmKey: String?

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.registryFactory = {
            try NativeModelRegistry()
        }
        self.loadOperation = { _ in }
        self.modelLoader = Self.defaultModelLoader
        self.loadCoordinator = NativeModelLoadCoordinator()
    }

    init(
        fileManager: FileManager = .default,
        manifestURL: URL? = nil,
        loadOperation: @escaping @Sendable (NativeModelDescriptor) async throws -> Void = { _ in },
        modelLoader: @escaping ModelLoader = MacNativeRuntime.defaultModelLoader,
        loadCoordinator: NativeModelLoadCoordinator = NativeModelLoadCoordinator()
    ) {
        self.fileManager = fileManager
        self.registryFactory = {
            try NativeModelRegistry(manifestURL: manifestURL)
        }
        self.loadOperation = loadOperation
        self.modelLoader = modelLoader
        self.loadCoordinator = loadCoordinator
    }

    @discardableResult
    public func initialize(appSupportDirectory: URL) async throws -> Paths {
        let paths = Paths(
            appSupportDirectory: appSupportDirectory,
            modelsDirectory: appSupportDirectory.appendingPathComponent("models", isDirectory: true),
            downloadsStagingDirectory: appSupportDirectory.appendingPathComponent("downloads/staging", isDirectory: true),
            nativeMLXCacheDirectory: appSupportDirectory.appendingPathComponent("cache/native_mlx", isDirectory: true),
            preparedAudioCacheDirectory: appSupportDirectory.appendingPathComponent("cache/prepared_audio", isDirectory: true),
            normalizedCloneReferencesDirectory: appSupportDirectory.appendingPathComponent("cache/normalized_clone_refs", isDirectory: true),
            streamSessionsDirectory: appSupportDirectory.appendingPathComponent("cache/stream_sessions", isDirectory: true),
            outputsDirectory: appSupportDirectory.appendingPathComponent("outputs", isDirectory: true),
            voicesDirectory: appSupportDirectory.appendingPathComponent("voices", isDirectory: true)
        )

        try createDirectoryTree(for: paths)
        _ = try requireRegistry()
        initializedPaths = paths
        loadedModel = nil
        nextRequestID = 1
        clearDesignWarmState()
        await loadCoordinator.unloadModel()
        return paths
    }

    public func loadModel(id: String) async throws {
        let paths = try requirePaths()
        let registry = try requireRegistry()
        try await loadCoordinator.loadModel(id: id) {
            try await self.validateAndLoadModel(
                modelID: id,
                registry: registry,
                modelsDirectory: paths.modelsDirectory
            )
        }
    }

    public func ensureModelLoadedIfNeeded(id: String) async throws {
        let paths = try requirePaths()
        let registry = try requireRegistry()
        try await loadCoordinator.ensureModelLoadedIfNeeded(id: id) {
            try await self.validateAndLoadModel(
                modelID: id,
                registry: registry,
                modelsDirectory: paths.modelsDirectory
            )
        }
    }

    public func prewarmModelIfNeeded(for request: GenerationRequest) async throws {
        try await ensureModelLoadedIfNeeded(id: request.modelID)

        let identityKey = GenerationSemantics.prewarmIdentityKey(for: request)
        let model = try await requireLoadedModel(expectedModelID: request.modelID)
        switch request.payload {
        case .design:
            _ = try await ensureDesignConditioningWarmStateIfNeeded(
                for: request,
                using: model,
                source: .prefetch
            )
        case .custom, .clone:
            guard !(await loadCoordinator.isPrewarmed(identityKey: identityKey)) else {
                return
            }
            try await prepareWarmState(for: request, using: model)
        }
        await loadCoordinator.markPrewarmed(identityKey: identityKey)
    }

    func prepareGeneration(for request: GenerationRequest) async throws -> NativePreparedGeneration {
        try await ensureModelLoadedIfNeeded(id: request.modelID)

        let model = try await requireLoadedModel(expectedModelID: request.modelID)
        let identityKey = GenerationSemantics.prewarmIdentityKey(for: request)
        let wasPrewarmed = await loadCoordinator.isPrewarmed(identityKey: identityKey)

        model.resetPreparationDiagnostics()
        let warmState: EngineWarmState
        var timingOverridesMS: [String: Int] = [:]
        var booleanFlags: [String: Bool] = [:]
        var stringFlags: [String: String] = [:]

        switch request.payload {
        case .design:
            let designWarmState = try await ensureDesignConditioningWarmStateIfNeeded(
                for: request,
                using: model,
                source: .generation
            )
            if !wasPrewarmed {
                await loadCoordinator.markPrewarmed(identityKey: identityKey)
            }
            warmState = wasPrewarmed ? .warm : .cold
            timingOverridesMS.merge(model.latestPreparationTimingsMS) { _, rhs in rhs }
            booleanFlags.merge(model.latestPreparationBooleanFlags) { _, rhs in rhs }
            booleanFlags["design_conditioning_reused"] = designWarmState.reused
            booleanFlags["design_conditioning_prefetch_hit"] = designWarmState.prefetchHit
            booleanFlags["design_conditioning_prewarmed"] = designWarmState.prewarmed
            booleanFlags["design_stream_step_prewarmed"] = designWarmState.streamStepPrewarmed
            booleanFlags["design_warm_bucket_short"] = designWarmState.bucket == .short
            booleanFlags["design_warm_bucket_long"] = designWarmState.bucket == .long
            booleanFlags["design_optimized_handler_used"] = model.supportsOptimizedVoiceDesign
            stringFlags["design_conditioning_request_key"] = designWarmState.requestKey
        case .custom, .clone:
            if wasPrewarmed {
                warmState = .warm
            } else {
                try await prepareWarmState(for: request, using: model)
                await loadCoordinator.markPrewarmed(identityKey: identityKey)
                warmState = .cold
            }
            timingOverridesMS = model.latestPreparationTimingsMS
            booleanFlags = mergedBooleanFlags(for: model, warmState: warmState)
        }

        let requestID = takeNextRequestID()
        stringFlags["generation_mode"] = request.modeIdentifier
        stringFlags["warm_state"] = warmState.rawValue

        return NativePreparedGeneration(
            requestID: requestID,
            request: request,
            model: model,
            streamSessionsDirectory: try requirePaths().streamSessionsDirectory,
            warmState: warmState,
            timingOverridesMS: timingOverridesMS,
            booleanFlags: booleanFlags,
            stringFlags: stringFlags
        )
    }

    public func unloadModel() async {
        loadedModel = nil
        clearDesignWarmState()
        await loadCoordinator.unloadModel()
    }

    public func currentLoadedModelID() async -> String? {
        await loadCoordinator.currentLoadedModelID()
    }

    func isPrewarmed(identityKey: String) async -> Bool {
        await loadCoordinator.isPrewarmed(identityKey: identityKey)
    }

    func modelAvailability(for modelID: String) throws -> NativeModelAvailability {
        let paths = try requirePaths()
        let registry = try requireRegistry()
        return registry.availability(
            forModelID: modelID,
            in: paths.modelsDirectory,
            fileManager: fileManager
        )
    }

    public func listPreparedVoices() throws -> [PreparedVoice] {
        let voicesDirectory = try requirePaths().voicesDirectory
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        let urls = try fileManager.contentsOfDirectory(
            at: voicesDirectory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        let voices = try urls.compactMap { url -> PreparedVoice? in
            guard try url.resourceValues(forKeys: resourceKeys).isRegularFile == true else {
                return nil
            }
            guard url.pathExtension.lowercased() != "txt" else {
                return nil
            }
            return try makePreparedVoice(fromAudioURL: url)
        }

        return voices.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func enrollPreparedVoice(
        name: String,
        audioPath: String,
        transcript: String?
    ) throws -> PreparedVoice {
        let paths = try requirePaths()
        let sourceURL = URL(fileURLWithPath: audioPath)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw RuntimeError.sourceAudioMissing(audioPath)
        }

        if try existingPreparedVoiceAudioURL(for: name) != nil {
            throw RuntimeError.duplicatePreparedVoice(name)
        }

        let audioExtension = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension.lowercased()
        let destinationAudioURL = paths.voicesDirectory
            .appendingPathComponent(name)
            .appendingPathExtension(audioExtension)
        let destinationTranscriptURL = paths.voicesDirectory
            .appendingPathComponent(name)
            .appendingPathExtension("txt")

        try fileManager.copyItem(at: sourceURL, to: destinationAudioURL)

        let trimmedTranscript = transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTranscript, !trimmedTranscript.isEmpty {
            try trimmedTranscript.write(to: destinationTranscriptURL, atomically: true, encoding: .utf8)
        }

        return try makePreparedVoice(fromAudioURL: destinationAudioURL)
    }

    public func deletePreparedVoice(id: String) throws {
        let audioURL = try existingPreparedVoiceAudioURL(for: id)
        guard let audioURL else {
            throw RuntimeError.preparedVoiceNotFound(id)
        }

        let transcriptURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        try fileManager.removeItem(at: audioURL)
        if fileManager.fileExists(atPath: transcriptURL.path) {
            try fileManager.removeItem(at: transcriptURL)
        }
    }

    private func requirePaths() throws -> Paths {
        guard let initializedPaths else {
            throw RuntimeError.notInitialized
        }
        return initializedPaths
    }

    private func requireRegistry() throws -> NativeModelRegistry {
        if let modelRegistry {
            return modelRegistry
        }

        let registry = try registryFactory()
        modelRegistry = registry
        return registry
    }

    private func createDirectoryTree(for paths: Paths) throws {
        let directories = [
            paths.appSupportDirectory,
            paths.modelsDirectory,
            paths.downloadsStagingDirectory,
            paths.nativeMLXCacheDirectory,
            paths.preparedAudioCacheDirectory,
            paths.normalizedCloneReferencesDirectory,
            paths.streamSessionsDirectory,
            paths.outputsDirectory,
            paths.voicesDirectory,
        ]

        for directory in directories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func prepareWarmState(
        for request: GenerationRequest,
        using model: NativeSpeechGenerationModel
    ) async throws {
        switch request.payload {
        case .custom(let speakerID, let deliveryStyle):
            try await model.prepareCustomVoice(
                text: request.text,
                language: GenerationSemantics.qwenLanguageHint(for: request),
                speaker: speakerID.trimmingCharacters(in: .whitespacesAndNewlines),
                instruct: GenerationSemantics.customInstruction(deliveryStyle: deliveryStyle)
            )
        case .design, .clone:
            return
        }
    }

    private func ensureDesignConditioningWarmStateIfNeeded(
        for request: GenerationRequest,
        using model: NativeSpeechGenerationModel,
        source: DesignWarmSource
    ) async throws -> DesignConditioningWarmState {
        guard case .design(let voiceDescription, let deliveryStyle) = request.payload else {
            return DesignConditioningWarmState(
                bucket: .short,
                requestKey: "",
                reused: false,
                prefetchHit: false,
                prewarmed: false,
                streamStepPrewarmed: false
            )
        }

        let warmBucket = GenerationSemantics.designWarmBucket(for: request.text)
        let trimmedVoiceDescription = voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVoiceDescription.isEmpty,
              let conditioningWarmKey = GenerationSemantics.designConditioningWarmKey(for: request) else {
            return DesignConditioningWarmState(
                bucket: warmBucket,
                requestKey: "",
                reused: false,
                prefetchHit: false,
                prewarmed: false,
                streamStepPrewarmed: false
            )
        }

        let reused = activeDesignConditioningWarmKey == conditioningWarmKey
        if reused {
            return DesignConditioningWarmState(
                bucket: warmBucket,
                requestKey: conditioningWarmKey,
                reused: true,
                prefetchHit: activeDesignConditioningWarmSource == .prefetch,
                prewarmed: false,
                streamStepPrewarmed: activeDesignStreamStepWarmKey == conditioningWarmKey
            )
        }

        let language = GenerationSemantics.qwenLanguageHint(for: request)
        let warmInstruction = GenerationSemantics.designInstruction(
            voiceDescription: voiceDescription,
            emotion: deliveryStyle ?? ""
        )
        let warmText = GenerationSemantics.canonicalDesignWarmText(for: warmBucket)
        try await model.prepareVoiceDesign(
            text: warmText,
            language: language,
            voiceDescription: warmInstruction
        )

        activeDesignConditioningWarmKey = conditioningWarmKey
        activeDesignConditioningWarmSource = source
        if model.latestPreparationBooleanFlags["design_stream_step_prewarmed"] == true {
            activeDesignStreamStepWarmKey = conditioningWarmKey
        } else {
            activeDesignStreamStepWarmKey = nil
        }

        return DesignConditioningWarmState(
            bucket: warmBucket,
            requestKey: conditioningWarmKey,
            reused: false,
            prefetchHit: false,
            prewarmed: true,
            streamStepPrewarmed: activeDesignStreamStepWarmKey == conditioningWarmKey
        )
    }

    private func mergedBooleanFlags(
        for model: NativeSpeechGenerationModel,
        warmState: EngineWarmState
    ) -> [String: Bool] {
        var flags = model.latestPreparationBooleanFlags
        flags["custom_dedicated_handler_used"] = model.supportsDedicatedCustomVoice
        flags["warm_state_warm"] = warmState == .warm
        flags["warm_state_cold"] = warmState == .cold
        return flags
    }

    private func clearDesignWarmState() {
        activeDesignConditioningWarmKey = nil
        activeDesignConditioningWarmSource = nil
        activeDesignStreamStepWarmKey = nil
    }

    private func requireLoadedModel(expectedModelID: String) async throws -> NativeSpeechGenerationModel {
        guard await loadCoordinator.currentLoadedModelID() == expectedModelID,
              let loadedModel else {
            throw RuntimeError.noLoadedModel(expectedModelID)
        }
        return loadedModel
    }

    private func takeNextRequestID() -> Int {
        let requestID = nextRequestID
        nextRequestID += 1
        return requestID
    }

    private func validateAndLoadModel(
        modelID: String,
        registry: NativeModelRegistry,
        modelsDirectory: URL
    ) async throws {
        switch registry.availability(
            forModelID: modelID,
            in: modelsDirectory,
            fileManager: fileManager
        ) {
        case .unknown:
            throw RuntimeError.unknownModel(modelID)
        case .unavailable(_, let missingRequiredPaths):
            throw RuntimeError.modelUnavailable(id: modelID, missingRequiredPaths: missingRequiredPaths)
        case .available(let descriptor):
            let installDirectory = registry.installDirectory(for: descriptor, in: modelsDirectory)
            loadedModel = nil
            clearDesignWarmState()
            try await loadOperation(descriptor)
            loadedModel = try await modelLoader(descriptor, installDirectory)
        }
    }

    private func existingPreparedVoiceAudioURL(for id: String) throws -> URL? {
        let voicesDirectory = try requirePaths().voicesDirectory
        let urls = try fileManager.contentsOfDirectory(
            at: voicesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return urls.first { url in
            url.deletingPathExtension().lastPathComponent == id
                && url.pathExtension.lowercased() != "txt"
        }
    }

    private func makePreparedVoice(fromAudioURL audioURL: URL) throws -> PreparedVoice {
        let id = audioURL.deletingPathExtension().lastPathComponent
        let transcriptURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        return PreparedVoice(
            id: id,
            name: id,
            audioPath: audioURL.path,
            hasTranscript: fileManager.fileExists(atPath: transcriptURL.path)
        )
    }

    private static func defaultModelLoader(
        descriptor: NativeModelDescriptor,
        installDirectory: URL
    ) async throws -> NativeSpeechGenerationModel {
        NativeSpeechGenerationModel(
            base: try await TTS.loadModel(
                fromPreparedDirectory: installDirectory,
                modelRepo: descriptor.huggingFaceRepo,
                modelType: "qwen3_tts"
            )
        )
    }
}
