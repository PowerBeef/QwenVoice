import AVFoundation
import Combine
import Foundation
@preconcurrency import MLX
@preconcurrency import MLXAudioTTS

public enum MLXTTSEngineError: LocalizedError, Equatable {
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

@MainActor
public final class MLXTTSEngine: TTSEngineRuntimeControlling {
    private static let lightweightWarmupText = "Hi."
    public static var lightweightWarmupTextForUI: String { lightweightWarmupText }

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

    /// In-order, lossless stream of every `GenerationEvent` the
    /// engine emits — chunks, completion, failures. Audit Finding
    /// #1 fix: replaces the prior single-slot `latestEvent` +
    /// `objectWillChange` sampling pattern that
    /// `EngineServiceHost` used as its chunk transport. The
    /// AsyncStream's continuation is `unbounded` so back-to-back
    /// emissions (notably the last `.chunk` followed immediately
    /// by `.completed` from
    /// `NativeStreamingSynthesisSession.run`) are buffered without
    /// loss; the consuming `Task { for await event in events }` in
    /// `EngineServiceHost.makeOrReuseRuntimeContext` drains the
    /// stream serially and publishes each event over XPC in the
    /// exact order they were yielded.
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

    public private(set) var visibleErrorMessage: String?

    private let audioPreparationService: any AudioPreparationService
    private let documentIO: any DocumentIO
    private let streamSessionsDirectory: URL
    private let telemetryRecorder: NativeTelemetryRecorder?
    private let diagnosticAppSupportBox: DiagnosticAppSupportBox
    private let runtime: NativeEngineRuntime
    private let streamingSessionFactory: StreamingSessionFactory
    private var isInitialized = false
    private var appSupportDirectoryURL: URL?
    private var voicesDirectory: URL?
    private var allowsProactiveWarmOperations = true

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
        streamingSessionFactory: @escaping StreamingSessionFactory
    ) {
        self.modelRegistry = modelRegistry
        self.modelAssetStore = modelAssetStore
        self.audioPreparationService = audioPreparationService
        self.documentIO = documentIO
        self.streamSessionsDirectory = streamSessionsDirectory
        self.telemetryRecorder = telemetryRecorder
        self.diagnosticAppSupportBox = diagnosticAppSupportBox
        // Audit Finding #1 — initialize the lossless event stream.
        // `bufferingPolicy: .unbounded` is correct here: events are
        // small structs and rare (≈ one per audio chunk on the
        // streaming hot path, plus one final `.completed` and any
        // error events). The XPC consumer in EngineServiceHost
        // drains the stream eagerly, so the buffer never grows
        // beyond a couple of events in practice. The unbounded
        // policy guarantees no drops — which is the entire point
        // of replacing the prior single-slot `latestEvent`
        // sampling path.
        var capturedContinuation: AsyncStream<GenerationEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { continuation in
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
    }

    public func supportDecision(for request: GenerationRequest) -> GenerationSupportDecision {
        guard request.batchIndex == nil, request.batchTotal == nil else {
            return .unsupported(reason: "Batch generation is not available in the native-only app.")
        }
        guard request.shouldStream else {
            return .unsupported(reason: "The native MLX engine currently supports streaming single-generation only.")
        }

        switch request.payload {
        case .custom, .design, .clone:
            return .supported(.nativeMLX)
        }
    }

    public func start() {}

    public func stop() {
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
        isInitialized = true
        loadState = .idle
        clonePreparationState = .idle
    }

    public func ping() async throws -> Bool {
        isReady
    }

    public func loadModel(id: String) async throws {
        try ensureInitialized()
        do {
            loadState = .starting
            _ = try await runtime.loadModel(id: id)
            loadState = .loaded(modelID: id)
            clonePreparationState = .idle
            visibleErrorMessage = nil
        } catch {
            handle(error)
            throw error
        }
    }

    public func unloadModel() async throws {
        await runtime.unloadModel()
        loadState = .idle
        clonePreparationState = .idle
        visibleErrorMessage = nil
    }

    public func prepareAudio(_ request: AudioPreparationRequest) async throws -> AudioNormalizationResult {
        try await audioPreparationService.normalizeAudio(request)
    }

    public func ensureModelLoadedIfNeeded(id: String) async {
        do {
            _ = try await runtime.loadModel(id: id)
            loadState = .loaded(modelID: id)
        } catch {
            handle(error)
        }
    }

    public func prewarmModelIfNeeded(for request: GenerationRequest) async {
        guard allowsProactiveWarmOperations else { return }
        guard case .supported = supportDecision(for: request) else { return }
        do {
            try ensureInitialized()
            loadState = .starting
            _ = try await runtime.prepareInteractiveReadiness(for: request)
            loadState = .loaded(modelID: request.modelID)
            visibleErrorMessage = nil
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
        do {
            try ensureInitialized()
            loadState = .starting
            let diagnostics = try await runtime.prepareInteractiveReadiness(
                for: request,
                customPrewarmDepth: customPrewarmDepth
            )
            loadState = .loaded(modelID: request.modelID)
            visibleErrorMessage = nil
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
        loadState = .running(modelID: modelID, label: "Preparing clone…", fraction: nil)

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
            let batchRequest = request.shouldStream ? request : GenerationRequest(
                mode: request.mode,
                modelID: request.modelID,
                text: request.text,
                outputPath: request.outputPath,
                shouldStream: true,
                streamingInterval: request.streamingInterval,
                batchIndex: request.batchIndex,
                batchTotal: request.batchTotal,
                streamingTitle: request.streamingTitle,
                benchmarkOptions: request.benchmarkOptions,
                payload: request.payload
            )
            let result = try await generate(batchRequest, allowsBatchRequest: true)
            results.append(result)
            clearGenerationActivity()
        }
        progressHandler?(1.0, "Done")
        return results
    }

    private func generate(_ request: GenerationRequest, allowsBatchRequest: Bool) async throws -> GenerationResult {
        try ensureInitialized()
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
            return Self.annotatingAllocationRetry(
                result,
                streamingUsed: request.shouldStream,
                attempted: false,
                succeeded: false,
                cleanupMS: nil
            )
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
                    return Self.annotatingAllocationRetry(
                        retryResult,
                        streamingUsed: request.shouldStream,
                        attempted: true,
                        succeeded: true,
                        cleanupMS: cleanupMS
                    )
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
            label: request.streamingTitle ?? String(request.text.prefix(40)),
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
            // Audit Finding #1 — yield to the lossless AsyncStream
            // BEFORE the @Published slot. The stream is the
            // chunk-delivery transport; the slot is for snapshot
            // consumers. Two distinct concerns. Order matters
            // here only in the failure-mode of these two writes
            // racing with concurrent observers — putting the
            // stream first means the in-order consumer wins by
            // construction, and the slot's @Published observers
            // run on whatever schedule Combine gives them.
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
        var timings: [String: Int] = [:]
        if let cleanupMS {
            timings["allocation_retry_cleanup_ms"] = cleanupMS
        }
        let flags = [
            "allocation_retry_attempted": attempted,
            "allocation_retry_succeeded": succeeded,
        ]
        let strings = attempted ? ["allocation_retry_reason": "mlx_allocation_failure"] : [:]
        let sample = result.benchmarkSample?.mergingBenchmarkFields(
            timingsMS: timings,
            booleanFlags: flags,
            stringFlags: strings
        ) ?? BenchmarkSample(
            streamingUsed: streamingUsed,
            timingsMS: timings,
            booleanFlags: flags,
            stringFlags: strings
        )
        return result.withBenchmarkSample(sample)
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
            guard fileURL.pathExtension.lowercased() == "wav" else { continue }
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
        let audioDestinationURL = voicesDirectory.appendingPathComponent("\(safeName).wav")
        let transcriptDestinationURL = voicesDirectory.appendingPathComponent("\(safeName).txt")

        if fileManager.fileExists(atPath: audioDestinationURL.path)
            || fileManager.fileExists(atPath: transcriptDestinationURL.path) {
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

        if let normalizedTranscript,
           let cloneModelID = modelRegistry.model(for: .clone)?.id {
            let runtime = runtime
            let cloneReference = CloneReference(
                audioPath: audioDestinationURL.path,
                transcript: normalizedTranscript,
                preparedVoiceID: safeName
            )
            if allowsProactiveWarmOperations {
                Task.detached(priority: .utility) {
                    await runtime.prebuildSavedVoiceClonePrompt(
                        modelID: cloneModelID,
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
        let audioURL = voicesDirectory.appendingPathComponent("\(id).wav")
        let transcriptURL = voicesDirectory.appendingPathComponent("\(id).txt")

        guard fileManager.fileExists(atPath: audioURL.path) else {
            throw MLXTTSEngineError.generationFailed("Voice '\(id)' does not exist.")
        }

        try fileManager.removeItem(at: audioURL)
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
        case .streamingOnly:
            return "streaming_only"
        }
    }

    nonisolated private static func resolvedPreparedLoadProfile(
        requestedCapabilityProfile: NativeLoadCapabilityProfile,
        explicitProfile: NativeQwenPreparedLoadProfile
    ) -> NativeQwenPreparedLoadProfile {
        switch explicitProfile {
        case .streamingOnly:
            return .streamingOnly
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
        case .streamingOnly:
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
