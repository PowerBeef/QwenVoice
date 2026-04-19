import Foundation
@preconcurrency import MLX
@preconcurrency import MLXAudioCore
@preconcurrency import MLXAudioTTS
import CoreFoundation
import CryptoKit

struct NativeModelLoadResult: Sendable {
    let model: UnsafeSpeechGenerationModel
    let didLoad: Bool
    let timingsMS: [String: Int]
    let booleanFlags: [String: Bool]
}

protocol MLXModelCoordinating: AnyObject, Sendable {
    func loadModel(id: String) async throws -> NativeModelLoadResult
    func unloadModel() async
    func isPrewarmed(identityKey: String) async -> Bool
    func markPrewarmed(identityKey: String) async
    func clearPrewarmState() async
}

actor MLXModelLoadCoordinator: MLXModelCoordinating {
    typealias NativeModelLoader = @Sendable (ModelAssetDescriptor, PreparedModelMetadata) async throws -> UnsafeSpeechGenerationModel
    fileprivate struct PreparedCacheMarker: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let descriptorVersion: String
        let sanitizedConfigHash: String?
        let qwenPreparedCheckpointTrust: QwenPreparedCheckpointTrust?

        func matchesBase(_ other: PreparedCacheMarker) -> Bool {
            schemaVersion == other.schemaVersion
                && descriptorVersion == other.descriptorVersion
                && sanitizedConfigHash == other.sanitizedConfigHash
        }
    }

    private struct PreparedCacheInputs: Sendable {
        let sanitizedTopLevelConfigData: Data?
        let marker: PreparedCacheMarker
        let qwenPreparedCheckpointQuickState: QuickQwenPreparedCheckpointTrust?
    }

    private struct PreparedCacheResult: Sendable {
        let metadata: PreparedModelMetadata
        let reusedPreparedCache: Bool
        let rebuiltPreparedCache: Bool
        let performedTokenizerPreparation: Bool
        let usedPreparedOverlay: Bool
    }

    private struct PreparedCacheValidationResult: Sendable {
        let isValid: Bool
        let marker: PreparedCacheMarker?
    }

    fileprivate struct PreparedArtifactTrust: Codable, Equatable, Sendable {
        let relativePath: String
        let fileSize: UInt64
        let contentModificationTimeIntervalSince1970: TimeInterval?
        let contentDigest: String

        fileprivate func matchesQuickly(_ quickState: QuickPreparedArtifactTrust) -> Bool {
            relativePath == quickState.relativePath
                && fileSize == quickState.fileSize
                && contentModificationTimeIntervalSince1970 == quickState.contentModificationTimeIntervalSince1970
        }
    }

    fileprivate struct QwenPreparedCheckpointTrust: Codable, Equatable, Sendable {
        let topLevelConfigHash: String?
        let speechTokenizerConfigHash: String?
        let modelArtifact: PreparedArtifactTrust
        let speechTokenizerModelArtifact: PreparedArtifactTrust

        fileprivate func matchesQuickly(_ quickState: QuickQwenPreparedCheckpointTrust) -> Bool {
            topLevelConfigHash == quickState.topLevelConfigHash
                && speechTokenizerConfigHash == quickState.speechTokenizerConfigHash
                && modelArtifact.matchesQuickly(quickState.modelArtifact)
                && speechTokenizerModelArtifact.matchesQuickly(quickState.speechTokenizerModelArtifact)
        }
    }

    fileprivate struct QuickPreparedArtifactTrust: Sendable {
        let relativePath: String
        let fileSize: UInt64
        let contentModificationTimeIntervalSince1970: TimeInterval?
    }

    fileprivate struct QuickQwenPreparedCheckpointTrust: Sendable {
        let topLevelConfigHash: String?
        let speechTokenizerConfigHash: String?
        let modelArtifact: QuickPreparedArtifactTrust
        let speechTokenizerModelArtifact: QuickPreparedArtifactTrust
    }

    struct PreparedModelMetadata: Sendable {
        let preparedDirectory: URL
        let sourceDirectory: URL?
        let modelType: String?
        let trustedPreparedCheckpoint: Bool
        private let marker: PreparedCacheMarker
        private let qwenPreparedCheckpointTrustToPersist: QwenPreparedCheckpointTrust?

        fileprivate init(
            preparedDirectory: URL,
            sourceDirectory: URL? = nil,
            modelType: String?,
            marker: PreparedCacheMarker,
            trustedPreparedCheckpoint: Bool,
            qwenPreparedCheckpointTrustToPersist: QwenPreparedCheckpointTrust? = nil
        ) {
            self.preparedDirectory = preparedDirectory
            self.sourceDirectory = sourceDirectory
            self.modelType = modelType
            self.trustedPreparedCheckpoint = trustedPreparedCheckpoint
            self.marker = marker
            self.qwenPreparedCheckpointTrustToPersist = qwenPreparedCheckpointTrustToPersist
        }

        fileprivate func matches(marker: PreparedCacheMarker) -> Bool {
            self.marker.matchesBase(marker)
        }

        fileprivate func trustingPreparedCheckpoint() -> PreparedModelMetadata {
            guard let trustMarker = qwenPreparedCheckpointTrustToPersist else {
                return self
            }
            return PreparedModelMetadata(
                preparedDirectory: preparedDirectory,
                sourceDirectory: sourceDirectory,
                modelType: modelType,
                marker: PreparedCacheMarker(
                    schemaVersion: marker.schemaVersion,
                    descriptorVersion: marker.descriptorVersion,
                    sanitizedConfigHash: marker.sanitizedConfigHash,
                    qwenPreparedCheckpointTrust: trustMarker
                ),
                trustedPreparedCheckpoint: true
            )
        }

        fileprivate var markerToPersistAfterSuccessfulLoad: PreparedCacheMarker? {
            guard let trustMarker = qwenPreparedCheckpointTrustToPersist else {
                return nil
            }
            return PreparedCacheMarker(
                schemaVersion: marker.schemaVersion,
                descriptorVersion: marker.descriptorVersion,
                sanitizedConfigHash: marker.sanitizedConfigHash,
                qwenPreparedCheckpointTrust: trustMarker
            )
        }

        fileprivate var baseMarker: PreparedCacheMarker {
            marker
        }
    }

    private static let preparedCacheMarkerFileName = ".qvoice_prepared_cache.json"
    private static let qwenSourceCheckpointTrustFileName = ".qvoice_qwen_checkpoint_trust.json"
    private static let qwenPreparedOverlayDirectoryName = ".qvoice_prepared_model"
    private static let preparedCacheSchemaVersion = 2
    private static let qwenModelWeightsRelativePath = "model.safetensors"
    private static let qwenSpeechTokenizerConfigRelativePath = "speech_tokenizer/config.json"
    private static let qwenSpeechTokenizerModelRelativePath = "speech_tokenizer/model.safetensors"

    private let modelAssetStore: any ModelAssetStore
    private let hubCacheDirectory: URL
    private let fileManager: FileManager
    private let modelLoader: NativeModelLoader
    private let beforeModelLoad: (@Sendable (String?) -> Void)?
    private let telemetryRecorder: NativeTelemetryRecorder?
    private let diagnosticEventSink: (@Sendable (String, [String: String]) async -> Void)?
    private var preparedMetadataByDescriptorID: [String: PreparedModelMetadata] = [:]

    private static let prewarmKeysFileName = ".qvoice_prewarm_keys.json"

    private(set) var loadedDescriptor: ModelAssetDescriptor?
    private(set) var loadedModel: UnsafeSpeechGenerationModel?
    private(set) var prewarmedIdentityKeys: Set<String> = []

    init(
        modelAssetStore: any ModelAssetStore,
        hubCacheDirectory: URL,
        fileManager: FileManager = .default,
        modelLoader: @escaping NativeModelLoader = MLXModelLoadCoordinator.defaultModelLoader,
        beforeModelLoad: (@Sendable (String?) -> Void)? = nil,
        telemetryRecorder: NativeTelemetryRecorder? = nil,
        diagnosticEventSink: (@Sendable (String, [String: String]) async -> Void)? = nil
    ) {
        self.modelAssetStore = modelAssetStore
        self.hubCacheDirectory = hubCacheDirectory
        self.fileManager = fileManager
        self.modelLoader = modelLoader
        self.beforeModelLoad = beforeModelLoad
        self.telemetryRecorder = telemetryRecorder
        self.diagnosticEventSink = diagnosticEventSink
    }

    func loadModel(id: String) async throws -> NativeModelLoadResult {
        if let loadedDescriptor,
           loadedDescriptor.id == id,
           let loadedModel {
            return NativeModelLoadResult(
                model: loadedModel,
                didLoad: false,
                timingsMS: [:],
                booleanFlags: [:]
            )
        }

        let descriptor = try descriptor(for: id)
        let state = modelAssetStore.state(for: descriptor)
        guard case .available = state else {
            throw MLXTTSEngineError.modelUnavailable(
                "Model '\(descriptor.name)' is unavailable or incomplete."
            )
        }

        if loadedDescriptor != nil {
            resetLoadedState()
        }

        beforeModelLoad?(loadedDescriptor?.id)
        let cachePrepareStartedAt = ContinuousClock.now
        let preparedCacheResult: PreparedCacheResult
        do {
            await emitDiagnostic(
                "coordinator-load-before-prepare-local-cache",
                details: diagnosticDetails(for: descriptor)
            )
            await telemetryRecorder?.mark(stage: .preparedCacheValidation)
            preparedCacheResult = try prepareLocalCache(for: descriptor)
            await emitDiagnostic(
                "coordinator-load-after-prepare-local-cache",
                details: diagnosticDetails(
                    for: descriptor,
                    extra: [
                        "modelType": preparedCacheResult.metadata.modelType ?? "",
                        "preparedDirectory": preparedCacheResult.metadata.preparedDirectory.path,
                        "sourceDirectory": preparedCacheResult.metadata.sourceDirectory?.path ?? "",
                        "trustedPreparedCheckpoint": preparedCacheResult.metadata.trustedPreparedCheckpoint ? "true" : "false",
                        "reusedPreparedCache": preparedCacheResult.reusedPreparedCache ? "true" : "false",
                        "rebuiltPreparedCache": preparedCacheResult.rebuiltPreparedCache ? "true" : "false",
                        "performedTokenizerPreparation": preparedCacheResult.performedTokenizerPreparation ? "true" : "false",
                        "usedPreparedOverlay": preparedCacheResult.usedPreparedOverlay ? "true" : "false",
                    ]
                )
            )
        } catch {
            resetLoadedState()
            throw NativeRuntimeError.wrapping(
                error,
                stage: .preparedCacheRebuild,
                message: "Failed to prepare the native model cache for '\(descriptor.name)'"
            )
        }
        let cachePrepareMS = cachePrepareStartedAt.elapsedMilliseconds
        if preparedCacheResult.rebuiltPreparedCache {
            await telemetryRecorder?.mark(stage: .preparedCacheRebuild)
        }
        if preparedCacheResult.performedTokenizerPreparation {
            await telemetryRecorder?.mark(stage: .tokenizerPreparation)
        }

        let modelLoadStartedAt = ContinuousClock.now
        let model: UnsafeSpeechGenerationModel
        do {
            await emitDiagnostic(
                "coordinator-load-before-model-loader",
                details: diagnosticDetails(
                    for: descriptor,
                    extra: [
                        "modelType": preparedCacheResult.metadata.modelType ?? "",
                        "preparedDirectory": preparedCacheResult.metadata.preparedDirectory.path,
                        "trustedPreparedCheckpoint": preparedCacheResult.metadata.trustedPreparedCheckpoint ? "true" : "false",
                    ]
                )
            )
            await telemetryRecorder?.mark(stage: .upstreamModelLoad)
            model = try await modelLoader(descriptor, preparedCacheResult.metadata)
            await emitDiagnostic(
                "coordinator-load-after-model-loader",
                details: diagnosticDetails(
                    for: descriptor,
                    extra: [
                        "modelType": preparedCacheResult.metadata.modelType ?? "",
                        "preparedDirectory": preparedCacheResult.metadata.preparedDirectory.path,
                        "trustedPreparedCheckpoint": preparedCacheResult.metadata.trustedPreparedCheckpoint ? "true" : "false",
                    ]
                )
            )
        } catch {
            resetLoadedState()
            throw NativeRuntimeError.wrapping(
                error,
                stage: .upstreamModelLoad,
                message: "Failed to load native model '\(descriptor.name)'"
            )
        }
        let modelLoadMS = modelLoadStartedAt.elapsedMilliseconds
        var timingsMS = model.loadDiagnosticsTimingsMS
        timingsMS["cache_prepare"] = cachePrepareMS
        timingsMS["mlx_model_load"] = modelLoadMS

        loadedDescriptor = descriptor
        loadedModel = model
        prewarmedIdentityKeys.removeAll()
        restorePrewarmKeys(for: descriptor)
        var booleanFlags = model.loadDiagnosticBooleanFlags
        booleanFlags["prepared_model_cache_hit"] = preparedCacheResult.reusedPreparedCache
        booleanFlags["prepared_overlay_cache_hit"] = preparedCacheResult.usedPreparedOverlay
            && preparedCacheResult.reusedPreparedCache
        booleanFlags["prepared_overlay_rebuilt"] = preparedCacheResult.usedPreparedOverlay
            && preparedCacheResult.rebuiltPreparedCache

        await emitDiagnostic(
            "coordinator-load-before-persist-trusted-marker",
            details: diagnosticDetails(
                for: descriptor,
                extra: [
                    "modelType": preparedCacheResult.metadata.modelType ?? "",
                    "preparedDirectory": preparedCacheResult.metadata.preparedDirectory.path,
                    "trustedPreparedCheckpoint": preparedCacheResult.metadata.trustedPreparedCheckpoint ? "true" : "false",
                ]
            )
        )
        if let persistedMetadata = persistTrustedPreparedCheckpointMarkerIfNeeded(
            for: descriptor,
            metadata: preparedCacheResult.metadata
        ) {
            preparedMetadataByDescriptorID[descriptor.id] = persistedMetadata
        }

        await emitDiagnostic(
            "coordinator-load-before-return",
            details: diagnosticDetails(
                for: descriptor,
                extra: [
                    "didLoad": "true",
                    "modelType": preparedCacheResult.metadata.modelType ?? "",
                    "preparedDirectory": preparedCacheResult.metadata.preparedDirectory.path,
                    "trustedPreparedCheckpoint": preparedCacheResult.metadata.trustedPreparedCheckpoint ? "true" : "false",
                ]
            )
        )

        return NativeModelLoadResult(
            model: model,
            didLoad: true,
            timingsMS: timingsMS,
            booleanFlags: booleanFlags
        )
    }

    func unloadModel() async {
        resetLoadedState()
    }

    func isPrewarmed(identityKey: String) async -> Bool {
        prewarmedIdentityKeys.contains(identityKey)
    }

    func markPrewarmed(identityKey: String) async {
        prewarmedIdentityKeys.insert(identityKey)
        persistPrewarmKeys()
    }

    func clearPrewarmState() async {
        prewarmedIdentityKeys.removeAll()
        guard let descriptor = loadedDescriptor else { return }
        let root = modelAssetStore.localRoot(for: descriptor)
        let url = root.appendingPathComponent(Self.prewarmKeysFileName)
        try? fileManager.removeItem(at: url)
    }

    // MARK: - Prewarm Key Persistence

    private func persistPrewarmKeys() {
        guard let descriptor = loadedDescriptor else { return }
        let root = modelAssetStore.localRoot(for: descriptor)
        let url = root.appendingPathComponent(Self.prewarmKeysFileName)
        let keys = Array(prewarmedIdentityKeys)
        guard let data = try? JSONEncoder().encode(keys) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func restorePrewarmKeys(for descriptor: ModelAssetDescriptor) {
        let root = modelAssetStore.localRoot(for: descriptor)
        let url = root.appendingPathComponent(Self.prewarmKeysFileName)
        guard let data = try? Data(contentsOf: url),
              let keys = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        prewarmedIdentityKeys = Set(keys)
    }

    private func resetLoadedState() {
        loadedDescriptor = nil
        loadedModel = nil
        prewarmedIdentityKeys.removeAll()
        Memory.clearCache()
    }

    private func descriptor(for id: String) throws -> ModelAssetDescriptor {
        guard let descriptor = modelAssetStore.descriptor(id: id) else {
            throw MLXTTSEngineError.unknownModel(id)
        }
        return descriptor
    }

    private func prepareLocalCache(for descriptor: ModelAssetDescriptor) throws -> PreparedCacheResult {
        let sourceDirectory = modelAssetStore.localRoot(for: descriptor)
        let preparedInputs = try Self.preparedCacheInputs(
            for: descriptor,
            sourceDirectory: sourceDirectory
        )
        let modelType = Self.preparedModelType(from: preparedInputs.sanitizedTopLevelConfigData)
        let additionalArtifacts = Self.additionalPreparedArtifacts(for: modelType)
        let usePreparedOverlay = Self.normalizedModelType(modelType) == "qwen3_tts"
        let targetDirectory: URL
        if usePreparedOverlay {
            targetDirectory = sourceDirectory.appendingPathComponent(
                Self.qwenPreparedOverlayDirectoryName,
                isDirectory: true
            )
        } else {
            targetDirectory = hubCacheDirectory
                .appendingPathComponent("mlx-audio", isDirectory: true)
                .appendingPathComponent(
                    descriptor.model.huggingFaceRepo.replacingOccurrences(of: "/", with: "_"),
                    isDirectory: true
                )
            try fileManager.createDirectory(
                at: targetDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        let cacheValidation = try Self.preparedCacheIsValid(
            at: targetDirectory,
            descriptor: descriptor,
            fileManager: fileManager,
            expectedMarker: preparedInputs.marker,
            additionalRequiredRelativePaths: additionalArtifacts
        )
        let qwenTrustEvaluation = try Self.evaluateQwenPreparedCheckpointTrust(
            storedMarker: cacheValidation.marker,
            sourceDirectory: sourceDirectory,
            modelType: modelType,
            qwenPreparedCheckpointQuickState: preparedInputs.qwenPreparedCheckpointQuickState
        )
        if cacheValidation.isValid,
           let cachedMetadata = preparedMetadataByDescriptorID[descriptor.id],
           cachedMetadata.matches(marker: preparedInputs.marker),
           cachedMetadata.trustedPreparedCheckpoint == qwenTrustEvaluation.trustedPreparedCheckpoint,
           qwenTrustEvaluation.qwenPreparedCheckpointTrustToPersist == nil {
            return PreparedCacheResult(
                metadata: cachedMetadata,
                reusedPreparedCache: true,
                rebuiltPreparedCache: false,
                performedTokenizerPreparation: false,
                usedPreparedOverlay: usePreparedOverlay
            )
        }
        if cacheValidation.isValid {
            let metadata = PreparedModelMetadata(
                preparedDirectory: targetDirectory,
                sourceDirectory: sourceDirectory,
                modelType: modelType,
                marker: PreparedCacheMarker(
                    schemaVersion: preparedInputs.marker.schemaVersion,
                    descriptorVersion: preparedInputs.marker.descriptorVersion,
                    sanitizedConfigHash: preparedInputs.marker.sanitizedConfigHash,
                    qwenPreparedCheckpointTrust: cacheValidation.marker?.qwenPreparedCheckpointTrust
                ),
                trustedPreparedCheckpoint: qwenTrustEvaluation.trustedPreparedCheckpoint,
                qwenPreparedCheckpointTrustToPersist: qwenTrustEvaluation.qwenPreparedCheckpointTrustToPersist
            )
            preparedMetadataByDescriptorID[descriptor.id] = metadata
            return PreparedCacheResult(
                metadata: metadata,
                reusedPreparedCache: true,
                rebuiltPreparedCache: false,
                performedTokenizerPreparation: false,
                usedPreparedOverlay: usePreparedOverlay
            )
        }

        let temporaryDirectory = targetDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("\(targetDirectory.lastPathComponent).tmp.\(UUID().uuidString)", isDirectory: true)
        if fileManager.fileExists(atPath: temporaryDirectory.path) {
            try? fileManager.removeItem(at: temporaryDirectory)
        }
        defer {
            if fileManager.fileExists(atPath: temporaryDirectory.path) {
                try? fileManager.removeItem(at: temporaryDirectory)
            }
        }

        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )

        try Self.mirrorDirectoryContents(
            from: sourceDirectory,
            to: temporaryDirectory,
            fileManager: fileManager,
            sanitizedTopLevelConfigData: preparedInputs.sanitizedTopLevelConfigData
        )
        try Self.preparePreparedDirectoryArtifacts(
            at: temporaryDirectory,
            modelRepo: descriptor.model.huggingFaceRepo,
            modelType: modelType,
            fileManager: fileManager
        )
        let rebuiltMarker: PreparedCacheMarker
        if let trustMarker = qwenTrustEvaluation.qwenPreparedCheckpointTrustToPersist {
            rebuiltMarker = PreparedCacheMarker(
                schemaVersion: preparedInputs.marker.schemaVersion,
                descriptorVersion: preparedInputs.marker.descriptorVersion,
                sanitizedConfigHash: preparedInputs.marker.sanitizedConfigHash,
                qwenPreparedCheckpointTrust: trustMarker
            )
        } else {
            rebuiltMarker = preparedInputs.marker
        }
        try Self.writePreparedCacheMarker(
            rebuiltMarker,
            to: temporaryDirectory.appendingPathComponent(Self.preparedCacheMarkerFileName)
        )

        if fileManager.fileExists(atPath: targetDirectory.path) {
            _ = try fileManager.replaceItemAt(
                targetDirectory,
                withItemAt: temporaryDirectory,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporaryDirectory, to: targetDirectory)
        }

        let metadata = PreparedModelMetadata(
            preparedDirectory: targetDirectory,
            sourceDirectory: sourceDirectory,
            modelType: modelType,
            marker: rebuiltMarker,
            trustedPreparedCheckpoint: qwenTrustEvaluation.qwenPreparedCheckpointTrustToPersist != nil,
            qwenPreparedCheckpointTrustToPersist: nil
        )
        preparedMetadataByDescriptorID[descriptor.id] = metadata
        return PreparedCacheResult(
            metadata: metadata,
            reusedPreparedCache: false,
            rebuiltPreparedCache: true,
            performedTokenizerPreparation: true,
            usedPreparedOverlay: usePreparedOverlay
        )
    }

    private static func defaultModelLoader(
        descriptor: ModelAssetDescriptor,
        preparedMetadata: PreparedModelMetadata
    ) async throws -> UnsafeSpeechGenerationModel {
        UnsafeSpeechGenerationModel(
            base: try await TTS.loadModel(
                fromPreparedDirectory: preparedMetadata.preparedDirectory,
                modelRepo: descriptor.model.huggingFaceRepo,
                modelType: preparedMetadata.modelType,
                trustPreparedCheckpoint: preparedMetadata.trustedPreparedCheckpoint
            )
        )
    }

    private func diagnosticDetails(
        for descriptor: ModelAssetDescriptor,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var details: [String: String] = [
            "descriptorID": descriptor.id,
            "descriptorVersion": descriptor.version,
            "modelRepo": descriptor.model.huggingFaceRepo,
            "modelFolder": descriptor.model.folder,
            "modelName": descriptor.name,
        ]

        for (key, value) in extra {
            details[key] = value
        }
        return details
    }

    private func emitDiagnostic(
        _ action: String,
        details: [String: String]
    ) async {
        guard let diagnosticEventSink else {
            return
        }
        await diagnosticEventSink(action, details)
    }

    private static func sanitizedTopLevelConfigData(from configURL: URL) throws -> Data {
        let data = try Data(contentsOf: configURL)
        guard var jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeRuntimeError(
                stage: .preparedCacheValidation,
                message: "The native model config at '\(configURL.path)' is not a JSON object."
            )
        }

        if var talkerConfig = jsonObject["talker_config"] as? [String: Any] {
            if let speakerIDs = talkerConfig["spk_id"] {
                let normalizedSpeakerIDs = normalizedSpeakerIDMap(from: speakerIDs)
                if normalizedSpeakerIDs.isEmpty {
                    talkerConfig.removeValue(forKey: "spk_id")
                } else {
                    talkerConfig["spk_id"] = normalizedSpeakerIDs
                }
            }

            if let dialects = talkerConfig["spk_is_dialect"] {
                let normalizedDialects = normalizedSpeakerDialectMap(from: dialects)
                if normalizedDialects.isEmpty {
                    talkerConfig.removeValue(forKey: "spk_is_dialect")
                } else {
                    talkerConfig["spk_is_dialect"] = normalizedDialects
                }
            }

            jsonObject["talker_config"] = talkerConfig
        }

        return try JSONSerialization.data(
            withJSONObject: jsonObject,
            options: [.sortedKeys]
        )
    }

    private static func preparedCacheInputs(
        for descriptor: ModelAssetDescriptor,
        sourceDirectory: URL
    ) throws -> PreparedCacheInputs {
        let configURL = sourceDirectory.appendingPathComponent("config.json")
        let sanitizedConfigData: Data?
        if FileManager.default.fileExists(atPath: configURL.path) {
            do {
                sanitizedConfigData = try sanitizedTopLevelConfigData(from: configURL)
            } catch {
                throw NativeRuntimeError.wrapping(
                    error,
                    stage: .preparedCacheValidation,
                    message: "The native runtime could not validate model metadata for '\(descriptor.name)'"
                )
            }
        } else {
            sanitizedConfigData = nil
        }

        let sanitizedConfigHash = sanitizedConfigData.map(Self.sha256Hex(data:))
        return PreparedCacheInputs(
            sanitizedTopLevelConfigData: sanitizedConfigData,
            marker: PreparedCacheMarker(
                schemaVersion: preparedCacheSchemaVersion,
                descriptorVersion: descriptor.version,
                sanitizedConfigHash: sanitizedConfigHash,
                qwenPreparedCheckpointTrust: nil
            ),
            qwenPreparedCheckpointQuickState: try makeQwenPreparedCheckpointQuickState(
                at: sourceDirectory,
                modelType: preparedModelType(from: sanitizedConfigData),
                topLevelConfigHash: sanitizedConfigHash
            )
        )
    }

    private static func preparedCacheIsValid(
        at targetDirectory: URL,
        descriptor: ModelAssetDescriptor,
        fileManager: FileManager,
        expectedMarker: PreparedCacheMarker,
        additionalRequiredRelativePaths: [String]
    ) throws -> PreparedCacheValidationResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: targetDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return PreparedCacheValidationResult(isValid: false, marker: nil)
        }

        let markerURL = targetDirectory.appendingPathComponent(preparedCacheMarkerFileName)
        guard let marker = readPreparedCacheMarker(at: markerURL),
              marker.matchesBase(expectedMarker) else {
            return PreparedCacheValidationResult(isValid: false, marker: nil)
        }

        let requiredRelativePaths = descriptor.artifacts.map(\.relativePath) + additionalRequiredRelativePaths
        let isValid = requiredRelativePaths.allSatisfy { relativePath in
            let artifactURL = targetDirectory.appendingPathComponent(relativePath)
            return fileManager.fileExists(atPath: artifactURL.path)
        }
        return PreparedCacheValidationResult(isValid: isValid, marker: isValid ? marker : nil)
    }

    private static func additionalPreparedArtifacts(for modelType: String?) -> [String] {
        guard normalizedModelType(modelType) == "qwen3_tts" else {
            return []
        }
        return ["tokenizer.json"]
    }

    private static func preparePreparedDirectoryArtifacts(
        at targetDirectory: URL,
        modelRepo: String,
        modelType: String?,
        fileManager: FileManager
    ) throws {
        do {
            try TTS.preparePreparedDirectory(
                targetDirectory,
                modelRepo: modelRepo,
                modelType: modelType
            )
        } catch {
            throw NativeRuntimeError.wrapping(
                error,
                stage: .tokenizerPreparation,
                message: "The native runtime could not prepare tokenizer artifacts"
            )
        }

        for relativePath in additionalPreparedArtifacts(for: modelType) {
            let artifactURL = targetDirectory.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: artifactURL.path) else {
                throw NativeRuntimeError(
                    stage: .tokenizerPreparation,
                    message: "The prepared native model cache is missing required artifact '\(relativePath)'."
                )
            }
        }
    }

    private static func writePreparedCacheMarker(
        _ marker: PreparedCacheMarker,
        to markerURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(marker)
        try data.write(to: markerURL, options: .atomic)
    }

    private func persistTrustedPreparedCheckpointMarkerIfNeeded(
        for descriptor: ModelAssetDescriptor,
        metadata: PreparedModelMetadata
    ) -> PreparedModelMetadata? {
        let marker: PreparedCacheMarker
        if let markerToPersist = metadata.markerToPersistAfterSuccessfulLoad {
            marker = markerToPersist
        } else if let sourceDirectory = metadata.sourceDirectory,
                  let preparedInputs = try? Self.preparedCacheInputs(
                      for: descriptor,
                      sourceDirectory: sourceDirectory
                  ),
                  let trustMarker = try? Self.resolveSourceQwenPreparedCheckpointTrustForPersistence(
                      at: sourceDirectory,
                      modelType: metadata.modelType,
                      qwenPreparedCheckpointQuickState: preparedInputs.qwenPreparedCheckpointQuickState
                  ) {
            marker = PreparedCacheMarker(
                schemaVersion: metadata.baseMarker.schemaVersion,
                descriptorVersion: metadata.baseMarker.descriptorVersion,
                sanitizedConfigHash: metadata.baseMarker.sanitizedConfigHash,
                qwenPreparedCheckpointTrust: trustMarker
            )
        } else {
            return nil
        }

        let markerURL = metadata.preparedDirectory
            .appendingPathComponent(Self.preparedCacheMarkerFileName)
        do {
            try Self.writePreparedCacheMarker(marker, to: markerURL)
            return metadata.trustingPreparedCheckpoint()
        } catch {
            return nil
        }
    }

    private struct QwenPreparedCheckpointTrustEvaluation: Sendable {
        let trustedPreparedCheckpoint: Bool
        let qwenPreparedCheckpointTrustToPersist: QwenPreparedCheckpointTrust?
    }

    private static func evaluateQwenPreparedCheckpointTrust(
        storedMarker: PreparedCacheMarker?,
        sourceDirectory: URL,
        modelType: String?,
        qwenPreparedCheckpointQuickState: QuickQwenPreparedCheckpointTrust?
    ) throws -> QwenPreparedCheckpointTrustEvaluation {
        guard normalizedModelType(modelType) == "qwen3_tts" else {
            return QwenPreparedCheckpointTrustEvaluation(
                trustedPreparedCheckpoint: false,
                qwenPreparedCheckpointTrustToPersist: nil
            )
        }

        guard let qwenPreparedCheckpointQuickState else {
            return QwenPreparedCheckpointTrustEvaluation(
                trustedPreparedCheckpoint: false,
                qwenPreparedCheckpointTrustToPersist: nil
            )
        }

        if let storedTrust = storedMarker?.qwenPreparedCheckpointTrust,
           storedTrust.matchesQuickly(qwenPreparedCheckpointQuickState) {
            return QwenPreparedCheckpointTrustEvaluation(
                trustedPreparedCheckpoint: true,
                qwenPreparedCheckpointTrustToPersist: nil
            )
        }

        if let storedTrust = storedMarker?.qwenPreparedCheckpointTrust {
            let currentTrust = try makeQwenPreparedCheckpointTrust(
                at: sourceDirectory,
                modelType: modelType,
                qwenPreparedCheckpointQuickState: qwenPreparedCheckpointQuickState
            )

            if let currentTrust,
               storedTrust == currentTrust {
                return QwenPreparedCheckpointTrustEvaluation(
                    trustedPreparedCheckpoint: true,
                    qwenPreparedCheckpointTrustToPersist: currentTrust
                )
            }

            return QwenPreparedCheckpointTrustEvaluation(
                trustedPreparedCheckpoint: false,
                qwenPreparedCheckpointTrustToPersist: currentTrust
            )
        }

        return QwenPreparedCheckpointTrustEvaluation(
            trustedPreparedCheckpoint: false,
            qwenPreparedCheckpointTrustToPersist: try readPersistedSourceQwenPreparedCheckpointTrust(
                at: sourceDirectory,
                modelType: modelType,
                qwenPreparedCheckpointQuickState: qwenPreparedCheckpointQuickState
            )
        )
    }

    private static func readPreparedCacheMarker(at markerURL: URL) -> PreparedCacheMarker? {
        guard let markerData = try? Data(contentsOf: markerURL) else {
            return nil
        }
        return try? JSONDecoder().decode(PreparedCacheMarker.self, from: markerData)
    }

    private static func readPersistedSourceQwenPreparedCheckpointTrust(
        at sourceDirectory: URL,
        modelType: String?,
        qwenPreparedCheckpointQuickState: QuickQwenPreparedCheckpointTrust?
    ) throws -> QwenPreparedCheckpointTrust? {
        guard normalizedModelType(modelType) == "qwen3_tts",
              let qwenPreparedCheckpointQuickState,
              let storedTrust = readSourceQwenPreparedCheckpointTrust(at: sourceDirectory) else {
            return nil
        }

        if storedTrust.matchesQuickly(qwenPreparedCheckpointQuickState) {
            return storedTrust
        }

        guard let currentTrust = try makeQwenPreparedCheckpointTrust(
            at: sourceDirectory,
            modelType: modelType,
            qwenPreparedCheckpointQuickState: qwenPreparedCheckpointQuickState
        ) else {
            return nil
        }

        if currentTrust != storedTrust {
            try? writeSourceQwenPreparedCheckpointTrust(currentTrust, at: sourceDirectory)
        }
        return currentTrust
    }

    private static func resolveSourceQwenPreparedCheckpointTrustForPersistence(
        at sourceDirectory: URL,
        modelType: String?,
        qwenPreparedCheckpointQuickState: QuickQwenPreparedCheckpointTrust?
    ) throws -> QwenPreparedCheckpointTrust? {
        if let persistedTrust = try readPersistedSourceQwenPreparedCheckpointTrust(
            at: sourceDirectory,
            modelType: modelType,
            qwenPreparedCheckpointQuickState: qwenPreparedCheckpointQuickState
        ) {
            return persistedTrust
        }

        guard let currentTrust = try makeQwenPreparedCheckpointTrust(
            at: sourceDirectory,
            modelType: modelType,
            qwenPreparedCheckpointQuickState: qwenPreparedCheckpointQuickState
        ) else {
            return nil
        }

        try? writeSourceQwenPreparedCheckpointTrust(currentTrust, at: sourceDirectory)
        return currentTrust
    }

    private static func readSourceQwenPreparedCheckpointTrust(
        at sourceDirectory: URL
    ) -> QwenPreparedCheckpointTrust? {
        let trustURL = sourceDirectory.appendingPathComponent(qwenSourceCheckpointTrustFileName)
        guard let markerData = try? Data(contentsOf: trustURL) else {
            return nil
        }
        return try? JSONDecoder().decode(QwenPreparedCheckpointTrust.self, from: markerData)
    }

    private static func writeSourceQwenPreparedCheckpointTrust(
        _ trust: QwenPreparedCheckpointTrust,
        at sourceDirectory: URL
    ) throws {
        let trustURL = sourceDirectory.appendingPathComponent(qwenSourceCheckpointTrustFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(trust)
        try data.write(to: trustURL, options: .atomic)
    }

    private static func makeQwenPreparedCheckpointQuickState(
        at sourceDirectory: URL,
        modelType: String?,
        topLevelConfigHash: String?
    ) throws -> QuickQwenPreparedCheckpointTrust? {
        guard normalizedModelType(modelType) == "qwen3_tts" else {
            return nil
        }

        guard let modelArtifact = try quickPreparedArtifactTrust(
            at: sourceDirectory,
            relativePath: qwenModelWeightsRelativePath
        ),
        let speechTokenizerModelArtifact = try quickPreparedArtifactTrust(
            at: sourceDirectory,
            relativePath: qwenSpeechTokenizerModelRelativePath
        ) else {
            return nil
        }

        return QuickQwenPreparedCheckpointTrust(
            topLevelConfigHash: topLevelConfigHash,
            speechTokenizerConfigHash: hashIfPresent(
                at: sourceDirectory.appendingPathComponent(qwenSpeechTokenizerConfigRelativePath)
            ),
            modelArtifact: modelArtifact,
            speechTokenizerModelArtifact: speechTokenizerModelArtifact
        )
    }

    private static func makeQwenPreparedCheckpointTrust(
        at sourceDirectory: URL,
        modelType: String?,
        qwenPreparedCheckpointQuickState: QuickQwenPreparedCheckpointTrust?
    ) throws -> QwenPreparedCheckpointTrust? {
        guard normalizedModelType(modelType) == "qwen3_tts",
              let qwenPreparedCheckpointQuickState else {
            return nil
        }

        guard let modelArtifact = try preparedArtifactTrust(
            at: sourceDirectory,
            quickState: qwenPreparedCheckpointQuickState.modelArtifact
        ),
        let speechTokenizerModelArtifact = try preparedArtifactTrust(
            at: sourceDirectory,
            quickState: qwenPreparedCheckpointQuickState.speechTokenizerModelArtifact
        ) else {
            return nil
        }

        return QwenPreparedCheckpointTrust(
            topLevelConfigHash: qwenPreparedCheckpointQuickState.topLevelConfigHash,
            speechTokenizerConfigHash: qwenPreparedCheckpointQuickState.speechTokenizerConfigHash,
            modelArtifact: modelArtifact,
            speechTokenizerModelArtifact: speechTokenizerModelArtifact
        )
    }

    private static func quickPreparedArtifactTrust(
        at rootDirectory: URL,
        relativePath: String
    ) throws -> QuickPreparedArtifactTrust? {
        let artifactURL = rootDirectory.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: artifactURL.path) else {
            return nil
        }
        let resourceValues = try artifactURL.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        )
        guard let fileSize = resourceValues.fileSize else {
            return nil
        }
        return QuickPreparedArtifactTrust(
            relativePath: relativePath,
            fileSize: UInt64(fileSize),
            contentModificationTimeIntervalSince1970: resourceValues.contentModificationDate?.timeIntervalSince1970
        )
    }

    private static func preparedArtifactTrust(
        at rootDirectory: URL,
        quickState: QuickPreparedArtifactTrust
    ) throws -> PreparedArtifactTrust? {
        let artifactURL = rootDirectory.appendingPathComponent(quickState.relativePath)
        guard FileManager.default.fileExists(atPath: artifactURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: artifactURL, options: [.mappedIfSafe])
        return PreparedArtifactTrust(
            relativePath: quickState.relativePath,
            fileSize: quickState.fileSize,
            contentModificationTimeIntervalSince1970: quickState.contentModificationTimeIntervalSince1970,
            contentDigest: sha256Hex(data: data)
        )
    }

    private static func hashIfPresent(at fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            return nil
        }
        return sha256Hex(data: data)
    }

    private static func preparedModelType(
        from configData: Data?
    ) -> String? {
        guard let configData,
              let object = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            return nil
        }
        if let modelType = object["model_type"] as? String,
           !modelType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return modelType
        }
        if let modelType = object["tts_model_type"] as? String,
           !modelType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return modelType
        }
        return nil
    }

    private static func normalizedModelType(_ modelType: String?) -> String? {
        guard let modelType else { return nil }
        let trimmed = modelType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    private static func mirrorDirectoryContents(
        from sourceDirectory: URL,
        to targetDirectory: URL,
        fileManager: FileManager,
        sanitizedTopLevelConfigData: Data?
    ) throws {
        let sourceContents = try fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for sourceItem in sourceContents {
            let isDirectory = try sourceItem.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
            let targetItem = targetDirectory.appendingPathComponent(
                sourceItem.lastPathComponent,
                isDirectory: isDirectory
            )

            if let sanitizedTopLevelConfigData, sourceItem.lastPathComponent == "config.json" {
                try sanitizedTopLevelConfigData.write(to: targetItem, options: .atomic)
                continue
            }

            if isDirectory {
                try fileManager.createDirectory(at: targetItem, withIntermediateDirectories: true)
                try mirrorDirectoryContents(
                    from: sourceItem,
                    to: targetItem,
                    fileManager: fileManager,
                    sanitizedTopLevelConfigData: nil
                )
            } else {
                try fileManager.createSymbolicLink(
                    atPath: targetItem.path,
                    withDestinationPath: sourceItem.path
                )
            }
        }
    }

    private static func normalizedSpeakerIDMap(from rawValue: Any) -> [String: [Int]] {
        guard let rawMap = rawValue as? [String: Any] else {
            return [:]
        }

        var normalized: [String: [Int]] = [:]
        for (speaker, value) in rawMap {
            if let number = value as? NSNumber, !isBoolean(number) {
                normalized[speaker] = [number.intValue]
                continue
            }

            if let values = value as? [NSNumber] {
                let ints = values.filter { !isBoolean($0) }.map(\.intValue)
                if !ints.isEmpty {
                    normalized[speaker] = ints
                }
            }
        }
        return normalized
    }

    private static func normalizedSpeakerDialectMap(from rawValue: Any) -> [String: String] {
        guard let rawMap = rawValue as? [String: Any] else {
            return [:]
        }

        var normalized: [String: String] = [:]
        for (speaker, value) in rawMap {
            if let dialect = value as? String,
               !dialect.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                normalized[speaker] = dialect
            }
        }
        return normalized
    }

    private static func isBoolean(_ value: NSNumber) -> Bool {
        CFGetTypeID(value) == CFBooleanGetTypeID()
    }

    private static func sha256Hex(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
