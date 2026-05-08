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
            shouldStream: true,
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

    let defaultSpeaker = SpeakerDescriptor(group: "English", id: "vivian")
    let groupedSpeakers = ["English": [SpeakerDescriptor(group: "English", id: "vivian")]]
    let allSpeakers = [SpeakerDescriptor(group: "English", id: "vivian")]

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
