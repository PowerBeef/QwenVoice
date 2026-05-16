import AVFoundation
import Combine
import Foundation
@preconcurrency import MLX
@preconcurrency import MLXAudioTTS

/// Engine-protocol-level error type. Adopted by every conformer of
/// `TTSEngine` and by every throwing function on that protocol once the
/// typed-throws sweep is complete. Conformers catch downstream typed
/// errors (e.g. `AudioPreparationError`, `DocumentIOError`,
/// `ExtensionEngineHostManagerError`) and rethrow them as
/// `.generationFailed(<localized description>)`. The cross-process
/// transports (`Sources/QwenVoiceNative/XPCNativeEngineClient.swift`,
/// `Sources/QwenVoiceCore/ExtensionBackedTTSEngine.swift`) carry
/// instances of this type across `NSXPCConnection` and `AppExtension`
/// boundaries.
public enum TTSEngineError: LocalizedError, Equatable {
    case notInitialized
    case unknownModel(String)
    case modelUnavailable(String)
    case unsupportedRequest(String)
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "The native MLX engine has not been initialized yet."
        case .unknownModel(let modelID):
            return "The native MLX engine could not find model '\(modelID)'."
        case .modelUnavailable(let message),
             .unsupportedRequest(let message),
             .generationFailed(let message):
            return message
        }
    }
}

/// Source-compatibility alias for the prior name. Existing call sites
/// that reference `MLXTTSEngineError.<case>` continue to work; the type
/// they see is now `TTSEngineError`. Retained for the duration of the
/// typed-throws sweep so individual files can migrate incrementally.
public typealias MLXTTSEngineError = TTSEngineError

@MainActor
public final class MLXTTSEngine: TTSEngineRuntimeControlling {
    private static let lightweightWarmupText = "Hi."
    public static let eventStreamBufferLimit = 64
    public static var lightweightWarmupTextForUI: String { lightweightWarmupText }

    /// Audio extensions the saved-voice store accepts on disk. Mirrors the
    /// UTType allowlist exposed by the file pickers in
    /// `SavedVoiceSheet.swift` (macOS) and `IOSGenerationModeViews.swift`
    /// (iOS). Used by `enrollPreparedVoice` to keep the source extension
    /// (so MP3/M4A bytes don't get a `.wav` filename slapped on), and by
    /// the list/delete paths to find each voice's audio file regardless
    /// of which format the user imported. `wav` stays the fallback for
    /// inputs whose extension is empty or unrecognized — preserves the
    /// pre-existing behavior for the seed/bootstrap fixtures.
    static let supportedSavedVoiceAudioExtensions: Set<String> = ["wav", "mp3", "aiff", "m4a"]

    typealias StreamingSessionFactory = (
        Int,
        GenerationRequest,
        UnsafeSpeechGenerationModel,
        URL,
        EngineWarmState,
        [String: Int],
        [String: Bool],
        [String: String],
        ResolvedCloneConditioning?,
        Bool,
        NativeTelemetryRecorder?,
        NativeLoadCapabilityProfile,
        NativeMemoryPolicy,
        [String: NativeMLXMemorySnapshot]
    ) -> any NativeStreamingSessionRunning

    public let modelRegistry: any ModelRegistry
    public let modelAssetStore: any ModelAssetStore

    @Published public private(set) var loadState: EngineLoadState = .idle
    @Published public private(set) var clonePreparationState: ClonePreparationState = .idle
    /// Most-recent event seen by the engine. Retained for snapshot
    /// consumers (UI bindings via the `TTSEngine` protocol —
    /// `IOSSimulatorTTSEngine`, `TTSEngineStore` macOS+iOS, the
    /// `TTSEngineFrontendState.latestEvent` field) that read the
    /// "what state is the engine in right now" view of generation
    /// activity. **NOT** the chunk-delivery transport — that role
    /// moved to the `events` `AsyncStream` below to fix the audit
    /// Finding #1 race where `EngineServiceHost`'s
    /// `objectWillChange.sink` slot-sampler could overwrite a
    /// chunk before it was published, silently dropping the last
    /// audio chunk of every streaming generation.
    @Published public private(set) var latestEvent: GenerationEvent?

    /// Bounded stream of `GenerationEvent` values for transport consumers.
    /// Active consumers receive events in the order they are yielded. If a
    /// consumer stalls, the stream keeps the newest `eventStreamBufferLimit`
    /// events and may drop older diagnostic preview payloads to keep memory
    /// bounded.
    public let events: AsyncStream<GenerationEvent>
    private let eventStreamContinuation: AsyncStream<GenerationEvent>.Continuation

    public var isReady: Bool {
        isInitialized
    }

    public var sidebarStatus: EngineLoadState {
        loadState
    }

    /// Returns the id of the currently loaded model, or `nil` when no model
    /// is loaded (idle / starting / failed states). API-parity surface for
    /// the legacy `NativeMLXMacEngine` shape so call sites that previously
    /// reached into `runtime.currentLoadedModelID()` can move to the engine
    /// directly. Derives from `loadState.currentModelID` — covers both
    /// `.loaded(modelID:)` and `.running(modelID:_:_:)`.
    public func currentLoadedModelID() async -> String? {
        loadState.currentModelID
    }

    private func cancelIdleUnload() {
        idleUnloadToken = nil
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    private func scheduleIdleUnloadIfNeeded(modelID: String, isBatch: Bool) {
        guard let mode = modelRegistry.model(id: modelID)?.mode else { return }
        scheduleIdleUnloadIfNeeded(modelID: modelID, mode: mode, isBatch: isBatch)
    }

    private func applyMemoryPolicyIfKnown(modelID: String, isBatch: Bool) {
        guard let mode = modelRegistry.model(id: modelID)?.mode else { return }
        NativeMemoryPolicyResolver.apply(
            NativeMemoryPolicyResolver.policy(mode: mode, isBatch: isBatch)
        )
    }

    private func scheduleIdleUnloadIfNeeded(
        modelID: String,
        mode: GenerationMode,
        isBatch: Bool
    ) {
        let policy = NativeMemoryPolicyResolver.policy(mode: mode, isBatch: isBatch)
        scheduleIdleUnloadIfNeeded(modelID: modelID, policy: policy)
    }

    private func scheduleIdleUnloadIfNeeded(modelID: String, policy: NativeMemoryPolicy) {
        cancelIdleUnload()
        guard let policyDelay = policy.unloadAfterIdleSeconds else { return }

        // Adaptive shortening: if the system is currently under memory
        // pressure (the macOS DispatchSource monitor has flagged it),
        // shorten the idle-unload window so we release the model
        // sooner. floor8GBMac's policy delay is 120s and we shrink it
        // to 30s under guarded pressure or 10s under critical — the
        // user re-pays the model-load cost (~500-700ms) on their next
        // generation, which is the right trade when memory is tight.
        // Override (used by tests) still wins over the adaptive value.
        let adaptiveDelay = adaptiveIdleUnloadDelay(
            policyDelay: policyDelay,
            deviceClass: policy.deviceClass
        )
        let delay = max(idleUnloadDelayOverride ?? adaptiveDelay, 0)
        let token = UUID()
        idleUnloadToken = token
        idleUnloadTask = Task { [weak self] in
            let nanoseconds = UInt64((delay * 1_000_000_000).rounded())
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            guard !Task.isCancelled else { return }
            await self?.performIdleUnloadIfStillIdle(modelID: modelID, token: token)
        }
    }

    private func adaptiveIdleUnloadDelay(
        policyDelay: Double,
        deviceClass: NativeDeviceMemoryClass
    ) -> Double {
        // Only the floor8GBMac tier reacts to pressure for idle-unload.
        // mid16GBMac has a 10-minute baseline; even under pressure we'd
        // rather keep the model warm than churn loads.
        // highMemoryMac has no policyDelay (nil).
        // iPhonePro already runs at a 30s baseline.
        guard deviceClass == .floor8GBMac else { return policyDelay }
        switch memoryPressureMonitor.currentLevel {
        case .softTrim:
            return min(policyDelay, 30.0)
        case .hardTrim, .fullUnload:
            return min(policyDelay, 10.0)
        case nil:
            return policyDelay
        }
    }

    private func performIdleUnloadIfStillIdle(modelID: String, token: UUID) async {
        guard idleUnloadToken == token, canIdleUnload(modelID: modelID) else { return }
        await runtime.unloadModel()
        guard idleUnloadToken == token, canIdleUnload(modelID: modelID) else { return }
        idleUnloadToken = nil
        idleUnloadTask = nil
        loadState = .idle
        clonePreparationState = .idle
        visibleErrorMessage = nil
    }

    private func canIdleUnload(modelID: String) -> Bool {
        guard case .loaded(let loadedModelID) = loadState,
              loadedModelID == modelID,
              clonePreparationState.phase == .idle
        else {
            return false
        }
        return true
    }

    public private(set) var visibleErrorMessage: String?

    private let audioPreparationService: any AudioPreparationService
    private let documentIO: any DocumentIO
    private let streamSessionsDirectory: URL
    private let telemetryRecorder: NativeTelemetryRecorder?
    private let diagnosticAppSupportBox: DiagnosticAppSupportBox
    private let runtime: NativeEngineRuntime
    private let streamingSessionFactory: StreamingSessionFactory
    private let idleUnloadDelayOverride: Double?
    private var isInitialized = false
    private var appSupportDirectoryURL: URL?
    private var voicesDirectory: URL?
    private var allowsProactiveWarmOperations = true
    private var idleUnloadTask: Task<Void, Never>?
    private var idleUnloadToken: UUID?

    /// macOS-side memory pressure monitor. On 8 GB and 16 GB Macs this
    /// subscribes to kernel pressure events and forwards them as trim
    /// levels to `runtime.trimMemory(...)`. On high-memory Macs the
    /// monitor is created but never started — there's no value in
    /// reacting on machines that aren't pressure-bound. On iOS the
    /// monitor is a no-op (the iOS host has its own infrastructure).
    private let memoryPressureMonitor: NativeMemoryPressureMonitor
    private var memoryPressureTask: Task<Void, Never>?

    public convenience init(
        modelRegistry: any ModelRegistry,
        modelAssetStore: any ModelAssetStore,
        audioPreparationService: any AudioPreparationService,
        documentIO: any DocumentIO,
        hubCacheDirectory: URL,
        streamSessionsDirectory: URL,
        telemetryRecorder: NativeTelemetryRecorder? = nil,
        customPrewarmPolicy: NativeCustomPrewarmPolicy = .eager,
        qwenPreparedLoadProfile: NativeQwenPreparedLoadProfile = .fullCapabilities
    ) {
        let diagnosticAppSupportBox = DiagnosticAppSupportBox()
        let loadCoordinator = MLXModelLoadCoordinator(
            modelAssetStore: modelAssetStore,
            hubCacheDirectory: hubCacheDirectory,
            modelLoader: { descriptor, preparedMetadata, capabilityProfile in
                let resolvedProfile = Self.resolvedPreparedLoadProfile(
                    requestedCapabilityProfile: capabilityProfile,
                    explicitProfile: qwenPreparedLoadProfile
                )
                await Self.recordDiagnosticEvent(
                    "engine-loader-before-tts-load-model",
                    details: [
                        "descriptorID": descriptor.id,
                        "modelType": preparedMetadata.modelType ?? "",
                        "preparedDirectory": preparedMetadata.preparedDirectory.path,
                        "sourceDirectory": preparedMetadata.sourceDirectory?.path ?? "",
                        "modelRepo": descriptor.model.huggingFaceRepo,
                        "nativeLoadCapabilityProfile": capabilityProfile.rawValue,
                        "qwenPreparedLoadProfile": Self.diagnosticLabel(for: resolvedProfile),
                        "trustedPreparedCheckpoint": preparedMetadata.trustedPreparedCheckpoint ? "true" : "false",
                    ].merging(preparedMetadata.qwenRuntimeProfile.diagnosticStringFlags()) { _, rhs in rhs },
                    appSupportDirectoryURL: diagnosticAppSupportBox.url
                )
                let base = try await TTS.loadModel(
                        fromPreparedDirectory: preparedMetadata.preparedDirectory,
                        modelRepo: descriptor.model.huggingFaceRepo,
                        modelType: preparedMetadata.modelType,
                        trustPreparedCheckpoint: preparedMetadata.trustedPreparedCheckpoint,
                        qwenPreparedLoadBehavior: Self.qwenPreparedLoadBehavior(
                            for: resolvedProfile,
                            trustPreparedCheckpoint: preparedMetadata.trustedPreparedCheckpoint,
                            preparedDirectoryAlreadyValidated: true
                        ),
                        diagnosticEventSink: { action, details in
                            await Self.recordDiagnosticEvent(
                                action,
                                details: details,
                                appSupportDirectoryURL: diagnosticAppSupportBox.url
                            )
                        }
                    )
                await Self.recordDiagnosticEvent(
                    "engine-loader-after-tts-load-model",
                    details: [
                        "descriptorID": descriptor.id,
                        "modelType": preparedMetadata.modelType ?? "",
                        "preparedDirectory": preparedMetadata.preparedDirectory.path,
                        "modelRepo": descriptor.model.huggingFaceRepo,
                        "nativeLoadCapabilityProfile": capabilityProfile.rawValue,
                        "qwenPreparedLoadProfile": Self.diagnosticLabel(for: resolvedProfile),
                        "trustedPreparedCheckpoint": preparedMetadata.trustedPreparedCheckpoint ? "true" : "false",
                    ].merging(preparedMetadata.qwenRuntimeProfile.diagnosticStringFlags()) { _, rhs in rhs },
                    appSupportDirectoryURL: diagnosticAppSupportBox.url
                )
                return try UnsafeSpeechGenerationModel.qwen3Optimized(base: base)
            },
            telemetryRecorder: telemetryRecorder,
            diagnosticEventSink: { action, details in
                await Self.recordDiagnosticEvent(
                    action,
                    details: details,
                    appSupportDirectoryURL: diagnosticAppSupportBox.url
                )
            }
        )
        self.init(
            modelRegistry: modelRegistry,
            modelAssetStore: modelAssetStore,
            audioPreparationService: audioPreparationService,
            documentIO: documentIO,
            streamSessionsDirectory: streamSessionsDirectory,
            loadCoordinator: loadCoordinator,
            telemetryRecorder: telemetryRecorder,
            customPrewarmPolicy: customPrewarmPolicy,
            diagnosticAppSupportBox: diagnosticAppSupportBox,
            streamingSessionFactory: Self.defaultStreamingSessionFactory
        )
    }

    init(
        modelRegistry: any ModelRegistry,
        modelAssetStore: any ModelAssetStore,
        audioPreparationService: any AudioPreparationService,
        documentIO: any DocumentIO,
        streamSessionsDirectory: URL,
        loadCoordinator: any MLXModelCoordinating,
        telemetryRecorder: NativeTelemetryRecorder? = nil,
        customPrewarmPolicy: NativeCustomPrewarmPolicy = .eager,
        diagnosticAppSupportBox: DiagnosticAppSupportBox = DiagnosticAppSupportBox(),
        streamingSessionFactory: @escaping StreamingSessionFactory,
        idleUnloadDelayOverride: Double? = nil
    ) {
        self.modelRegistry = modelRegistry
        self.modelAssetStore = modelAssetStore
        self.audioPreparationService = audioPreparationService
        self.documentIO = documentIO
        self.streamSessionsDirectory = streamSessionsDirectory
        self.telemetryRecorder = telemetryRecorder
        self.diagnosticAppSupportBox = diagnosticAppSupportBox
        self.idleUnloadDelayOverride = idleUnloadDelayOverride
        // Keep enough event history for the XPC forwarder to survive short
        // scheduling stalls, but bound the buffer so diagnostic preview PCM
        // payloads cannot accumulate without limit if the consumer is blocked.
        var capturedContinuation: AsyncStream<GenerationEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(Self.eventStreamBufferLimit)) { continuation in
            capturedContinuation = continuation
        }
        self.eventStreamContinuation = capturedContinuation
        self.runtime = NativeEngineRuntime(
            loadCoordinator: loadCoordinator,
            audioPreparationService: audioPreparationService,
            lightweightWarmupText: Self.lightweightWarmupText,
            telemetryRecorder: telemetryRecorder,
            customPrewarmPolicy: customPrewarmPolicy,
            diagnosticEventSink: { action, details in
                await Self.recordDiagnosticEvent(
                    action,
                    details: details,
                    appSupportDirectoryURL: diagnosticAppSupportBox.url
                )
            }
        )
        self.streamingSessionFactory = streamingSessionFactory
        self.memoryPressureMonitor = NativeMemoryPressureMonitor()
    }

    public func supportDecision(for request: GenerationRequest) -> GenerationSupportDecision {
        guard request.batchIndex == nil, request.batchTotal == nil else {
            return .unsupported(reason: "Batch generation is not available in the native-only app.")
        }

        switch request.payload {
        case .custom, .design, .clone:
            return .supported(.nativeMLX)
        }
    }

    public func start() {}

    public func stop() {
        cancelIdleUnload()
        memoryPressureTask?.cancel()
        memoryPressureTask = nil
        memoryPressureMonitor.stop()
        let runtime = runtime
        Task.detached(priority: .utility) {
            await runtime.configure(normalizedCloneReferenceDirectory: nil, voicesDirectory: nil)
            await runtime.stop()
        }
        isInitialized = false
        appSupportDirectoryURL = nil
        diagnosticAppSupportBox.url = nil
        voicesDirectory = nil
        latestEvent = nil
        loadState = .idle
        visibleErrorMessage = nil
        clonePreparationState = .idle
    }

    /// Subscribe to kernel memory-pressure events on macOS so the engine
    /// can softTrim / hardTrim ahead of allocation failures. Idempotent —
    /// safe to call multiple times. Skipped on `.highMemoryMac` where
    /// there's no value in reacting, and a no-op on iOS where the
    /// IOS-side host (`Sources/iOS/IOSShellPrimitives.swift`) drives its
    /// own monitor with finer per-frame headroom data.
    private func startMemoryPressureMonitorIfNeeded() {
        guard memoryPressureTask == nil else { return }
        let deviceClass = NativeMemoryPolicyResolver.deviceClass()
        guard deviceClass == .floor8GBMac || deviceClass == .mid16GBMac else { return }
        memoryPressureMonitor.start()
        let runtime = runtime
        memoryPressureTask = Task { [memoryPressureMonitor] in
            for await level in memoryPressureMonitor.events {
                await runtime.trimMemory(
                    level: level,
                    reason: "macos_memory_pressure_\(level.rawValue)"
                )
            }
        }
    }

    public func initialize(appSupportDirectory: URL) async throws {
        let voicesDirectory = appSupportDirectory.appendingPathComponent("voices", isDirectory: true)
        let normalizedCloneReferenceDirectory = appSupportDirectory.appendingPathComponent(
            "cache/normalized_clone_refs",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: streamSessionsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: voicesDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: normalizedCloneReferenceDirectory,
            withIntermediateDirectories: true
        )

        appSupportDirectoryURL = appSupportDirectory
        diagnosticAppSupportBox.url = appSupportDirectory
        self.voicesDirectory = voicesDirectory
        await runtime.configure(
            normalizedCloneReferenceDirectory: normalizedCloneReferenceDirectory,
            voicesDirectory: voicesDirectory
        )
        startMemoryPressureMonitorIfNeeded()
        isInitialized = true
        loadState = .idle
        clonePreparationState = .idle
    }

    public func ping() async throws -> Bool {
        isReady
    }

    public func loadModel(id: String) async throws {
        try ensureInitialized()
        cancelIdleUnload()
        do {
            loadState = .starting
            applyMemoryPolicyIfKnown(modelID: id, isBatch: false)
            _ = try await runtime.loadModel(id: id)
            loadState = .loaded(modelID: id)
            clonePreparationState = .idle
            visibleErrorMessage = nil
            scheduleIdleUnloadIfNeeded(modelID: id, isBatch: false)
        } catch {
            // Quality → Speed automatic fallback on the floor8GBMac
            // tier. If a user picked the 8-bit Quality variant on a
            // memory-constrained Mac and it failed to load with an
            // allocation-related error, retry with the Speed sibling
            // and surface a notice. False positives (non-OOM errors
            // mistaken for OOM) only cause a slower run; the user
            // can still pick Quality manually on their next attempt.
            if let speedID = self.speedFallbackID(for: id),
               Self.looksLikeMemoryAllocationError(error) {
                #if DEBUG
                print("[MLXTTSEngine] Quality load failed (\(id)) with allocation error; falling back to Speed sibling (\(speedID)): \(error.localizedDescription)")
                #endif
                do {
                    applyMemoryPolicyIfKnown(modelID: speedID, isBatch: false)
                    _ = try await runtime.loadModel(id: speedID)
                    loadState = .loaded(modelID: speedID)
                    clonePreparationState = .idle
                    visibleErrorMessage = "Switched to Speed (4-bit) — Quality didn't fit in memory."
                    scheduleIdleUnloadIfNeeded(modelID: speedID, isBatch: false)
                    return
                } catch {
                    // The fallback also failed — surface the original
                    // error so the user sees the actionable message,
                    // not a confusing "Speed failed too" cascade.
                    handle(error)
                    throw error
                }
            }
            handle(error)
            throw error
        }
    }

    /// If `id` is a Quality variant on the floor8GBMac tier, return the
    /// matching Speed variant's id. Otherwise return nil. Used by the
    /// OOM-fallback path in `loadModel`.
    private func speedFallbackID(for id: String) -> String? {
        guard NativeMemoryPolicyResolver.deviceClass() == .floor8GBMac else { return nil }
        guard let descriptor = modelRegistry.model(id: id) else { return nil }
        // After expandedForPlatform, a variant-aliased descriptor carries
        // exactly one variant in its `variants` array. We rely on that
        // to detect Quality and look for the Speed sibling.
        guard descriptor.variants.first?.kind == .quality else { return nil }
        // Find a sibling descriptor for the same mode with kind == .speed.
        // Both descriptors come from the same expandedForPlatform pass so
        // their `mode` fields will match.
        for candidate in modelRegistryAllDescriptors() {
            guard candidate.id != descriptor.id,
                  candidate.mode == descriptor.mode,
                  candidate.variants.first?.kind == .speed else { continue }
            return candidate.id
        }
        return nil
    }

    /// Iterate the registry's model descriptors. The `ModelRegistry`
    /// protocol exposes `model(id:)` / `model(for:)` but not a full
    /// list, so we discover siblings by mode + variant kind through
    /// `model(for:)` enumeration over the three known generation modes.
    private func modelRegistryAllDescriptors() -> [ModelDescriptor] {
        var seen: Set<String> = []
        var results: [ModelDescriptor] = []
        for mode in GenerationMode.allCases {
            // model(for:) returns the alias-resolved descriptor (one
            // per mode), not all variants. We rebuild the variant
            // descriptors via the `variants` array on that base.
            guard let base = modelRegistry.model(for: mode) else { continue }
            for variant in base.variants {
                let scopedID = base.variantScopedID(for: variant)
                guard !seen.contains(scopedID) else { continue }
                seen.insert(scopedID)
                if let resolved = modelRegistry.model(id: scopedID) {
                    results.append(resolved)
                }
            }
        }
        return results
    }

    /// Heuristic detection of memory-allocation errors. MLX, Metal, and
    /// the macOS allocator surface OOM as a variety of NSError shapes;
    /// rather than enumerate every domain/code we look for "memory" or
    /// "allocate" in the localized description. False positives only
    /// cause an unnecessary downgrade to Speed; false negatives only
    /// cause the existing error to surface (status quo behavior).
    private static func looksLikeMemoryAllocationError(_ error: Error) -> Bool {
        let message = (error as NSError).localizedDescription.lowercased()
        if message.contains("memory") || message.contains("allocate") || message.contains("allocation") {
            return true
        }
        if let posix = (error as NSError) as NSError?,
           posix.domain == NSPOSIXErrorDomain,
           posix.code == Int(ENOMEM) {
            return true
        }
        return false
    }

    public func unloadModel() async throws {
        cancelIdleUnload()
        await runtime.unloadModel()
        loadState = .idle
        clonePreparationState = .idle
        visibleErrorMessage = nil
    }

    public func prepareAudio(_ request: AudioPreparationRequest) async throws -> AudioNormalizationResult {
        try await audioPreparationService.normalizeAudio(request)
    }

    public func ensureModelLoadedIfNeeded(id: String) async {
        cancelIdleUnload()
        do {
            applyMemoryPolicyIfKnown(modelID: id, isBatch: false)
            _ = try await runtime.loadModel(id: id)
            loadState = .loaded(modelID: id)
            scheduleIdleUnloadIfNeeded(modelID: id, isBatch: false)
        } catch {
            handle(error)
        }
    }

    public func prewarmModelIfNeeded(for request: GenerationRequest) async {
        guard allowsProactiveWarmOperations else { return }
        guard case .supported = supportDecision(for: request) else { return }
        cancelIdleUnload()
        do {
            try ensureInitialized()
            let previousLoadState = loadState
            let shouldPublishStarting = previousLoadState.currentModelID != request.modelID
            if shouldPublishStarting {
                loadState = .starting
            }
            _ = try await runtime.prepareInteractiveReadiness(for: request)
            loadState = .loaded(modelID: request.modelID)
            visibleErrorMessage = nil
            scheduleIdleUnloadIfNeeded(modelID: request.modelID, mode: request.mode, isBatch: false)
        } catch {
            handle(error)
        }
    }

    @discardableResult
    public func prefetchInteractiveReadinessIfNeeded(
        for request: GenerationRequest
    ) async -> InteractivePrefetchDiagnostics? {
        await prefetchInteractiveReadinessIfNeeded(for: request, customPrewarmDepth: nil)
    }

    @discardableResult
    public func prefetchInteractiveReadinessIfNeeded(
        for request: GenerationRequest,
        customPrewarmDepth: String?
    ) async -> InteractivePrefetchDiagnostics? {
        guard allowsProactiveWarmOperations else { return nil }
        guard case .supported = supportDecision(for: request) else { return nil }
        cancelIdleUnload()
        do {
            try ensureInitialized()
            let previousLoadState = loadState
            let shouldPublishStarting = previousLoadState.currentModelID != request.modelID
            if shouldPublishStarting {
                loadState = .starting
            }
            let diagnostics = try await runtime.prepareInteractiveReadiness(
                for: request,
                customPrewarmDepth: customPrewarmDepth
            )
            loadState = .loaded(modelID: request.modelID)
            visibleErrorMessage = nil
            scheduleIdleUnloadIfNeeded(modelID: request.modelID, mode: request.mode, isBatch: false)
            return diagnostics
        } catch {
            // Background prefetch should not interrupt the active UI with an
            // eager surfaced error. The regular generate path will still
            // report actionable failures if the model cannot be used.
            if case .starting = loadState {
                loadState = .idle
            }
            return nil
        }
    }

    public func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {
        guard allowsProactiveWarmOperations else { return }
        try ensureInitialized()
        cancelIdleUnload()

        let requestedTranscript = NativePreparedCloneConditioningCache.normalizedTranscript(
            reference.transcript
        )
        let uiIdentityKey = GenerationSemantics.cloneReferenceIdentityKey(
            modelID: modelID,
            refAudio: reference.audioPath,
            refText: requestedTranscript
        )
        clonePreparationState = ClonePreparationState(
            phase: .preparing,
            identityKey: uiIdentityKey
        )
        loadState = .running(
            modelID: modelID,
            label: EngineActivityLabels.preparingVoiceReference,
            fraction: nil
        )

        do {
            let result = try await runtime.primeCloneReference(
                modelID: modelID,
                reference: reference
            )
            clonePreparationState = ClonePreparationState(
                phase: .primed,
                identityKey: result.uiIdentityKey
            )
            loadState = .loaded(modelID: modelID)
            visibleErrorMessage = nil
            scheduleIdleUnloadIfNeeded(modelID: modelID, mode: .clone, isBatch: false)
        } catch is CancellationError {
            clonePreparationState = .idle
            loadState = .loaded(modelID: modelID)
            throw CancellationError()
        } catch {
            clonePreparationState = ClonePreparationState(
                phase: .failed,
                identityKey: uiIdentityKey,
                message: error.localizedDescription
            )
            handle(error)
            throw error
        }
    }

    public func cancelClonePreparationIfNeeded() async {
        await runtime.cancelClonePreparation()
        clonePreparationState = .idle
        if case .running(let modelID, _, _) = loadState {
            loadState = modelID.map { .loaded(modelID: $0) } ?? .idle
        }
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        try await generate(request, allowsBatchRequest: false)
    }

    public func generateBatch(
        _ requests: [GenerationRequest],
        progressHandler: (@MainActor (Double?, String) -> Void)? = nil
    ) async throws -> [GenerationResult] {
        try ensureInitialized()
        guard !requests.isEmpty else { return [] }
        cancelIdleUnload()
        let firstKey = Self.generationSessionKey(for: requests[0])
        guard requests.allSatisfy({ Self.generationSessionKey(for: $0) == firstKey }) else {
            throw MLXTTSEngineError.unsupportedRequest(
                "Batch generation requires one model, mode, language, speaker/design, and clone reference session."
            )
        }

        var results: [GenerationResult] = []
        results.reserveCapacity(requests.count)
        for (index, request) in requests.enumerated() {
            try Task.checkCancellation()
            progressHandler?(
                Double(index) / Double(max(requests.count, 1)),
                "Generating item \(index + 1)/\(requests.count)"
            )
            let result = try await generate(request, allowsBatchRequest: true)
            results.append(result)
            clearGenerationActivity()
        }
        progressHandler?(1.0, "Done")
        if let trimLevel = NativeMemoryPolicyResolver.postBatchTrimLevel() {
            await runtime.trimMemory(level: trimLevel, reason: "post_batch_low_ram")
            if trimLevel == .hardTrim {
                clonePreparationState = .idle
            }
        }
        scheduleIdleUnloadIfNeeded(
            modelID: requests[0].modelID,
            mode: requests[0].mode,
            isBatch: true
        )
        return results
    }

    private func generate(_ request: GenerationRequest, allowsBatchRequest: Bool) async throws -> GenerationResult {
        try ensureInitialized()
        cancelIdleUnload()
        if !allowsBatchRequest {
            let supportDecision = supportDecision(for: request)
            guard case .supported = supportDecision else {
                throw MLXTTSEngineError.unsupportedRequest(
                    supportDecision.unsupportedReason
                        ?? "The requested generation path is not supported by the native MLX engine."
                )
            }
        }

        do {
            let result = try await runGenerationAttempt(request)
            loadState = .loaded(modelID: request.modelID)
            visibleErrorMessage = nil
            let annotated = Self.annotatingAllocationRetry(
                result,
                streamingUsed: request.shouldStream,
                attempted: false,
                succeeded: false,
                cleanupMS: nil
            )
            scheduleIdleUnloadIfNeeded(
                modelID: request.modelID,
                mode: request.mode,
                isBatch: allowsBatchRequest || request.batchTotal != nil
            )
            return annotated
        } catch {
            if Self.isRetryableAllocationFailure(error) {
                let cleanupStartedAt = ContinuousClock.now
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: request.outputPath))
                Memory.clearCache()
                await runtime.unloadModel()
                let cleanupMS = cleanupStartedAt.elapsedMilliseconds
                do {
                    let retryResult = try await runGenerationAttempt(request)
                    loadState = .loaded(modelID: request.modelID)
                    visibleErrorMessage = nil
                    let annotated = Self.annotatingAllocationRetry(
                        retryResult,
                        streamingUsed: request.shouldStream,
                        attempted: true,
                        succeeded: true,
                        cleanupMS: cleanupMS
                    )
                    scheduleIdleUnloadIfNeeded(
                        modelID: request.modelID,
                        mode: request.mode,
                        isBatch: allowsBatchRequest || request.batchTotal != nil
                    )
                    return annotated
                } catch {
                    let surfacedError = NativeRuntimeError.wrapping(
                        error,
                        stage: .streamStartup,
                        message: "The native runtime could not start audio generation after one allocation retry."
                    )
                    handle(surfacedError)
                    let failureEvent = GenerationEvent.failed(surfacedError.localizedDescription)
                    eventStreamContinuation.yield(failureEvent)
                    latestEvent = failureEvent
                    throw surfacedError
                }
            }
            let surfacedError = NativeRuntimeError.wrapping(
                error,
                stage: .streamStartup,
                message: "The native runtime could not start audio generation."
            )
            handle(surfacedError)
            let failureEvent = GenerationEvent.failed(surfacedError.localizedDescription)
            eventStreamContinuation.yield(failureEvent)
            latestEvent = failureEvent
            throw surfacedError
        }
    }

    private func runGenerationAttempt(_ request: GenerationRequest) async throws -> GenerationResult {
        await telemetryRecorder?.reset()
        loadState = .running(
            modelID: request.modelID,
            label: request.engineActivityLabel,
            fraction: nil
        )

        let prepared = try await runtime.prepareGeneration(for: request)
        let session = streamingSessionFactory(
            prepared.requestID,
            request,
            prepared.model,
            streamSessionsDirectory,
            prepared.warmState,
            prepared.timingOverridesMS,
            prepared.booleanFlags,
            prepared.stringFlags,
            prepared.cloneConditioning,
            prepared.wasPrimed,
            telemetryRecorder,
            prepared.loadCapabilityProfile,
            prepared.memoryPolicy,
            prepared.mlxMemorySnapshots
        )
        return try await session.run { [weak self] event in
            // Yield to the bounded AsyncStream BEFORE the @Published
            // slot. The stream is the chunk-delivery transport; the
            // slot is for snapshot consumers.
            self?.eventStreamContinuation.yield(event)
            self?.latestEvent = event
        }
    }

    private static func annotatingAllocationRetry(
        _ result: GenerationResult,
        streamingUsed: Bool,
        attempted: Bool,
        succeeded: Bool,
        cleanupMS: Int?
    ) -> GenerationResult {
        result
    }

    nonisolated private static func isRetryableAllocationFailure(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        let lowercased = [
            error.localizedDescription,
            String(reflecting: error),
        ]
            .joined(separator: "\n")
            .lowercased()

        if lowercased.contains("out of memory")
            || lowercased.contains("resource exhausted")
            || lowercased.contains("failed to allocate") {
            return true
        }

        let allocationLike = lowercased.contains("allocation")
            || lowercased.contains("allocate")
            || lowercased.contains("memory")
        let mlxOrMetal = lowercased.contains("mlx")
            || lowercased.contains("metal")
            || lowercased.contains("mps")
            || lowercased.contains("gpu")
        return allocationLike && mlxOrMetal
    }

    private static func generationSessionKey(for request: GenerationRequest) -> GenerationSessionKey {
        let language = GenerationSemantics.qwenLanguageHint(for: request)
        switch request.payload {
        case .custom(let speakerID, let deliveryStyle):
            return GenerationSessionKey(
                modelID: request.modelID,
                mode: request.mode,
                language: language,
                speakerOrVoiceDescriptionHash: stableSessionHash(
                    "\(speakerID)|\(deliveryStyle ?? "")"
                )
            )
        case .design(let voiceDescription, let deliveryStyle):
            return GenerationSessionKey(
                modelID: request.modelID,
                mode: request.mode,
                language: language,
                speakerOrVoiceDescriptionHash: stableSessionHash(
                    "\(voiceDescription)|\(deliveryStyle ?? "")"
                )
            )
        case .clone(let reference):
            return GenerationSessionKey(
                modelID: request.modelID,
                mode: request.mode,
                language: language,
                cloneReferenceHash: stableSessionHash(
                    "\(reference.audioPath)|\(reference.transcript ?? "")|\(reference.preparedVoiceID ?? "")"
                )
            )
        }
    }

    private static func stableSessionHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    public func listPreparedVoices() async throws -> [PreparedVoice] {
        try ensureInitialized()
        let voicesDirectory = try requireVoicesDirectory()
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: voicesDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        var voices: [PreparedVoice] = []
        for fileURL in (enumerator.allObjects as? [URL]) ?? [] {
            guard Self.supportedSavedVoiceAudioExtensions.contains(fileURL.pathExtension.lowercased()) else {
                continue
            }
            let transcriptURL = fileURL.deletingPathExtension().appendingPathExtension("txt")
            voices.append(
                PreparedVoice(
                    id: fileURL.deletingPathExtension().lastPathComponent,
                    name: fileURL.deletingPathExtension().lastPathComponent,
                    audioPath: fileURL.path,
                    hasTranscript: fileManager.fileExists(atPath: transcriptURL.path),
                    qualityWarnings: Self.savedReferenceQualityWarnings(forAudioAt: fileURL.path)
                )
            )
        }

        return voices.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Cheap duration-only probe of a saved-voice reference WAV used at
    /// enrollment + list time. Tokens match the
    /// `NativeCloneSupport.referenceQualityWarnings(for:)` schema, but
    /// this path skips the full audio-normalization (resample, trim,
    /// peak/RMS analysis) — those finer warnings come back via
    /// `clone_reference_warnings` at generation time. Thresholds match
    /// NativeCloneSupport: <10 s = short, >20 s = long.
    nonisolated static func savedReferenceQualityWarnings(forAudioAt path: String) -> [String] {
        var warnings: [String] = []
        guard let durationSeconds = referenceAudioDurationSeconds(at: path) else {
            warnings.append("reference_quality_unreadable")
            return warnings
        }
        if durationSeconds < 10 {
            warnings.append("reference_duration_short")
        } else if durationSeconds > 20 {
            warnings.append("reference_duration_long")
        }
        return warnings
    }

    /// Reads the WAV header via `AVAudioFile` (no PCM decode). Returns
    /// `nil` for unreadable files; the caller treats that as a
    /// `reference_quality_unreadable` warning.
    nonisolated static func referenceAudioDurationSeconds(at path: String) -> Double? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
            return nil
        }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(file.length) / sampleRate
    }

    public func enrollPreparedVoice(
        name: String,
        audioPath: String,
        transcript: String?
    ) async throws -> PreparedVoice {
        try ensureInitialized()
        let voicesDirectory = try requireVoicesDirectory()
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: audioPath)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw MLXTTSEngineError.generationFailed("Reference audio file not found.")
        }

        let safeName = NativeSavedVoiceNaming.normalizedName(name)
        guard !safeName.isEmpty else {
            throw MLXTTSEngineError.generationFailed("Invalid saved voice name.")
        }

        try fileManager.createDirectory(at: voicesDirectory, withIntermediateDirectories: true)

        // Preserve the source extension so MP3 / AIFF / M4A bytes don't
        // end up stored under a `.wav` filename. Falls back to `wav` for
        // inputs whose extension is empty or outside the supported set —
        // this preserves the pre-existing behavior for the seed/bootstrap
        // fixtures and matches the fallback the UI pickers expose.
        let sourceExtension = sourceURL.pathExtension.lowercased()
        let destinationExtension = Self.supportedSavedVoiceAudioExtensions.contains(sourceExtension)
            ? sourceExtension
            : "wav"
        let audioDestinationURL = voicesDirectory.appendingPathComponent("\(safeName).\(destinationExtension)")
        let transcriptDestinationURL = voicesDirectory.appendingPathComponent("\(safeName).txt")

        // Disallow the new save if a voice with this `safeName` already
        // exists in ANY supported audio format — otherwise the user could
        // double-up an entry that the list path would render as a single
        // ambiguous row.
        let nameConflictExists = Self.supportedSavedVoiceAudioExtensions.contains { ext in
            fileManager.fileExists(
                atPath: voicesDirectory.appendingPathComponent("\(safeName).\(ext)").path
            )
        } || fileManager.fileExists(atPath: transcriptDestinationURL.path)
        if nameConflictExists {
            throw MLXTTSEngineError.generationFailed(
                "A saved voice named \"\(safeName)\" already exists. Choose a different name."
            )
        }

        try fileManager.copyItem(at: sourceURL, to: audioDestinationURL)
        let normalizedTranscript = NativePreparedCloneConditioningCache.normalizedTranscript(transcript)
        if let normalizedTranscript {
            try normalizedTranscript.write(
                to: transcriptDestinationURL,
                atomically: true,
                encoding: .utf8
            )
        }

        // Audit Finding A (May 2026 dual-variant cleanup): the
        // prior code used `modelRegistry.model(for: .clone)?.id`
        // here, which with the macOS expanded registry returns
        // the BASE alias `pro_clone`. Base alias resolves to the
        // hardware-recommended variant — so on a mid-memory Mac
        // where the user manually selected Speed for clone via
        // the Use button, the prebuild fired with `modelID =
        // "pro_clone"` (alias → Quality folder) while the
        // runtime had `activeModelID = "pro_clone_speed"` from
        // the user's last generation. The runtime's
        // `prebuildSavedVoiceClonePrompt` guards on
        // `activeModelID != modelID` and silently bailed,
        // disabling the optimization entirely for users who
        // picked the non-recommended variant.
        //
        // Fix: read the runtime's currently-loaded model ID from
        // `loadState.currentModelID`. If a clone-mode model is
        // loaded, prebuild for THAT model — which is the user's
        // selected variant by construction (the runtime got
        // there via prewarm / generate, both of which carry
        // variant-scoped IDs from the UI generate path). If no
        // clone model is loaded, skip — the prebuild is a
        // background optimization, not a correctness
        // requirement, and we don't want to evict the user's
        // currently-loaded Custom Voice / Voice Design model
        // just to warm a clone prompt. The first generation
        // after enrollment will prime the prompt explicitly via
        // `ensureCloneReferencePrimed`, so user-perceived
        // latency stays bounded regardless.
        if let normalizedTranscript,
           let activeCloneModelID = loadState.currentModelID,
           modelRegistry.model(id: activeCloneModelID)?.mode == .clone {
            let runtime = runtime
            let cloneReference = CloneReference(
                audioPath: audioDestinationURL.path,
                transcript: normalizedTranscript,
                preparedVoiceID: safeName
            )
            if allowsProactiveWarmOperations {
                Task.detached(priority: .utility) {
                    await runtime.prebuildSavedVoiceClonePrompt(
                        modelID: activeCloneModelID,
                        reference: cloneReference
                    )
                }
            }
        }

        return PreparedVoice(
            id: safeName,
            name: safeName,
            audioPath: audioDestinationURL.path,
            hasTranscript: normalizedTranscript != nil,
            qualityWarnings: Self.savedReferenceQualityWarnings(forAudioAt: audioDestinationURL.path)
        )
    }

    public func deletePreparedVoice(id: String) async throws {
        try ensureInitialized()
        let voicesDirectory = try requireVoicesDirectory()
        let fileManager = FileManager.default

        // Voices may now be stored under any supported audio extension
        // (see `supportedSavedVoiceAudioExtensions`). Find whichever
        // extension this voice's file uses on disk; if no audio file
        // exists in any supported format, the voice doesn't exist.
        let candidateAudioURLs = Self.supportedSavedVoiceAudioExtensions.map { ext in
            voicesDirectory.appendingPathComponent("\(id).\(ext)")
        }
        let existingAudioURLs = candidateAudioURLs.filter {
            fileManager.fileExists(atPath: $0.path)
        }
        let transcriptURL = voicesDirectory.appendingPathComponent("\(id).txt")

        guard !existingAudioURLs.isEmpty else {
            throw MLXTTSEngineError.generationFailed("Voice '\(id)' does not exist.")
        }

        for audioURL in existingAudioURLs {
            try fileManager.removeItem(at: audioURL)
        }
        if fileManager.fileExists(atPath: transcriptURL.path) {
            try? fileManager.removeItem(at: transcriptURL)
        }
        let clonePromptRootDirectory = NativePreparedCloneConditioningCache.preparedVoiceClonePromptRootDirectory(
            in: voicesDirectory,
            voiceID: id
        )
        if fileManager.fileExists(atPath: clonePromptRootDirectory.path) {
            try? fileManager.removeItem(at: clonePromptRootDirectory)
        }
    }

    public func importReferenceAudio(from sourceURL: URL) throws -> ImportedReferenceAudio {
        try documentIO.importReferenceAudio(from: sourceURL)
    }

    public func exportGeneratedAudio(from sourceURL: URL, to destinationURL: URL) throws -> ExportedDocument {
        try documentIO.exportGeneratedAudio(from: sourceURL, to: destinationURL)
    }

    public func clearGenerationActivity() {
        latestEvent = nil
        if case .running(let modelID, _, _) = loadState {
            loadState = modelID.map { .loaded(modelID: $0) } ?? .idle
        }
    }

    public func clearVisibleError() {
        visibleErrorMessage = nil
        if case .failed = loadState {
            loadState = .idle
        }
    }

    public func setVisibleError(_ message: String?) {
        visibleErrorMessage = message
        if let message {
            loadState = .failed(message: message)
        } else if case .failed = loadState {
            loadState = .idle
        }
    }

    public func setAllowsProactiveWarmOperations(_ allow: Bool) {
        allowsProactiveWarmOperations = allow
    }

    public func trimMemory(level: NativeMemoryTrimLevel, reason: String) async {
        if level == .fullUnload {
            cancelIdleUnload()
        }
        await runtime.trimMemory(level: level, reason: reason)

        switch level {
        case .softTrim:
            break
        case .hardTrim:
            clonePreparationState = .idle
        case .fullUnload:
            loadState = .idle
            clonePreparationState = .idle
            visibleErrorMessage = nil
        }
    }

    private func requireVoicesDirectory() throws -> URL {
        guard let voicesDirectory else {
            throw MLXTTSEngineError.notInitialized
        }
        return voicesDirectory
    }

    private func ensureInitialized() throws {
        guard isInitialized else {
            throw MLXTTSEngineError.notInitialized
        }
    }

    private func handle(_ error: Error) {
        visibleErrorMessage = error.localizedDescription
        loadState = .failed(message: error.localizedDescription)
    }

    private static func defaultStreamingSessionFactory(
        requestID: Int,
        request: GenerationRequest,
        model: UnsafeSpeechGenerationModel,
        streamSessionsDirectory: URL,
        warmState: EngineWarmState,
        timingOverridesMS: [String: Int],
        booleanFlags: [String: Bool],
        stringFlags: [String: String],
        cloneConditioning: ResolvedCloneConditioning?,
        wasPrimed: Bool,
        telemetryRecorder: NativeTelemetryRecorder?,
        loadCapabilityProfile: NativeLoadCapabilityProfile,
        memoryPolicy: NativeMemoryPolicy,
        mlxMemorySnapshots: [String: NativeMLXMemorySnapshot]
    ) -> any NativeStreamingSessionRunning {
        NativeStreamingSynthesisSession(
            requestID: requestID,
            request: request,
            model: model,
            streamSessionsDirectory: streamSessionsDirectory,
            warmState: warmState,
            timingOverridesMS: timingOverridesMS,
            booleanFlags: booleanFlags,
            stringFlags: stringFlags,
            cloneConditioning: cloneConditioning,
            wasPrimed: wasPrimed,
            telemetryRecorder: telemetryRecorder,
            loadCapabilityProfile: loadCapabilityProfile,
            memoryPolicy: memoryPolicy,
            mlxMemorySnapshots: mlxMemorySnapshots
        )
    }

    nonisolated private static func diagnosticDetailsString(from details: [String: String]) -> String {
        details
            .keys
            .sorted()
            .map { key in
                "\(key)=\(details[key] ?? "")"
            }
            .joined(separator: "\n")
    }

    nonisolated private static func diagnosticLabel(
        for profile: NativeQwenPreparedLoadProfile
    ) -> String {
        switch profile {
        case .fullCapabilities:
            return "full_capabilities"
        case .withoutCloneEncoders:
            return "without_clone_encoders"
        case .streamingOnly:
            return "without_clone_encoders"
        }
    }

    nonisolated static func resolvedPreparedLoadProfile(
        requestedCapabilityProfile: NativeLoadCapabilityProfile,
        explicitProfile: NativeQwenPreparedLoadProfile
    ) -> NativeQwenPreparedLoadProfile {
        switch explicitProfile {
        case .withoutCloneEncoders, .streamingOnly:
            switch requestedCapabilityProfile {
            case .customOnly, .designOnly:
                return .withoutCloneEncoders
            case .cloneOnly, .fullCapabilities:
                return .fullCapabilities
            }
        case .fullCapabilities:
            return NativeQwenPreparedLoadProfile(capabilityProfile: requestedCapabilityProfile)
        }
    }

    nonisolated static func qwenPreparedLoadBehavior(
        for profile: NativeQwenPreparedLoadProfile,
        trustPreparedCheckpoint: Bool,
        preparedDirectoryAlreadyValidated: Bool = false
    ) -> QwenPreparedLoadBehavior {
        switch profile {
        case .fullCapabilities:
            return QwenPreparedLoadBehavior(
                trustPreparedCheckpoint: trustPreparedCheckpoint,
                preparedDirectoryAlreadyValidated: preparedDirectoryAlreadyValidated
            )
        case .withoutCloneEncoders, .streamingOnly:
            return QwenPreparedLoadBehavior(
                trustPreparedCheckpoint: trustPreparedCheckpoint,
                preparedDirectoryAlreadyValidated: preparedDirectoryAlreadyValidated,
                loadSpeakerEncoder: false,
                loadSpeechTokenizerEncoder: false,
                skipSpeechTokenizerEval: true
            )
        }
    }

    nonisolated private static func recordDiagnosticEvent(
        _ name: String,
        details: [String: String],
        appSupportDirectoryURL: URL?
    ) async {
        // Diagnostic event recording has been retired.
    }
}

final class DiagnosticAppSupportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: URL?

    var url: URL? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
