import Combine
import XCTest
@testable import QVoiceiOS
@testable import QwenVoiceCore

final class IOSFoundationPolicyTests: XCTestCase {
    func testAppPathsResolveAbsoluteAndRelativeOverrides() {
        let absolute = AppPaths.resolvedAppSupportDir(
            environment: [AppPaths.appSupportOverrideEnvironmentKey: "/tmp/vocello-override"]
        )
        XCTAssertEqual(absolute.path, "/tmp/vocello-override")

        let relative = AppPaths.resolvedAppSupportDir(
            environment: [AppPaths.appSupportOverrideEnvironmentKey: "sandbox/dev"]
        )
        XCTAssertEqual(
            relative.path,
            AppPaths.managedAppSupportDir
                .appendingPathComponent("sandbox/dev", isDirectory: true)
                .path
        )
    }

    func testAppPathsShareAppGroupIdentifierWithFoundationExpectations() {
        XCTAssertEqual(AppPaths.sharedAppGroupIdentifier, "group.com.qvoice.shared")
    }

    func testCapabilityMatrixMatchesIOSFoundationExpectations() throws {
        let matrix = try loadMatrix()

        XCTAssertEqual(
            matrix.iOS.app.applicationGroups,
            [AppPaths.sharedAppGroupIdentifier]
        )
        XCTAssertEqual(
            matrix.iOS.app.engineCapabilities,
            EngineCapabilities(
                supportsBatchGeneration: false,
                supportsAudioPreparation: false,
                supportsInteractivePrefetch: false,
                supportsMemoryTrim: false,
                supportsPreparedVoiceManagement: true
            )
        )
        XCTAssertEqual(
            matrix.iOS.extension.engineCapabilities,
            EngineCapabilities.iOSExtensionDefault
        )
    }

    func testDeliveryInputStateMapsNeutralAndLegacyAliasesToNeutral() {
        let legacyNeutral = ["Normal", "tone"].joined(separator: " ")

        for instruction in ["", "Neutral", "Neutral tone", legacyNeutral] {
            let state = DeliveryInputState(legacyEmotion: instruction)

            XCTAssertEqual(state.mode, .preset)
            XCTAssertEqual(state.resolvedDeliveryInstruction, "Neutral")
            XCTAssertEqual(state.selectedPresetLabel, "Neutral")
        }
    }

    func testIOSExcitedStrongPresetUsesSaferControlledPacingInstruction() {
        XCTAssertEqual(
            EmotionPreset.preset(id: "excited")?.instruction(for: .strong),
            "Very excited and animated, energetic and anticipatory, with lively emphasis, controlled pacing, and clear pronunciation."
        )
    }

    func testIOSWhisperPresetUsesExplicitWhisperInstructions() {
        let whisper = EmotionPreset.preset(id: "whisper")

        XCTAssertEqual(
            whisper?.instruction(for: .subtle),
            "Subtle audible whisper, close-mic and quiet, with gentle breath, hushed tone, and clear words."
        )
        XCTAssertEqual(
            whisper?.instruction(for: .normal),
            "Hushed whisper, intimate and quiet, with breathy texture, clear articulation, and soft pacing."
        )
        XCTAssertEqual(
            whisper?.instruction(for: .strong),
            "Very soft and breathy whisper, intimate and intense, with clear pronunciation and enough audibility to understand every word."
        )
    }

    func testIOSCustomVoicePrefetchRequestUsesFinalResultSemantics() throws {
        let model = try XCTUnwrap(TTSModel.model(for: .custom))
        let draft = CustomVoiceDraft(
            selectedSpeaker: "aiden",
            delivery: DeliveryInputState(),
            text: "Warm this final-result iPhone path."
        )

        let request = IOSPrefetchRequestFactory.customVoiceRequest(
            model: model,
            draft: draft,
            fallbackText: MLXTTSEngine.lightweightWarmupTextForUI
        )

        XCTAssertFalse(request.shouldStream)
        XCTAssertEqual(request.mode, .custom)
        XCTAssertEqual(request.text, draft.text)
        XCTAssertEqual(request.streamingInterval, GenerationSemantics.appStreamingInterval)
        guard case .custom(let speakerID, let deliveryStyle) = request.payload else {
            return XCTFail("Expected Custom Voice prefetch payload")
        }
        XCTAssertEqual(speakerID, "aiden")
        XCTAssertEqual(deliveryStyle, DeliveryProfile.neutralInstruction)
    }

    func testIOSVoiceDesignPrefetchRequestUsesFinalResultSemantics() throws {
        let model = try XCTUnwrap(TTSModel.model(for: .design))
        let draft = VoiceDesignDraft(
            voiceDescription: "A clear, grounded English narrator.",
            delivery: DeliveryInputState(mode: .custom, customText: "Calm and reassuring."),
            text: "Warm this final-result design path."
        )

        let request = IOSPrefetchRequestFactory.voiceDesignRequest(
            model: model,
            draft: draft,
            fallbackText: GenerationSemantics.canonicalDesignWarmShortText,
            fallbackVoiceDescription: "Clear, natural narration voice"
        )

        XCTAssertFalse(request.shouldStream)
        XCTAssertEqual(request.mode, .design)
        XCTAssertEqual(request.text, draft.text)
        XCTAssertEqual(request.streamingInterval, GenerationSemantics.appStreamingInterval)
        guard case .design(let voiceDescription, let deliveryStyle) = request.payload else {
            return XCTFail("Expected Voice Design prefetch payload")
        }
        XCTAssertEqual(voiceDescription, "A clear, grounded English narrator.")
        XCTAssertEqual(deliveryStyle, "Calm and reassuring.")
    }

    @MainActor
    func testTTSEngineStoreForwardsActiveGenerationCancellationAndResetsState() async throws {
        let engine = IOSCancellableEngineFixture()
        let store = TTSEngineStore(
            backend: AnyTTSEngineBackend(
                engine: engine,
                supportsSavedVoiceMutation: true,
                supportsModelManagementMutation: true,
                supportedModes: [.custom]
            ),
            memorySnapshotProvider: { healthyIOSMemorySnapshot() }
        )
        let request = GenerationRequest(
            mode: .custom,
            modelID: "pro_custom_speed",
            text: "Cancel this iPhone generation.",
            outputPath: "/tmp/ios-cancel.wav",
            shouldStream: false,
            payload: .custom(speakerID: "vivian", deliveryStyle: nil)
        )

        let generationTask = Task {
            try await store.generate(request)
        }
        await engine.waitForGenerationStart()
        XCTAssertTrue(store.hasActiveGeneration)

        try await store.cancelActiveGeneration()

        XCTAssertEqual(engine.cancelActiveGenerationCallCount, 1)
        XCTAssertFalse(store.hasActiveGeneration)

        engine.finishGeneration(throwing: CancellationError())
        do {
            _ = try await generationTask.value
            XCTFail("Expected suspended generation to finish with cancellation.")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testIOSMemoryBudgetPolicyBandsAdmissionAndTrimLevels() {
        let policy = IOSMemoryBudgetPolicy.iPhoneShippingDefault

        let healthySnapshot = IOSMemorySnapshot(
            totalDeviceRAMBytes: 8 * 1_073_741_824,
            availableHeadroomBytes: policy.healthyHeadroomBytes + 1,
            residentBytes: nil,
            physFootprintBytes: nil,
            compressedBytes: nil,
            gpuAllocatedBytes: 10,
            gpuRecommendedWorkingSetBytes: 1_000,
            hasUnifiedMemory: true
        )
        XCTAssertEqual(policy.band(for: healthySnapshot), .healthy)
        XCTAssertTrue(policy.allowsModelAdmission(for: .healthy))
        XCTAssertTrue(policy.allowsProactiveWarmOperations(for: .healthy))
        XCTAssertNil(policy.postGenerationTrimLevel(for: .healthy))

        let guardedSnapshot = IOSMemorySnapshot(
            totalDeviceRAMBytes: 8 * 1_073_741_824,
            availableHeadroomBytes: policy.guardedHeadroomBytes + 1,
            residentBytes: nil,
            physFootprintBytes: nil,
            compressedBytes: nil,
            gpuAllocatedBytes: 10,
            gpuRecommendedWorkingSetBytes: 1_000,
            hasUnifiedMemory: true
        )
        XCTAssertEqual(policy.band(for: guardedSnapshot), .guarded)
        XCTAssertTrue(policy.allowsModelAdmission(for: .guarded))
        XCTAssertFalse(policy.allowsProactiveWarmOperations(for: .guarded))
        XCTAssertEqual(policy.postGenerationTrimLevel(for: .guarded), .hardTrim)

        let criticalSnapshot = IOSMemorySnapshot(
            totalDeviceRAMBytes: 8 * 1_073_741_824,
            availableHeadroomBytes: policy.guardedHeadroomBytes - 1,
            residentBytes: nil,
            physFootprintBytes: nil,
            compressedBytes: nil,
            gpuAllocatedBytes: 900,
            gpuRecommendedWorkingSetBytes: 1_000,
            hasUnifiedMemory: true
        )
        XCTAssertEqual(policy.band(for: criticalSnapshot), .critical)
        XCTAssertFalse(policy.allowsModelAdmission(for: .critical))
        XCTAssertFalse(policy.allowsProactiveWarmOperations(for: .critical))
        XCTAssertEqual(policy.postGenerationTrimLevel(for: .critical), .fullUnload)
        XCTAssertEqual(
            policy.trimLevelForPressureEvent(
                snapshot: criticalSnapshot,
                isBackgroundTransition: false
            ),
            .fullUnload
        )
        XCTAssertEqual(
            policy.trimLevelForPressureEvent(
                snapshot: healthySnapshot,
                isBackgroundTransition: true
            ),
            .fullUnload
        )
    }

    func testIOSMemoryBandFallsBackToFootprintWhenHeadroomIsUnavailable() {
        let policy = IOSMemoryBudgetPolicy.iPhoneShippingDefault
        let totalRAM = UInt64(8 * 1_073_741_824)

        let guardedSnapshot = IOSMemorySnapshot(
            totalDeviceRAMBytes: totalRAM,
            availableHeadroomBytes: nil,
            residentBytes: nil,
            physFootprintBytes: totalRAM - policy.healthyHeadroomBytes + 1,
            compressedBytes: nil,
            gpuAllocatedBytes: nil,
            gpuRecommendedWorkingSetBytes: nil,
            hasUnifiedMemory: true
        )
        XCTAssertEqual(policy.band(for: guardedSnapshot), .guarded)

        let criticalSnapshot = IOSMemorySnapshot(
            totalDeviceRAMBytes: totalRAM,
            availableHeadroomBytes: nil,
            residentBytes: totalRAM - policy.guardedHeadroomBytes + 1,
            physFootprintBytes: nil,
            compressedBytes: nil,
            gpuAllocatedBytes: nil,
            gpuRecommendedWorkingSetBytes: nil,
            hasUnifiedMemory: true
        )
        XCTAssertEqual(policy.band(for: criticalSnapshot), .critical)

        let unknownSnapshot = IOSMemorySnapshot(
            totalDeviceRAMBytes: totalRAM,
            availableHeadroomBytes: nil,
            residentBytes: nil,
            physFootprintBytes: nil,
            compressedBytes: nil,
            gpuAllocatedBytes: nil,
            gpuRecommendedWorkingSetBytes: nil,
            hasUnifiedMemory: true
        )
        XCTAssertEqual(policy.band(for: unknownSnapshot), .healthy)
    }

    private func loadMatrix() throws -> PlatformCapabilityMatrix {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let matrixURL = repoRoot
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("apple-platform-capability-matrix.json", isDirectory: false)
        let data = try Data(contentsOf: matrixURL)
        return try JSONDecoder().decode(PlatformCapabilityMatrix.self, from: data)
    }
}

private struct PlatformCapabilityMatrix: Decodable {
    let iOS: IOSPlatform

    private enum CodingKeys: String, CodingKey {
        case iOS = "iOS"
    }

    struct IOSPlatform: Decodable {
        let app: RuntimeSurface
        let `extension`: RuntimeSurface
    }

    struct RuntimeSurface: Decodable {
        let applicationGroups: [String]
        let engineCapabilities: EngineCapabilities
    }
}

private func healthyIOSMemorySnapshot() -> IOSMemorySnapshot {
    IOSMemorySnapshot(
        totalDeviceRAMBytes: 8 * 1_073_741_824,
        availableHeadroomBytes: 3 * 1_073_741_824,
        residentBytes: nil,
        physFootprintBytes: nil,
        compressedBytes: nil,
        gpuAllocatedBytes: 128 * 1_048_576,
        gpuRecommendedWorkingSetBytes: 2 * 1_073_741_824,
        hasUnifiedMemory: true
    )
}

private struct IOSPolicyStubModelRegistry: ModelRegistry {
    let models = [
        ModelDescriptor(
            id: "pro_custom_speed",
            name: "Custom Voice Speed",
            tier: "pro",
            folder: "Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
            mode: .custom,
            huggingFaceRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
            huggingFaceRevision: "0123456789abcdef0123456789abcdef01234567",
            artifactVersion: "2026.04.05.2",
            iosDownloadEligible: true,
            estimatedDownloadBytes: 1,
            outputSubfolder: "CustomVoice",
            requiredRelativePaths: ["model.safetensors"]
        ),
    ]

    let defaultSpeaker = SpeakerDescriptor(group: "English", id: "aiden")
    let groupedSpeakers = ["English": [SpeakerDescriptor(group: "English", id: "aiden")]]
    let allSpeakers = [SpeakerDescriptor(group: "English", id: "aiden")]

    func model(for mode: GenerationMode) -> ModelDescriptor? {
        models.first { $0.mode == mode }
    }

    func model(id: String) -> ModelDescriptor? {
        models.first { $0.id == id }
    }
}

@MainActor
private final class IOSCancellableEngineFixture: TTSEngine, ActiveGenerationCancellable {
    let objectWillChange = ObservableObjectPublisher()
    let modelRegistry: any ModelRegistry = IOSPolicyStubModelRegistry()
    var loadState: EngineLoadState = .loaded(modelID: "pro_custom_speed")
    var clonePreparationState: ClonePreparationState = .idle
    var latestEvent: GenerationEvent?
    var isReady = true
    var visibleErrorMessage: String?
    private(set) var cancelActiveGenerationCallCount = 0

    private var didStartGeneration = false
    private var generationStartedContinuation: CheckedContinuation<Void, Never>?
    private var generationContinuation: CheckedContinuation<GenerationResult, Error>?

    func waitForGenerationStart() async {
        if didStartGeneration { return }
        await withCheckedContinuation { continuation in
            generationStartedContinuation = continuation
        }
    }

    func finishGeneration(throwing error: Error) {
        generationContinuation?.resume(throwing: error)
        generationContinuation = nil
    }

    func supportDecision(for request: GenerationRequest) -> GenerationSupportDecision {
        .supported(.nativeMLX)
    }

    func start() {}
    func stop() {}
    func initialize(appSupportDirectory: URL) async throws {}
    func ping() async throws -> Bool { true }
    func loadModel(id: String) async throws {}
    func unloadModel() async throws {}

    func prepareAudio(_ request: AudioPreparationRequest) async throws -> AudioNormalizationResult {
        throw MLXTTSEngineError.unsupportedRequest("Audio preparation is not used by this fixture.")
    }

    func ensureModelLoadedIfNeeded(id: String) async {}
    func prewarmModelIfNeeded(for request: GenerationRequest) async {}
    func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {}
    func cancelClonePreparationIfNeeded() async {}

    func cancelActiveGeneration() async throws {
        cancelActiveGenerationCallCount += 1
    }

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        didStartGeneration = true
        generationStartedContinuation?.resume()
        generationStartedContinuation = nil
        return try await withCheckedThrowingContinuation { continuation in
            generationContinuation = continuation
        }
    }

    func listPreparedVoices() async throws -> [PreparedVoice] { [] }

    func enrollPreparedVoice(name: String, audioPath: String, transcript: String?) async throws -> PreparedVoice {
        PreparedVoice(id: name, name: name, audioPath: audioPath, hasTranscript: !(transcript?.isEmpty ?? true))
    }

    func deletePreparedVoice(id: String) async throws {}

    func importReferenceAudio(from sourceURL: URL) throws -> ImportedReferenceAudio {
        ImportedReferenceAudio(
            originalPath: sourceURL.path,
            materializedPath: sourceURL.path,
            transcriptSidecarPath: nil,
            fingerprint: "fixture"
        )
    }

    func exportGeneratedAudio(from sourceURL: URL, to destinationURL: URL) throws -> ExportedDocument {
        ExportedDocument(sourcePath: sourceURL.path, destinationPath: destinationURL.path)
    }

    func clearGenerationActivity() {
        latestEvent = nil
    }

    func clearVisibleError() {
        visibleErrorMessage = nil
    }
}
