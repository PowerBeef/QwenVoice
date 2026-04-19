import Foundation
import MLX
@preconcurrency import MLXAudioCore
@preconcurrency import MLXAudioTTS

enum NativeRuntimeStage: String, Codable, Sendable {
    case preparedCacheValidation
    case preparedCacheRebuild
    case tokenizerPreparation
    case upstreamModelLoad
    case prewarm
    case clonePreparation
    case streamStartup
    case firstChunk
    case streamCompleted
    case streamFailed
    case unload

    var description: String {
        switch self {
        case .preparedCacheValidation:
            return "prepared cache validation"
        case .preparedCacheRebuild:
            return "prepared cache rebuild"
        case .tokenizerPreparation:
            return "tokenizer preparation"
        case .upstreamModelLoad:
            return "native model load"
        case .prewarm:
            return "model warm-up"
        case .clonePreparation:
            return "clone preparation"
        case .streamStartup:
            return "generation startup"
        case .firstChunk:
            return "first stream chunk"
        case .streamCompleted:
            return "generation completion"
        case .streamFailed:
            return "generation failure"
        case .unload:
            return "runtime unload"
        }
    }
}

struct NativeRuntimeError: LocalizedError, Sendable {
    let stage: NativeRuntimeStage
    let message: String
    let underlyingDescription: String?

    init(
        stage: NativeRuntimeStage,
        message: String,
        underlying: Error? = nil
    ) {
        self.stage = stage
        self.message = message
        self.underlyingDescription = underlying.map { String(reflecting: $0) }
    }

    var errorDescription: String? {
        message
    }

    static func wrapping(
        _ error: Error,
        stage: NativeRuntimeStage,
        message: String
    ) -> NativeRuntimeError {
        if let runtimeError = error as? NativeRuntimeError {
            return runtimeError
        }
        return NativeRuntimeError(
            stage: stage,
            message: "\(message) (\(stage.description)). \(error.localizedDescription)",
            underlying: error
        )
    }
}

struct NativePreparedGeneration: Sendable {
    let requestID: Int
    let model: UnsafeSpeechGenerationModel
    let warmState: EngineWarmState
    let timingOverridesMS: [String: Int]
    let booleanFlags: [String: Bool]
    let stringFlags: [String: String]
    let cloneConditioning: ResolvedCloneConditioning?
    let wasPrimed: Bool
}

public struct InteractivePrefetchDiagnostics: Codable, Sendable {
    public let timingsMS: [String: Int]
    public let booleanFlags: [String: Bool]
    public let requestKey: String?

    public init(
        timingsMS: [String: Int],
        booleanFlags: [String: Bool],
        requestKey: String?
    ) {
        self.timingsMS = timingsMS
        self.booleanFlags = booleanFlags
        self.requestKey = requestKey
    }
}

struct NativeClonePrimeResult: Sendable {
    let uiIdentityKey: String
}

actor NativeEngineRuntime {
    private enum DesignConditioningWarmSource: String, Sendable {
        case prefetch
        case generation
    }

    private let loadCoordinator: any MLXModelCoordinating
    private let audioPreparationService: any AudioPreparationService
    private let preparedCloneConditioningCache: NativePreparedCloneConditioningCache
    private let lightweightWarmupText: String
    private let telemetryRecorder: NativeTelemetryRecorder?
    private let customPrewarmPolicy: NativeCustomPrewarmPolicy
    private let diagnosticEventSink: (@Sendable (String, [String: String]) async -> Void)?

    private var normalizedCloneReferenceDirectory: URL?
    private var voicesDirectory: URL?
    private var activeModelID: String?
    private var primedCloneReferenceKeys: Set<String> = []
    private var clonePrimeTimingOverridesMS: [String: [String: Int]] = [:]
    private var activeClonePrimeToken: UUID?
    private var activeDesignConditioningWarmKey: String?
    private var activeDesignConditioningWarmSource: DesignConditioningWarmSource?
    private var activeDesignStreamStepWarmKey: String?
    private var activeDesignStreamStepWarmSource: DesignConditioningWarmSource?
    private var activeCloneConditioningKey: String?
    private var nextRequestID = 1

    init(
        loadCoordinator: any MLXModelCoordinating,
        audioPreparationService: any AudioPreparationService,
        preparedCloneConditioningCache: NativePreparedCloneConditioningCache = NativePreparedCloneConditioningCache(),
        lightweightWarmupText: String,
        telemetryRecorder: NativeTelemetryRecorder? = nil,
        customPrewarmPolicy: NativeCustomPrewarmPolicy = .eager,
        diagnosticEventSink: (@Sendable (String, [String: String]) async -> Void)? = nil
    ) {
        self.loadCoordinator = loadCoordinator
        self.audioPreparationService = audioPreparationService
        self.preparedCloneConditioningCache = preparedCloneConditioningCache
        self.lightweightWarmupText = lightweightWarmupText
        self.telemetryRecorder = telemetryRecorder
        self.customPrewarmPolicy = customPrewarmPolicy
        self.diagnosticEventSink = diagnosticEventSink
    }

    func configure(normalizedCloneReferenceDirectory: URL?, voicesDirectory: URL? = nil) {
        self.normalizedCloneReferenceDirectory = normalizedCloneReferenceDirectory
        self.voicesDirectory = voicesDirectory
    }

    func stop() async {
        activeClonePrimeToken = nil
        await loadCoordinator.unloadModel()
        activeModelID = nil
        await clearCloneState()
        await telemetryRecorder?.mark(stage: .unload)
    }

    func loadModel(id: String) async throws -> NativeModelLoadResult {
        try await loadModel(id: id, preserveActiveClonePrimeToken: false)
    }

    func unloadModel() async {
        await loadCoordinator.unloadModel()
        activeModelID = nil
        await clearCloneState()
        await telemetryRecorder?.mark(stage: .unload)
    }

    func trimMemory(level: NativeMemoryTrimLevel, reason: String) async {
        await telemetryRecorder?.mark(stage: "memory_trim", metadata: [
            "level": level.rawValue,
            "reason": reason,
        ])

        switch level {
        case .softTrim:
            await preparedCloneConditioningCache.softTrim(retainingMostRecent: 1)
            Memory.clearCache()
        case .hardTrim:
            await preparedCloneConditioningCache.clear()
            await loadCoordinator.clearPrewarmState()
            activeDesignConditioningWarmKey = nil
            activeDesignConditioningWarmSource = nil
            activeDesignStreamStepWarmKey = nil
            activeDesignStreamStepWarmSource = nil
            activeCloneConditioningKey = nil
            primedCloneReferenceKeys.removeAll()
            clonePrimeTimingOverridesMS.removeAll()
            Memory.clearCache()
        case .fullUnload:
            await unloadModel()
        }
    }

    func prepareInteractiveReadiness(for request: GenerationRequest) async throws -> InteractivePrefetchDiagnostics {
        let prefetchStartedAt = ContinuousClock.now
        let identityKey = prewarmIdentityKey(for: request)
        let loadResult = try await loadModel(id: request.modelID, preserveActiveClonePrimeToken: false)
        loadResult.model.resetPreparationDiagnostics()
        var booleanFlags = loadResult.booleanFlags
        var timingsMS: [String: Int] = [
            "interactive_prefetch_load_model_ms": loadResult.didLoad ? prefetchStartedAt.elapsedMilliseconds : 0
        ]
        var conditioningPrepareMS = 0
        var requestKey: String?

        switch request.payload {
        case .custom:
            if shouldSkipDedicatedCustomPrewarm(for: request, model: loadResult.model) {
                booleanFlags["custom_dedicated_prewarm_skipped"] = true
            } else {
                let genericWarmReady: Bool
                if let identityKey, activeModelID == request.modelID {
                    genericWarmReady = await loadCoordinator.isPrewarmed(identityKey: identityKey)
                } else {
                    genericWarmReady = false
                }
                if !genericWarmReady {
                    _ = try await ensureWarmStateIfNeeded(
                        for: request,
                        model: loadResult.model
                    )
                    booleanFlags.merge(loadResult.model.latestPreparationBooleanFlags) { _, rhs in rhs }
                }
            }
        case .design:
            let conditioningStartedAt = ContinuousClock.now
            let warmState = try await ensureDesignConditioningWarmStateIfNeeded(
                for: request,
                model: loadResult.model,
                source: .prefetch
            )
            conditioningPrepareMS = warmState.prewarmed ? conditioningStartedAt.elapsedMilliseconds : 0
            requestKey = warmState.requestKey.isEmpty ? nil : warmState.requestKey
            booleanFlags.merge(loadResult.model.latestPreparationBooleanFlags) { _, rhs in rhs }
            booleanFlags["design_conditioning_reused"] = warmState.reused
            booleanFlags["design_conditioning_prefetch_hit"] = warmState.prefetchHit
            booleanFlags["interactive_design_prefetch_hit"] = warmState.prefetchHit
            booleanFlags["design_conditioning_prewarmed"] = warmState.prewarmed
            booleanFlags["design_stream_step_prewarmed"] = warmState.streamStepPrewarmed
            booleanFlags["design_stream_step_prefetch_hit"] = warmState.streamStepPrefetchHit
            if let streamStepWarmMS = loadResult.model.latestPreparationTimingsMS["design_stream_step_warm_ms"] {
                timingsMS["design_stream_step_warm_ms"] = streamStepWarmMS
            }
        case .clone:
            break
        }

        timingsMS["interactive_prefetch_conditioning_prepare_ms"] = conditioningPrepareMS
        timingsMS["interactive_prefetch_total_ms"] = prefetchStartedAt.elapsedMilliseconds
        return InteractivePrefetchDiagnostics(
            timingsMS: timingsMS,
            booleanFlags: booleanFlags,
            requestKey: requestKey
        )
    }

    func prepareGeneration(for request: GenerationRequest) async throws -> NativePreparedGeneration {
        await recordDiagnosticEvent(
            "runtime-prepare-before-load-model",
            request: request
        )
        let loadStartedAt = ContinuousClock.now
        let loadResult = try await loadModel(id: request.modelID, preserveActiveClonePrimeToken: false)
        await recordDiagnosticEvent(
            "runtime-prepare-after-load-model",
            request: request,
            extra: [
                "didLoad": loadResult.didLoad ? "true" : "false",
            ]
        )
        let model = loadResult.model
        model.resetPreparationDiagnostics()
        await recordDiagnosticEvent(
            "runtime-prepare-after-reset-preparation-diagnostics",
            request: request
        )
        var timingOverridesMS = loadResult.timingsMS
        var booleanFlags = loadResult.booleanFlags
        var stringFlags: [String: String] = [:]

        if loadResult.didLoad {
            timingOverridesMS["load_model"] = loadStartedAt.elapsedMilliseconds
        }

        let cloneConditioning: ResolvedCloneConditioning?
        let wasPrimed: Bool
        switch request.payload {
        case .clone(let reference):
            var conditioning = try await resolveCloneConditioning(
                modelID: request.modelID,
                reference: reference,
                sampleRate: model.sampleRate
            )
            conditioning = try await preparedCloneConditioningCache.resolveVoiceClonePrompt(
                for: conditioning,
                modelID: request.modelID,
                model: model,
                voicesDirectory: voicesDirectory
            )
            cloneConditioning = conditioning
            wasPrimed = primedCloneReferenceKeys.contains(conditioning.internalIdentityKey)
            timingOverridesMS.merge(conditioning.timingsMS) { current, _ in current }
            let cloneConditioningReused = conditioning.cloneConditioningReused
                || activeCloneConditioningKey == conditioning.internalIdentityKey
            booleanFlags["clone_conditioning_reused"] = cloneConditioningReused
            activeCloneConditioningKey = conditioning.internalIdentityKey
            if wasPrimed,
               let primeTimings = clonePrimeTimingOverridesMS[conditioning.internalIdentityKey] {
                timingOverridesMS.merge(primeTimings) { current, _ in current }
            } else {
                let prewarmTimings = try await ensureWarmStateIfNeeded(
                    for: request,
                    model: model,
                    cloneConditioning: conditioning
                )
                timingOverridesMS.merge(prewarmTimings) { _, rhs in rhs }
                booleanFlags.merge(model.latestPreparationBooleanFlags) { _, rhs in rhs }
            }
        case .custom:
            await recordDiagnosticEvent(
                "runtime-prepare-custom-entered",
                request: request,
                extra: [
                    "supportsDedicatedCustomVoice": model.supportsDedicatedCustomVoice ? "true" : "false",
                    "customPrewarmPolicy": customPrewarmPolicyLabel,
                ]
            )
            cloneConditioning = nil
            wasPrimed = false
            if shouldSkipDedicatedCustomPrewarm(for: request, model: model) {
                booleanFlags["custom_dedicated_prewarm_skipped"] = true
                await recordDiagnosticEvent(
                    "runtime-prepare-custom-skip-dedicated-prewarm",
                    request: request
                )
            } else {
                let prewarmTimings = try await ensureWarmStateIfNeeded(
                    for: request,
                    model: model
                )
                timingOverridesMS.merge(prewarmTimings) { _, rhs in rhs }
                booleanFlags.merge(model.latestPreparationBooleanFlags) { _, rhs in rhs }
            }
            booleanFlags["custom_dedicated_handler_used"] = model.supportsDedicatedCustomVoice
        case .design:
            cloneConditioning = nil
            wasPrimed = false
            let warmState = try await ensureDesignConditioningWarmStateIfNeeded(
                for: request,
                model: model,
                source: .generation
            )
            timingOverridesMS.merge(model.latestPreparationTimingsMS) { _, rhs in rhs }
            booleanFlags.merge(model.latestPreparationBooleanFlags) { _, rhs in rhs }
            let warmBucket = warmState.bucket
            booleanFlags["design_conditioning_reused"] = warmState.reused
            booleanFlags["design_conditioning_prefetch_hit"] = warmState.prefetchHit
            booleanFlags["interactive_design_prefetch_hit"] = warmState.prefetchHit
            booleanFlags["design_conditioning_prewarmed"] = warmState.prewarmed
            booleanFlags["design_stream_step_prewarmed"] = warmState.streamStepPrewarmed
            booleanFlags["design_stream_step_prefetch_hit"] = warmState.streamStepPrefetchHit
            booleanFlags["design_warm_bucket_short"] = warmBucket == .short
            booleanFlags["design_warm_bucket_long"] = warmBucket == .long
            stringFlags["design_conditioning_request_key"] = warmState.requestKey
        }

        if cloneConditioning?.cloneCacheHit != nil {
            booleanFlags["prepared_clone_cache_hit"] = cloneConditioning?.cloneCacheHit ?? false
        }

        await recordDiagnosticEvent(
            "runtime-prepare-before-return",
            request: request,
            extra: [
                "customDedicatedHandlerUsed": booleanFlags["custom_dedicated_handler_used"] == true ? "true" : "false",
                "customDedicatedPrewarmSkipped": booleanFlags["custom_dedicated_prewarm_skipped"] == true ? "true" : "false",
            ]
        )

        return NativePreparedGeneration(
            requestID: takeNextRequestID(),
            model: model,
            warmState: loadResult.didLoad ? .cold : .warm,
            timingOverridesMS: timingOverridesMS,
            booleanFlags: booleanFlags,
            stringFlags: stringFlags,
            cloneConditioning: cloneConditioning,
            wasPrimed: wasPrimed
        )
    }

    func primeCloneReference(
        modelID: String,
        reference: CloneReference
    ) async throws -> NativeClonePrimeResult {
        let token = UUID()
        activeClonePrimeToken = token
        defer {
            if activeClonePrimeToken == token {
                activeClonePrimeToken = nil
            }
        }

        let loadStartedAt = ContinuousClock.now
        let loadResult = try await loadModel(id: modelID, preserveActiveClonePrimeToken: true)
        let model = loadResult.model
        try ensureActiveClonePrimeToken(token)

        let conditioning = try await resolveCloneConditioning(
            modelID: modelID,
            reference: reference,
            sampleRate: model.sampleRate
        )
        let resolvedConditioning = try await preparedCloneConditioningCache.resolveVoiceClonePrompt(
            for: conditioning,
            modelID: modelID,
            model: model,
            voicesDirectory: voicesDirectory
        )
        try ensureActiveClonePrimeToken(token)

        if primedCloneReferenceKeys.contains(resolvedConditioning.internalIdentityKey) {
            return NativeClonePrimeResult(uiIdentityKey: resolvedConditioning.uiIdentityKey)
        }

        activeCloneConditioningKey = resolvedConditioning.internalIdentityKey

        var timingOverrides = loadResult.timingsMS
        timingOverrides.merge(resolvedConditioning.timingsMS) { _, rhs in rhs }
        if loadResult.didLoad {
            timingOverrides["load_model"] = loadStartedAt.elapsedMilliseconds
        }

        let primeTimings = try await primeCloneConditioning(
            model: model,
            conditioning: resolvedConditioning,
            language: GenerationSemantics.qwenLanguageHint(
                for: GenerationRequest(
                    mode: .clone,
                    modelID: modelID,
                    text: lightweightWarmupText,
                    outputPath: "",
                    shouldStream: true,
                    payload: .clone(reference: reference)
                ),
                resolvedCloneTranscript: resolvedConditioning.resolvedTranscript
            ),
            token: token
        )
        timingOverrides.merge(primeTimings) { _, rhs in rhs }
        clonePrimeTimingOverridesMS[resolvedConditioning.internalIdentityKey] = timingOverrides
        primedCloneReferenceKeys.insert(resolvedConditioning.internalIdentityKey)
        return NativeClonePrimeResult(uiIdentityKey: resolvedConditioning.uiIdentityKey)
    }

    func cancelClonePreparation() {
        activeClonePrimeToken = nil
    }

    func prebuildSavedVoiceClonePrompt(
        modelID: String,
        reference: CloneReference
    ) async {
        guard reference.preparedVoiceID != nil else { return }
        if let activeModelID, activeModelID != modelID {
            return
        }
        if let preparedVoiceID = reference.preparedVoiceID,
           await preparedCloneConditioningCache.hasPersistedVoiceClonePromptArtifact(
               modelID: modelID,
               preparedVoiceID: preparedVoiceID,
               voicesDirectory: voicesDirectory
           ) {
            return
        }

        do {
            let loadResult = try await loadModel(id: modelID, preserveActiveClonePrimeToken: true)
            let conditioning = try await resolveCloneConditioning(
                modelID: modelID,
                reference: reference,
                sampleRate: loadResult.model.sampleRate
            )
            _ = try await preparedCloneConditioningCache.resolveVoiceClonePrompt(
                for: conditioning,
                modelID: modelID,
                model: loadResult.model,
                voicesDirectory: voicesDirectory
            )
        } catch {
            return
        }
    }

    private func loadModel(
        id: String,
        preserveActiveClonePrimeToken: Bool
    ) async throws -> NativeModelLoadResult {
        do {
            let loadResult = try await loadCoordinator.loadModel(id: id)
            if loadResult.didLoad {
                activeModelID = id
                await clearCloneState(preserveActiveClonePrimeToken: preserveActiveClonePrimeToken)
            }
            return loadResult
        } catch {
            await loadCoordinator.unloadModel()
            activeModelID = nil
            await clearCloneState(preserveActiveClonePrimeToken: preserveActiveClonePrimeToken)
            throw NativeRuntimeError.wrapping(
                error,
                stage: .upstreamModelLoad,
                message: "The native runtime could not load model '\(id)'"
            )
        }
    }

    private func resolveCloneConditioning(
        modelID: String,
        reference: CloneReference,
        sampleRate: Int
    ) async throws -> ResolvedCloneConditioning {
        do {
            await telemetryRecorder?.mark(stage: .clonePreparation)
            return try await preparedCloneConditioningCache.resolve(
                modelID: modelID,
                reference: reference,
                sampleRate: sampleRate,
                audioPreparationService: audioPreparationService,
                normalizedCloneReferenceDirectory: try requireNormalizedCloneReferenceDirectory()
            )
        } catch {
            throw NativeRuntimeError.wrapping(
                error,
                stage: .clonePreparation,
                message: "The native runtime could not prepare the clone reference"
            )
        }
    }

    private func ensureWarmStateIfNeeded(
        for request: GenerationRequest,
        model: UnsafeSpeechGenerationModel,
        cloneConditioning: ResolvedCloneConditioning? = nil
    ) async throws -> [String: Int] {
        if shouldSkipDedicatedCustomPrewarm(for: request, model: model) {
            return [:]
        }

        let identityKey: String
        switch request.payload {
        case .custom, .design:
            guard let requestIdentityKey = prewarmIdentityKey(for: request) else {
                return [:]
            }
            identityKey = requestIdentityKey
        case .clone:
            guard let cloneConditioning else {
                throw NativeRuntimeError(
                    stage: .clonePreparation,
                    message: "Clone generation needs resolved native clone conditioning."
                )
            }
            identityKey = cloneConditioning.internalIdentityKey
        }

        guard !(await loadCoordinator.isPrewarmed(identityKey: identityKey)) else {
            return [:]
        }

        let prewarmStartedAt = ContinuousClock.now
        do {
            await telemetryRecorder?.mark(stage: .prewarm)
            switch request.payload {
            case .custom(let speakerID, let deliveryStyle):
                let language = GenerationSemantics.qwenLanguageHint(for: request)
                let speaker = speakerID.trimmingCharacters(in: .whitespacesAndNewlines)
                if model.supportsDedicatedCustomVoice {
                    try await model.prewarmCustomVoice(
                        text: lightweightWarmupText,
                        language: language,
                        speaker: GenerationSemantics.canonicalCustomWarmSpeaker,
                        instruct: GenerationSemantics.canonicalCustomWarmInstruction()
                    )
                } else {
                    try await model.prewarm(
                        text: lightweightWarmupText,
                        voice: Self.fallbackCustomVoice(
                            speaker: speaker,
                            instruct: GenerationSemantics.customInstruction(deliveryStyle: deliveryStyle)
                        )
                    )
                }
            case .design:
                let language = GenerationSemantics.qwenLanguageHint(for: request)
                if model.supportsOptimizedVoiceDesign {
                    try await model.prewarmVoiceDesign(
                        text: lightweightWarmupText,
                        language: language,
                        voiceDescription: GenerationSemantics.canonicalDesignWarmInstruction()
                    )
                } else {
                    try await model.prewarm(
                        text: lightweightWarmupText,
                        voice: GenerationSemantics.canonicalDesignWarmInstruction()
                    )
                }
            case .clone:
                guard let cloneConditioning else {
                    throw NativeRuntimeError(
                        stage: .clonePreparation,
                        message: "Clone generation needs resolved native clone conditioning."
                    )
                }
                let language = GenerationSemantics.qwenLanguageHint(
                    for: request,
                    resolvedCloneTranscript: cloneConditioning.resolvedTranscript
                )
                if let voiceClonePrompt = cloneConditioning.voiceClonePrompt,
                   model.supportsOptimizedVoiceClone {
                    try await model.prewarmVoiceClone(
                        text: lightweightWarmupText,
                        language: language,
                        voiceClonePrompt: voiceClonePrompt
                    )
                } else {
                    try await model.prewarm(
                        text: lightweightWarmupText,
                        voice: nil,
                        refAudio: cloneConditioning.referenceAudio,
                        refText: cloneConditioning.resolvedTranscript
                    )
                }
            }
            await loadCoordinator.markPrewarmed(identityKey: identityKey)
            var timings = model.latestPreparationTimingsMS
            timings["prewarm_model"] = prewarmStartedAt.elapsedMilliseconds
            return timings
        } catch {
            await loadCoordinator.unloadModel()
            activeModelID = nil
            await clearCloneState()
            throw NativeRuntimeError.wrapping(
                error,
                stage: .prewarm,
                message: "The native runtime could not warm model '\(request.modelID)'"
            )
        }
    }

    private func shouldSkipDedicatedCustomPrewarm(
        for request: GenerationRequest,
        model: UnsafeSpeechGenerationModel
    ) -> Bool {
        guard case .custom = request.payload else {
            return false
        }
        guard model.supportsDedicatedCustomVoice else {
            return false
        }
        return customPrewarmPolicy == .skipDedicatedCustomPrewarm
    }

    private var customPrewarmPolicyLabel: String {
        switch customPrewarmPolicy {
        case .eager:
            return "eager"
        case .skipDedicatedCustomPrewarm:
            return "skipDedicatedCustomPrewarm"
        }
    }

    private func recordDiagnosticEvent(
        _ action: String,
        request: GenerationRequest,
        extra: [String: String] = [:]
    ) async {
        guard let diagnosticEventSink else {
            return
        }

        var details: [String: String] = [
            "mode": request.mode.rawValue,
            "modelID": request.modelID,
            "textLength": String(request.text.count),
        ]

        switch request.payload {
        case .custom(let speakerID, let deliveryStyle):
            details["speaker"] = speakerID
            if let deliveryStyle {
                details["deliveryStyle"] = deliveryStyle
            }
        case .design(let voiceDescription, let deliveryStyle):
            details["voiceDescriptionLength"] = String(voiceDescription.count)
            if let deliveryStyle {
                details["deliveryStyle"] = deliveryStyle
            }
        case .clone:
            break
        }

        details.merge(extra) { _, rhs in rhs }
        await diagnosticEventSink(action, details)
    }

    private func primeCloneConditioning(
        model: UnsafeSpeechGenerationModel,
        conditioning: ResolvedCloneConditioning,
        language: String,
        token: UUID
    ) async throws -> [String: Int] {
        let startedAt = ContinuousClock.now
        var firstChunkMS: Int?
        let stream: AsyncThrowingStream<AudioGeneration, Error>
        if let voiceClonePrompt = conditioning.voiceClonePrompt,
           model.supportsOptimizedVoiceClone {
            stream = model.generateVoiceCloneStream(
                text: lightweightWarmupText,
                language: language,
                voiceClonePrompt: voiceClonePrompt,
                streamingInterval: GenerationSemantics.appStreamingInterval
            )
        } else {
            stream = model.generateStream(
                text: lightweightWarmupText,
                voice: nil as String?,
                refAudio: conditioning.referenceAudio,
                refText: conditioning.resolvedTranscript,
                streamingInterval: GenerationSemantics.appStreamingInterval
            )
        }

        for try await event in stream {
            try ensureActiveClonePrimeToken(token)
            switch event {
            case .audio(let samples):
                let chunkSamples = samples.asArray(Float.self)
                guard !chunkSamples.isEmpty else { continue }
                if firstChunkMS == nil {
                    firstChunkMS = startedAt.elapsedMilliseconds
                }
            case .token, .info:
                continue
            }

            if firstChunkMS != nil {
                break
            }
        }

        guard firstChunkMS != nil else {
            throw NativeRuntimeError(
                stage: .prewarm,
                message: "Clone priming produced no streaming chunk."
            )
        }

        var timings = model.latestPreparationTimingsMS
        timings["prime_clone_reference"] = startedAt.elapsedMilliseconds
        return timings
    }

    private struct DesignConditioningWarmState: Sendable {
        let bucket: GenerationSemantics.DesignWarmBucket
        let requestKey: String
        let reused: Bool
        let prefetchHit: Bool
        let prewarmed: Bool
        let streamStepPrewarmed: Bool
        let streamStepPrefetchHit: Bool
    }

    private func ensureDesignConditioningWarmStateIfNeeded(
        for request: GenerationRequest,
        model: UnsafeSpeechGenerationModel,
        source: DesignConditioningWarmSource
    ) async throws -> DesignConditioningWarmState {
        guard case .design(let voiceDescription, let deliveryStyle) = request.payload else {
            return DesignConditioningWarmState(
                bucket: .short,
                requestKey: "",
                reused: false,
                prefetchHit: false,
                prewarmed: false,
                streamStepPrewarmed: false,
                streamStepPrefetchHit: false
            )
        }

        let trimmedVoiceDescription = voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let warmBucket = GenerationSemantics.designWarmBucket(for: request.text)
        guard !trimmedVoiceDescription.isEmpty else {
            return DesignConditioningWarmState(
                bucket: warmBucket,
                requestKey: "",
                reused: false,
                prefetchHit: false,
                prewarmed: false,
                streamStepPrewarmed: false,
                streamStepPrefetchHit: false
            )
        }

        let language = GenerationSemantics.qwenLanguageHint(for: request)
        guard let conditioningWarmKey = GenerationSemantics.designConditioningWarmKey(for: request) else {
            return DesignConditioningWarmState(
                bucket: warmBucket,
                requestKey: "",
                reused: false,
                prefetchHit: false,
                prewarmed: false,
                streamStepPrewarmed: false,
                streamStepPrefetchHit: false
            )
        }
        let reused = activeDesignConditioningWarmKey == conditioningWarmKey
        if reused {
            await markDesignWarmSatisfied(
                for: request,
                conditioningWarmKey: conditioningWarmKey
            )
            return DesignConditioningWarmState(
                bucket: warmBucket,
                requestKey: conditioningWarmKey,
                reused: true,
                prefetchHit: activeDesignConditioningWarmSource == .prefetch,
                prewarmed: false,
                streamStepPrewarmed: false,
                streamStepPrefetchHit: activeDesignStreamStepWarmKey == conditioningWarmKey
                    && activeDesignStreamStepWarmSource == .prefetch
            )
        }

        let warmText = GenerationSemantics.canonicalDesignWarmText(for: warmBucket)
        let warmInstruction = GenerationSemantics.designInstruction(
            voiceDescription: voiceDescription,
            emotion: deliveryStyle ?? ""
        )
        do {
            if model.supportsOptimizedVoiceDesign {
                try await model.prewarmVoiceDesign(
                    text: warmText,
                    language: language,
                    voiceDescription: warmInstruction
                )
            } else {
                try await model.prewarm(
                    text: warmText,
                    voice: warmInstruction
                )
            }
            activeDesignConditioningWarmKey = conditioningWarmKey
            activeDesignConditioningWarmSource = source
            let streamStepPrewarmed = model.latestPreparationBooleanFlags["design_stream_step_prewarmed"] == true
            if streamStepPrewarmed {
                activeDesignStreamStepWarmKey = conditioningWarmKey
                activeDesignStreamStepWarmSource = source
            } else {
                activeDesignStreamStepWarmKey = nil
                activeDesignStreamStepWarmSource = nil
            }
            await markDesignWarmSatisfied(
                for: request,
                conditioningWarmKey: conditioningWarmKey
            )
            return DesignConditioningWarmState(
                bucket: warmBucket,
                requestKey: conditioningWarmKey,
                reused: false,
                prefetchHit: false,
                prewarmed: true,
                streamStepPrewarmed: streamStepPrewarmed,
                streamStepPrefetchHit: false
            )
        } catch {
            await loadCoordinator.unloadModel()
            activeModelID = nil
            await clearCloneState()
            throw NativeRuntimeError.wrapping(
                error,
                stage: .prewarm,
                message: "The native runtime could not warm the design conditioning for '\(request.modelID)'"
            )
        }
    }

    private func markDesignWarmSatisfied(
        for request: GenerationRequest,
        conditioningWarmKey: String
    ) async {
        await loadCoordinator.markPrewarmed(identityKey: conditioningWarmKey)
        if let identityKey = prewarmIdentityKey(for: request) {
            await loadCoordinator.markPrewarmed(identityKey: identityKey)
        }
    }

    private func prewarmIdentityKey(for request: GenerationRequest) -> String? {
        switch request.payload {
        case .custom:
            return GenerationSemantics.prewarmIdentityKey(
                modelID: request.modelID,
                mode: request.mode
            )
        case .design:
            return GenerationSemantics.prewarmIdentityKey(
                modelID: request.modelID,
                mode: request.mode
            )
        case .clone:
            return nil
        }
    }

    private func clearCloneState(
        preserveActiveClonePrimeToken: Bool = false
    ) async {
        await preparedCloneConditioningCache.clear()
        activeDesignConditioningWarmKey = nil
        activeDesignConditioningWarmSource = nil
        activeDesignStreamStepWarmKey = nil
        activeDesignStreamStepWarmSource = nil
        activeCloneConditioningKey = nil
        primedCloneReferenceKeys.removeAll()
        clonePrimeTimingOverridesMS.removeAll()
        if !preserveActiveClonePrimeToken {
            activeClonePrimeToken = nil
        }
    }

    private func ensureActiveClonePrimeToken(_ token: UUID) throws {
        if Task.isCancelled || activeClonePrimeToken != token {
            throw CancellationError()
        }
    }

    private func requireNormalizedCloneReferenceDirectory() throws -> URL {
        guard let normalizedCloneReferenceDirectory else {
            throw MLXTTSEngineError.notInitialized
        }
        return normalizedCloneReferenceDirectory
    }

    private func takeNextRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private static func fallbackCustomVoice(speaker: String, instruct: String?) -> String {
        let trimmedInstruction = instruct?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedInstruction.isEmpty else {
            return speaker
        }
        return "\(speaker), \(trimmedInstruction)"
    }
}
