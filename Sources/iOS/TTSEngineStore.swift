import Combine
import Foundation
import QwenVoiceCore

extension Notification.Name {
    static let ttsEngineMemoryContextDidChange = Notification.Name("TTSEngineStoreMemoryContextDidChange")
}

enum IOSNativeDeviceFeatureGate {
    static func unsupportedReason(for mode: GenerationMode) -> String? {
#if targetEnvironment(simulator)
        return IOSSimulatorRuntimeSupport.unsupportedMessage
#else
        switch mode {
        case .custom, .design, .clone:
            return nil
        }
#endif
    }

    static func isModeSupported(
        _ mode: GenerationMode,
        declaredModes: Set<GenerationMode>
    ) -> Bool {
        declaredModes.contains(mode) && unsupportedReason(for: mode) == nil
    }

    static func unavailableMessage(for model: ModelDescriptor) -> String? {
        unsupportedReason(for: model.mode)
    }

    static func allowsModelDownloads(for model: ModelDescriptor) -> Bool {
        model.iosDownloadEligible && unavailableMessage(for: model) == nil
    }
}

@MainActor
final class TTSEngineStore: ObservableObject, TTSEngine {
    @Published private(set) var loadState: EngineLoadState = .idle
    @Published private(set) var clonePreparationState: ClonePreparationState = .idle
    @Published private(set) var latestEvent: GenerationEvent?
    @Published private(set) var hasActiveGeneration = false
    @Published private(set) var extensionLifecycleState: ExtensionEngineLifecycleState = .idle

    let modelRegistry: any ModelRegistry
    let supportsSavedVoiceMutation: Bool
    let supportsModelManagementMutation: Bool
    let supportedModes: Set<GenerationMode>

    var isReady: Bool { frontendState.isReady }
    var visibleErrorMessage: String? { frontendState.visibleErrorMessage }
    private(set) var frontendState: TTSEngineFrontendState

    private let backend: AnyTTSEngineBackend
    private let memoryBudgetPolicy: IOSMemoryBudgetPolicy
    private let memorySnapshotProvider: @Sendable () -> IOSMemorySnapshot
    private var changeObserver: AnyCancellable?
    private var activeGenerationDepth = 0

    init(
        backend: AnyTTSEngineBackend,
        memoryBudgetPolicy: IOSMemoryBudgetPolicy = .iPhoneShippingDefault,
        memorySnapshotProvider: @escaping @Sendable () -> IOSMemorySnapshot = { IOSMemorySnapshot.capture() }
    ) {
        self.backend = backend
        self.memoryBudgetPolicy = memoryBudgetPolicy
        self.memorySnapshotProvider = memorySnapshotProvider
        self.modelRegistry = backend.modelRegistry
        self.supportsSavedVoiceMutation = backend.supportsSavedVoiceMutation
        self.supportsModelManagementMutation = backend.supportsModelManagementMutation
        self.supportedModes = backend.supportedModes
        self.frontendState = backend.snapshot()
        syncFromSnapshot(frontendState)
        applyMemoryPolicyContext(for: memorySnapshotProvider())
        changeObserver = backend.stateDidChange
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    self?.syncFromBackend()
                }
            }
    }

    func supportsMode(_ mode: GenerationMode) -> Bool {
        IOSNativeDeviceFeatureGate.isModeSupported(mode, declaredModes: supportedModes)
    }

    func start() {
        backend.start()
        syncFromBackend()
    }

    func stop() {
        backend.stop()
        syncFromBackend()
    }

    func initialize(appSupportDirectory: URL) async throws {
        try await backend.initialize(appSupportDirectory)
        syncFromBackend()
        notifyMemoryContextDidChange()
    }

    func ping() async throws -> Bool {
        let result = try await backend.ping()
        syncFromBackend()
        return result
    }

    func supportDecision(for request: GenerationRequest) -> GenerationSupportDecision {
        if let reason = IOSNativeDeviceFeatureGate.unsupportedReason(for: request.mode) {
            return .unsupported(reason: reason)
        }
        return backend.supportDecision(for: request)
    }

    func loadModel(id: String) async throws {
        try guardModelAdmission(shouldSurfaceError: false)
        try await backend.loadModel(id: id)
        syncFromBackend()
        notifyMemoryContextDidChange()
    }

    func unloadModel() async throws {
        try await backend.unloadModel()
        syncFromBackend()
        notifyMemoryContextDidChange()
    }

    func prepareAudio(_ request: AudioPreparationRequest) async throws -> AudioNormalizationResult {
        let result = try await backend.prepareAudio(request)
        syncFromBackend()
        return result
    }

    func ensureModelLoadedIfNeeded(id: String) async {
        guard canAdmitModel(shouldSurfaceError: false) else { return }
        await backend.ensureModelLoadedIfNeeded(id: id)
        syncFromBackend()
        notifyMemoryContextDidChange()
    }

    func prewarmModelIfNeeded(for request: GenerationRequest) async {
        guard allowsProactiveWarmOperations() else { return }
        await backend.prewarmModelIfNeeded(for: request)
        syncFromBackend()
        notifyMemoryContextDidChange()
    }

    func prefetchInteractiveReadinessIfNeeded(
        for request: GenerationRequest
    ) async -> InteractivePrefetchDiagnostics? {
        guard allowsProactiveWarmOperations() else { return nil }
        let diagnostics = await backend.prefetchInteractiveReadinessIfNeeded(for: request)
        syncFromBackend()
        notifyMemoryContextDidChange()
        return diagnostics
    }

    func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {
        guard allowsProactiveWarmOperations() else { return }
        try await backend.ensureCloneReferencePrimed(modelID: modelID, reference: reference)
        syncFromBackend()
        notifyMemoryContextDidChange()
    }

    func cancelClonePreparationIfNeeded() async {
        await backend.cancelClonePreparationIfNeeded()
        syncFromBackend()
        notifyMemoryContextDidChange()
    }

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        if case .unsupported(let reason) = supportDecision(for: request) {
            throw MLXTTSEngineError.unsupportedRequest(reason)
        }
        try guardModelAdmission(shouldSurfaceError: true)
        activeGenerationDepth += 1
        hasActiveGeneration = activeGenerationDepth > 0
        defer {
            activeGenerationDepth = max(activeGenerationDepth - 1, 0)
            hasActiveGeneration = activeGenerationDepth > 0
            syncFromBackend()
        }

        let result = try await backend.generate(request)
        let postGenerationBand = applyMemoryPolicyContext(for: currentMemorySnapshot())
        if let trimLevel = memoryBudgetPolicy.postGenerationTrimLevel(for: postGenerationBand) {
            await backend.trimMemory(
                level: trimLevel,
                reason: "post_generation_\(postGenerationBand.rawValue)"
            )
        }
        syncFromBackend()
        notifyMemoryContextDidChange()
        return result
    }

    func listPreparedVoices() async throws -> [PreparedVoice] {
        let voices = try await backend.listPreparedVoices()
        syncFromBackend()
        return voices
    }

    func enrollPreparedVoice(name: String, audioPath: String, transcript: String?) async throws -> PreparedVoice {
        let voice = try await backend.enrollPreparedVoice(name: name, audioPath: audioPath, transcript: transcript)
        syncFromBackend()
        return voice
    }

    func deletePreparedVoice(id: String) async throws {
        try await backend.deletePreparedVoice(id: id)
        syncFromBackend()
    }

    func importReferenceAudio(from sourceURL: URL) throws -> ImportedReferenceAudio {
        try backend.importReferenceAudio(from: sourceURL)
    }

    func exportGeneratedAudio(from sourceURL: URL, to destinationURL: URL) throws -> ExportedDocument {
        try backend.exportGeneratedAudio(from: sourceURL, to: destinationURL)
    }

    func clearGenerationActivity() {
        backend.clearGenerationActivity()
        syncFromBackend()
    }

    func clearVisibleError() {
        backend.clearVisibleError()
        syncFromBackend()
    }

    func setVisibleError(_ message: String?) {
        backend.setVisibleError(message)
        syncFromBackend()
    }

    nonisolated var memoryIndicatorBudgetPolicy: IOSMemoryBudgetPolicy {
        memoryBudgetPolicy
    }

    nonisolated var memoryIndicatorSnapshotProvider: @Sendable () -> IOSMemorySnapshot {
        memorySnapshotProvider
    }

    nonisolated func currentMemorySnapshot() -> IOSMemorySnapshot {
        memorySnapshotProvider()
    }

    @discardableResult
    func refreshMemoryPolicy() -> IOSMemoryPressureBand {
        applyMemoryPolicyContext(for: currentMemorySnapshot())
    }

    func trimMemory(level: NativeMemoryTrimLevel, reason: String) async {
        await backend.trimMemory(level: level, reason: reason)
        syncFromBackend()
        notifyMemoryContextDidChange()
    }

    private func notifyMemoryContextDidChange() {
        NotificationCenter.default.post(name: .ttsEngineMemoryContextDidChange, object: self)
    }

    private func syncFromBackend() {
        let snapshot = backend.snapshot()
        frontendState = snapshot
        syncFromSnapshot(snapshot)
    }

    private func syncFromSnapshot(_ snapshot: TTSEngineFrontendState) {
        let previousLatestEvent = latestEvent
        loadState = snapshot.loadState
        clonePreparationState = snapshot.clonePreparationState
        latestEvent = snapshot.latestEvent
        extensionLifecycleState = snapshot.lifecycleState
        applyMemoryPolicyContext(for: currentMemorySnapshot())

        guard previousLatestEvent != snapshot.latestEvent,
              let latestEvent = snapshot.latestEvent else {
            return
        }

        if case .chunk(let chunk) = latestEvent {
            NotificationCenter.default.post(
                name: .generationChunkReceived,
                object: self,
                userInfo: ["chunk": chunk]
            )
            guard let chunkPath = chunk.chunkPath else {
                return
            }
            let chunkIndex = Self.chunkIndex(from: chunkPath)
            Task { @MainActor in
                await AppGenerationTelemetryCoordinator.shared.recordPreviewChunk(
                    chunkIndex: chunkIndex
                )
            }
        }
    }

    private func canAdmitModel(shouldSurfaceError: Bool) -> Bool {
        do {
            try guardModelAdmission(shouldSurfaceError: shouldSurfaceError)
            return true
        } catch {
            return false
        }
    }

    private func guardModelAdmission(shouldSurfaceError: Bool) throws {
        let band = applyMemoryPolicyContext(for: currentMemorySnapshot())
        guard memoryBudgetPolicy.allowsModelAdmission(for: band) else {
            let error = MLXTTSEngineError.generationFailed(
                "Vocello needs more available memory before loading this model. Close background apps and try again."
            )
            if shouldSurfaceError {
                backend.setVisibleError(error.localizedDescription)
            }
            throw error
        }
    }

    private func allowsProactiveWarmOperations() -> Bool {
        let band = applyMemoryPolicyContext(for: currentMemorySnapshot())
        return memoryBudgetPolicy.allowsProactiveWarmOperations(for: band)
    }

    @discardableResult
    private func applyMemoryPolicyContext(for snapshot: IOSMemorySnapshot) -> IOSMemoryPressureBand {
        let band = memoryBudgetPolicy.band(for: snapshot)
        backend.setAllowsProactiveWarmOperations(
            memoryBudgetPolicy.allowsProactiveWarmOperations(for: band)
        )
        return band
    }

    private static func chunkIndex(from chunkPath: String) -> Int {
        let fileName = URL(fileURLWithPath: chunkPath).deletingPathExtension().lastPathComponent
        let digits = fileName.compactMap(\.wholeNumberValue)
        guard !digits.isEmpty else { return 0 }
        return digits.reduce(into: 0) { partialResult, digit in
            partialResult = partialResult * 10 + digit
        }
    }
}

@MainActor
final class AnyTTSEngineBackend {
    let modelRegistry: any ModelRegistry
    let supportsSavedVoiceMutation: Bool
    let supportsModelManagementMutation: Bool
    let supportedModes: Set<GenerationMode>
    let stateDidChange: AnyPublisher<Void, Never>

    private let snapshotBlock: () -> TTSEngineFrontendState
    private let supportDecisionBlock: (GenerationRequest) -> GenerationSupportDecision
    private let startBlock: () -> Void
    private let stopBlock: () -> Void
    private let initializeBlock: (URL) async throws -> Void
    private let pingBlock: () async throws -> Bool
    private let loadModelBlock: (String) async throws -> Void
    private let unloadModelBlock: () async throws -> Void
    private let prepareAudioBlock: (AudioPreparationRequest) async throws -> AudioNormalizationResult
    private let ensureModelLoadedIfNeededBlock: (String) async -> Void
    private let prewarmModelIfNeededBlock: (GenerationRequest) async -> Void
    private let prefetchInteractiveReadinessIfNeededBlock: (GenerationRequest) async -> InteractivePrefetchDiagnostics?
    private let ensureCloneReferencePrimedBlock: (String, CloneReference) async throws -> Void
    private let cancelClonePreparationIfNeededBlock: () async -> Void
    private let generateBlock: (GenerationRequest) async throws -> GenerationResult
    private let listPreparedVoicesBlock: () async throws -> [PreparedVoice]
    private let enrollPreparedVoiceBlock: (String, String, String?) async throws -> PreparedVoice
    private let deletePreparedVoiceBlock: (String) async throws -> Void
    private let importReferenceAudioBlock: (URL) throws -> ImportedReferenceAudio
    private let exportGeneratedAudioBlock: (URL, URL) throws -> ExportedDocument
    private let clearGenerationActivityBlock: () -> Void
    private let clearVisibleErrorBlock: () -> Void
    private let setVisibleErrorBlock: (String?) -> Void
    private let setAllowsProactiveWarmOperationsBlock: (Bool) -> Void
    private let trimMemoryBlock: (NativeMemoryTrimLevel, String) async -> Void
    private let extensionLifecycleStateBlock: () -> ExtensionEngineLifecycleState

    init<Engine: TTSEngine & AnyObject>(
        engine: Engine,
        supportsSavedVoiceMutation: Bool,
        supportsModelManagementMutation: Bool,
        supportedModes: Set<GenerationMode>
    ) {
        self.modelRegistry = engine.modelRegistry
        self.supportsSavedVoiceMutation = supportsSavedVoiceMutation
        self.supportsModelManagementMutation = supportsModelManagementMutation
        self.supportedModes = supportedModes
        self.stateDidChange = engine.objectWillChange
            .map { _ in () }
            .eraseToAnyPublisher()
        self.snapshotBlock = {
            TTSEngineFrontendState(
                isReady: engine.isReady,
                lifecycleState: Self.frontendLifecycleState(for: engine),
                loadState: engine.loadState,
                clonePreparationState: engine.clonePreparationState,
                latestEvent: engine.latestEvent,
                visibleErrorMessage: engine.visibleErrorMessage
            )
        }
        self.supportDecisionBlock = { engine.supportDecision(for: $0) }
        self.startBlock = { engine.start() }
        self.stopBlock = { engine.stop() }
        self.initializeBlock = { try await engine.initialize(appSupportDirectory: $0) }
        self.pingBlock = { try await engine.ping() }
        self.loadModelBlock = { try await engine.loadModel(id: $0) }
        self.unloadModelBlock = { try await engine.unloadModel() }
        self.prepareAudioBlock = { try await engine.prepareAudio($0) }
        self.ensureModelLoadedIfNeededBlock = { await engine.ensureModelLoadedIfNeeded(id: $0) }
        self.prewarmModelIfNeededBlock = { await engine.prewarmModelIfNeeded(for: $0) }
        if let engine = engine as? any TTSEngineRuntimeControlling {
            self.prefetchInteractiveReadinessIfNeededBlock = { await engine.prefetchInteractiveReadinessIfNeeded(for: $0) }
        } else {
            self.prefetchInteractiveReadinessIfNeededBlock = { _ in nil }
        }
        self.ensureCloneReferencePrimedBlock = { try await engine.ensureCloneReferencePrimed(modelID: $0, reference: $1) }
        self.cancelClonePreparationIfNeededBlock = { await engine.cancelClonePreparationIfNeeded() }
        self.generateBlock = { try await engine.generate($0) }
        self.listPreparedVoicesBlock = { try await engine.listPreparedVoices() }
        self.enrollPreparedVoiceBlock = { try await engine.enrollPreparedVoice(name: $0, audioPath: $1, transcript: $2) }
        self.deletePreparedVoiceBlock = { try await engine.deletePreparedVoice(id: $0) }
        self.importReferenceAudioBlock = { try engine.importReferenceAudio(from: $0) }
        self.exportGeneratedAudioBlock = { try engine.exportGeneratedAudio(from: $0, to: $1) }
        self.clearGenerationActivityBlock = { engine.clearGenerationActivity() }
        self.clearVisibleErrorBlock = { engine.clearVisibleError() }
        if let engine = engine as? any TTSEngineRuntimeControlling {
            self.setVisibleErrorBlock = { engine.setVisibleError($0) }
            self.setAllowsProactiveWarmOperationsBlock = { engine.setAllowsProactiveWarmOperations($0) }
            self.trimMemoryBlock = { level, reason in
                await engine.trimMemory(level: level, reason: reason)
            }
        } else {
            self.setVisibleErrorBlock = { _ in }
            self.setAllowsProactiveWarmOperationsBlock = { _ in }
            self.trimMemoryBlock = { _, _ in }
        }
        self.extensionLifecycleStateBlock = {
            Self.frontendLifecycleState(for: engine)
        }
    }

    fileprivate func snapshot() -> TTSEngineFrontendState {
        let snapshot = snapshotBlock()
        return TTSEngineFrontendState(
            isReady: snapshot.isReady,
            lifecycleState: extensionLifecycleStateBlock(),
            loadState: snapshot.loadState,
            clonePreparationState: snapshot.clonePreparationState,
            latestEvent: snapshot.latestEvent,
            visibleErrorMessage: snapshot.visibleErrorMessage
        )
    }
    func supportDecision(for request: GenerationRequest) -> GenerationSupportDecision { supportDecisionBlock(request) }
    func start() { startBlock() }
    func stop() { stopBlock() }
    func initialize(_ appSupportDirectory: URL) async throws { try await initializeBlock(appSupportDirectory) }
    func ping() async throws -> Bool { try await pingBlock() }
    func loadModel(id: String) async throws { try await loadModelBlock(id) }
    func unloadModel() async throws { try await unloadModelBlock() }
    func prepareAudio(_ request: AudioPreparationRequest) async throws -> AudioNormalizationResult { try await prepareAudioBlock(request) }
    func ensureModelLoadedIfNeeded(id: String) async { await ensureModelLoadedIfNeededBlock(id) }
    func prewarmModelIfNeeded(for request: GenerationRequest) async { await prewarmModelIfNeededBlock(request) }
    func prefetchInteractiveReadinessIfNeeded(for request: GenerationRequest) async -> InteractivePrefetchDiagnostics? {
        await prefetchInteractiveReadinessIfNeededBlock(request)
    }
    func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {
        try await ensureCloneReferencePrimedBlock(modelID, reference)
    }
    func cancelClonePreparationIfNeeded() async { await cancelClonePreparationIfNeededBlock() }
    func generate(_ request: GenerationRequest) async throws -> GenerationResult { try await generateBlock(request) }
    func listPreparedVoices() async throws -> [PreparedVoice] { try await listPreparedVoicesBlock() }
    func enrollPreparedVoice(name: String, audioPath: String, transcript: String?) async throws -> PreparedVoice {
        try await enrollPreparedVoiceBlock(name, audioPath, transcript)
    }
    func deletePreparedVoice(id: String) async throws { try await deletePreparedVoiceBlock(id) }
    func importReferenceAudio(from sourceURL: URL) throws -> ImportedReferenceAudio { try importReferenceAudioBlock(sourceURL) }
    func exportGeneratedAudio(from sourceURL: URL, to destinationURL: URL) throws -> ExportedDocument {
        try exportGeneratedAudioBlock(sourceURL, destinationURL)
    }
    func clearGenerationActivity() { clearGenerationActivityBlock() }
    func clearVisibleError() { clearVisibleErrorBlock() }
    func setVisibleError(_ message: String?) { setVisibleErrorBlock(message) }
    func setAllowsProactiveWarmOperations(_ allow: Bool) { setAllowsProactiveWarmOperationsBlock(allow) }
    func trimMemory(level: NativeMemoryTrimLevel, reason: String) async { await trimMemoryBlock(level, reason) }

    private static func frontendLifecycleState<Engine: TTSEngine>(
        for engine: Engine
    ) -> ExtensionEngineLifecycleState {
        if let engine = engine as? ExtensionBackedTTSEngine {
            return engine.lifecycleState
        }
        if engine.isReady {
            return .connected
        }
        if let visibleErrorMessage = engine.visibleErrorMessage,
           !visibleErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failed
        }
        return .idle
    }
}
