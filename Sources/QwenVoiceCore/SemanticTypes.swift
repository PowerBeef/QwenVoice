import Foundation

public enum GenerationMode: String, CaseIterable, Codable, Hashable, Sendable {
    case custom
    case design
    case clone

    public var displayName: String {
        switch self {
        case .custom:
            return "Custom Voice"
        case .design:
            return "Voice Design"
        case .clone:
            return "Voice Cloning"
        }
    }

    public var iconName: String {
        switch self {
        case .custom:
            return "person.wave.2"
        case .design:
            return "text.bubble"
        case .clone:
            return "waveform.badge.plus"
        }
    }
}

public enum EngineActivityLabels {
    public static let preparingVoiceReference = "Preparing voice reference…"

    public static func generating(mode: GenerationMode) -> String {
        "Generating \(mode.displayName)…"
    }
}

public enum EngineImplementationKind: String, Codable, Hashable, Sendable {
    case nativeMLX
}

public enum EngineRoutingPolicy: String, Codable, Hashable, Sendable {
    case nativeDefault
    case nativeOnly
}

public enum EngineWarmState: String, Codable, Hashable, Sendable {
    case cold
    case warm
}

public enum GenerationSupportDecision: Hashable, Codable, Sendable {
    case supported(EngineImplementationKind)
    case unsupported(reason: String)

    public var implementationKind: EngineImplementationKind? {
        switch self {
        case .supported(let kind):
            return kind
        case .unsupported:
            return nil
        }
    }

    public var unsupportedReason: String? {
        switch self {
        case .supported:
            return nil
        case .unsupported(let reason):
            return reason
        }
    }

    public var isSupported: Bool {
        implementationKind != nil
    }
}

public struct SpeakerMetadata: Hashable, Codable, Sendable {
    public let displayName: String
    public let nativeLanguage: String
    public let shortDescription: String
    public let isEnglishNative: Bool

    public init(
        displayName: String,
        nativeLanguage: String,
        shortDescription: String,
        isEnglishNative: Bool
    ) {
        self.displayName = displayName
        self.nativeLanguage = nativeLanguage
        self.shortDescription = shortDescription
        self.isEnglishNative = isEnglishNative
    }
}

public struct SpeakerDescriptor: Identifiable, Hashable, Codable, Sendable {
    public let group: String
    public let id: String
    public let metadata: SpeakerMetadata?

    public init(group: String, id: String, metadata: SpeakerMetadata? = nil) {
        self.group = group
        self.id = id
        self.metadata = metadata
    }

    public var displayName: String {
        metadata?.displayName ?? id.capitalized
    }

    public var nativeLanguage: String? {
        metadata?.nativeLanguage
    }

    public var shortDescription: String? {
        metadata?.shortDescription
    }

    public var isEnglishNative: Bool {
        metadata?.isEnglishNative ?? false
    }

    public var annotatedDisplayName: String {
        guard let nativeLanguage,
              !nativeLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return displayName
        }
        return "\(displayName) - \(nativeLanguage) native"
    }
}

public enum ModelArtifactPlatform: String, Codable, Hashable, Sendable {
    case macOS
    case iOS
}

public enum ModelVariantKind: String, Codable, Hashable, Sendable {
    case speed
    case quality
}

public struct ModelVariantDescriptor: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let kind: ModelVariantKind
    public let platforms: Set<ModelArtifactPlatform>
    public let folder: String
    public let huggingFaceRepo: String
    public let huggingFaceRevision: String?
    public let artifactVersion: String
    public let iosDownloadEligible: Bool
    public let estimatedDownloadBytes: Int64?
    public let requiredRelativePaths: [String]

    public init(
        id: String,
        name: String,
        kind: ModelVariantKind,
        platforms: Set<ModelArtifactPlatform>,
        folder: String,
        huggingFaceRepo: String,
        huggingFaceRevision: String? = nil,
        artifactVersion: String,
        iosDownloadEligible: Bool,
        estimatedDownloadBytes: Int64?,
        requiredRelativePaths: [String]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.platforms = platforms
        self.folder = folder
        self.huggingFaceRepo = huggingFaceRepo
        self.huggingFaceRevision = huggingFaceRevision
        self.artifactVersion = artifactVersion
        self.iosDownloadEligible = iosDownloadEligible
        self.estimatedDownloadBytes = estimatedDownloadBytes
        self.requiredRelativePaths = requiredRelativePaths
    }
}

public struct ModelDescriptor: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let tier: String
    public let folder: String
    public let mode: GenerationMode
    public let huggingFaceRepo: String
    public let huggingFaceRevision: String?
    public let artifactVersion: String
    public let iosDownloadEligible: Bool
    public let estimatedDownloadBytes: Int64?
    public let outputSubfolder: String
    public let requiredRelativePaths: [String]
    public let variants: [ModelVariantDescriptor]

    public init(
        id: String,
        name: String,
        tier: String,
        folder: String,
        mode: GenerationMode,
        huggingFaceRepo: String,
        huggingFaceRevision: String? = nil,
        artifactVersion: String,
        iosDownloadEligible: Bool,
        estimatedDownloadBytes: Int64?,
        outputSubfolder: String,
        requiredRelativePaths: [String],
        variants: [ModelVariantDescriptor] = []
    ) {
        self.id = id
        self.name = name
        self.tier = tier
        self.folder = folder
        self.mode = mode
        self.huggingFaceRepo = huggingFaceRepo
        self.huggingFaceRevision = huggingFaceRevision
        self.artifactVersion = artifactVersion
        self.iosDownloadEligible = iosDownloadEligible
        self.estimatedDownloadBytes = estimatedDownloadBytes
        self.outputSubfolder = outputSubfolder
        self.requiredRelativePaths = requiredRelativePaths
        self.variants = variants
    }

    public func installDirectory(in modelsDirectory: URL) -> URL {
        modelsDirectory.appendingPathComponent(folder, isDirectory: true)
    }

    public func isAvailable(in modelsDirectory: URL, fileManager: FileManager = .default) -> Bool {
        let installDirectory = installDirectory(in: modelsDirectory)
        return requiredRelativePaths.allSatisfy { relativePath in
            fileManager.fileExists(atPath: installDirectory.appendingPathComponent(relativePath).path)
        }
    }

    public func platformVariants(for platform: ModelArtifactPlatform) -> [ModelVariantDescriptor] {
        variants.filter { $0.platforms.contains(platform) }
    }

    public func variantScopedID(for variant: ModelVariantDescriptor) -> String {
        "\(id)_\(variant.id)"
    }

    public func preferredVariant(for platform: ModelArtifactPlatform) -> ModelVariantDescriptor? {
        preferredVariant(for: platform, deviceClass: nil)
    }

    public func preferredVariant(
        for platform: ModelArtifactPlatform,
        deviceClass: NativeDeviceMemoryClass?
    ) -> ModelVariantDescriptor? {
        let platformVariants = variants.filter { $0.platforms.contains(platform) }
        guard !platformVariants.isEmpty else { return nil }

        switch platform {
        case .iOS:
            return platformVariants.first(where: { $0.kind == .speed }) ?? platformVariants.first
        case .macOS:
            if deviceClass == .floor8GBMac {
                return platformVariants.first(where: { $0.kind == .speed }) ?? platformVariants.first
            }
            return platformVariants.first(where: { $0.kind == .quality }) ?? platformVariants.first
        }
    }

    public func resolvedForPlatform(_ platform: ModelArtifactPlatform) -> ModelDescriptor {
        resolvedForPlatform(platform, deviceClass: nil)
    }

    public func resolvedForPlatform(
        _ platform: ModelArtifactPlatform,
        deviceClass: NativeDeviceMemoryClass?
    ) -> ModelDescriptor {
        guard let variant = preferredVariant(for: platform, deviceClass: deviceClass) else {
            return self
        }

        return resolved(with: variant, id: id)
    }

    public func resolved(with variant: ModelVariantDescriptor, id resolvedID: String? = nil) -> ModelDescriptor {
        return ModelDescriptor(
            id: resolvedID ?? id,
            name: name,
            tier: tier,
            folder: variant.folder,
            mode: mode,
            huggingFaceRepo: variant.huggingFaceRepo,
            huggingFaceRevision: variant.huggingFaceRevision,
            artifactVersion: variant.artifactVersion,
            iosDownloadEligible: variant.iosDownloadEligible,
            estimatedDownloadBytes: variant.estimatedDownloadBytes,
            outputSubfolder: outputSubfolder,
            requiredRelativePaths: variant.requiredRelativePaths,
            variants: variants
        )
    }
}

public struct CloneReference: Hashable, Codable, Sendable {
    public let audioPath: String
    public let transcript: String?
    public let preparedVoiceID: String?

    public init(audioPath: String, transcript: String? = nil, preparedVoiceID: String? = nil) {
        self.audioPath = audioPath
        self.transcript = transcript
        self.preparedVoiceID = preparedVoiceID
    }

    public var audioURL: URL {
        URL(fileURLWithPath: audioPath)
    }
}

public struct PreparedVoice: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let audioPath: String
    public let hasTranscript: Bool
    /// Quality observations about the underlying reference audio. Tokens
    /// match the existing `clone_reference_warnings` schema in
    /// `NativeCloneSupport.referenceQualityWarnings(for:)` —
    /// e.g. `reference_duration_short`, `reference_duration_long`,
    /// `reference_quality_unreadable`. Empty when the reference is
    /// within the recommended window (currently 10–20 s).
    /// UI surfaces these as soft warnings during enrollment + as inline
    /// badges in the saved-voices list.
    public let qualityWarnings: [String]

    public init(
        id: String,
        name: String,
        audioPath: String,
        hasTranscript: Bool,
        qualityWarnings: [String] = []
    ) {
        self.id = id
        self.name = name
        self.audioPath = audioPath
        self.hasTranscript = hasTranscript
        self.qualityWarnings = qualityWarnings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.audioPath = try container.decode(String.self, forKey: .audioPath)
        self.hasTranscript = try container.decode(Bool.self, forKey: .hasTranscript)
        // Backward-compat: older encoded forms (pre-May 2026) lacked
        // `qualityWarnings`; missing key decodes as empty.
        self.qualityWarnings = try container
            .decodeIfPresent([String].self, forKey: .qualityWarnings) ?? []
    }

    public var audioURL: URL {
        URL(fileURLWithPath: audioPath)
    }

    /// Cached headline for the first warning token. Avoids re-running
    /// the `PreparedVoiceQualityWarning.headline(for:)` lookup every
    /// time the saved-voices list re-renders. Nil when no warnings
    /// (the common case).
    public var qualityHeadline: String? {
        qualityWarnings.first.flatMap(PreparedVoiceQualityWarning.headline(for:))
    }
}

/// Human-readable summaries of `PreparedVoice.qualityWarnings` tokens.
/// Used by enrollment dialogs and library badges across macOS + iOS.
/// Unknown tokens fall through to `nil` so callers can choose whether to
/// display a generic warning line or drop it.
public enum PreparedVoiceQualityWarning {
    /// Sentence-length explanation. Used in the enrollment alert body
    /// and any place the row has room for full prose.
    public static func headline(for token: String) -> String? {
        switch token {
        case "reference_duration_short":
            return "Reference is shorter than recommended (under 10 seconds)."
        case "reference_duration_long":
            return "Reference is longer than recommended (over 20 seconds)."
        case "reference_quality_unreadable":
            return "Reference audio could not be read."
        default:
            return nil
        }
    }

    /// Compact 2-3 word label used inside the saved-voice row's
    /// warning chip, where the full sentence wraps awkwardly. Pairs
    /// with `exclamationmark.triangle.fill` + a chevron; the popover
    /// behind the chip carries the full headline + `summary(for:)` body.
    public static func shortLabel(for token: String) -> String? {
        switch token {
        case "reference_duration_short":
            return "Reference too short"
        case "reference_duration_long":
            return "Reference too long"
        case "reference_quality_unreadable":
            return "Reference unreadable"
        default:
            return nil
        }
    }

    /// Multi-line summary suitable for a warning dialog body.
    public static func summary(for tokens: [String]) -> String {
        let lines = tokens.compactMap { headline(for: $0) }
        if lines.isEmpty {
            return "Voice cloning works best with 10–20 seconds of clean speech."
        }
        return "Voice cloning works best with 10–20 seconds of clean speech.\n\n" +
            lines.map { "• \($0)" }.joined(separator: "\n") +
            "\n\nKeeping this voice may produce lower-quality clones."
    }
}

public struct AudioPreparationRequest: Hashable, Codable, Sendable {
    public let inputPath: String
    public let outputPath: String?

    public init(inputPath: String, outputPath: String? = nil) {
        self.inputPath = inputPath
        self.outputPath = outputPath
    }
}

public struct NativeMLXMemorySnapshot: Hashable, Codable, Sendable {
    public let activeMB: Double?
    public let cacheMB: Double?
    public let peakMB: Double?

    public init(activeMB: Double?, cacheMB: Double?, peakMB: Double?) {
        self.activeMB = activeMB
        self.cacheMB = cacheMB
        self.peakMB = peakMB
    }
}

public struct NativeBackendPerformanceSample: Hashable, Codable, Sendable {
    public let coldLoadMS: Int?
    public let warmGenerationMS: Int?
    public let timeToFirstAudioMS: Int?
    public let audioSecondsPerWallSecond: Double?
    public let chunkWriteTotalMS: Int?
    public let chunkWriteMaxMS: Int?
    public let eventDispatchMS: Int?
    public let finalWriteMS: Int?
    public let mlxMemoryByStage: [String: NativeMLXMemorySnapshot]
    public let loadCapabilityProfile: String?
    public let memoryPolicyName: String?
    public let streamingTransport: String?
    public let telemetryMode: String?

    public init(
        coldLoadMS: Int? = nil,
        warmGenerationMS: Int? = nil,
        timeToFirstAudioMS: Int? = nil,
        audioSecondsPerWallSecond: Double? = nil,
        chunkWriteTotalMS: Int? = nil,
        chunkWriteMaxMS: Int? = nil,
        eventDispatchMS: Int? = nil,
        finalWriteMS: Int? = nil,
        mlxMemoryByStage: [String: NativeMLXMemorySnapshot] = [:],
        loadCapabilityProfile: String? = nil,
        memoryPolicyName: String? = nil,
        streamingTransport: String? = nil,
        telemetryMode: String? = nil
    ) {
        self.coldLoadMS = coldLoadMS
        self.warmGenerationMS = warmGenerationMS
        self.timeToFirstAudioMS = timeToFirstAudioMS
        self.audioSecondsPerWallSecond = audioSecondsPerWallSecond
        self.chunkWriteTotalMS = chunkWriteTotalMS
        self.chunkWriteMaxMS = chunkWriteMaxMS
        self.eventDispatchMS = eventDispatchMS
        self.finalWriteMS = finalWriteMS
        self.mlxMemoryByStage = mlxMemoryByStage
        self.loadCapabilityProfile = loadCapabilityProfile
        self.memoryPolicyName = memoryPolicyName
        self.streamingTransport = streamingTransport
        self.telemetryMode = telemetryMode
    }
}

public enum NativeLoadCapabilityProfile: String, Hashable, Codable, Sendable {
    case customOnly = "custom_only"
    case designOnly = "design_only"
    case cloneOnly = "clone_only"
    case fullCapabilities = "full_capabilities"

    public init(for request: GenerationRequest) {
        switch request.payload {
        case .custom:
            self = .customOnly
        case .design:
            self = .designOnly
        case .clone:
            self = .cloneOnly
        }
    }

    public func canServe(_ requested: NativeLoadCapabilityProfile) -> Bool {
        self == requested || self == .fullCapabilities
    }
}

public enum NativeDeviceMemoryClass: String, Hashable, Codable, Sendable {
    case floor8GBMac = "floor_8gb_mac"
    case mid16GBMac = "mid_16gb_mac"
    case highMemoryMac = "high_memory_mac"
    case iPhonePro = "iphone_pro"
}

public struct NativeMemoryPolicy: Hashable, Codable, Sendable {
    public let name: String
    public let deviceClass: NativeDeviceMemoryClass
    public let cacheLimitBytes: Int
    public let memoryLimitBytes: Int?
    public let clearCacheAfterGeneration: Bool
    public let unloadAfterIdleSeconds: Double?

    public init(
        name: String,
        deviceClass: NativeDeviceMemoryClass,
        cacheLimitBytes: Int,
        memoryLimitBytes: Int? = nil,
        clearCacheAfterGeneration: Bool,
        unloadAfterIdleSeconds: Double?
    ) {
        self.name = name
        self.deviceClass = deviceClass
        self.cacheLimitBytes = cacheLimitBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.clearCacheAfterGeneration = clearCacheAfterGeneration
        self.unloadAfterIdleSeconds = unloadAfterIdleSeconds
    }
}

public enum NativeTelemetryMode: String, Hashable, Codable, Sendable {
    case off
    case lightweight

    public var sampleIntervalMS: Int? {
        switch self {
        case .off:
            return nil
        case .lightweight:
            return 250
        }
    }

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> NativeTelemetryMode {
        switch environment["QWENVOICE_NATIVE_TELEMETRY_MODE"]?.lowercased() {
        case "off", "disabled":
            return .off
        case "light", "lightweight":
            return .lightweight
        default:
            return .off
        }
    }
}

public enum NativeStreamingOutputPolicy: String, Hashable, Codable, Sendable {
    case pcmPreview = "pcm_preview"
    case pcmPreviewAndFileArtifacts = "pcm_preview_and_file_artifacts"

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> NativeStreamingOutputPolicy {
        switch environment["QWENVOICE_STREAMING_OUTPUT_POLICY"]?.lowercased() {
        case "file", "files", "pcm_and_files", "pcm_preview_and_file_artifacts":
            return .pcmPreviewAndFileArtifacts
        default:
            return .pcmPreview
        }
    }
}

/// Opt-out switch for the per-chunk PCM preview Data materialization.
/// The streaming generator always builds a `Data` from the per-chunk
/// Int16 samples (and ships it through the chunk event) so the UI can
/// play audio live. For headless workloads — bench runs, CI, batch
/// generation where nobody is listening to the in-flight preview —
/// emitting an empty `Data` for the preview saves ~50-100 KB of
/// allocation churn per chunk. Audio files on disk are unaffected;
/// only the in-flight preview data carried by `GenerationEvent.chunk`
/// is suppressed.
///
/// Set `QWENVOICE_STREAMING_PREVIEW_DATA=off` (case-insensitive) to
/// opt out. Default is "on" — preserves existing live-streaming UX.
public enum NativeStreamingPreviewDataPolicy: String, Hashable, Codable, Sendable {
    case emit
    case skip

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> NativeStreamingPreviewDataPolicy {
        switch environment["QWENVOICE_STREAMING_PREVIEW_DATA"]?.lowercased() {
        case "off", "skip", "false", "0", "no":
            return .skip
        default:
            return .emit
        }
    }
}

public struct StreamingAudioChunk: Hashable, Codable, Sendable {
    public let requestID: Int?
    public let sampleRate: Int
    public let frameOffset: Int64
    public let frameCount: Int
    public let pcm16LE: Data
    public let isFinal: Bool

    public init(
        requestID: Int? = nil,
        sampleRate: Int,
        frameOffset: Int64,
        frameCount: Int,
        pcm16LE: Data,
        isFinal: Bool
    ) {
        self.requestID = requestID
        self.sampleRate = sampleRate
        self.frameOffset = frameOffset
        self.frameCount = frameCount
        self.pcm16LE = pcm16LE
        self.isFinal = isFinal
    }
}

public struct GenerationSessionKey: Hashable, Codable, Sendable {
    public let modelID: String
    public let variantID: String?
    public let mode: GenerationMode
    public let language: String
    public let speakerOrVoiceDescriptionHash: String?
    public let cloneReferenceHash: String?

    public init(
        modelID: String,
        variantID: String? = nil,
        mode: GenerationMode,
        language: String,
        speakerOrVoiceDescriptionHash: String? = nil,
        cloneReferenceHash: String? = nil
    ) {
        self.modelID = modelID
        self.variantID = variantID
        self.mode = mode
        self.language = language
        self.speakerOrVoiceDescriptionHash = speakerOrVoiceDescriptionHash
        self.cloneReferenceHash = cloneReferenceHash
    }
}

public enum GenerationFinishReason: String, Hashable, Codable, Sendable {
    case eos
    case maxTokens = "max_tokens"
    case cancelled
    case failed
}

public struct GenerationResult: Hashable, Codable, Sendable {
    public let audioPath: String
    public let durationSeconds: Double
    public let streamSessionDirectory: String?
    public let usedStreaming: Bool
    public let finishReason: GenerationFinishReason?

    public init(
        audioPath: String,
        durationSeconds: Double,
        streamSessionDirectory: String?,
        usedStreaming: Bool,
        finishReason: GenerationFinishReason? = nil
    ) {
        self.audioPath = audioPath
        self.durationSeconds = durationSeconds
        self.streamSessionDirectory = streamSessionDirectory
        self.usedStreaming = usedStreaming
        self.finishReason = finishReason
    }

    public var audioURL: URL {
        URL(fileURLWithPath: audioPath)
    }

    public var streamSessionDirectoryURL: URL? {
        guard let streamSessionDirectory else { return nil }
        return URL(fileURLWithPath: streamSessionDirectory)
    }

}

public enum EngineActivityPresentation: String, Hashable, Codable, Sendable {
    case standaloneCard
    case inlinePlayer
}

public struct EngineActivity: Hashable, Codable, Sendable {
    public let label: String
    public let fraction: Double?
    public let presentation: EngineActivityPresentation

    public init(label: String, fraction: Double?, presentation: EngineActivityPresentation) {
        self.label = label
        self.fraction = fraction
        self.presentation = presentation
    }
}

public enum EngineLoadState: Hashable, Codable, Sendable {
    case idle
    case starting
    case loaded(modelID: String)
    case running(modelID: String?, label: String?, fraction: Double?)
    case failed(message: String)

    public var isReady: Bool {
        switch self {
        case .idle, .loaded, .running, .failed:
            return true
        case .starting:
            return false
        }
    }

    public var currentModelID: String? {
        switch self {
        case .loaded(let modelID):
            return modelID
        case .running(let modelID, _, _):
            return modelID
        case .idle, .starting, .failed:
            return nil
        }
    }
}

public enum ClonePreparationPhase: String, Hashable, Codable, Sendable {
    case idle
    case preparing
    case primed
    case failed
}

public struct ClonePreparationState: Hashable, Codable, Sendable {
    public let phase: ClonePreparationPhase
    public let identityKey: String?
    public let message: String?

    public init(
        phase: ClonePreparationPhase,
        identityKey: String? = nil,
        message: String? = nil
    ) {
        self.phase = phase
        self.identityKey = identityKey
        self.message = message
    }

    public static let idle = ClonePreparationState(phase: .idle)

    public static func preparing(key: String?) -> ClonePreparationState {
        ClonePreparationState(phase: .preparing, identityKey: key)
    }

    public static func primed(key: String?) -> ClonePreparationState {
        ClonePreparationState(phase: .primed, identityKey: key)
    }

    public static func failed(key: String?, message: String?) -> ClonePreparationState {
        ClonePreparationState(phase: .failed, identityKey: key, message: message)
    }

    public var key: String? {
        identityKey
    }

    public var errorMessage: String? {
        phase == .failed ? message : nil
    }

    public var isPreparingOrPrimed: Bool {
        phase == .preparing || phase == .primed
    }

    public var isPrimed: Bool {
        phase == .primed
    }
}

public enum CloneReferenceContextResolution: Hashable, Sendable {
    case waitingForHydration
    case preparing
    case primed
    case usableWithoutPriming
    case degraded(String)
}

public enum CloneReferenceContextResolver {
    public static let defaultDegradedMessage =
        "Reference prep didn't finish. Generation is still available, but the first generation may be slower."

    public static func resolve(
        hasReference: Bool,
        selectedSavedVoiceID: String?,
        hydratedSavedVoiceID: String?,
        transcriptLoadError: String?,
        expectedPreparationKey: String?,
        preparationState: ClonePreparationState
    ) -> CloneReferenceContextResolution? {
        guard hasReference else { return nil }

        if let selectedSavedVoiceID,
           hydratedSavedVoiceID != selectedSavedVoiceID,
           transcriptLoadError == nil {
            return .waitingForHydration
        }

        guard let expectedPreparationKey else {
            return .usableWithoutPriming
        }

        guard preparationState.key == expectedPreparationKey else {
            return .usableWithoutPriming
        }

        switch preparationState.phase {
        case .idle:
            return .usableWithoutPriming
        case .preparing:
            return .preparing
        case .primed:
            return .primed
        case .failed:
            return .degraded(preparationState.errorMessage ?? defaultDegradedMessage)
        }
    }
}

public struct GenerationRequest: Hashable, Codable, Sendable {
    public enum Payload: Hashable, Codable, Sendable {
        case custom(speakerID: String, deliveryStyle: String?)
        case design(voiceDescription: String, deliveryStyle: String?)
        case clone(reference: CloneReference)
    }

    public let mode: GenerationMode
    public let modelID: String
    public let text: String
    public let outputPath: String
    public let shouldStream: Bool
    public let streamingInterval: Double?
    public let batchIndex: Int?
    public let batchTotal: Int?
    public let streamingTitle: String?
    public let payload: Payload

    public init(
        mode: GenerationMode,
        modelID: String,
        text: String,
        outputPath: String,
        shouldStream: Bool,
        streamingInterval: Double? = nil,
        batchIndex: Int? = nil,
        batchTotal: Int? = nil,
        streamingTitle: String? = nil,
        payload: Payload
    ) {
        self.mode = mode
        self.modelID = modelID
        self.text = text
        self.outputPath = outputPath
        self.shouldStream = shouldStream
        self.streamingInterval = streamingInterval
        self.batchIndex = batchIndex
        self.batchTotal = batchTotal
        self.streamingTitle = streamingTitle
        self.payload = payload
    }

    public init(
        modelID: String,
        text: String,
        outputPath: String,
        shouldStream: Bool = false,
        streamingInterval: Double? = nil,
        batchIndex: Int? = nil,
        batchTotal: Int? = nil,
        streamingTitle: String? = nil,
        payload: Payload
    ) {
        let resolvedMode: GenerationMode
        switch payload {
        case .custom:
            resolvedMode = .custom
        case .design:
            resolvedMode = .design
        case .clone:
            resolvedMode = .clone
        }

        self.init(
            mode: resolvedMode,
            modelID: modelID,
            text: text,
            outputPath: outputPath,
            shouldStream: shouldStream,
            streamingInterval: streamingInterval,
            batchIndex: batchIndex,
            batchTotal: batchTotal,
            streamingTitle: streamingTitle,
            payload: payload
        )
    }

    public var modeIdentifier: String {
        mode.rawValue
    }

    public var engineActivityLabel: String {
        EngineActivityLabels.generating(mode: mode)
    }
}

public struct GenerationProgress: Hashable, Codable, Sendable {
    public let percent: Int
    public let message: String

    public init(percent: Int, message: String) {
        self.percent = percent
        self.message = message
    }
}

public struct GenerationChunk: Hashable, Codable, Sendable {
    public let requestID: Int?
    public let mode: String
    public let title: String
    public let chunkPath: String?
    public let isFinal: Bool
    public let chunkDurationSeconds: Double?
    public let cumulativeDurationSeconds: Double?
    public let streamSessionDirectory: String?
    public let previewAudio: StreamingAudioChunk?

    public init(
        requestID: Int? = nil,
        mode: String,
        title: String,
        chunkPath: String?,
        isFinal: Bool,
        chunkDurationSeconds: Double?,
        cumulativeDurationSeconds: Double?,
        streamSessionDirectory: String?,
        previewAudio: StreamingAudioChunk? = nil
    ) {
        self.requestID = requestID
        self.mode = mode
        self.title = title
        self.chunkPath = chunkPath
        self.isFinal = isFinal
        self.chunkDurationSeconds = chunkDurationSeconds
        self.cumulativeDurationSeconds = cumulativeDurationSeconds
        self.streamSessionDirectory = streamSessionDirectory
        self.previewAudio = previewAudio
    }

    public func withoutPreviewAudioPayload() -> GenerationChunk {
        GenerationChunk(
            requestID: requestID,
            mode: mode,
            title: title,
            chunkPath: chunkPath,
            isFinal: isFinal,
            chunkDurationSeconds: chunkDurationSeconds,
            cumulativeDurationSeconds: cumulativeDurationSeconds,
            streamSessionDirectory: streamSessionDirectory,
            previewAudio: nil
        )
    }

    public var deliveryIdentity: GenerationChunkDeliveryIdentity {
        GenerationChunkDeliveryIdentity(
            requestID: requestID,
            mode: mode,
            title: title,
            chunkPath: chunkPath,
            isFinal: isFinal,
            chunkDurationSeconds: chunkDurationSeconds,
            cumulativeDurationSeconds: cumulativeDurationSeconds,
            streamSessionDirectory: streamSessionDirectory,
            previewAudioRequestID: previewAudio?.requestID,
            previewAudioSampleRate: previewAudio?.sampleRate,
            previewAudioFrameOffset: previewAudio?.frameOffset,
            previewAudioFrameCount: previewAudio?.frameCount,
            previewAudioIsFinal: previewAudio?.isFinal
        )
    }
}

public struct GenerationChunkDeliveryIdentity: Hashable, Sendable {
    public let requestID: Int?
    public let mode: String
    public let title: String
    public let chunkPath: String?
    public let isFinal: Bool
    public let chunkDurationSeconds: Double?
    public let cumulativeDurationSeconds: Double?
    public let streamSessionDirectory: String?
    public let previewAudioRequestID: Int?
    public let previewAudioSampleRate: Int?
    public let previewAudioFrameOffset: Int64?
    public let previewAudioFrameCount: Int?
    public let previewAudioIsFinal: Bool?
}

public enum GenerationEvent: Hashable, Codable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable {
        case streamChunk
        case progress
        case completed
        case failed
    }

    case progress(GenerationProgress)
    case chunk(GenerationChunk)
    case completed(GenerationResult)
    case failed(String)

    public init(
        kind: Kind,
        requestID: Int,
        mode: String,
        title: String,
        chunkPath: String? = nil,
        isFinal: Bool,
        chunkDurationSeconds: Double? = nil,
        cumulativeDurationSeconds: Double? = nil,
        streamSessionDirectory: String? = nil,
        previewAudio: StreamingAudioChunk? = nil
    ) {
        precondition(kind == .streamChunk, "This initializer only supports chunk events.")
        self = .chunk(
            GenerationChunk(
                requestID: requestID,
                mode: mode,
                title: title,
                chunkPath: chunkPath,
                isFinal: isFinal,
                chunkDurationSeconds: chunkDurationSeconds,
                cumulativeDurationSeconds: cumulativeDurationSeconds,
                streamSessionDirectory: streamSessionDirectory,
                previewAudio: previewAudio
            )
        )
    }

    public var kind: Kind {
        switch self {
        case .progress:
            return .progress
        case .chunk:
            return .streamChunk
        case .completed:
            return .completed
        case .failed:
            return .failed
        }
    }

    public var requestID: Int? {
        guard case .chunk(let chunk) = self else { return nil }
        return chunk.requestID
    }

    public var mode: String? {
        guard case .chunk(let chunk) = self else { return nil }
        return chunk.mode
    }

    public var title: String? {
        guard case .chunk(let chunk) = self else { return nil }
        return chunk.title
    }

    public var chunkPath: String? {
        guard case .chunk(let chunk) = self else { return nil }
        return chunk.chunkPath
    }

    public var previewAudio: StreamingAudioChunk? {
        guard case .chunk(let chunk) = self else { return nil }
        return chunk.previewAudio
    }

    public var isFinal: Bool? {
        guard case .chunk(let chunk) = self else { return nil }
        return chunk.isFinal
    }

    public var chunkDurationSeconds: Double? {
        guard case .chunk(let chunk) = self else { return nil }
        return chunk.chunkDurationSeconds
    }

    public var cumulativeDurationSeconds: Double? {
        guard case .chunk(let chunk) = self else { return nil }
        return chunk.cumulativeDurationSeconds
    }

    public var streamSessionDirectory: String? {
        guard case .chunk(let chunk) = self else { return nil }
        return chunk.streamSessionDirectory
    }

    public func withoutPreviewAudioPayload() -> GenerationEvent {
        switch self {
        case .chunk(let chunk):
            return .chunk(chunk.withoutPreviewAudioPayload())
        case .progress, .completed, .failed:
            return self
        }
    }

    public var chunkDeliveryIdentity: GenerationChunkDeliveryIdentity? {
        guard case .chunk(let chunk) = self else { return nil }
        return chunk.deliveryIdentity
    }
}

public struct TTSEngineSnapshot: Hashable, Codable, Sendable {
    public let isReady: Bool
    public let loadState: EngineLoadState
    public let clonePreparationState: ClonePreparationState
    public let visibleErrorMessage: String?

    public init(
        isReady: Bool,
        loadState: EngineLoadState,
        clonePreparationState: ClonePreparationState,
        visibleErrorMessage: String?
    ) {
        self.isReady = isReady
        self.loadState = loadState
        self.clonePreparationState = clonePreparationState
        self.visibleErrorMessage = visibleErrorMessage
    }
}

public struct EngineBatchProgressUpdate: Hashable, Codable, Sendable {
    public let commandID: UUID
    public let fraction: Double?
    public let message: String

    public init(commandID: UUID, fraction: Double?, message: String) {
        self.commandID = commandID
        self.fraction = fraction
        self.message = message
    }
}
