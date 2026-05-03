import Foundation
import XCTest
@testable import QwenVoiceCore

/// Smoke tests for the Session 5b mock infrastructure
/// (`MockMLXModelCoordinator` + `MLXTTSEngine.makeForTesting`). These
/// validate that `MLXTTSEngine` can be driven through its internal
/// load-coordinator seam without touching MLX, so the bulk test port in
/// Session 5c can rely on the recipe.
///
/// Coverage here is intentionally minimal — the goal is to prove the
/// seam works end-to-end, not to duplicate the 19 tests in
/// `NativeMLXMacEngineTests` (those land against the same recipe in
/// Session 5c).
@MainActor
final class MLXTTSEngineMockBackedTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        temporaryRoot = try Self.makeTemporaryRoot()
    }

    override func tearDown() async throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
        try await super.tearDown()
    }

    func testEngineSurfacesMockLoadFailureAndKeepsCurrentLoadedModelIDNil() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator()
        let engine = MLXTTSEngine.makeForTesting(
            modelRegistry: registry,
            rootDirectory: temporaryRoot,
            loadCoordinator: coordinator
        )
        try await engine.initialize(appSupportDirectory: temporaryRoot)

        XCTAssertEqual(engine.loadState, .idle)
        let preLoadID = await engine.currentLoadedModelID()
        XCTAssertNil(preLoadID)

        var didThrow = false
        do {
            try await engine.loadModel(id: "qwen3_custom_voice")
        } catch {
            didThrow = true
        }
        XCTAssertTrue(didThrow, "Expected loadModel to throw when the mock coordinator's loadHandler is nil.")

        XCTAssertEqual(coordinator.loadCalls.count, 1)
        XCTAssertEqual(coordinator.loadCalls.first?.modelID, "qwen3_custom_voice")
        let postLoadID = await engine.currentLoadedModelID()
        XCTAssertNil(postLoadID)
        if case .failed = engine.loadState {
            // Expected
        } else {
            XCTFail("Expected loadState to be .failed after the mock coordinator threw, got \(engine.loadState)")
        }
        XCTAssertNotNil(engine.visibleErrorMessage)
    }

    func testEngineUnloadInvokesMockCoordinatorAndClearsLoadState() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator()
        let engine = MLXTTSEngine.makeForTesting(
            modelRegistry: registry,
            rootDirectory: temporaryRoot,
            loadCoordinator: coordinator
        )
        try await engine.initialize(appSupportDirectory: temporaryRoot)

        try await engine.unloadModel()

        XCTAssertEqual(coordinator.unloadCallCount, 1)
        XCTAssertEqual(engine.loadState, .idle)
        let loadedID = await engine.currentLoadedModelID()
        XCTAssertNil(loadedID)
    }

    // MARK: - Ported from NativeMLXMacEngineTests (Session 5c batch 1)

    /// Ported equivalent of
    /// `NativeMLXMacEngineTests.testInitializeCreatesNativeRuntimeDirectoriesAndSupportsPreparedVoices`.
    /// Asserts the directory layout that `MLXTTSEngine.initialize` actually
    /// owns (a smaller set than `MacNativeRuntime` did — `models/`,
    /// `downloads/staging/`, `outputs/` etc. are owned by other layers and
    /// created on demand, not at init).
    func testInitializeCreatesEngineOwnedDirectoriesAndSupportsPreparedVoices() async throws {
        let sourceAudio = temporaryRoot.appendingPathComponent("sample.wav")
        try Data("sample-audio".utf8).write(to: sourceAudio)

        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator()
        let engine = MLXTTSEngine.makeForTesting(
            modelRegistry: registry,
            rootDirectory: temporaryRoot,
            loadCoordinator: coordinator
        )
        try await engine.initialize(appSupportDirectory: temporaryRoot)

        let engineOwnedDirectories = [
            "voices",
            "cache/normalized_clone_refs",
            "cache/stream_sessions",
        ]

        for relativePath in engineOwnedDirectories {
            let directoryURL = temporaryRoot.appendingPathComponent(relativePath, isDirectory: true)
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
                "Expected directory at \(relativePath)"
            )
            XCTAssertTrue(isDirectory.boolValue, "Expected \(relativePath) to be a directory")
        }

        let enrolled = try await engine.enrollPreparedVoice(
            name: "Sample Voice",
            audioPath: sourceAudio.path,
            transcript: "Hello from the mock-backed engine"
        )
        XCTAssertEqual(enrolled.id, "Sample Voice")
        XCTAssertTrue(enrolled.hasTranscript)
        XCTAssertTrue(
            enrolled.audioPath.hasPrefix(temporaryRoot.appendingPathComponent("voices").path),
            "Expected enrolled voice audio under the engine's voices directory."
        )

        let listed = try await engine.listPreparedVoices()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, enrolled.id)
        XCTAssertEqual(listed.first?.name, enrolled.name)
        XCTAssertEqual(listed.first?.hasTranscript, enrolled.hasTranscript)
        XCTAssertEqual(
            URL(fileURLWithPath: listed.first?.audioPath ?? "").resolvingSymlinksInPath().path,
            URL(fileURLWithPath: enrolled.audioPath).resolvingSymlinksInPath().path
        )

        try await engine.deletePreparedVoice(id: enrolled.id)
        let remainingVoices = try await engine.listPreparedVoices()
        XCTAssertTrue(remainingVoices.isEmpty)
    }

    /// Ported equivalent of
    /// `NativeMLXMacEngineTests.testNativeMLXMacEnginePublishesStartingAndLoadedStateForAvailableModel`.
    /// The mock load handler sleeps 150 ms so the test can observe the
    /// `.starting` state transition before the load completes, then
    /// asserts the `.loaded(modelID:)` final state and clean unload.
    func testEnginePublishesStartingAndLoadedStateAcrossSuccessfulMockLoad() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator(loadHandler: { _, capabilityProfile in
            try await Task.sleep(nanoseconds: 150_000_000)
            return await NativeModelLoadResult.makeForTesting(
                capabilityProfile: capabilityProfile
            )
        })
        let engine = MLXTTSEngine.makeForTesting(
            modelRegistry: registry,
            rootDirectory: temporaryRoot,
            loadCoordinator: coordinator
        )
        try await engine.initialize(appSupportDirectory: temporaryRoot)
        XCTAssertEqual(engine.loadState, .idle)

        let loadTask = Task { @MainActor in
            try await engine.loadModel(id: "qwen3_custom_voice")
        }
        await Task.yield()
        _ = await waitUntil(
            timeoutSeconds: 0.5,
            description: "engine load state reaches .starting"
        ) {
            engine.loadState == .starting
        }
        XCTAssertEqual(engine.loadState, .starting)
        try await loadTask.value

        XCTAssertEqual(engine.loadState, .loaded(modelID: "qwen3_custom_voice"))
        XCTAssertNil(engine.visibleErrorMessage)
        let loadedID = await engine.currentLoadedModelID()
        XCTAssertEqual(loadedID, "qwen3_custom_voice")
        XCTAssertEqual(coordinator.loadCalls.count, 1)
        XCTAssertEqual(coordinator.loadCalls.first?.modelID, "qwen3_custom_voice")

        try await engine.unloadModel()
        XCTAssertEqual(engine.loadState, .idle)
        XCTAssertNil(engine.visibleErrorMessage)
        XCTAssertEqual(coordinator.unloadCallCount, 1)
    }

    /// Ported equivalent of
    /// `NativeMLXMacEngineTests.testNativeMLXMacEngineClonePrimingRequiresAvailableModel`.
    /// Verifies that calling `ensureCloneReferencePrimed` against a model
    /// the coordinator cannot load surfaces both `clonePreparationState`
    /// `.failed` and `loadState` `.failed(...)`. Note: Core's
    /// `MLXTTSEngine` retains the failed clone-prep state on error
    /// (NativeMLXMacEngine reset it to `.idle` via its
    /// `publishRuntimeFailure` snapshot), so the assertion shape differs
    /// from the legacy test by design.
    /// Ported (in shape) from
    /// `NativeMLXMacEngineTests.testNativeMLXMacEngineGeneratesCustomAudioAndPublishesChunkEvents`.
    /// Validates the full `MLXTTSEngine.generate(_:)` path via the
    /// streaming-session seam: the engine prepares generation, builds a
    /// streaming session through the test factory (which returns a
    /// `MockNativeStreamingSession`), and surfaces canned events to
    /// `latestEvent`.
    ///
    /// Differs from the legacy test by design: the legacy test exercised
    /// a real `NativeStreamingSynthesisSession` driven by a closure-based
    /// `NativeSpeechGenerationModel`, which actually wrote audio to disk.
    /// Here we mock the entire streaming session, so no audio file is
    /// written — the assertion shape verifies the orchestration (prepare
    /// → factory → session.run) rather than file artifacts. File-artifact
    /// coverage will land via integration tests that exercise a richer
    /// model mock in a later batch.
    func testEngineGenerateRoutesThroughStreamingSessionFactoryAndSurfacesLatestEvent() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator(loadHandler: { _, capabilityProfile in
            return await NativeModelLoadResult.makeForTesting(
                model: UnsafeSpeechGenerationModel.makeFullySupportingForTesting(),
                capabilityProfile: capabilityProfile
            )
        })

        let chunk1 = GenerationEvent(
            kind: .streamChunk,
            requestID: 1,
            mode: "custom",
            title: "Mock Custom Preview",
            isFinal: false,
            chunkDurationSeconds: 0.05,
            cumulativeDurationSeconds: 0.05
        )
        let chunk2Final = GenerationEvent(
            kind: .streamChunk,
            requestID: 1,
            mode: "custom",
            title: "Mock Custom Preview",
            isFinal: true,
            chunkDurationSeconds: 0.05,
            cumulativeDurationSeconds: 0.10
        )
        let cannedOutputPath = temporaryRoot.appendingPathComponent("mock-custom.wav").path
        let cannedResult = GenerationResult(
            audioPath: cannedOutputPath,
            durationSeconds: 0.10,
            streamSessionDirectory: temporaryRoot.appendingPathComponent("cache/stream_sessions/mock").path,
            benchmarkSample: nil
        )
        let mockSession = MockNativeStreamingSession(
            events: [chunk1, chunk2Final],
            result: cannedResult
        )

        let engine = MLXTTSEngine.makeForTesting(
            modelRegistry: registry,
            rootDirectory: temporaryRoot,
            loadCoordinator: coordinator,
            streamingSessionFactory: { _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
                mockSession
            }
        )
        try await engine.initialize(appSupportDirectory: temporaryRoot)
        try await engine.loadModel(id: "qwen3_custom_voice")

        let request = GenerationRequest(
            modelID: "qwen3_custom_voice",
            text: "Hello from the mock-backed engine.",
            outputPath: cannedOutputPath,
            shouldStream: true,
            streamingTitle: "Mock Custom Preview",
            payload: .custom(speakerID: "vivian", deliveryStyle: "Conversational")
        )
        let result = try await engine.generate(request)

        XCTAssertEqual(mockSession.runCallCount, 1)
        XCTAssertEqual(result.audioPath, cannedResult.audioPath)
        XCTAssertEqual(result.durationSeconds, cannedResult.durationSeconds)
        XCTAssertEqual(result.streamSessionDirectory, cannedResult.streamSessionDirectory)
        XCTAssertEqual(engine.latestEvent, chunk2Final)
        XCTAssertEqual(engine.loadState, .loaded(modelID: "qwen3_custom_voice"))
        XCTAssertNil(engine.visibleErrorMessage)
    }

    func testEngineClonePrimingSurfacesLoadFailureWhenCoordinatorCannotLoadModel() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator()
        let engine = MLXTTSEngine.makeForTesting(
            modelRegistry: registry,
            rootDirectory: temporaryRoot,
            loadCoordinator: coordinator
        )
        try await engine.initialize(appSupportDirectory: temporaryRoot)

        let reference = CloneReference(
            audioPath: "/tmp/missing-reference.wav",
            transcript: "Reference transcript"
        )
        var didThrow = false
        do {
            try await engine.ensureCloneReferencePrimed(
                modelID: "qwen3_clone_voice",
                reference: reference
            )
        } catch {
            didThrow = true
        }
        XCTAssertTrue(didThrow, "Expected ensureCloneReferencePrimed to throw when the coordinator cannot load the model.")

        // The runtime calls loadModel with `.cloneOnly` capability profile
        // before resolving conditioning, so the mock should observe a
        // single load attempt with that profile.
        XCTAssertEqual(coordinator.loadCalls.count, 1)
        XCTAssertEqual(coordinator.loadCalls.first?.modelID, "qwen3_clone_voice")
        XCTAssertEqual(coordinator.loadCalls.first?.capabilityProfile, .cloneOnly)

        XCTAssertEqual(engine.clonePreparationState.phase, .failed)
        if case .failed(let message) = engine.loadState {
            XCTAssertEqual(engine.visibleErrorMessage, message)
        } else {
            XCTFail("Expected loadState to be .failed after the prime path threw, got \(engine.loadState)")
        }
    }

    // MARK: - Helpers

    private static func makeTemporaryRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXTTSEngineMockBackedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func bundledManifestURL() throws -> URL {
        let bundles = [Bundle.main, Bundle(for: BundleLocator.self)] + Bundle.allBundles + Bundle.allFrameworks
        for bundle in bundles {
            if let url = bundle.url(forResource: "qwenvoice_contract", withExtension: "json") {
                return url
            }
        }
        throw NSError(
            domain: "MLXTTSEngineMockBackedTests",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate qwenvoice_contract.json in any test bundle."]
        )
    }

    private final class BundleLocator: NSObject {}
}
