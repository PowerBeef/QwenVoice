import XCTest
import Combine
@testable import QwenVoiceNative

@MainActor
final class NativeMLXMacEngineTests: XCTestCase {
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

        try await engine.loadModel(id: "pro_clone")
        try await engine.ensureCloneReferencePrimed(
            modelID: "pro_clone",
            reference: CloneReference(audioPath: "/tmp/ref.wav", transcript: "Reference")
        )
        guard case .primed(let key) = engine.snapshot.clonePreparationState else {
            return XCTFail("Expected clone reference to be primed")
        }
        XCTAssertEqual(
            key,
            GenerationSemantics.clonePreparationKey(
                modelID: "pro_clone",
                reference: CloneReference(audioPath: "/tmp/ref.wav", transcript: "Reference")
            )
        )

        try await engine.unloadModel()
        XCTAssertEqual(engine.snapshot.loadState, EngineLoadState.idle)
        XCTAssertEqual(engine.snapshot.clonePreparationState, ClonePreparationState.idle)
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
        engine.snapshotPublisher
            .compactMap { $0.latestEvent }
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

        XCTAssertEqual(observedEvents.count, 3)
        XCTAssertEqual(observedEvents.first?.isFinal, false)
        XCTAssertTrue(observedEvents.dropFirst().allSatisfy(\.isFinal))
        XCTAssertEqual(observedEvents.last?.isFinal, true)
        XCTAssertEqual(engine.snapshot.latestEvent?.isFinal, true)
        XCTAssertEqual(engine.snapshot.loadState.currentModelID, "pro_custom")
        XCTAssertNil(engine.snapshot.visibleErrorMessage)

        let sample: BenchmarkSample = try XCTUnwrap(result.benchmarkSample)
        XCTAssertTrue(sample.streamingUsed)
        XCTAssertEqual(sample.tokenCount, 34)
        XCTAssertEqual(sample.booleanFlags["custom_dedicated_handler_used"], true)
        XCTAssertNotNil(sample.firstChunkMs)
        XCTAssertFalse(sample.telemetryStageMarks.isEmpty)
    }

    func testNativeMLXMacEngineGenerateBatchSupportsCustomRequestsOnly() async throws {
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

    func testNativeMLXMacEngineRejectsNativeDesignAndCloneGenerationExplicitly() async throws {
        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = NativeMLXMacEngine(
            runtime: MacNativeRuntime(manifestURL: try NativeRuntimeTestSupport.writeManifest(at: root, models: []))
        )
        try await engine.initialize(appSupportDirectory: root)

        await XCTAssertThrowsErrorAsync {
            _ = try await engine.generate(
                GenerationRequest(
                    modelID: "pro_design",
                    text: "Design me a voice",
                    outputPath: root.appendingPathComponent("design.wav").path,
                    shouldStream: true,
                    payload: .design(voiceDescription: "Warm narrator", deliveryStyle: nil)
                )
            )
        } verify: { error in
            XCTAssertEqual(error.localizedDescription, "Native Voice Design is not implemented yet.")
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await engine.generate(
                GenerationRequest(
                    modelID: "pro_clone",
                    text: "Clone me",
                    outputPath: root.appendingPathComponent("clone.wav").path,
                    shouldStream: true,
                    payload: .clone(reference: CloneReference(audioPath: "/tmp/ref.wav", transcript: "Reference"))
                )
            )
        } verify: { error in
            XCTAssertEqual(error.localizedDescription, "Native Voice Cloning is not implemented yet.")
        }
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
