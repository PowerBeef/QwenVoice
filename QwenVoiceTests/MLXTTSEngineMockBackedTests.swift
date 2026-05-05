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

    func testIdleUnloadPolicyUnloadsLoadedModelAfterDelay() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator(loadHandler: { _, capabilityProfile in
            await NativeModelLoadResult.makeForTesting(
                model: UnsafeSpeechGenerationModel.makeFullySupportingForTesting(),
                capabilityProfile: capabilityProfile
            )
        })
        let engine = MLXTTSEngine.makeForTesting(
            modelRegistry: registry,
            rootDirectory: temporaryRoot,
            loadCoordinator: coordinator,
            idleUnloadDelayOverride: 0.01
        )
        try await engine.initialize(appSupportDirectory: temporaryRoot)

        try await engine.loadModel(id: "pro_custom")
        XCTAssertEqual(engine.loadState, .loaded(modelID: "pro_custom"))

        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(coordinator.unloadCallCount, 1)
        XCTAssertEqual(engine.loadState, .idle)
        let loadedID = await engine.currentLoadedModelID()
        XCTAssertNil(loadedID)
    }

    func testIdleUnloadPolicyCancelsWhenWorkRestarts() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator(loadHandler: { _, capabilityProfile in
            await NativeModelLoadResult.makeForTesting(
                model: UnsafeSpeechGenerationModel.makeFullySupportingForTesting(),
                capabilityProfile: capabilityProfile
            )
        })
        let engine = MLXTTSEngine.makeForTesting(
            modelRegistry: registry,
            rootDirectory: temporaryRoot,
            loadCoordinator: coordinator,
            idleUnloadDelayOverride: 0.06
        )
        try await engine.initialize(appSupportDirectory: temporaryRoot)

        try await engine.loadModel(id: "pro_custom")
        try await Task.sleep(nanoseconds: 30_000_000)
        try await engine.loadModel(id: "pro_custom")
        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(coordinator.unloadCallCount, 0)
        XCTAssertEqual(engine.loadState, .loaded(modelID: "pro_custom"))

        try await engine.unloadModel()
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

    /// Ported equivalent of
    /// `NativeMLXMacEngineTests.testNativeMLXMacEngineGenerateBatchSupports
    /// HomogeneousCloneRequestsAndReusesConditioning`. Drives a 2-item
    /// homogeneous clone batch through the engine and asserts that the
    /// runtime emits `clone_conditioning_reused == false` on the first
    /// request and `clone_conditioning_reused == true` on the second
    /// (the cache hit path).
    ///
    /// Captures the `booleanFlags` at each streaming-session-factory
    /// invocation via `MockNativeStreamingSession.recordFactoryFlags(_:)`
    /// — `MLXTTSEngine.runGenerationAttempt` passes the runtime's
    /// `prepareGeneration`-emitted flags to the factory at index 6, and
    /// the mock session itself does not expose them on the result.
    func testEngineCloneBatchSurfacesConditioningReuseFlagAcrossRequests() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator(loadHandler: { _, capabilityProfile in
            return await NativeModelLoadResult.makeForTesting(
                model: UnsafeSpeechGenerationModel.makeFullySupportingForTesting(),
                capabilityProfile: capabilityProfile
            )
        })

        let referenceURL = temporaryRoot.appendingPathComponent("batch-clone-reference.wav")
        try NativeRuntimeTestSupport.writeTestWAV(to: referenceURL, sampleRate: 24_000, channels: 1)

        let mockSession = MockNativeStreamingSession(
            events: [],
            result: GenerationResult(
                audioPath: temporaryRoot.appendingPathComponent("batch-clone.wav").path,
                durationSeconds: 0.05,
                streamSessionDirectory: nil,
                benchmarkSample: nil
            )
        )
        let engine = MLXTTSEngine.makeForTesting(
            modelRegistry: registry,
            rootDirectory: temporaryRoot,
            loadCoordinator: coordinator,
            streamingSessionFactory: { _, _, _, _, _, _, booleanFlags, _, _, _, _, _, _, _ in
                mockSession.recordFactoryFlags(booleanFlags)
                return mockSession
            }
        )
        try await engine.initialize(appSupportDirectory: temporaryRoot)

        let reference = CloneReference(
            audioPath: referenceURL.path,
            transcript: "Batch transcript"
        )
        let first = GenerationRequest(
            modelID: "qwen3_clone_voice",
            text: "First clone item",
            outputPath: temporaryRoot.appendingPathComponent("clone-first.wav").path,
            shouldStream: false,
            payload: .clone(reference: reference)
        )
        let second = GenerationRequest(
            modelID: "qwen3_clone_voice",
            text: "Second clone item",
            outputPath: temporaryRoot.appendingPathComponent("clone-second.wav").path,
            shouldStream: false,
            payload: .clone(reference: reference)
        )

        let results = try await engine.generateBatch([first, second]) { _, _ in }

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(mockSession.runCallCount, 2)
        XCTAssertEqual(mockSession.factoryBooleanFlagsHistory.count, 2)
        XCTAssertEqual(
            mockSession.factoryBooleanFlagsHistory[0]["clone_conditioning_reused"],
            false,
            "First batch item should not have clone-conditioning reuse."
        )
        XCTAssertEqual(
            mockSession.factoryBooleanFlagsHistory[1]["clone_conditioning_reused"],
            true,
            "Second batch item should hit the clone-conditioning cache."
        )
        XCTAssertEqual(engine.loadState, .loaded(modelID: "qwen3_clone_voice"))
        XCTAssertNil(engine.visibleErrorMessage)
    }

    /// Ported (in shape) from
    /// `NativeMLXMacEngineTests.testNativeMLXMacEngineGenerateBatchSupports
    /// HomogeneousCustomRequests`. The earlier `testEngineGenerateBatch
    /// RoutesEachRequestThroughStreamingSession` covers `.design` mode
    /// only — `.custom` mode flows through a different prepare path
    /// inside `NativeEngineRuntime.prepareGeneration` (custom prewarm
    /// policy + `ensureWarmStateIfNeeded`), so a separate batch port is
    /// needed for true coverage of the custom-batch orchestration.
    ///
    /// Asserts every batched request reaches the streaming session
    /// factory once. Drops the legacy `usedStreaming == false` assertion
    /// and the audio-file-existence checks for the same reason as the
    /// design-batch port (mock streaming session bypasses real audio
    /// writing; orchestration is what's being verified).
    func testEngineGenerateBatchRoutesCustomModeRequestsThroughStreamingSession() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator(loadHandler: { _, capabilityProfile in
            return await NativeModelLoadResult.makeForTesting(
                model: UnsafeSpeechGenerationModel.makeFullySupportingForTesting(),
                capabilityProfile: capabilityProfile
            )
        })

        let mockSession = MockNativeStreamingSession(
            events: [],
            result: GenerationResult(
                audioPath: temporaryRoot.appendingPathComponent("mock-custom-batch.wav").path,
                durationSeconds: 0.05,
                streamSessionDirectory: nil,
                benchmarkSample: nil
            )
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

        // True homogeneous custom batch: same speaker + same delivery style.
        // Core's `MLXTTSEngine.generateBatch` rejects mixed sessions (model
        // + mode + language + speaker/design + clone reference), and that
        // rejection path is already covered by
        // `testEngineGenerateBatchRejectsMixedModesBeforeLoading`.
        let first = GenerationRequest(
            modelID: "qwen3_custom_voice",
            text: "First custom item",
            outputPath: temporaryRoot.appendingPathComponent("custom-first.wav").path,
            shouldStream: false,
            payload: .custom(speakerID: "vivian", deliveryStyle: "Conversational")
        )
        let second = GenerationRequest(
            modelID: "qwen3_custom_voice",
            text: "Second custom item",
            outputPath: temporaryRoot.appendingPathComponent("custom-second.wav").path,
            shouldStream: false,
            payload: .custom(speakerID: "vivian", deliveryStyle: "Conversational")
        )

        let results = try await engine.generateBatch([first, second]) { _, _ in }

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(mockSession.runCallCount, 2)
        XCTAssertEqual(engine.loadState, .loaded(modelID: "qwen3_custom_voice"))
        XCTAssertNil(engine.visibleErrorMessage)
    }

    /// Ported (in shape) from
    /// `NativeMLXMacEngineTests.testNativeMLXMacEngineBatchCancellation
    /// StopsBeforeLaterItemsStart`. Verifies that cancellation during
    /// the first batch item's streaming session prevents the second
    /// item from EVER reaching the streaming-session factory — which is
    /// the responsibility of the `try Task.checkCancellation()` at the
    /// top of `MLXTTSEngine.generateBatch`'s for-loop.
    ///
    /// Cancellation is propagated via `task.cancel()` on the calling
    /// Task (Core's `MLXTTSEngine` does not expose a separate
    /// `cancelActiveGeneration()` API). The mock session has
    /// `eventDelay: 500ms` so the first item's session.run is mid-sleep
    /// when cancellation fires; cancellation throws out of session.run,
    /// out of generateBatch's first iteration, and the for-loop's
    /// `try Task.checkCancellation()` rejects the second iteration
    /// before any factory call.
    ///
    /// Differs from the existing single-item cancellation test
    /// (`testEngineGenerateCancelledMidStreamStopsFurtherChunks`) by
    /// asserting at the BATCH level: only one factory call total,
    /// proving the second item never started.
    func testEngineGenerateBatchCancellationStopsBeforeSecondItemStarts() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator(loadHandler: { _, capabilityProfile in
            return await NativeModelLoadResult.makeForTesting(
                model: UnsafeSpeechGenerationModel.makeFullySupportingForTesting(),
                capabilityProfile: capabilityProfile
            )
        })

        let mockSession = MockNativeStreamingSession(
            events: [
                GenerationEvent(
                    kind: .streamChunk,
                    requestID: 1,
                    mode: "custom",
                    title: "Batch cancel item 1",
                    isFinal: false,
                    chunkDurationSeconds: 0.05,
                    cumulativeDurationSeconds: 0.05
                )
            ],
            result: GenerationResult(
                audioPath: temporaryRoot.appendingPathComponent("mock-batch-cancel.wav").path,
                durationSeconds: 0.05,
                streamSessionDirectory: nil,
                benchmarkSample: nil
            ),
            eventDelay: .milliseconds(500)
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

        let first = GenerationRequest(
            modelID: "qwen3_custom_voice",
            text: "First batch item",
            outputPath: temporaryRoot.appendingPathComponent("batch-first.wav").path,
            shouldStream: true,
            payload: .custom(speakerID: "vivian", deliveryStyle: nil)
        )
        let second = GenerationRequest(
            modelID: "qwen3_custom_voice",
            text: "Second batch item",
            outputPath: temporaryRoot.appendingPathComponent("batch-second.wav").path,
            shouldStream: true,
            payload: .custom(speakerID: "vivian", deliveryStyle: nil)
        )

        let task = Task { @MainActor in
            try await engine.generateBatch([first, second]) { _, _ in }
        }
        _ = await waitUntil(
            timeoutSeconds: 1.0,
            description: "first batch item reaches streaming session"
        ) {
            mockSession.runCallCount >= 1
        }
        task.cancel()

        var observedCancellation = false
        do {
            _ = try await task.value
            XCTFail("Expected batch generation to be cancelled.")
        } catch is CancellationError {
            observedCancellation = true
        } catch {
            XCTAssertTrue(
                error.localizedDescription.lowercased().contains("cancel"),
                "Expected CancellationError or cancel-flavored failure, got \(error)"
            )
            observedCancellation = true
        }
        XCTAssertTrue(observedCancellation)
        XCTAssertEqual(
            mockSession.runCallCount,
            1,
            "Only the first batch item should have reached the streaming session; the second must be rejected at the for-loop's Task.checkCancellation() before its factory call."
        )
    }

    /// Ported equivalent of
    /// `NativeMLXMacEngineTests.testNativeMLXMacEnginePublishesLoadAndClone
    /// PreparationStateForAvailableCloneModel`. Verifies the happy path:
    /// load the model, prime a real reference WAV, observe
    /// `clonePreparationState.phase == .primed` with the expected key,
    /// then unload returns to `.idle`.
    func testEngineCloneReferencePrimingPublishesPrimedStateForAvailableModel() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator(loadHandler: { _, capabilityProfile in
            return await NativeModelLoadResult.makeForTesting(
                model: UnsafeSpeechGenerationModel.makeFullySupportingForTesting(),
                capabilityProfile: capabilityProfile
            )
        })
        let engine = MLXTTSEngine.makeForTesting(
            modelRegistry: registry,
            rootDirectory: temporaryRoot,
            loadCoordinator: coordinator
        )
        try await engine.initialize(appSupportDirectory: temporaryRoot)

        let referenceURL = temporaryRoot.appendingPathComponent("primed-reference.wav")
        try NativeRuntimeTestSupport.writeTestWAV(to: referenceURL, sampleRate: 24_000, channels: 1)

        try await engine.loadModel(id: "qwen3_clone_voice")
        let reference = CloneReference(
            audioPath: referenceURL.path,
            transcript: "Reference"
        )
        try await engine.ensureCloneReferencePrimed(
            modelID: "qwen3_clone_voice",
            reference: reference
        )

        XCTAssertEqual(engine.clonePreparationState.phase, .primed)
        XCTAssertNotNil(engine.clonePreparationState.identityKey)
        XCTAssertNil(engine.visibleErrorMessage)

        try await engine.unloadModel()
        XCTAssertEqual(engine.loadState, .idle)
        XCTAssertEqual(engine.clonePreparationState, .idle)
    }

    /// Ported (in shape) from
    /// `NativeMLXMacEngineTests.testNativeMLXMacEnginePublishesFailedClone
    /// PreparationStateForInvalidReferenceAfterLoad`. Differs from the
    /// already-ported negative-load test by design: here the model loads
    /// successfully and only the *reference file* is invalid, so the
    /// failure mode is "prime threw post-load" rather than "load
    /// failed".
    ///
    /// Behavior divergence from the legacy test by design: legacy
    /// NativeMLXMacEngine left `loadState == .loaded(modelID:)` after a
    /// prime failure (only `clonePreparationState` flipped to `.failed`).
    /// Core's `MLXTTSEngine.ensureCloneReferencePrimed` catch block calls
    /// `handle(error)` which sets `loadState = .failed`, treating the
    /// prime failure as a load failure surfaced to the UI. Both
    /// `clonePreparationState.phase == .failed` AND `loadState == .failed`
    /// after the throw on Core's path.
    func testEngineCloneReferencePrimingPublishesFailedStateForMissingReferenceAfterLoad() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator(loadHandler: { _, capabilityProfile in
            return await NativeModelLoadResult.makeForTesting(
                model: UnsafeSpeechGenerationModel.makeFullySupportingForTesting(),
                capabilityProfile: capabilityProfile
            )
        })
        let engine = MLXTTSEngine.makeForTesting(
            modelRegistry: registry,
            rootDirectory: temporaryRoot,
            loadCoordinator: coordinator
        )
        try await engine.initialize(appSupportDirectory: temporaryRoot)
        try await engine.loadModel(id: "qwen3_clone_voice")
        XCTAssertEqual(engine.loadState, .loaded(modelID: "qwen3_clone_voice"))

        let missingReference = temporaryRoot.appendingPathComponent("missing.wav")
        let reference = CloneReference(
            audioPath: missingReference.path,
            transcript: "Reference"
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
        XCTAssertTrue(didThrow)

        XCTAssertEqual(engine.clonePreparationState.phase, .failed)
        XCTAssertNotNil(engine.clonePreparationState.errorMessage)
        if case .failed(let message) = engine.loadState {
            XCTAssertEqual(engine.visibleErrorMessage, message)
        } else {
            XCTFail("Expected loadState to be .failed (Core treats prime failure as a load failure), got \(engine.loadState)")
        }
    }

    /// Ported (in shape) from
    /// `NativeMLXMacEngineTests.testNativeMLXMacEngineCancellationBeforeFirstChunkDoesNotWriteFinalOutput`.
    /// The mock streaming session is configured with `initialDelay`
    /// (500 ms) before any events fire; the test cancels the generate
    /// task after 50 ms, so the session's `Task.sleep` throws
    /// `CancellationError` before the first event.
    ///
    /// Cancellation is propagated via `task.cancel()` on the calling
    /// Task — Core's `MLXTTSEngine` does not expose a separate
    /// `cancelActiveGeneration()` API (the legacy NativeMLXMacEngine
    /// did); the mock streaming session's cancellation-aware
    /// `Task.sleep` and explicit `Task.checkCancellation()` boundaries
    /// give the same effective control surface.
    func testEngineGenerateCancelledBeforeFirstChunkPropagatesCancellationError() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator(loadHandler: { _, capabilityProfile in
            return await NativeModelLoadResult.makeForTesting(
                model: UnsafeSpeechGenerationModel.makeFullySupportingForTesting(),
                capabilityProfile: capabilityProfile
            )
        })

        let cannedOutputPath = temporaryRoot.appendingPathComponent("cancel-before-first-chunk.wav").path
        let mockSession = MockNativeStreamingSession(
            events: [
                GenerationEvent(
                    kind: .streamChunk,
                    requestID: 1,
                    mode: "custom",
                    title: "Cancel before first chunk",
                    isFinal: true,
                    chunkDurationSeconds: 0.05,
                    cumulativeDurationSeconds: 0.05
                )
            ],
            result: GenerationResult(
                audioPath: cannedOutputPath,
                durationSeconds: 0.05,
                streamSessionDirectory: nil,
                benchmarkSample: nil
            ),
            initialDelay: .milliseconds(500)
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

        let request = GenerationRequest(
            modelID: "qwen3_custom_voice",
            text: "Cancel before first chunk",
            outputPath: cannedOutputPath,
            shouldStream: true,
            payload: .custom(speakerID: "vivian", deliveryStyle: nil)
        )

        let task = Task { @MainActor in
            try await engine.generate(request)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        var observedCancellation = false
        do {
            _ = try await task.value
            XCTFail("Expected generate to be cancelled.")
        } catch is CancellationError {
            observedCancellation = true
        } catch {
            // The streaming-session-startup wrapper in MLXTTSEngine wraps
            // some errors via NativeRuntimeError.wrapping; CancellationError
            // is the expected unwrapped propagation path, but accept any
            // localized description containing "cancel" as well.
            XCTAssertTrue(
                error.localizedDescription.lowercased().contains("cancel"),
                "Expected CancellationError or a cancel-flavored wrap, got \(error)"
            )
            observedCancellation = true
        }
        XCTAssertTrue(observedCancellation)
        XCTAssertEqual(mockSession.runCallCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cannedOutputPath),
            "Cancelled generation must not leave a final output WAV behind."
        )
    }

    /// Ported (in shape) from
    /// `NativeMLXMacEngineTests.testNativeMLXMacEngineCancellationMidStreamStopsFurtherChunksAndFinalOutput`.
    /// The mock streaming session emits one chunk immediately, then
    /// awaits a 500 ms `eventDelay` before the next; the test waits for
    /// the engine to surface the first event into `latestEvent`, then
    /// cancels. The session's `Task.sleep` between events throws
    /// `CancellationError` before any further chunks fire.
    func testEngineGenerateCancelledMidStreamStopsFurtherChunks() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator(loadHandler: { _, capabilityProfile in
            return await NativeModelLoadResult.makeForTesting(
                model: UnsafeSpeechGenerationModel.makeFullySupportingForTesting(),
                capabilityProfile: capabilityProfile
            )
        })

        let cannedOutputPath = temporaryRoot.appendingPathComponent("cancel-mid-stream.wav").path
        let firstChunk = GenerationEvent(
            kind: .streamChunk,
            requestID: 1,
            mode: "custom",
            title: "Cancel mid-stream",
            isFinal: false,
            chunkDurationSeconds: 0.05,
            cumulativeDurationSeconds: 0.05
        )
        let secondChunkUnreached = GenerationEvent(
            kind: .streamChunk,
            requestID: 1,
            mode: "custom",
            title: "Cancel mid-stream",
            isFinal: true,
            chunkDurationSeconds: 0.05,
            cumulativeDurationSeconds: 0.10
        )
        let mockSession = MockNativeStreamingSession(
            events: [firstChunk, secondChunkUnreached],
            result: GenerationResult(
                audioPath: cannedOutputPath,
                durationSeconds: 0.10,
                streamSessionDirectory: nil,
                benchmarkSample: nil
            ),
            eventDelay: .milliseconds(500)
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

        let request = GenerationRequest(
            modelID: "qwen3_custom_voice",
            text: "Cancel after first chunk",
            outputPath: cannedOutputPath,
            shouldStream: true,
            payload: .custom(speakerID: "vivian", deliveryStyle: nil)
        )

        let task = Task { @MainActor in
            try await engine.generate(request)
        }
        _ = await waitUntil(
            timeoutSeconds: 1.0,
            description: "engine.latestEvent picks up the first chunk"
        ) {
            engine.latestEvent == firstChunk
        }
        task.cancel()

        var observedCancellation = false
        do {
            _ = try await task.value
            XCTFail("Expected generate to be cancelled.")
        } catch is CancellationError {
            observedCancellation = true
        } catch {
            XCTAssertTrue(
                error.localizedDescription.lowercased().contains("cancel"),
                "Expected CancellationError or a cancel-flavored wrap, got \(error)"
            )
            observedCancellation = true
        }
        XCTAssertTrue(observedCancellation)
        XCTAssertEqual(mockSession.runCallCount, 1)
        XCTAssertEqual(
            mockSession.deliveredEventCount,
            1,
            "Only the first chunk should have been delivered; the cancellation must fire during the eventDelay before the second chunk."
        )
    }

    /// Ported (in shape) from
    /// `NativeMLXMacEngineTests.testNativeMLXMacEngineGeneratesDesignAudioAndPublishesOptimizedBenchmarkFlags`.
    /// Exercises the prewarm-then-generate sequence for `.design` mode:
    /// `engine.prewarmModelIfNeeded(for:)` runs the runtime's design-
    /// conditioning warm path, then `engine.generate(...)` re-enters the
    /// runtime, prepares again (warm-state cache reused), and routes
    /// through the mock streaming session.
    ///
    /// Differs from the legacy test by design: this port mocks the
    /// streaming session entirely, so the assertion shape verifies the
    /// orchestration (prewarm path runs, generate routes through factory)
    /// rather than the legacy NativeSpeechGenerationModel handler-call
    /// tracking and benchmark-flag introspection. Those assertions need
    /// richer mock model instrumentation that's deferred to a later batch.
    func testEngineDesignPrewarmThenGenerateRoutesThroughStreamingSession() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator(loadHandler: { _, capabilityProfile in
            return await NativeModelLoadResult.makeForTesting(
                model: UnsafeSpeechGenerationModel.makeFullySupportingForTesting(),
                capabilityProfile: capabilityProfile
            )
        })

        let cannedOutputPath = temporaryRoot.appendingPathComponent("design.wav").path
        let mockSession = MockNativeStreamingSession(
            events: [
                GenerationEvent(
                    kind: .streamChunk,
                    requestID: 1,
                    mode: "design",
                    title: "Native Design Preview",
                    isFinal: true,
                    chunkDurationSeconds: 0.10,
                    cumulativeDurationSeconds: 0.10
                )
            ],
            result: GenerationResult(
                audioPath: cannedOutputPath,
                durationSeconds: 0.10,
                streamSessionDirectory: nil,
                benchmarkSample: nil
            )
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

        let request = GenerationRequest(
            modelID: "qwen3_voice_design",
            text: "Please introduce the episode in a warm, steady voice.",
            outputPath: cannedOutputPath,
            shouldStream: true,
            streamingTitle: "Native Design Preview",
            payload: .design(voiceDescription: "Warm narrator", deliveryStyle: "Calm")
        )
        await engine.prewarmModelIfNeeded(for: request)
        let result = try await engine.generate(request)

        XCTAssertEqual(mockSession.runCallCount, 1)
        XCTAssertEqual(result.audioPath, cannedOutputPath)
        XCTAssertEqual(result.durationSeconds, 0.10)
        XCTAssertEqual(engine.loadState, .loaded(modelID: "qwen3_voice_design"))
        XCTAssertNil(engine.visibleErrorMessage)
        XCTAssertGreaterThanOrEqual(coordinator.loadCalls.count, 1)
        XCTAssertTrue(
            coordinator.loadCalls.allSatisfy { $0.modelID == "qwen3_voice_design" },
            "Every load attempt should be for the design model id."
        )
    }

    /// Ported (in shape) from
    /// `NativeMLXMacEngineTests.testNativeMLXMacEngineGeneratesOptimizedClone
    /// AudioAndPublishesCloneBenchmarkFlags`. Exercises the
    /// `.clone(reference:)` path: the runtime resolves clone conditioning
    /// (reads the reference WAV, calls the model's `clonePromptCreator`,
    /// caches the result), then routes through the mock streaming session.
    ///
    /// Differs from the legacy test by design: this port mocks the
    /// streaming session entirely so no audio is actually generated; the
    /// assertion shape verifies that the clone-conditioning resolve path
    /// runs end-to-end (the reference file is read, the prompt creator
    /// fires) and the engine routes to the mock session. Benchmark-flag
    /// introspection (`clone_conditioning_reused`,
    /// `prepared_clone_cache_hit`) needs richer mock instrumentation
    /// deferred to a later batch.
    func testEngineCloneGenerateResolvesCloneConditioningAndRoutesThroughStreamingSession() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator(loadHandler: { _, capabilityProfile in
            return await NativeModelLoadResult.makeForTesting(
                model: UnsafeSpeechGenerationModel.makeFullySupportingForTesting(),
                capabilityProfile: capabilityProfile
            )
        })

        let referenceURL = temporaryRoot.appendingPathComponent("clone-reference.wav")
        try NativeRuntimeTestSupport.writeTestWAV(to: referenceURL, sampleRate: 24_000, channels: 1)

        let cannedOutputPath = temporaryRoot.appendingPathComponent("clone.wav").path
        let mockSession = MockNativeStreamingSession(
            events: [
                GenerationEvent(
                    kind: .streamChunk,
                    requestID: 1,
                    mode: "clone",
                    title: "Native Clone Preview",
                    isFinal: true,
                    chunkDurationSeconds: 0.10,
                    cumulativeDurationSeconds: 0.10
                )
            ],
            result: GenerationResult(
                audioPath: cannedOutputPath,
                durationSeconds: 0.10,
                streamSessionDirectory: nil,
                benchmarkSample: nil
            )
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

        let request = GenerationRequest(
            modelID: "qwen3_clone_voice",
            text: "This will sound like the reference speaker.",
            outputPath: cannedOutputPath,
            shouldStream: true,
            streamingTitle: "Native Clone Preview",
            payload: .clone(
                reference: CloneReference(
                    audioPath: referenceURL.path,
                    transcript: "Reference speaker transcript"
                )
            )
        )
        let result = try await engine.generate(request)

        XCTAssertEqual(mockSession.runCallCount, 1)
        XCTAssertEqual(result.audioPath, cannedOutputPath)
        XCTAssertEqual(result.durationSeconds, 0.10)
        XCTAssertEqual(engine.loadState, .loaded(modelID: "qwen3_clone_voice"))
        XCTAssertNil(engine.visibleErrorMessage)
        XCTAssertGreaterThanOrEqual(coordinator.loadCalls.count, 1)
        XCTAssertTrue(
            coordinator.loadCalls.allSatisfy { $0.modelID == "qwen3_clone_voice" },
            "Every load attempt should be for the clone model id."
        )
    }

    /// Ported equivalent of
    /// `NativeMLXMacEngineTests.testNativeMLXMacEngineGenerateBatchRejectsMixedModes`.
    /// `generateBatch` validates the batch up front and throws an
    /// `unsupportedRequest` error before any model interaction. No
    /// streaming-session mock is needed because the validation gate
    /// fires first.
    func testEngineGenerateBatchRejectsMixedModesBeforeLoading() async throws {
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

        let custom = GenerationRequest(
            modelID: "qwen3_custom_voice",
            text: "Custom item",
            outputPath: temporaryRoot.appendingPathComponent("custom.wav").path,
            shouldStream: false,
            payload: .custom(speakerID: "vivian", deliveryStyle: "Conversational")
        )
        let design = GenerationRequest(
            modelID: "qwen3_voice_design",
            text: "Design item",
            outputPath: temporaryRoot.appendingPathComponent("design.wav").path,
            shouldStream: false,
            payload: .design(voiceDescription: "Warm narrator", deliveryStyle: "Calm")
        )

        var didThrow = false
        do {
            _ = try await engine.generateBatch([custom, design]) { _, _ in }
        } catch let error as MLXTTSEngineError {
            didThrow = true
            if case .unsupportedRequest(let message) = error {
                XCTAssertTrue(
                    message.contains("Batch generation requires one model"),
                    "Unexpected error message: \(message)"
                )
            } else {
                XCTFail("Expected .unsupportedRequest, got \(error)")
            }
        } catch {
            XCTFail("Expected MLXTTSEngineError, got \(type(of: error)): \(error)")
        }
        XCTAssertTrue(didThrow, "Expected generateBatch to throw on mixed modes.")

        // Validation fires before model load, so the coordinator should
        // never be invoked.
        XCTAssertEqual(coordinator.loadCalls.count, 0)
    }

    /// Ported (in shape) from
    /// `NativeMLXMacEngineTests.testNativeMLXMacEngineGenerateBatchSupports
    /// HomogeneousDesignRequests`. Confirms the engine routes every
    /// request in a homogeneous batch through the streaming-session
    /// factory (each invocation increments `runCallCount`).
    ///
    /// Differs from the legacy test by design: this port mocks the
    /// streaming session so no files are written; the assertion shape
    /// verifies the orchestration (one factory call per request) rather
    /// than file artifacts.
    func testEngineGenerateBatchRoutesEachRequestThroughStreamingSession() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator(loadHandler: { _, capabilityProfile in
            return await NativeModelLoadResult.makeForTesting(
                model: UnsafeSpeechGenerationModel.makeFullySupportingForTesting(),
                capabilityProfile: capabilityProfile
            )
        })

        let mockSession = MockNativeStreamingSession(
            events: [],
            result: GenerationResult(
                audioPath: temporaryRoot.appendingPathComponent("mock-batch.wav").path,
                durationSeconds: 0.05,
                streamSessionDirectory: nil,
                benchmarkSample: nil
            )
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

        let first = GenerationRequest(
            modelID: "qwen3_voice_design",
            text: "First design item",
            outputPath: temporaryRoot.appendingPathComponent("design-first.wav").path,
            shouldStream: false,
            payload: .design(voiceDescription: "Warm narrator", deliveryStyle: "Calm")
        )
        let second = GenerationRequest(
            modelID: "qwen3_voice_design",
            text: "Second design item",
            outputPath: temporaryRoot.appendingPathComponent("design-second.wav").path,
            shouldStream: false,
            payload: .design(voiceDescription: "Warm narrator", deliveryStyle: "Calm")
        )

        let results = try await engine.generateBatch([first, second]) { _, _ in }

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(mockSession.runCallCount, 2)
        // Note: `usedStreaming` reflects an internal coercion in
        // `MLXTTSEngine.generateBatch` (it forces `shouldStream = true`
        // and the resulting benchmark sample's `streamingUsed`
        // annotation propagates). The legacy NativeMLXMacEngine path
        // didn't apply that annotation wrapper, hence the divergence.
        // The assertion of interest here is "every request reached the
        // streaming session" — `mockSession.runCallCount == 2` covers it.
        XCTAssertEqual(engine.loadState, .loaded(modelID: "qwen3_voice_design"))
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
