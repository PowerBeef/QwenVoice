import Combine
import Foundation
import OSLog
import QwenVoiceCore

extension Notification.Name {
    static let ttsEngineMemoryContextDidChange = Notification.Name("TTSEngineStoreMemoryContextDidChange")
}

enum IOSNativeDeviceFeatureGate {
    static func unsupportedReason(for mode: GenerationMode) -> String? {
#if targetEnvironment(simulator)
        return nil
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
    private static let memoryLogger = Logger(
        subsystem: "com.patricedery.vocello",
        category: "MemoryGuard"
    )

    private static var allowsAggregateGuardedAdmission: Bool {
        let raw = ProcessInfo.processInfo.environment["QVOICE_IOS_ALLOW_AGGREGATE_GUARDED_ADMISSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
#if DEBUG
        guard let raw, !raw.isEmpty else { return true }
        return raw == "1" || raw == "true" || raw == "yes"
#else
        guard let raw, !raw.isEmpty else { return false }
        return raw == "1" || raw == "true" || raw == "yes"
#endif
    }

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
    private let diagnosticsRecorder: IOSDeviceDiagnosticsRecorder?
    private(set) var latestMemoryContext: IOSMemoryContext
    private var changeObserver: AnyCancellable?
    private var activeGenerationDepth = 0
    private var lastForwardedChunkIdentity: GenerationChunkDeliveryIdentity?
    private var activeGenerationMemoryGuardTask: Task<Void, Never>?
    private var activeGenerationPeakMemoryContext: IOSMemoryContext?
    private var criticalMemoryActionInFlight = false
    private var lastLoggedMemoryBand: IOSMemoryPressureBand?
    private var debugForceCriticalOnceArmed = false

    init(
        backend: AnyTTSEngineBackend,
        memoryBudgetPolicy: IOSMemoryBudgetPolicy = .iPhoneShippingDefault,
        memorySnapshotProvider: @escaping @Sendable () -> IOSMemorySnapshot = { IOSMemorySnapshot.capture(role: .app) }
    ) {
        self.backend = backend
        self.memoryBudgetPolicy = memoryBudgetPolicy
        self.memorySnapshotProvider = memorySnapshotProvider
        self.diagnosticsRecorder = IOSDeviceDiagnosticsRecorder.makeIfEnabled()
#if DEBUG
        self.debugForceCriticalOnceArmed = Self.debugForceCriticalOnceEnabled()
#endif
        let initialAppSnapshot = memorySnapshotProvider()
        self.latestMemoryContext = memoryBudgetPolicy.context(
            appSnapshot: initialAppSnapshot,
            engineExtensionSnapshot: nil,
            reason: "init",
            source: "store"
        )
        self.modelRegistry = backend.modelRegistry
        self.supportsSavedVoiceMutation = backend.supportsSavedVoiceMutation
        self.supportsModelManagementMutation = backend.supportsModelManagementMutation
        self.supportedModes = backend.supportedModes
        let initialSnapshot = backend.snapshot()
        self.frontendState = initialSnapshot.withoutPreviewAudioPayload()
        syncFromSnapshot(initialSnapshot)
        applyMemoryPolicyContext(latestMemoryContext, notify: false)
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
        stopActiveGenerationMemoryGuard(reason: "store_stop")
        backend.stop()
        syncFromBackend()
    }

    func initialize(appSupportDirectory: URL) async throws {
        try await backend.initialize(appSupportDirectory)
        syncFromBackend()
        await refreshMemoryContext(reason: "initialize", source: "store")
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
        try await guardModelAdmission(shouldSurfaceError: false, reason: "load_model")
        try await backend.loadModel(id: id)
        syncFromBackend()
        await refreshMemoryContext(reason: "load_model_complete", source: "store")
        notifyMemoryContextDidChange()
    }

    func unloadModel() async throws {
        try await backend.unloadModel()
        diagnosticsRecorder?.recordAction(
            event: "unload_model",
            reason: "explicit_unload",
            context: latestMemoryContext
        )
        syncFromBackend()
        notifyMemoryContextDidChange()
    }

    func prepareAudio(_ request: AudioPreparationRequest) async throws -> AudioNormalizationResult {
        let result = try await backend.prepareAudio(request)
        syncFromBackend()
        return result
    }

    func ensureModelLoadedIfNeeded(id: String) async {
        guard await allowsProactiveWarmOperations(reason: "ensure_model_loaded") else { return }
        await backend.ensureModelLoadedIfNeeded(id: id)
        syncFromBackend()
        notifyMemoryContextDidChange()
    }

    func prewarmModelIfNeeded(for request: GenerationRequest) async {
        guard await allowsProactiveWarmOperations(reason: "prewarm_model") else { return }
        await backend.prewarmModelIfNeeded(for: request)
        syncFromBackend()
        notifyMemoryContextDidChange()
    }

    func prefetchInteractiveReadinessIfNeeded(
        for request: GenerationRequest
    ) async -> InteractivePrefetchDiagnostics? {
        guard await allowsProactiveWarmOperations(reason: "prefetch_interactive_readiness") else { return nil }
        let diagnostics = await backend.prefetchInteractiveReadinessIfNeeded(for: request)
        syncFromBackend()
        notifyMemoryContextDidChange()
        return diagnostics
    }

    func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {
        guard await allowsProactiveWarmOperations(reason: "clone_reference_prime") else { return }
        try await backend.ensureCloneReferencePrimed(modelID: modelID, reference: reference)
        syncFromBackend()
        notifyMemoryContextDidChange()
    }

    func cancelClonePreparationIfNeeded() async {
        await backend.cancelClonePreparationIfNeeded()
        syncFromBackend()
        notifyMemoryContextDidChange()
    }

    func cancelActiveGeneration() async throws {
        defer {
            activeGenerationDepth = 0
            hasActiveGeneration = false
            syncFromBackend()
            notifyMemoryContextDidChange()
        }
        try await backend.cancelActiveGeneration()
    }

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        if case .unsupported(let reason) = supportDecision(for: request) {
            throw MLXTTSEngineError.unsupportedRequest(reason)
        }
        try await guardModelAdmission(shouldSurfaceError: true, reason: "generation_admission")
        guard !hasActiveGeneration else {
            throw MLXTTSEngineError.generationFailed(
                "The engine is already generating audio. Wait for it to finish or cancel it before starting another generation."
            )
        }
        activeGenerationDepth += 1
        hasActiveGeneration = activeGenerationDepth > 0
        startActiveGenerationMemoryGuard(reason: "generation_active")
        defer {
            stopActiveGenerationMemoryGuard(reason: "generation_finished")
            logActiveGenerationPeakMemoryContext()
            activeGenerationPeakMemoryContext = nil
            criticalMemoryActionInFlight = false
            activeGenerationDepth = max(activeGenerationDepth - 1, 0)
            hasActiveGeneration = activeGenerationDepth > 0
            syncFromBackend()
        }

        let result = try await backend.generate(request)
        let postGenerationContext = await refreshMemoryContext(reason: "post_generation", source: "store")
        let postGenerationBand = postGenerationContext.pressureBand
        if let trimLevel = memoryBudgetPolicy.postGenerationTrimLevel(for: postGenerationBand) {
            diagnosticsRecorder?.recordAction(
                event: "post_generation_trim",
                reason: "post_generation_\(postGenerationBand.rawValue)",
                context: postGenerationContext,
                trimLevel: trimLevel
            )
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

    func currentMemoryContext() -> IOSMemoryContext {
        latestMemoryContext
    }

    @discardableResult
    func refreshMemoryContext(reason: String, source: String = "store") async -> IOSMemoryContext {
        let appSnapshot = memorySnapshotProvider()
        let engineSnapshot = await backend.captureMemorySnapshot(role: .engineExtension)
        let context = memoryBudgetPolicy.context(
            appSnapshot: appSnapshot,
            engineExtensionSnapshot: engineSnapshot,
            reason: reason,
            source: source
        )
        let effectiveContext = contextApplyingDebugForcedBand(context)
        applyMemoryPolicyContext(effectiveContext)
        return effectiveContext
    }

    @discardableResult
    func refreshMemoryPolicy() -> IOSMemoryPressureBand {
        let context = memoryBudgetPolicy.context(
            appSnapshot: currentMemorySnapshot(),
            engineExtensionSnapshot: nil,
            reason: "refresh_memory_policy",
            source: "store"
        )
        let effectiveContext = contextApplyingDebugForcedBand(context)
        applyMemoryPolicyContext(effectiveContext)
        return effectiveContext.pressureBand
    }

    func trimMemory(level: NativeMemoryTrimLevel, reason: String) async {
        await backend.trimMemory(level: level, reason: reason)
        diagnosticsRecorder?.recordAction(
            event: "trim_memory",
            reason: reason,
            context: latestMemoryContext,
            trimLevel: level
        )
        syncFromBackend()
        notifyMemoryContextDidChange()
    }

    private func notifyMemoryContextDidChange() {
        NotificationCenter.default.post(name: .ttsEngineMemoryContextDidChange, object: self)
    }

    private func syncFromBackend() {
        let snapshot = backend.snapshot()
        syncFromSnapshot(snapshot)
    }

    private func syncFromSnapshot(_ snapshot: TTSEngineFrontendState) {
        let rawLatestEvent = snapshot.latestEvent
        let retainedLatestEvent: GenerationEvent?
        if case .chunk = rawLatestEvent {
            // Streaming chunks are forwarded below through NotificationCenter
            // for playback. Publishing each one through this app-wide
            // ObservableObject invalidates every screen that observes engine
            // readiness, even when only the player needs the audio chunk.
            retainedLatestEvent = latestEvent
        } else {
            retainedLatestEvent = rawLatestEvent?.withoutPreviewAudioPayload()
        }
        let retainedSnapshot = TTSEngineFrontendState(
            isReady: snapshot.isReady,
            lifecycleState: snapshot.lifecycleState,
            loadState: snapshot.loadState,
            clonePreparationState: snapshot.clonePreparationState,
            latestEvent: retainedLatestEvent,
            visibleErrorMessage: snapshot.visibleErrorMessage
        )

        if frontendState != retainedSnapshot {
            frontendState = retainedSnapshot
        }
        if loadState != retainedSnapshot.loadState {
            loadState = retainedSnapshot.loadState
        }
        if clonePreparationState != retainedSnapshot.clonePreparationState {
            clonePreparationState = retainedSnapshot.clonePreparationState
        }
        if latestEvent != retainedLatestEvent {
            latestEvent = retainedLatestEvent
        }
        if extensionLifecycleState != retainedSnapshot.lifecycleState {
            extensionLifecycleState = retainedSnapshot.lifecycleState
        }
        let snapshotHasActiveGeneration: Bool
        if case .running(_, let label, _) = retainedSnapshot.loadState,
           label != EngineActivityLabels.preparingVoiceReference {
            snapshotHasActiveGeneration = true
        } else {
            snapshotHasActiveGeneration = false
        }
        let nextHasActiveGeneration = activeGenerationDepth > 0 || snapshotHasActiveGeneration
        if hasActiveGeneration != nextHasActiveGeneration {
            hasActiveGeneration = nextHasActiveGeneration
        }
        backend.setAllowsProactiveWarmOperations(
            memoryBudgetPolicy.allowsProactiveWarmOperations(for: latestMemoryContext.pressureBand)
        )

        guard let latestEvent = rawLatestEvent,
              let chunkIdentity = latestEvent.chunkDeliveryIdentity,
              lastForwardedChunkIdentity != chunkIdentity else {
            return
        }
        lastForwardedChunkIdentity = chunkIdentity

        if case .chunk(let chunk) = latestEvent {
            guard chunk.previewAudio != nil || chunk.chunkPath != nil else { return }
            NotificationCenter.default.post(
                name: .generationChunkReceived,
                object: self,
                userInfo: [
                    "chunk": chunk,
                    "generationID": chunk.generationID as Any,
                    "requestID": chunk.requestID as Any,
                    "title": chunk.title,
                    "chunkPath": chunk.chunkPath as Any,
                    "streamSessionDirectory": chunk.streamSessionDirectory as Any,
                    "cumulativeDurationSeconds": chunk.cumulativeDurationSeconds as Any,
                ]
            )
        }
    }

    private func canAdmitModel(shouldSurfaceError: Bool, reason: String) async -> Bool {
        do {
            try await guardModelAdmission(shouldSurfaceError: shouldSurfaceError, reason: reason)
            return true
        } catch {
            return false
        }
    }

    private func guardModelAdmission(shouldSurfaceError: Bool, reason: String) async throws {
        let context = await refreshMemoryContext(reason: reason, source: "admission")
        let admissionBand = memoryBudgetPolicy.engineExecutionBand(
            for: context,
            includesAggregatePressure: false
        )
        let shouldBlockAdmission =
            !memoryBudgetPolicy.allowsModelAdmission(for: admissionBand)
            || context.aggregatePressureBand == .critical
            || (context.aggregatePressureBand == .guarded && !Self.allowsAggregateGuardedAdmission)
        guard !shouldBlockAdmission else {
            let error = MLXTTSEngineError.generationFailed(
                "Vocello needs more available memory before loading this model. Close background apps and try again."
            )
            diagnosticsRecorder?.recordAction(
                event: "model_admission_blocked",
                reason: reason,
                context: context,
                message: error.localizedDescription
            )
            if shouldSurfaceError {
                backend.setVisibleError(error.localizedDescription)
            }
            throw error
        }
#if DEBUG
        if context.aggregatePressureBand == .guarded, admissionBand != .critical {
            print(
                "[TTSEngineStore] Admitting model under aggregate guarded pressure; perProcess=\(admissionBand.rawValue), combinedFootprintMB=\(context.combinedPhysFootprintBytes.map(Self.megabytesString) ?? "unknown"), appHeadroomMB=\(context.appSnapshot.availableHeadroomBytes.map(Self.megabytesString) ?? "unknown"), extensionHeadroomMB=\(context.engineExtensionSnapshot?.availableHeadroomBytes.map(Self.megabytesString) ?? "missing")"
            )
        }
#endif
    }

    private func allowsProactiveWarmOperations(reason: String) async -> Bool {
#if targetEnvironment(simulator)
        let hardwarePrefetchAllowed = true
#elseif DEBUG
        let hardwarePrefetchAllowed = ProcessInfo.processInfo.environment["QVOICE_IOS_ENABLE_PROACTIVE_PREFETCH"] == "1"
#else
        let hardwarePrefetchAllowed = false
#endif
        guard hardwarePrefetchAllowed else {
            diagnosticsRecorder?.recordAction(
                event: "proactive_warm_blocked",
                reason: "\(reason)_hardware_default",
                context: latestMemoryContext,
                message: "iPhone proactive warm/load work is disabled by default."
            )
            return false
        }
        let context = await refreshMemoryContext(reason: reason, source: "warm_gate")
        let allowed = memoryBudgetPolicy.allowsProactiveWarmOperations(for: context.pressureBand)
        if !allowed {
            diagnosticsRecorder?.recordAction(
                event: "proactive_warm_blocked",
                reason: reason,
                context: context
            )
        }
        return allowed
    }

    @discardableResult
    private func applyMemoryPolicyContext(
        _ context: IOSMemoryContext,
        notify: Bool = true
    ) -> IOSMemoryPressureBand {
        let band = context.pressureBand
        let previousBand = latestMemoryContext.pressureBand
        latestMemoryContext = context
        backend.setAllowsProactiveWarmOperations(
            memoryBudgetPolicy.allowsProactiveWarmOperations(for: band)
        )
        recordActiveGenerationPeakIfNeeded(context)
        diagnosticsRecorder?.recordMemoryContext(context, event: "memory_context")
        if previousBand != band {
            diagnosticsRecorder?.recordMemoryContext(
                context,
                event: "memory_band_transition",
                previousBand: previousBand
            )
        }
        logMemoryContextTransitionIfNeeded(context)
        if notify {
            notifyMemoryContextDidChange()
        }
        return band
    }

    private func startActiveGenerationMemoryGuard(reason: String) {
        stopActiveGenerationMemoryGuard(reason: "restart")
        activeGenerationPeakMemoryContext = nil
        activeGenerationMemoryGuardTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let initialContext = await self.refreshMemoryContext(reason: reason, source: "active_generation_guard")
            if self.shouldEnforceCriticalMemoryContext(initialContext) {
                await self.enforceCriticalMemoryContext(initialContext)
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, self.hasActiveGeneration else { break }
                let sampledContext = await self.refreshMemoryContext(
                    reason: "active_generation_sample",
                    source: "active_generation_guard"
                )
                let context = self.contextApplyingDebugCriticalOnceIfNeeded(sampledContext)
                if self.shouldEnforceCriticalMemoryContext(context) {
                    await self.enforceCriticalMemoryContext(context)
                    break
                }
            }
        }
    }

    private func stopActiveGenerationMemoryGuard(reason: String) {
        activeGenerationMemoryGuardTask?.cancel()
        activeGenerationMemoryGuardTask = nil
    }

    private func enforceCriticalMemoryContext(_ context: IOSMemoryContext) async {
        guard !criticalMemoryActionInFlight else { return }
        criticalMemoryActionInFlight = true
        Self.memoryLogger.fault(
            "Critical iOS memory context during \(context.reason, privacy: .public); aggregate=\(context.aggregatePressureBand.rawValue, privacy: .public), worst=\(context.worstProcessRole?.rawValue ?? "unknown", privacy: .public), headroomMB=\(context.minimumHeadroomBytes.map(Self.megabytesString) ?? "unknown", privacy: .public), extensionFootprintMB=\(context.engineExtensionSnapshot?.physFootprintBytes.map(Self.megabytesString) ?? "unknown", privacy: .public), combinedFootprintMB=\(context.combinedPhysFootprintBytes.map(Self.megabytesString) ?? "unknown", privacy: .public)"
        )
        diagnosticsRecorder?.recordAction(
            event: "critical_memory_action",
            reason: context.reason,
            context: context
        )

        if hasActiveGeneration {
            do {
                try await backend.cancelActiveGeneration()
                diagnosticsRecorder?.recordAction(
                    event: "critical_generation_cancel",
                    reason: context.reason,
                    context: context
                )
            } catch {
                backend.setVisibleError(nil)
                diagnosticsRecorder?.recordAction(
                    event: "critical_generation_cancel_failed",
                    reason: context.reason,
                    context: context,
                    message: error.localizedDescription
                )
            }
            activeGenerationDepth = 0
            hasActiveGeneration = false
        }
        diagnosticsRecorder?.recordAction(
            event: "critical_full_unload",
            reason: "critical_memory_context",
            context: context,
            trimLevel: .fullUnload
        )
        await backend.trimMemory(level: .fullUnload, reason: "critical_memory_context")
        backend.clearGenerationActivity()
        syncFromBackend()
        notifyMemoryContextDidChange()
    }

    private func shouldEnforceCriticalMemoryContext(_ context: IOSMemoryContext) -> Bool {
#if DEBUG
        if context.reason.contains("debug_force_critical_once") {
            return true
        }
#endif
        return memoryBudgetPolicy.engineExecutionBand(for: context) == .critical
    }

    private func recordActiveGenerationPeakIfNeeded(_ context: IOSMemoryContext) {
        guard hasActiveGeneration else { return }
        guard let currentPeak = activeGenerationPeakMemoryContext else {
            activeGenerationPeakMemoryContext = context
            return
        }
        if Self.isHigherPressure(context, than: currentPeak) {
            activeGenerationPeakMemoryContext = context
        }
    }

    private static func isHigherPressure(_ lhs: IOSMemoryContext, than rhs: IOSMemoryContext) -> Bool {
        if lhs.pressureBand.severityRank != rhs.pressureBand.severityRank {
            return lhs.pressureBand.severityRank > rhs.pressureBand.severityRank
        }
        let lhsFootprint = lhs.combinedPhysFootprintBytes ?? lhs.peakPhysFootprintBytes ?? lhs.peakResidentBytes ?? 0
        let rhsFootprint = rhs.combinedPhysFootprintBytes ?? rhs.peakPhysFootprintBytes ?? rhs.peakResidentBytes ?? 0
        return lhsFootprint > rhsFootprint
    }

    private func logMemoryContextTransitionIfNeeded(_ context: IOSMemoryContext) {
        guard lastLoggedMemoryBand != context.pressureBand else { return }
        lastLoggedMemoryBand = context.pressureBand
        Self.memoryLogger.notice(
            "iOS memory context \(context.pressureBand.rawValue, privacy: .public) from \(context.source, privacy: .public)/\(context.reason, privacy: .public); aggregate=\(context.aggregatePressureBand.rawValue, privacy: .public), worst=\(context.worstProcessRole?.rawValue ?? "unknown", privacy: .public), appFootprintMB=\(context.appSnapshot.physFootprintBytes.map(Self.megabytesString) ?? "unknown", privacy: .public), extensionFootprintMB=\(context.engineExtensionSnapshot?.physFootprintBytes.map(Self.megabytesString) ?? "missing", privacy: .public), combinedFootprintMB=\(context.combinedPhysFootprintBytes.map(Self.megabytesString) ?? "unknown", privacy: .public), minHeadroomMB=\(context.minimumHeadroomBytes.map(Self.megabytesString) ?? "unknown", privacy: .public)"
        )
    }

    private func logActiveGenerationPeakMemoryContext() {
        guard let context = activeGenerationPeakMemoryContext else { return }
        diagnosticsRecorder?.recordMemoryContext(context, event: "active_generation_peak")
        Self.memoryLogger.notice(
            "iOS generation peak memory \(context.pressureBand.rawValue, privacy: .public); aggregate=\(context.aggregatePressureBand.rawValue, privacy: .public), worst=\(context.worstProcessRole?.rawValue ?? "unknown", privacy: .public), appFootprintMB=\(context.appSnapshot.physFootprintBytes.map(Self.megabytesString) ?? "unknown", privacy: .public), extensionFootprintMB=\(context.engineExtensionSnapshot?.physFootprintBytes.map(Self.megabytesString) ?? "missing", privacy: .public), combinedFootprintMB=\(context.combinedPhysFootprintBytes.map(Self.megabytesString) ?? "unknown", privacy: .public), minHeadroomMB=\(context.minimumHeadroomBytes.map(Self.megabytesString) ?? "unknown", privacy: .public)"
        )
    }

    private func contextApplyingDebugForcedBand(_ context: IOSMemoryContext) -> IOSMemoryContext {
#if DEBUG
        guard let forcedBand = Self.debugForcedMemoryBand(),
              forcedBand.severityRank > context.pressureBand.severityRank else {
            return context
        }
        return Self.context(
            context,
            overridingBand: forcedBand,
            reason: "\(context.reason)_debug_force_\(forcedBand.rawValue)"
        )
#else
        return context
#endif
    }

    private func contextApplyingDebugCriticalOnceIfNeeded(_ context: IOSMemoryContext) -> IOSMemoryContext {
#if DEBUG
        guard debugForceCriticalOnceArmed else { return context }
        debugForceCriticalOnceArmed = false
        let forcedContext = Self.context(
            context,
            overridingBand: .critical,
            reason: "\(context.reason)_debug_force_critical_once"
        )
        applyMemoryPolicyContext(forcedContext)
        diagnosticsRecorder?.recordAction(
            event: "debug_force_critical_once",
            reason: forcedContext.reason,
            context: forcedContext
        )
        return forcedContext
#else
        return context
#endif
    }

    private static func context(
        _ context: IOSMemoryContext,
        overridingBand band: IOSMemoryPressureBand,
        reason: String
    ) -> IOSMemoryContext {
        IOSMemoryContext(
            appSnapshot: context.appSnapshot,
            engineExtensionSnapshot: context.engineExtensionSnapshot,
            pressureBand: band,
            aggregatePressureBand: context.aggregatePressureBand,
            worstProcessRole: context.worstProcessRole ?? .app,
            reason: reason,
            source: context.source
        )
    }

#if DEBUG
    private static func debugForcedMemoryBand(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> IOSMemoryPressureBand? {
        switch environment["QVOICE_IOS_MEMORY_GUARD_FORCE_BAND"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "guarded":
            return .guarded
        default:
            return nil
        }
    }

    private static func debugForceCriticalOnceEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        switch environment["QVOICE_IOS_MEMORY_GUARD_FORCE_CRITICAL_ONCE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
#endif

    private static func megabytesString(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
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
    private let cancelActiveGenerationBlock: () async throws -> Void
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
    private let captureMemorySnapshotBlock: (IOSMemoryProcessRole) async -> IOSMemorySnapshot?
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
        if let engine = engine as? any ActiveGenerationCancellable {
            self.cancelActiveGenerationBlock = { try await engine.cancelActiveGeneration() }
        } else {
            self.cancelActiveGenerationBlock = {}
        }
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
        if let engine = engine as? any NativeMemoryReporting {
            self.captureMemorySnapshotBlock = { role in
                await engine.captureMemorySnapshot(role: role)
            }
        } else {
            self.captureMemorySnapshotBlock = { _ in nil }
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
    func cancelActiveGeneration() async throws { try await cancelActiveGenerationBlock() }
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
    func captureMemorySnapshot(role: IOSMemoryProcessRole) async -> IOSMemorySnapshot? {
        await captureMemorySnapshotBlock(role)
    }

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
