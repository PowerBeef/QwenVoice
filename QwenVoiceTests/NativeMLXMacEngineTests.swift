import XCTest
@testable import QwenVoiceNative

@MainActor
final class NativeMLXMacEngineTests: XCTestCase {
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
            runtime: MacNativeRuntime(manifestURL: manifestURL)
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
                }
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
            runtime: MacNativeRuntime(manifestURL: manifestURL)
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
            runtime: MacNativeRuntime(manifestURL: manifestURL)
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
            runtime: MacNativeRuntime(manifestURL: manifestURL)
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
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
    }
}
