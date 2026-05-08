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

public struct SpeakerDescriptor: Identifiable, Hashable, Codable, Sendable {
    public let group: String
    public let id: String

    public init(group: String, id: String) {
        self.group = group
        self.id = id
    }

    public var displayName: String {
        id.capitalized
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
    case benchmarkFull = "benchmark_full"

    public var sampleIntervalMS: Int? {
        switch self {
        case .off:
            return nil
        case .lightweight:
            return 250
        case .benchmarkFull:
            return 50
        }
    }

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> NativeTelemetryMode {
        current(environment: environment, benchmarkOptions: nil)
    }

    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        benchmarkOptions: GenerationRequest.BenchmarkOptions?
    ) -> NativeTelemetryMode {
        switch environment["QWENVOICE_NATIVE_TELEMETRY_MODE"]?.lowercased() {
        case "off", "disabled":
            return .off
        case "full", "benchmark", "benchmark_full":
            return .benchmarkFull
        case "light", "lightweight":
            return .lightweight
        default:
            return benchmarkOptions == nil ? .off : .lightweight
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

public struct BenchmarkSample: Hashable, Codable, Sendable {
    public let engineKind: EngineImplementationKind?
    public let routingPolicy: EngineRoutingPolicy?
    public let warmState: EngineWarmState?
    public let tokenCount: Int?
    public let processingTimeSeconds: Double?
    public let peakMemoryUsage: Double?
    public let streamingUsed: Bool
    public let preparedCloneUsed: Bool?
    public let cloneCacheHit: Bool?
    public let firstChunkMs: Int?
    public let peakResidentMB: Double?
    public let peakPhysFootprintMB: Double?
    public let residentStartMB: Double?
    public let residentEndMB: Double?
    public let compressedPeakMB: Double?
    public let headroomStartMB: Double?
    public let headroomEndMB: Double?
    public let headroomMinMB: Double?
    public let gpuAllocatedPeakMB: Double?
    public let gpuRecommendedWorkingSetMB: Double?
    public let telemetryEnabled: Bool?
    public let telemetrySamples: [TelemetrySample]?
    public let telemetryStageMarks: [NativeTelemetryStageMark]?
    public let timingsMS: [String: Int]
    public let booleanFlags: [String: Bool]
    public let stringFlags: [String: String]
    public let backendPerformance: NativeBackendPerformanceSample?

    public init(
        engineKind: EngineImplementationKind? = nil,
        routingPolicy: EngineRoutingPolicy? = nil,
        warmState: EngineWarmState? = nil,
        tokenCount: Int? = nil,
        processingTimeSeconds: Double? = nil,
        peakMemoryUsage: Double? = nil,
        streamingUsed: Bool,
        preparedCloneUsed: Bool? = nil,
        cloneCacheHit: Bool? = nil,
        firstChunkMs: Int? = nil,
        peakResidentMB: Double? = nil,
        peakPhysFootprintMB: Double? = nil,
        residentStartMB: Double? = nil,
        residentEndMB: Double? = nil,
        compressedPeakMB: Double? = nil,
        headroomStartMB: Double? = nil,
        headroomEndMB: Double? = nil,
        headroomMinMB: Double? = nil,
        gpuAllocatedPeakMB: Double? = nil,
        gpuRecommendedWorkingSetMB: Double? = nil,
        telemetryEnabled: Bool? = nil,
        telemetrySamples: [TelemetrySample]? = nil,
        telemetryStageMarks: [NativeTelemetryStageMark]? = nil,
        timingsMS: [String: Int] = [:],
        booleanFlags: [String: Bool] = [:],
        stringFlags: [String: String] = [:],
        backendPerformance: NativeBackendPerformanceSample? = nil
    ) {
        self.engineKind = engineKind
        self.routingPolicy = routingPolicy
        self.warmState = warmState
        self.tokenCount = tokenCount
        self.processingTimeSeconds = processingTimeSeconds
        self.peakMemoryUsage = peakMemoryUsage
        self.streamingUsed = streamingUsed
        self.preparedCloneUsed = preparedCloneUsed
        self.cloneCacheHit = cloneCacheHit
        self.firstChunkMs = firstChunkMs
        self.peakResidentMB = peakResidentMB
        self.peakPhysFootprintMB = peakPhysFootprintMB
        self.residentStartMB = residentStartMB
        self.residentEndMB = residentEndMB
        self.compressedPeakMB = compressedPeakMB
        self.headroomStartMB = headroomStartMB
        self.headroomEndMB = headroomEndMB
        self.headroomMinMB = headroomMinMB
        self.gpuAllocatedPeakMB = gpuAllocatedPeakMB
        self.gpuRecommendedWorkingSetMB = gpuRecommendedWorkingSetMB
        self.telemetryEnabled = telemetryEnabled
        self.telemetrySamples = telemetrySamples
        self.telemetryStageMarks = telemetryStageMarks
        self.timingsMS = timingsMS
        self.booleanFlags = booleanFlags
        self.stringFlags = stringFlags
        self.backendPerformance = backendPerformance
    }

    public func mergingBenchmarkFields(
        timingsMS additionalTimingsMS: [String: Int] = [:],
        booleanFlags additionalBooleanFlags: [String: Bool] = [:],
        stringFlags additionalStringFlags: [String: String] = [:]
    ) -> BenchmarkSample {
        BenchmarkSample(
            engineKind: engineKind,
            routingPolicy: routingPolicy,
            warmState: warmState,
            tokenCount: tokenCount,
            processingTimeSeconds: processingTimeSeconds,
            peakMemoryUsage: peakMemoryUsage,
            streamingUsed: streamingUsed,
            preparedCloneUsed: preparedCloneUsed,
            cloneCacheHit: cloneCacheHit,
            firstChunkMs: firstChunkMs,
            peakResidentMB: peakResidentMB,
            peakPhysFootprintMB: peakPhysFootprintMB,
            residentStartMB: residentStartMB,
            residentEndMB: residentEndMB,
            compressedPeakMB: compressedPeakMB,
            headroomStartMB: headroomStartMB,
            headroomEndMB: headroomEndMB,
            headroomMinMB: headroomMinMB,
            gpuAllocatedPeakMB: gpuAllocatedPeakMB,
            gpuRecommendedWorkingSetMB: gpuRecommendedWorkingSetMB,
            telemetryEnabled: telemetryEnabled,
            telemetrySamples: telemetrySamples,
            telemetryStageMarks: telemetryStageMarks,
            timingsMS: timingsMS.merging(additionalTimingsMS) { _, rhs in rhs },
            booleanFlags: booleanFlags.merging(additionalBooleanFlags) { _, rhs in rhs },
            stringFlags: stringFlags.merging(additionalStringFlags) { _, rhs in rhs },
            backendPerformance: backendPerformance
        )
    }
}

public struct GenerationResult: Hashable, Codable, Sendable {
    public let audioPath: String
    public let durationSeconds: Double
    public let streamSessionDirectory: String?
    public let benchmarkSample: BenchmarkSample?

    public init(
        audioPath: String,
        durationSeconds: Double,
        streamSessionDirectory: String?,
        benchmarkSample: BenchmarkSample?
    ) {
        self.audioPath = audioPath
        self.durationSeconds = durationSeconds
        self.streamSessionDirectory = streamSessionDirectory
        self.benchmarkSample = benchmarkSample
    }

    public var audioURL: URL {
        URL(fileURLWithPath: audioPath)
    }

    public var streamSessionDirectoryURL: URL? {
        guard let streamSessionDirectory else { return nil }
        return URL(fileURLWithPath: streamSessionDirectory)
    }

    public var usedStreaming: Bool {
        benchmarkSample?.streamingUsed ?? false
    }

    public func withBenchmarkSample(_ benchmarkSample: BenchmarkSample?) -> GenerationResult {
        GenerationResult(
            audioPath: audioPath,
            durationSeconds: durationSeconds,
            streamSessionDirectory: streamSessionDirectory,
            benchmarkSample: benchmarkSample
        )
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

public struct GenerationRequest: Hashable, Codable, Sendable {
    public enum Payload: Hashable, Codable, Sendable {
        case custom(speakerID: String, deliveryStyle: String?)
        case design(voiceDescription: String, deliveryStyle: String?)
        case clone(reference: CloneReference)
    }

    /// Per-request overrides used by live audio-QC and benchmark suites.
    /// Every field is consumed by the engine: see
    /// `UnsafeSpeechGenerationModel.swift` (Qwen3 parameter policy +
    /// custom-voice prewarm) and `NativeStreamingSynthesisSession.swift`
    /// (`NativeBenchmarkPostRequestCachePolicy`). Adding a field here is a
    /// load-bearing change — wire it through both sites.
    public struct BenchmarkOptions: Hashable, Codable, Sendable {
        public let customVoiceProfile: String?
        public let streamStepEvalPolicy: String?
        public let generationSpeedProfile: String?
        public let memoryClearCadence: Int?
        public let postRequestCachePolicy: String?
        /// Sampling temperature override; replaces the Custom Voice product
        /// default (0.7) before `Qwen3BenchmarkGenerationParameterOverrides`
        /// applies any `QWENVOICE_QWEN3_BENCHMARK_TEMPERATURE` env override.
        public let temperature: Double?
        /// Sampling top-p override; replaces the Custom Voice product
        /// default (0.9) before
        /// `Qwen3BenchmarkGenerationParameterOverrides` applies any
        /// `QWENVOICE_QWEN3_BENCHMARK_TOP_P` env override.
        public let topP: Double?

        public init(
            customVoiceProfile: String? = nil,
            streamStepEvalPolicy: String? = nil,
            generationSpeedProfile: String? = nil,
            memoryClearCadence: Int? = nil,
            postRequestCachePolicy: String? = nil,
            temperature: Double? = nil,
            topP: Double? = nil
        ) {
            self.customVoiceProfile = customVoiceProfile
            self.streamStepEvalPolicy = streamStepEvalPolicy
            self.generationSpeedProfile = generationSpeedProfile
            self.memoryClearCadence = memoryClearCadence
            self.postRequestCachePolicy = postRequestCachePolicy
            self.temperature = temperature
            self.topP = topP
        }
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
    public let benchmarkOptions: BenchmarkOptions?
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
        benchmarkOptions: BenchmarkOptions? = nil,
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
        self.benchmarkOptions = benchmarkOptions
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
        benchmarkOptions: BenchmarkOptions? = nil,
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
            benchmarkOptions: benchmarkOptions,
            payload: payload
        )
    }

    public var modeIdentifier: String {
        mode.rawValue
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

/// Per-chunk metadata used by the cross-layer probe trace
/// (`[Probe.Engine]`, `[Probe.Transport]`, `[Probe.UI]`).
///
/// Set by the engine at chunk-construction time inside the bundled XPC
/// helper (`NativeStreamingSynthesisSession`). The app process re-emits
/// the engine + transport probe events from `XPCNativeEngineClient` on
/// receipt, using the embedded `engineEmittedAtMS` (wall-clock) for
/// cross-process latency math. `seq` is the engine's monotonic per-
/// generation chunk index (1-based) and is the join key that the bench
/// helper uses to correlate `[Probe.*]` lines across layers.
///
/// Optional: nil when the chunk did not originate from the streaming
/// synthesis path (legacy paths, mocks, fixtures), so the probe emits
/// are skipped gracefully and Codable round-trip stays backward-compat.
public struct ChunkProbeMetadata: Hashable, Codable, Sendable {
    public let seq: Int
    public let engineEmittedAtMS: Double
    public let inferMS: Double
    /// Engine probe Phase 1 sub-stage breakdown of `inferMS`. Optional
    /// so legacy chunks (mock-backed tests, fixtures, non-Qwen3
    /// backends) decode unchanged + the bench helper omits the
    /// columns when no sub-stage data is available.
    /// All three are millisecond deltas from the previous chunk's
    /// emit boundary (or generation start for chunk seq 1).
    public let talkerForwardMS: Double?
    public let codePredictorMS: Double?
    public let audioDecoderMS: Double?
    /// Engine probe Phase 2a — the `eval(...)` cadence and `eval`
    /// flushes that sit BETWEEN the Phase 1 stages. The May 2026
    /// Phase 1 re-bench showed talker + code predictor + audio
    /// decoder summed to only 18-26 % of `inferMS`; these three
    /// fields chase the missing 74-82 %.
    public let streamStepEvalMS: Double?
    public let streamStepEOSReadMS: Double?
    public let audioChunkEvalMS: Double?

    public init(
        seq: Int,
        engineEmittedAtMS: Double,
        inferMS: Double,
        talkerForwardMS: Double? = nil,
        codePredictorMS: Double? = nil,
        audioDecoderMS: Double? = nil,
        streamStepEvalMS: Double? = nil,
        streamStepEOSReadMS: Double? = nil,
        audioChunkEvalMS: Double? = nil
    ) {
        self.seq = seq
        self.engineEmittedAtMS = engineEmittedAtMS
        self.inferMS = inferMS
        self.talkerForwardMS = talkerForwardMS
        self.codePredictorMS = codePredictorMS
        self.audioDecoderMS = audioDecoderMS
        self.streamStepEvalMS = streamStepEvalMS
        self.streamStepEOSReadMS = streamStepEOSReadMS
        self.audioChunkEvalMS = audioChunkEvalMS
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
    public let probeMetadata: ChunkProbeMetadata?

    public init(
        requestID: Int? = nil,
        mode: String,
        title: String,
        chunkPath: String?,
        isFinal: Bool,
        chunkDurationSeconds: Double?,
        cumulativeDurationSeconds: Double?,
        streamSessionDirectory: String?,
        previewAudio: StreamingAudioChunk? = nil,
        probeMetadata: ChunkProbeMetadata? = nil
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
        self.probeMetadata = probeMetadata
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
            previewAudio: nil,
            probeMetadata: probeMetadata
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

    public var probeMetadata: ChunkProbeMetadata? {
        guard case .chunk(let chunk) = self else { return nil }
        return chunk.probeMetadata
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
