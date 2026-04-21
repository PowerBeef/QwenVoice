import XCTest
import Combine
@preconcurrency import MLX
@preconcurrency import MLXAudioTTS
@testable import QwenVoiceNativeRuntime

@MainActor
final class NativeMLXMacEngineTests: XCTestCase {
    private struct GenericGenerationCall: Equatable {
        let text: String
        let voice: String?
        let language: String?
    }

    private struct DesignGenerationCall: Equatable {
        let text: String
        let language: String
        let voiceDescription: String
    }

    private struct ClonePromptCall: Equatable {
        let text: String
        let language: String
        let refText: String?
    }

    private final class DesignInvocationBox: @unchecked Sendable {
        var latestPreparationBooleanFlags: [String: Bool] = [:]
        var genericPrewarmCalls: [GenericGenerationCall] = []
        var genericStreamCalls: [GenericGenerationCall] = []
        var designPrewarmCalls: [DesignGenerationCall] = []
        var designStreamCalls: [DesignGenerationCall] = []
    }

    private final class CloneInvocationBox: @unchecked Sendable {
        var latestPreparationBooleanFlags: [String: Bool] = [:]
        var genericPrewarmRefTexts: [String?] = []
        var genericStreamRefTexts: [String?] = []
        var optimizedClonePrewarmCalls: [ClonePromptCall] = []
        var optimizedCloneStreamCalls: [ClonePromptCall] = []
        var clonePromptCreationCount = 0
    }

    private final class StreamCallBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ value: String) {
            lock.lock()
            defer { lock.unlock() }
            values.append(value)
        }

        var allValues: [String] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private var cancellables: Set<AnyCancellable> = []

    func testInitializeCreatesNativeRuntimeDirectoriesAndSupportsPreparedVoices() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceAudio = root.appendingPathComponent("sample.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("sample-audio".utf8).write(to: sourceAudio)

        let manifestURL = try NativeRuntimeTestSupport.writeManifest(
            at: root,
            models: [
                NativeRuntimeTestSupport.ModelEntry(
                    id: "pro_clone",
                    name: "Voice Cloning",
                    folder: "Clone-Model",
                    mode: "clone"
                )
            ]
        )
        let engine = NativeMLXMacEngine(
            runtime: MacNativeRuntime(
                manifestURL: manifestURL,
                modelLoader: { _, _ in .placeholder() }
            )
        )
        try await engine.initialize(appSupportDirectory: root)

        let expectedDirectories = [
            "models",
            "downloads/staging",
            "cache/native_mlx",
            "cache/prepared_audio",
            "cache/normalized_clone_refs",
            "cache/stream_sessions",
            "outputs",
            "voices",
        ]

        for relativePath in expectedDirectories {
            let directoryURL = root.appendingPathComponent(relativePath, isDirectory: true)
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
            transcript: "Hello from native shell"
        )
        XCTAssertEqual(enrolled.id, "Sample Voice")
        XCTAssertTrue(enrolled.hasTranscript)
        XCTAssertTrue(enrolled.audioPath.hasPrefix(root.appendingPathComponent("voices").path))

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

    func testNativeMLXMacEnginePublishesStartingAndLoadedStateForAvailableModel() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = NativeRuntimeTestSupport.ModelEntry(
            id: "pro_clone",
            name: "Voice Cloning",
            folder: "Clone-Model",
            mode: "clone"
        )
        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [model])
        let modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        _ = try NativeRuntimeTestSupport.installModel(model, into: modelsDirectory)

        let engine = NativeMLXMacEngine(
            runtime: MacNativeRuntime(
                manifestURL: manifestURL,
                loadOperation: { _ in
                    try await Task.sleep(nanoseconds: 150_000_000)
                },
                modelLoader: { _, _ in .placeholder() }
            )
        )
        try await engine.initialize(appSupportDirectory: root)

        let loadTask = Task {
            try await engine.loadModel(id: "pro_clone")
        }
        await Task.yield()
        _ = await waitUntil(
            timeoutSeconds: 0.5,
            description: "engine load state reaches .starting"
        ) {
            engine.snapshot.loadState == .starting
        }
        XCTAssertEqual(engine.snapshot.loadState, .starting)
        try await loadTask.value
        XCTAssertEqual(engine.snapshot.loadState, EngineLoadState.loaded(modelID: "pro_clone"))
        XCTAssertNil(engine.snapshot.visibleErrorMessage)

        try await engine.unloadModel()
        XCTAssertEqual(engine.snapshot.loadState, .idle)
        XCTAssertNil(engine.snapshot.visibleErrorMessage)
    }

    func testNativeMLXMacEnginePublishesFailedLoadStateForUnavailableModel() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = NativeRuntimeTestSupport.ModelEntry(
            id: "pro_clone",
            name: "Voice Cloning",
            folder: "Clone-Model",
            mode: "clone"
        )
        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [model])
        let engine = NativeMLXMacEngine(
            runtime: MacNativeRuntime(
                manifestURL: manifestURL,
                modelLoader: { _, _ in .placeholder() }
            )
        )
        try await engine.initialize(appSupportDirectory: root)

        await XCTAssertThrowsErrorAsync {
            try await engine.loadModel(id: "pro_clone")
        }

        guard case .failed(let message) = engine.snapshot.loadState else {
            return XCTFail("Expected failed load state")
        }
        XCTAssertTrue(message.contains("unavailable"))
        XCTAssertEqual(engine.snapshot.visibleErrorMessage, message)
    }

    func testNativeMLXMacEngineClonePrimingRequiresAvailableModel() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = NativeRuntimeTestSupport.ModelEntry(
            id: "pro_clone",
            name: "Voice Cloning",
            folder: "Clone-Model",
            mode: "clone"
        )
        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [model])
        let engine = NativeMLXMacEngine(
            runtime: MacNativeRuntime(
                manifestURL: manifestURL,
                modelLoader: { _, _ in .placeholder() }
            )
        )
        try await engine.initialize(appSupportDirectory: root)

        await XCTAssertThrowsErrorAsync {
            try await engine.ensureCloneReferencePrimed(
                modelID: "pro_clone",
                reference: CloneReference(audioPath: "/tmp/ref.wav", transcript: "Reference")
            )
        }

        XCTAssertEqual(engine.snapshot.clonePreparationState, .idle)
        guard case .failed(let message) = engine.snapshot.loadState else {
            return XCTFail("Expected failed load state after priming failure")
        }
        XCTAssertEqual(engine.snapshot.visibleErrorMessage, message)
    }

    func testNativeMLXMacEnginePublishesLoadAndClonePreparationStateForAvailableCloneModel() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = NativeRuntimeTestSupport.ModelEntry(
            id: "pro_clone",
            name: "Voice Cloning",
            folder: "Clone-Model",
            mode: "clone"
        )
        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [model])
        let modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        _ = try NativeRuntimeTestSupport.installModel(model, into: modelsDirectory)

        let engine = NativeMLXMacEngine(
            runtime: MacNativeRuntime(
                manifestURL: manifestURL,
                modelLoader: { _, _ in .placeholder() }
            )
        )
        try await engine.initialize(appSupportDirectory: root)

        let referenceURL = root.appendingPathComponent("reference.wav")
        try NativeRuntimeTestSupport.writeTestWAV(to: referenceURL, sampleRate: 24_000, channels: 1)
        try await engine.loadModel(id: "pro_clone")
        try await engine.ensureCloneReferencePrimed(
            modelID: "pro_clone",
            reference: CloneReference(audioPath: referenceURL.path, transcript: "Reference")
        )
        let primedState = engine.snapshot.clonePreparationState
        guard primedState.phase == .primed else {
            return XCTFail("Expected clone reference to be primed")
        }
        XCTAssertEqual(
            primedState.key,
            GenerationSemantics.clonePreparationKey(
                modelID: "pro_clone",
                reference: CloneReference(audioPath: referenceURL.path, transcript: "Reference")
            )
        )

        try await engine.unloadModel()
        XCTAssertEqual(engine.snapshot.loadState, EngineLoadState.idle)
        XCTAssertEqual(engine.snapshot.clonePreparationState, ClonePreparationState.idle)
    }

    func testNativeMLXMacEnginePublishesFailedClonePreparationStateForInvalidReferenceAfterLoad() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = NativeRuntimeTestSupport.ModelEntry(
            id: "pro_clone",
            name: "Voice Cloning",
            folder: "Clone-Model",
            mode: "clone"
        )
        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [model])
        let modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        _ = try NativeRuntimeTestSupport.installModel(model, into: modelsDirectory)

        let engine = NativeMLXMacEngine(
            runtime: MacNativeRuntime(
                manifestURL: manifestURL,
                modelLoader: { _, _ in .placeholder() }
            )
        )
        try await engine.initialize(appSupportDirectory: root)
        try await engine.loadModel(id: "pro_clone")

        let missingReference = root.appendingPathComponent("missing.wav")
        await XCTAssertThrowsErrorAsync {
            try await engine.ensureCloneReferencePrimed(
                modelID: "pro_clone",
                reference: CloneReference(audioPath: missingReference.path, transcript: "Reference")
            )
        }

        XCTAssertEqual(engine.snapshot.loadState, .loaded(modelID: "pro_clone"))
        let failedState = engine.snapshot.clonePreparationState
        guard failedState.phase == .failed else {
            return XCTFail("Expected failed clone preparation state")
        }
        XCTAssertEqual(
            failedState.key,
            GenerationSemantics.clonePreparationKey(
                modelID: "pro_clone",
                reference: CloneReference(audioPath: missingReference.path, transcript: "Reference")
            )
        )
        XCTAssertNotNil(failedState.errorMessage)
        XCTAssertEqual(engine.snapshot.visibleErrorMessage, failedState.errorMessage)
    }

    func testNativeMLXMacEngineGeneratesCustomAudioAndPublishesChunkEvents() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = NativeRuntimeTestSupport.ModelEntry(
            id: "pro_custom",
            name: "Custom Voice",
            folder: "Custom-Model",
            mode: "custom"
        )
        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [model])
        let modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        _ = try NativeRuntimeTestSupport.installModel(model, into: modelsDirectory)

        let customModel = NativeSpeechGenerationModel(
            sampleRate: 24_000,
            customPrewarmHandler: { _, _, _, _ in },
            customStreamHandler: { _, _, _, _, _ in
                let (stream, continuation) = AsyncThrowingStream<NativeSpeechGenerationEvent, Error>.makeStream()
                Task {
                    continuation.yield(NativeSpeechGenerationEvent.audio([0.0, 0.2, -0.2, 0.1]))
                    continuation.yield(NativeSpeechGenerationEvent.audio([0.1, -0.1, 0.0, 0.05]))
                    continuation.yield(
                        NativeSpeechGenerationEvent.info(
                            NativeSpeechGenerationInfo(
                                promptTokenCount: 12,
                                generationTokenCount: 34,
                                prefillTime: 0.12,
                                generateTime: 0.34,
                                peakMemoryUsage: 1.5
                            )
                        )
                    )
                    continuation.finish()
                }
                return stream
            }
        )

        let engine = NativeMLXMacEngine(
            runtime: MacNativeRuntime(
                manifestURL: manifestURL,
                modelLoader: { descriptor, _ in
                    XCTAssertEqual(descriptor.id, "pro_custom")
                    return customModel
                }
            )
        )
        try await engine.initialize(appSupportDirectory: root)

        var observedEvents: [GenerationEvent] = []
        engine.generationEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { observedEvents.append($0) }
            .store(in: &cancellables)

        let outputPath = root.appendingPathComponent("custom.wav").path
        let request = GenerationRequest(
            modelID: "pro_custom",
            text: "Hello from native custom generation.",
            outputPath: outputPath,
            shouldStream: true,
            streamingTitle: "Native Custom Preview",
            payload: .custom(speakerID: "vivian", deliveryStyle: "Conversational")
        )

        let result = try await engine.generate(request)

        XCTAssertEqual(result.audioPath, outputPath)
        XCTAssertGreaterThan(result.durationSeconds, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))

        let sessionDirectory: String = try XCTUnwrap(result.streamSessionDirectory)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: sessionDirectory)
                    .appendingPathComponent("chunk_0000.wav")
                    .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: sessionDirectory)
                    .appendingPathComponent("chunk_0001.wav")
                    .path
            )
        )

        XCTAssertEqual(observedEvents.count, 2)
        XCTAssertEqual(observedEvents.first?.isFinal, false)
        XCTAssertTrue(observedEvents.dropFirst().allSatisfy { $0.isFinal == true })
        XCTAssertEqual(observedEvents.last?.isFinal, true)
        XCTAssertEqual(engine.snapshot.loadState.currentModelID, "pro_custom")
        XCTAssertNil(engine.snapshot.visibleErrorMessage)

        let sample: BenchmarkSample = try XCTUnwrap(result.benchmarkSample)
        XCTAssertTrue(sample.streamingUsed)
        XCTAssertEqual(sample.tokenCount, 34)
        XCTAssertEqual(sample.booleanFlags["custom_dedicated_handler_used"], true)
        XCTAssertNotNil(sample.firstChunkMs)
        XCTAssertFalse(sample.telemetryStageMarks?.isEmpty ?? true)
    }

    func testNativeMLXMacEngineGenerateBatchSupportsHomogeneousCustomRequests() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = NativeRuntimeTestSupport.ModelEntry(
            id: "pro_custom",
            name: "Custom Voice",
            folder: "Custom-Model",
            mode: "custom"
        )
        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [model])
        let modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        _ = try NativeRuntimeTestSupport.installModel(model, into: modelsDirectory)

        let customModel = NativeSpeechGenerationModel(
            sampleRate: 24_000,
            customPrewarmHandler: { _, _, _, _ in },
            customStreamHandler: { text, _, _, _, _ in
                AsyncThrowingStream { continuation in
                    let samples: [Float] = text.contains("Second") ? [0.0, 0.1] : [0.0, -0.1]
                    continuation.yield(.audio(samples))
                    continuation.finish()
                }
            }
        )

        let engine = NativeMLXMacEngine(
            runtime: MacNativeRuntime(
                manifestURL: manifestURL,
                modelLoader: { _, _ in customModel }
            )
        )
        try await engine.initialize(appSupportDirectory: root)

        let first = GenerationRequest(
            modelID: "pro_custom",
            text: "First item",
            outputPath: root.appendingPathComponent("first.wav").path,
            shouldStream: false,
            payload: .custom(speakerID: "vivian", deliveryStyle: "Conversational")
        )
        let second = GenerationRequest(
            modelID: "pro_custom",
            text: "Second item",
            outputPath: root.appendingPathComponent("second.wav").path,
            shouldStream: false,
            payload: .custom(speakerID: "serena", deliveryStyle: nil)
        )

        let results = try await engine.generateBatch([first, second]) { _, _ in }

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.outputPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.outputPath))
        XCTAssertFalse(results[0].usedStreaming)
        XCTAssertFalse(results[1].usedStreaming)
    }

    func testNativeMLXMacEngineGenerateBatchSupportsHomogeneousDesignRequests() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = NativeRuntimeTestSupport.ModelEntry(
            id: "pro_design",
            name: "Voice Design",
            folder: "Design-Model",
            mode: "design"
        )
        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [model])
        let modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        _ = try NativeRuntimeTestSupport.installModel(model, into: modelsDirectory)

        let designModel = NativeSpeechGenerationModel(
            sampleRate: 24_000,
            designPrewarmHandler: { _, _, _ in },
            designStreamHandler: { text, _, _, _ in
                AsyncThrowingStream { continuation in
                    let samples: [Float] = text.contains("Second") ? [0.0, 0.1] : [0.0, -0.1]
                    continuation.yield(.audio(samples))
                    continuation.finish()
                }
            }
        )

        let engine = NativeMLXMacEngine(
            runtime: MacNativeRuntime(
                manifestURL: manifestURL,
                modelLoader: { _, _ in designModel }
            )
        )
        try await engine.initialize(appSupportDirectory: root)

        let first = GenerationRequest(
            modelID: "pro_design",
            text: "First design item",
            outputPath: root.appendingPathComponent("design-first.wav").path,
            shouldStream: false,
            payload: .design(voiceDescription: "Warm narrator", deliveryStyle: "Calm")
        )
        let second = GenerationRequest(
            modelID: "pro_design",
            text: "Second design item",
            outputPath: root.appendingPathComponent("design-second.wav").path,
            shouldStream: false,
            payload: .design(voiceDescription: "Warm narrator", deliveryStyle: "Calm")
        )

        let results = try await engine.generateBatch([first, second]) { _, _ in }

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.outputPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.outputPath))
        XCTAssertFalse(results[0].usedStreaming)
        XCTAssertFalse(results[1].usedStreaming)
    }

    func testNativeMLXMacEngineGenerateBatchSupportsHomogeneousCloneRequestsAndReusesConditioning() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = NativeRuntimeTestSupport.ModelEntry(
            id: "pro_clone",
            name: "Voice Cloning",
            folder: "Clone-Model",
            mode: "clone"
        )
        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [model])
        let modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        _ = try NativeRuntimeTestSupport.installModel(model, into: modelsDirectory)

        let referenceURL = root.appendingPathComponent("batch-reference.wav")
        try NativeRuntimeTestSupport.writeTestWAV(to: referenceURL, sampleRate: 24_000, channels: 1)

        let box = CloneInvocationBox()
        let cloneModel = NativeSpeechGenerationModel(
            sampleRate: 24_000,
            clonePromptCreator: { _, refText, xVectorOnlyMode in
                box.clonePromptCreationCount += 1
                return Qwen3TTSVoiceClonePrompt(
                    refCodes: MLXArray([Int32(1), Int32(2), Int32(3)]),
                    speakerEmbedding: MLXArray([Float32(0.25), Float32(0.5)]),
                    refText: refText,
                    xVectorOnlyMode: xVectorOnlyMode,
                    iclMode: false
                )
            },
            clonePrewarmHandler: { _, _, _ in },
            cloneStreamHandler: { text, language, voiceClonePrompt, _ in
                box.optimizedCloneStreamCalls.append(
                    ClonePromptCall(text: text, language: language, refText: voiceClonePrompt.refText)
                )
                return AsyncThrowingStream { continuation in
                    let samples: [Float] = text.contains("Second") ? [0.0, 0.1] : [0.0, -0.1]
                    continuation.yield(.audio(samples))
                    continuation.finish()
                }
            }
        )

        let engine = NativeMLXMacEngine(
            runtime: MacNativeRuntime(
                manifestURL: manifestURL,
                modelLoader: { _, _ in cloneModel }
            )
        )
        try await engine.initialize(appSupportDirectory: root)

        let reference = CloneReference(
            audioPath: referenceURL.path,
            transcript: "Batch transcript"
        )
        let first = GenerationRequest(
            modelID: "pro_clone",
            text: "First clone item",
            outputPath: root.appendingPathComponent("clone-first.wav").path,
            shouldStream: false,
            payload: .clone(reference: reference)
        )
        let second = GenerationRequest(
            modelID: "pro_clone",
            text: "Second clone item",
            outputPath: root.appendingPathComponent("clone-second.wav").path,
            shouldStream: false,
            payload: .clone(reference: reference)
        )

        let results = try await engine.generateBatch([first, second]) { _, _ in }

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(box.clonePromptCreationCount, 1)
        XCTAssertEqual(
            box.optimizedCloneStreamCalls.map(\.text),
            ["First clone item", "Second clone item"]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.outputPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.outputPath))
        let firstSample = try XCTUnwrap(results[0].benchmarkSample)
        let secondSample = try XCTUnwrap(results[1].benchmarkSample)
        XCTAssertEqual(firstSample.booleanFlags["clone_conditioning_reused"], false)
        XCTAssertEqual(secondSample.booleanFlags["clone_conditioning_reused"], true)
    }

    func testNativeMLXMacEngineGenerateBatchRejectsMixedModes() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [])
        let engine = NativeMLXMacEngine(
            runtime: MacNativeRuntime(
                manifestURL: manifestURL,
                modelLoader: { _, _ in .placeholder() }
            )
        )
        try await engine.initialize(appSupportDirectory: root)

        let custom = GenerationRequest(
            modelID: "pro_custom",
            text: "Custom item",
            outputPath: root.appendingPathComponent("custom.wav").path,
            shouldStream: false,
            payload: .custom(speakerID: "vivian", deliveryStyle: "Conversational")
        )
        let design = GenerationRequest(
            modelID: "pro_design",
            text: "Design item",
            outputPath: root.appendingPathComponent("design.wav").path,
            shouldStream: false,
            payload: .design(voiceDescription: "Warm narrator", deliveryStyle: "Calm")
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await engine.generateBatch([custom, design]) { _, _ in }
        } verify: { error in
            XCTAssertEqual(
                error as? NativeMLXMacEngine.EngineError,
                .nativeBatchRequiresSingleMode
            )
        }

        XCTAssertEqual(
            engine.snapshot.visibleErrorMessage,
            NativeMLXMacEngine.EngineError.nativeBatchRequiresSingleMode.localizedDescription
        )
    }

    func testNativeMLXMacEngineGeneratesDesignAudioAndPublishesOptimizedBenchmarkFlags() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = NativeRuntimeTestSupport.ModelEntry(
            id: "pro_design",
            name: "Voice Design",
            folder: "Design-Model",
            mode: "design"
        )
        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [model])
        let modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        _ = try NativeRuntimeTestSupport.installModel(model, into: modelsDirectory)

        let box = DesignInvocationBox()
        let designModel = NativeSpeechGenerationModel(
            sampleRate: 24_000,
            genericPrewarmHandler: { _, _, _ in
                XCTFail("Optimized Voice Design should not fall back to the generic prewarm path.")
            },
            latestPreparationBooleanFlagsProvider: {
                box.latestPreparationBooleanFlags
            },
            designPrewarmHandler: { text, language, voiceDescription in
                box.designPrewarmCalls.append(
                    DesignGenerationCall(text: text, language: language, voiceDescription: voiceDescription)
                )
                box.latestPreparationBooleanFlags = ["design_stream_step_prewarmed": true]
            },
            designStreamHandler: { text, language, voiceDescription, _ in
                box.designStreamCalls.append(
                    DesignGenerationCall(text: text, language: language, voiceDescription: voiceDescription)
                )
                let (stream, continuation) = AsyncThrowingStream<NativeSpeechGenerationEvent, Error>.makeStream()
                Task {
                    continuation.yield(.audio([0.0, 0.2, -0.1, 0.05]))
                    continuation.yield(.audio([0.05, -0.02, 0.0, 0.1]))
                    continuation.yield(
                        .info(
                            NativeSpeechGenerationInfo(
                                promptTokenCount: 16,
                                generationTokenCount: 41,
                                prefillTime: 0.18,
                                generateTime: 0.42,
                                peakMemoryUsage: 2.0
                            )
                        )
                    )
                    continuation.finish()
                }
                return stream
            }
        )

        let engine = NativeMLXMacEngine(
            runtime: MacNativeRuntime(
                manifestURL: manifestURL,
                modelLoader: { _, _ in designModel }
            )
        )
        try await engine.initialize(appSupportDirectory: root)

        var observedEvents: [GenerationEvent] = []
        engine.generationEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { observedEvents.append($0) }
            .store(in: &cancellables)

        let request = GenerationRequest(
            modelID: "pro_design",
            text: "Please introduce the episode in a warm, steady voice.",
            outputPath: root.appendingPathComponent("design.wav").path,
            shouldStream: true,
            streamingTitle: "Native Design Preview",
            payload: .design(voiceDescription: "Warm narrator", deliveryStyle: "Calm")
        )
        let expectedVoiceDescription = GenerationSemantics.designInstruction(
            voiceDescription: "Warm narrator",
            emotion: "Calm"
        )

        await engine.prewarmModelIfNeeded(for: request)
        let result = try await engine.generate(request)

        XCTAssertEqual(
            box.designPrewarmCalls,
            [
                DesignGenerationCall(
                    text: GenerationSemantics.canonicalDesignWarmText(for: .short),
                    language: "auto",
                    voiceDescription: expectedVoiceDescription
                )
            ]
        )
        XCTAssertEqual(
            box.designStreamCalls,
            [
                DesignGenerationCall(
                    text: request.text,
                    language: "auto",
                    voiceDescription: expectedVoiceDescription
                )
            ]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.audioPath))
        XCTAssertEqual(observedEvents.count, 2)
        XCTAssertEqual(observedEvents.first?.isFinal, false)
        XCTAssertEqual(observedEvents.last?.isFinal, true)

        let sample: BenchmarkSample = try XCTUnwrap(result.benchmarkSample)
        XCTAssertEqual(sample.tokenCount, 41)
        XCTAssertEqual(sample.booleanFlags["design_conditioning_reused"], true)
        XCTAssertEqual(sample.booleanFlags["design_conditioning_prefetch_hit"], true)
        XCTAssertEqual(sample.booleanFlags["design_conditioning_prewarmed"], false)
        XCTAssertEqual(sample.booleanFlags["design_stream_step_prewarmed"], true)
        XCTAssertEqual(sample.booleanFlags["design_warm_bucket_short"], true)
        XCTAssertEqual(sample.booleanFlags["design_warm_bucket_long"], false)
        XCTAssertEqual(sample.booleanFlags["design_optimized_handler_used"], true)
        XCTAssertEqual(
            sample.stringFlags["design_conditioning_request_key"],
            GenerationSemantics.designConditioningWarmKey(for: request)
        )
    }

    func testNativeMLXMacEngineFallsBackToGenericVoiceStringForDesignGeneration() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = NativeRuntimeTestSupport.ModelEntry(
            id: "pro_design",
            name: "Voice Design",
            folder: "Design-Model",
            mode: "design"
        )
        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [model])
        let modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        _ = try NativeRuntimeTestSupport.installModel(model, into: modelsDirectory)

        let box = DesignInvocationBox()
        let longText = GenerationSemantics.canonicalDesignWarmLongText + " Please continue the sample."
        let designModel = NativeSpeechGenerationModel(
            sampleRate: 24_000,
            genericPrewarmHandler: { text, voice, language in
                box.genericPrewarmCalls.append(
                    GenericGenerationCall(text: text, voice: voice, language: language)
                )
            },
            genericStreamHandler: { text, voice, language, _ in
                box.genericStreamCalls.append(
                    GenericGenerationCall(text: text, voice: voice, language: language)
                )
                let (stream, continuation) = AsyncThrowingStream<NativeSpeechGenerationEvent, Error>.makeStream()
                Task {
                    continuation.yield(.audio([0.0, 0.1, -0.1, 0.05]))
                    continuation.yield(
                        .info(
                            NativeSpeechGenerationInfo(
                                promptTokenCount: 14,
                                generationTokenCount: 29,
                                prefillTime: 0.15,
                                generateTime: 0.31,
                                peakMemoryUsage: 1.2
                            )
                        )
                    )
                    continuation.finish()
                }
                return stream
            }
        )

        let engine = NativeMLXMacEngine(
            runtime: MacNativeRuntime(
                manifestURL: manifestURL,
                modelLoader: { _, _ in designModel }
            )
        )
        try await engine.initialize(appSupportDirectory: root)

        let request = GenerationRequest(
            modelID: "pro_design",
            text: longText,
            outputPath: root.appendingPathComponent("design-fallback.wav").path,
            shouldStream: true,
            payload: .design(voiceDescription: "Warm narrator", deliveryStyle: "Dramatic")
        )
        let expectedVoiceDescription = GenerationSemantics.designInstruction(
            voiceDescription: "Warm narrator",
            emotion: "Dramatic"
        )

        let result = try await engine.generate(request)

        XCTAssertEqual(
            box.genericPrewarmCalls,
            [
                GenericGenerationCall(
                    text: GenerationSemantics.canonicalDesignWarmText(for: .long),
                    voice: expectedVoiceDescription,
                    language: "auto"
                )
            ]
        )
        XCTAssertEqual(
            box.genericStreamCalls,
            [
                GenericGenerationCall(
                    text: longText,
                    voice: expectedVoiceDescription,
                    language: "auto"
                )
            ]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.audioPath))

        let sample: BenchmarkSample = try XCTUnwrap(result.benchmarkSample)
        XCTAssertEqual(sample.booleanFlags["design_conditioning_reused"], false)
        XCTAssertEqual(sample.booleanFlags["design_conditioning_prefetch_hit"], false)
        XCTAssertEqual(sample.booleanFlags["design_conditioning_prewarmed"], true)
        XCTAssertEqual(sample.booleanFlags["design_warm_bucket_short"], false)
        XCTAssertEqual(sample.booleanFlags["design_warm_bucket_long"], true)
        XCTAssertEqual(sample.booleanFlags["design_optimized_handler_used"], false)
    }

    func testNativeMLXMacEngineGeneratesOptimizedCloneAudioAndPublishesCloneBenchmarkFlags() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = NativeRuntimeTestSupport.ModelEntry(
            id: "pro_clone",
            name: "Voice Cloning",
            folder: "Clone-Model",
            mode: "clone"
        )
        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [model])
        let modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        _ = try NativeRuntimeTestSupport.installModel(model, into: modelsDirectory)

        let referenceURL = root.appendingPathComponent("reference.wav")
        try NativeRuntimeTestSupport.writeTestWAV(to: referenceURL, sampleRate: 24_000, channels: 1)

        let box = CloneInvocationBox()
        let cloneModel = NativeSpeechGenerationModel(
            sampleRate: 24_000,
            latestPreparationBooleanFlagsProvider: { box.latestPreparationBooleanFlags },
            clonePromptCreator: { _, refText, xVectorOnlyMode in
                Qwen3TTSVoiceClonePrompt(
                    refCodes: MLXArray([Int32(1), Int32(2), Int32(3)]),
                    speakerEmbedding: MLXArray([Float32(0.25), Float32(0.5)]),
                    refText: refText,
                    xVectorOnlyMode: xVectorOnlyMode,
                    iclMode: false
                )
            },
            clonePrewarmHandler: { text, language, voiceClonePrompt in
                box.optimizedClonePrewarmCalls.append(
                    ClonePromptCall(text: text, language: language, refText: voiceClonePrompt.refText)
                )
                box.latestPreparationBooleanFlags = ["clone_stream_step_prewarmed": true]
            },
            cloneStreamHandler: { text, language, voiceClonePrompt, _ in
                box.optimizedCloneStreamCalls.append(
                    ClonePromptCall(text: text, language: language, refText: voiceClonePrompt.refText)
                )
                let (stream, continuation) = AsyncThrowingStream<NativeSpeechGenerationEvent, Error>.makeStream()
                Task {
                    continuation.yield(.audio([0.0, 0.2, -0.1, 0.05]))
                    continuation.yield(.audio([0.05, -0.02, 0.0, 0.1]))
                    continuation.yield(
                        .info(
                            NativeSpeechGenerationInfo(
                                promptTokenCount: 10,
                                generationTokenCount: 28,
                                prefillTime: 0.2,
                                generateTime: 0.35,
                                peakMemoryUsage: 1.8
                            )
                        )
                    )
                    continuation.finish()
                }
                return stream
            }
        )

        let engine = NativeMLXMacEngine(
            runtime: MacNativeRuntime(
                manifestURL: manifestURL,
                modelLoader: { _, _ in cloneModel }
            )
        )
        try await engine.initialize(appSupportDirectory: root)
        try await engine.ensureCloneReferencePrimed(
            modelID: "pro_clone",
            reference: CloneReference(
                audioPath: referenceURL.path,
                transcript: "Reference transcript",
                preparedVoiceID: "SavedVoice"
            )
        )

        var observedEvents: [GenerationEvent] = []
        engine.generationEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { observedEvents.append($0) }
            .store(in: &cancellables)

        let request = GenerationRequest(
            modelID: "pro_clone",
            text: "Clone me natively",
            outputPath: root.appendingPathComponent("clone.wav").path,
            shouldStream: true,
            streamingTitle: "Native Clone Preview",
            payload: .clone(
                reference: CloneReference(
                    audioPath: referenceURL.path,
                    transcript: "Reference transcript",
                    preparedVoiceID: "SavedVoice"
                )
            )
        )

        let result = try await engine.generate(request)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.audioPath))
        XCTAssertEqual(
            box.optimizedClonePrewarmCalls,
            [
                ClonePromptCall(
                    text: GenerationSemantics.canonicalDesignWarmShortText,
                    language: "auto",
                    refText: "Reference transcript"
                )
            ]
        )
        XCTAssertEqual(
            box.optimizedCloneStreamCalls,
            [
                ClonePromptCall(
                    text: request.text,
                    language: "auto",
                    refText: "Reference transcript"
                )
            ]
        )
        XCTAssertEqual(observedEvents.count, 2)
        XCTAssertEqual(observedEvents.last?.isFinal, true)

        let sample = try XCTUnwrap(result.benchmarkSample)
        XCTAssertTrue(sample.streamingUsed)
        XCTAssertEqual(sample.preparedCloneUsed, true)
        XCTAssertEqual(sample.cloneCacheHit, false)
        XCTAssertEqual(sample.booleanFlags["clone_optimized_handler_used"], true)
        XCTAssertEqual(sample.booleanFlags["clone_prompt_cache_hit"], false)
        XCTAssertEqual(sample.booleanFlags["clone_conditioning_reused"], true)
        XCTAssertEqual(sample.stringFlags["clone_transcript_mode"], "inline")
    }

    func testNativeMLXMacEngineFallsBackToGenericReferenceAudioForCloneGeneration() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = NativeRuntimeTestSupport.ModelEntry(
            id: "pro_clone",
            name: "Voice Cloning",
            folder: "Clone-Model",
            mode: "clone"
        )
        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [model])
        let modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        _ = try NativeRuntimeTestSupport.installModel(model, into: modelsDirectory)

        let referenceURL = root.appendingPathComponent("reference.wav")
        try NativeRuntimeTestSupport.writeTestWAV(to: referenceURL, sampleRate: 24_000, channels: 1)

        let box = CloneInvocationBox()
        let cloneModel = NativeSpeechGenerationModel(
            sampleRate: 24_000,
            fullGenericPrewarmHandler: { _, _, refAudio, refText, _ in
                XCTAssertNotNil(refAudio)
                box.genericPrewarmRefTexts.append(refText)
            },
            fullGenericStreamHandler: { _, _, refAudio, refText, _, _ in
                XCTAssertNotNil(refAudio)
                box.genericStreamRefTexts.append(refText)
                let (stream, continuation) = AsyncThrowingStream<NativeSpeechGenerationEvent, Error>.makeStream()
                Task {
                    continuation.yield(.audio([0.0, 0.1, -0.1, 0.0]))
                    continuation.finish()
                }
                return stream
            }
        )

        let engine = NativeMLXMacEngine(
            runtime: MacNativeRuntime(
                manifestURL: manifestURL,
                modelLoader: { _, _ in cloneModel }
            )
        )
        try await engine.initialize(appSupportDirectory: root)

        let request = GenerationRequest(
            modelID: "pro_clone",
            text: "Fallback clone generation",
            outputPath: root.appendingPathComponent("clone-fallback.wav").path,
            shouldStream: true,
            payload: .clone(
                reference: CloneReference(
                    audioPath: referenceURL.path,
                    transcript: "Fallback transcript"
                )
            )
        )

        let result = try await engine.generate(request)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.audioPath))
        XCTAssertEqual(box.genericPrewarmRefTexts, ["Fallback transcript"])
        XCTAssertEqual(box.genericStreamRefTexts, ["Fallback transcript"])

        let sample = try XCTUnwrap(result.benchmarkSample)
        XCTAssertEqual(sample.preparedCloneUsed, false)
        XCTAssertEqual(sample.booleanFlags["clone_optimized_handler_used"], false)
        XCTAssertEqual(sample.stringFlags["clone_transcript_mode"], "inline")
    }

    func testNativeMLXMacEngineCancellationBeforeFirstChunkDoesNotWriteFinalOutput() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = NativeRuntimeTestSupport.ModelEntry(
            id: "pro_custom",
            name: "Custom Voice",
            folder: "Custom-Model",
            mode: "custom"
        )
        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [model])
        let modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        _ = try NativeRuntimeTestSupport.installModel(model, into: modelsDirectory)

        let customModel = NativeSpeechGenerationModel(
            sampleRate: 24_000,
            customPrewarmHandler: { _, _, _, _ in },
            customStreamHandler: { _, _, _, _, _ in
                AsyncThrowingStream { continuation in
                    Task {
                        do {
                            try await Task.sleep(for: .milliseconds(500))
                            continuation.yield(.audio([0.0, 0.1, -0.1, 0.0]))
                            continuation.finish()
                        } catch is CancellationError {
                            continuation.finish(throwing: CancellationError())
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            }
        )

        let engine = NativeMLXMacEngine(
            runtime: MacNativeRuntime(
                manifestURL: manifestURL,
                modelLoader: { _, _ in customModel }
            )
        )
        try await engine.initialize(appSupportDirectory: root)

        var observedEvents: [GenerationEvent] = []
        engine.generationEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { observedEvents.append($0) }
            .store(in: &cancellables)

        let outputPath = root.appendingPathComponent("cancel-before-first-chunk.wav").path
        let request = GenerationRequest(
            modelID: "pro_custom",
            text: "Cancel before first chunk",
            outputPath: outputPath,
            shouldStream: true,
            payload: .custom(speakerID: "vivian", deliveryStyle: nil)
        )

        let task = Task {
            try await engine.generate(request)
        }
        try await Task.sleep(for: .milliseconds(50))
        try await engine.cancelActiveGeneration()

        do {
            _ = try await task.value
            XCTFail("Expected generation to be cancelled.")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: outputPath))
        XCTAssertTrue(observedEvents.isEmpty)
        XCTAssertEqual(engine.snapshot.loadState, .loaded(modelID: "pro_custom"))
        XCTAssertNil(engine.snapshot.visibleErrorMessage)
    }

    func testNativeMLXMacEngineCancellationMidStreamStopsFurtherChunksAndFinalOutput() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = NativeRuntimeTestSupport.ModelEntry(
            id: "pro_custom",
            name: "Custom Voice",
            folder: "Custom-Model",
            mode: "custom"
        )
        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [model])
        let modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        _ = try NativeRuntimeTestSupport.installModel(model, into: modelsDirectory)

        let customModel = NativeSpeechGenerationModel(
            sampleRate: 24_000,
            customPrewarmHandler: { _, _, _, _ in },
            customStreamHandler: { _, _, _, _, _ in
                AsyncThrowingStream { continuation in
                    Task {
                        do {
                            continuation.yield(.audio([0.0, 0.1, -0.1, 0.0]))
                            try await Task.sleep(for: .milliseconds(50))
                            continuation.yield(.audio([0.05, -0.05, 0.02, -0.02]))
                            try await Task.sleep(for: .milliseconds(500))
                            continuation.yield(.audio([0.1, 0.0, -0.05, 0.02]))
                            continuation.finish()
                        } catch is CancellationError {
                            continuation.finish(throwing: CancellationError())
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            }
        )

        let engine = NativeMLXMacEngine(
            runtime: MacNativeRuntime(
                manifestURL: manifestURL,
                modelLoader: { _, _ in customModel }
            )
        )
        try await engine.initialize(appSupportDirectory: root)

        var observedEvents: [GenerationEvent] = []
        engine.generationEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { observedEvents.append($0) }
            .store(in: &cancellables)

        let outputPath = root.appendingPathComponent("cancel-mid-stream.wav").path
        let request = GenerationRequest(
            modelID: "pro_custom",
            text: "Cancel after first chunk",
            outputPath: outputPath,
            shouldStream: true,
            payload: .custom(speakerID: "vivian", deliveryStyle: nil)
        )

        let task = Task {
            try await engine.generate(request)
        }

        _ = await waitUntil(timeoutSeconds: 1.0, description: "first streaming event") {
            observedEvents.count == 1
        }
        try await engine.cancelActiveGeneration()

        do {
            _ = try await task.value
            XCTFail("Expected generation to be cancelled.")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(observedEvents.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputPath))
        XCTAssertEqual(engine.snapshot.loadState, .loaded(modelID: "pro_custom"))
        XCTAssertNil(engine.snapshot.visibleErrorMessage)
    }

    /// Tier 4.3: after cancelling mid-stream, the session directory and any
    /// partial chunk files it contains must be cleaned up alongside the output
    /// file — the cleanup path is owned by `NativeStreamingSynthesisSession`'s
    /// retention-flag `defer` (Tier 1.5).
    func testNativeMLXMacEngineCancellationCleansUpStreamSessionArtifacts() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = NativeRuntimeTestSupport.ModelEntry(
            id: "pro_custom",
            name: "Custom Voice",
            folder: "Custom-Model",
            mode: "custom"
        )
        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [model])
        let modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        _ = try NativeRuntimeTestSupport.installModel(model, into: modelsDirectory)

        let customModel = NativeSpeechGenerationModel(
            sampleRate: 24_000,
            customPrewarmHandler: { _, _, _, _ in },
            customStreamHandler: { _, _, _, _, _ in
                AsyncThrowingStream { continuation in
                    Task {
                        do {
                            continuation.yield(.audio([0.0, 0.1, -0.1, 0.0]))
                            try await Task.sleep(for: .milliseconds(50))
                            continuation.yield(.audio([0.05, -0.05, 0.02, -0.02]))
                            try await Task.sleep(for: .milliseconds(500))
                            continuation.yield(.audio([0.1, 0.0, -0.05, 0.02]))
                            continuation.finish()
                        } catch is CancellationError {
                            continuation.finish(throwing: CancellationError())
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            }
        )

        let engine = NativeMLXMacEngine(
            runtime: MacNativeRuntime(
                manifestURL: manifestURL,
                modelLoader: { _, _ in customModel }
            )
        )
        try await engine.initialize(appSupportDirectory: root)

        var observedEvents: [GenerationEvent] = []
        engine.generationEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { observedEvents.append($0) }
            .store(in: &cancellables)

        let outputPath = root.appendingPathComponent("cleanup-session.wav").path
        let request = GenerationRequest(
            modelID: "pro_custom",
            text: "Session cleanup",
            outputPath: outputPath,
            shouldStream: true,
            payload: .custom(speakerID: "vivian", deliveryStyle: nil)
        )

        let task = Task {
            try await engine.generate(request)
        }

        _ = await waitUntil(
            timeoutSeconds: 1.0,
            description: "first streaming event (session directory created)"
        ) {
            observedEvents.count == 1
        }

        // Stream-session-directory should exist while generation is in flight.
        let streamSessionsRoot = root.appendingPathComponent("cache/stream_sessions", isDirectory: true)
        let sessionsBeforeCancel = (try? FileManager.default.contentsOfDirectory(atPath: streamSessionsRoot.path)) ?? []
        XCTAssertFalse(sessionsBeforeCancel.isEmpty, "expected at least one session directory during streaming")

        try await engine.cancelActiveGeneration()

        do {
            _ = try await task.value
            XCTFail("Expected generation to be cancelled.")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        try await Task.sleep(for: .milliseconds(100))

        // After cancellation: no output file, no leftover session directories,
        // no partial chunk files.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outputPath),
            "final output must not be left behind after cancellation"
        )
        let sessionsAfterCancel = (try? FileManager.default.contentsOfDirectory(atPath: streamSessionsRoot.path)) ?? []
        XCTAssertTrue(
            sessionsAfterCancel.isEmpty,
            "stream_sessions directory must be empty after cancellation, found: \(sessionsAfterCancel)"
        )
    }

    func testNativeMLXMacEngineBatchCancellationStopsBeforeLaterItemsStart() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = NativeRuntimeTestSupport.ModelEntry(
            id: "pro_custom",
            name: "Custom Voice",
            folder: "Custom-Model",
            mode: "custom"
        )
        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [model])
        let modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        _ = try NativeRuntimeTestSupport.installModel(model, into: modelsDirectory)

        let streamCalls = StreamCallBox()
        let customModel = NativeSpeechGenerationModel(
            sampleRate: 24_000,
            customPrewarmHandler: { _, _, _, _ in },
            customStreamHandler: { text, _, _, _, _ in
                streamCalls.append(text)
                return AsyncThrowingStream { continuation in
                    Task {
                        do {
                            try await Task.sleep(for: .milliseconds(500))
                            continuation.yield(.audio([0.0, 0.1, -0.1, 0.0]))
                            continuation.finish()
                        } catch is CancellationError {
                            continuation.finish(throwing: CancellationError())
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            }
        )

        let engine = NativeMLXMacEngine(
            runtime: MacNativeRuntime(
                manifestURL: manifestURL,
                modelLoader: { _, _ in customModel }
            )
        )
        try await engine.initialize(appSupportDirectory: root)

        let first = GenerationRequest(
            modelID: "pro_custom",
            text: "First item",
            outputPath: root.appendingPathComponent("first.wav").path,
            shouldStream: false,
            payload: .custom(speakerID: "vivian", deliveryStyle: nil)
        )
        let second = GenerationRequest(
            modelID: "pro_custom",
            text: "Second item",
            outputPath: root.appendingPathComponent("second.wav").path,
            shouldStream: false,
            payload: .custom(speakerID: "vivian", deliveryStyle: nil)
        )

        let task = Task {
            try await engine.generateBatch([first, second]) { _, _ in }
        }

        _ = await waitUntil(timeoutSeconds: 1.0, description: "first batch stream call") {
            streamCalls.allValues == ["First item"]
        }
        try await engine.cancelActiveGeneration()

        do {
            _ = try await task.value
            XCTFail("Expected batch generation to be cancelled.")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertEqual(streamCalls.allValues, ["First item"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.outputPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.outputPath))
    }

}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    verify: ((Error) -> Void)? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        verify?(error)
    }
}
