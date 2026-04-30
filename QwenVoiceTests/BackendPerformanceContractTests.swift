import XCTest
@preconcurrency import MLXLMCommon
@preconcurrency import MLXAudioTTS
@testable import QwenVoiceCore

final class BackendPerformanceContractTests: XCTestCase {
    func testBenchmarkSampleRoundTripsBackendPerformanceAndPCMPreviewChunk() throws {
        let preview = StreamingAudioChunk(
            requestID: 42,
            sampleRate: 24_000,
            frameOffset: 128,
            frameCount: 4,
            pcm16LE: Data([0, 0, 255, 127, 1, 128, 0, 0]),
            isFinal: false
        )
        let performance = NativeBackendPerformanceSample(
            coldLoadMS: 1_200,
            warmGenerationMS: 800,
            timeToFirstAudioMS: 160,
            audioSecondsPerWallSecond: 1.75,
            chunkWriteTotalMS: 0,
            chunkWriteMaxMS: 0,
            eventDispatchMS: 3,
            finalWriteMS: 12,
            mlxMemoryByStage: [
                "first_chunk": NativeMLXMemorySnapshot(
                    activeMB: 100,
                    cacheMB: 32,
                    peakMB: 140
                )
            ],
            loadCapabilityProfile: NativeLoadCapabilityProfile.customOnly.rawValue,
            memoryPolicyName: "floor_8gb_mac_custom_single",
            streamingTransport: NativeStreamingOutputPolicy.pcmPreview.rawValue,
            telemetryMode: NativeTelemetryMode.lightweight.rawValue
        )
        let result = GenerationResult(
            audioPath: "/tmp/audio.wav",
            durationSeconds: 1.0,
            streamSessionDirectory: "/tmp/session",
            benchmarkSample: BenchmarkSample(
                engineKind: .nativeMLX,
                processingTimeSeconds: 0.8,
                streamingUsed: true,
                firstChunkMs: 160,
                timingsMS: ["generation": 800],
                stringFlags: ["streaming_transport": "pcm_preview"],
                backendPerformance: performance
            )
        )
        let event = GenerationEvent.chunk(
            GenerationChunk(
                requestID: 42,
                mode: GenerationMode.custom.rawValue,
                title: "Preview",
                chunkPath: nil,
                isFinal: false,
                chunkDurationSeconds: 0.1,
                cumulativeDurationSeconds: 0.1,
                streamSessionDirectory: "/tmp/session",
                previewAudio: preview
            )
        )

        let encodedResult = try JSONEncoder().encode(result)
        let decodedResult = try JSONDecoder().decode(GenerationResult.self, from: encodedResult)
        XCTAssertEqual(decodedResult, result)
        XCTAssertEqual(decodedResult.benchmarkSample?.backendPerformance, performance)

        let encodedEvent = try JSONEncoder().encode(event)
        let decodedEvent = try JSONDecoder().decode(GenerationEvent.self, from: encodedEvent)
        XCTAssertEqual(decodedEvent, event)
        XCTAssertNil(decodedEvent.chunkPath)
        XCTAssertEqual(decodedEvent.previewAudio, preview)
    }

    func testLoadCapabilityProfilesMapFromGenerationRequests() {
        XCTAssertEqual(
            NativeLoadCapabilityProfile(
                for: GenerationRequest(
                    modelID: "pro_custom",
                    text: "Hello",
                    outputPath: "/tmp/custom.wav",
                    payload: .custom(speakerID: "vivian", deliveryStyle: nil)
                )
            ),
            .customOnly
        )
        XCTAssertEqual(
            NativeLoadCapabilityProfile(
                for: GenerationRequest(
                    modelID: "pro_design",
                    text: "Hello",
                    outputPath: "/tmp/design.wav",
                    payload: .design(voiceDescription: "Warm narrator", deliveryStyle: nil)
                )
            ),
            .designOnly
        )
        XCTAssertEqual(
            NativeLoadCapabilityProfile(
                for: GenerationRequest(
                    modelID: "pro_clone",
                    text: "Hello",
                    outputPath: "/tmp/clone.wav",
                    payload: .clone(
                        reference: CloneReference(
                            audioPath: "/tmp/reference.wav",
                            transcript: "Hello"
                        )
                    )
                )
            ),
            .cloneOnly
        )
    }

    func testCapabilityProfilesMapToPreparedQwenLoadBehavior() {
        let customBehavior = MLXTTSEngine.qwenPreparedLoadBehavior(
            for: NativeQwenPreparedLoadProfile(capabilityProfile: .customOnly),
            trustPreparedCheckpoint: true
        )
        XCTAssertEqual(customBehavior.trustPreparedCheckpoint, true)
        XCTAssertEqual(customBehavior.loadSpeakerEncoder, false)
        XCTAssertEqual(customBehavior.loadSpeechTokenizerEncoder, false)
        XCTAssertTrue(customBehavior.skipSpeechTokenizerEval)
        XCTAssertFalse(customBehavior.preparedDirectoryAlreadyValidated)

        let validatedCustomBehavior = MLXTTSEngine.qwenPreparedLoadBehavior(
            for: NativeQwenPreparedLoadProfile(capabilityProfile: .customOnly),
            trustPreparedCheckpoint: true,
            preparedDirectoryAlreadyValidated: true
        )
        XCTAssertTrue(validatedCustomBehavior.preparedDirectoryAlreadyValidated)

        let cloneBehavior = MLXTTSEngine.qwenPreparedLoadBehavior(
            for: NativeQwenPreparedLoadProfile(capabilityProfile: .cloneOnly),
            trustPreparedCheckpoint: false
        )
        XCTAssertNil(cloneBehavior.loadSpeakerEncoder)
        XCTAssertNil(cloneBehavior.loadSpeechTokenizerEncoder)
        XCTAssertFalse(cloneBehavior.skipSpeechTokenizerEval)
    }

    func testMemoryPolicySelectionForDeviceClasses() {
        let floorPolicy = NativeMemoryPolicyResolver.policy(
            deviceClass: .floor8GBMac,
            mode: .custom,
            isBatch: false
        )
        XCTAssertEqual(floorPolicy.cacheLimitBytes, 256 * 1_024 * 1_024)
        XCTAssertTrue(floorPolicy.clearCacheAfterGeneration)
        XCTAssertEqual(floorPolicy.unloadAfterIdleSeconds, 120)

        let midBatchPolicy = NativeMemoryPolicyResolver.policy(
            deviceClass: .mid16GBMac,
            mode: .design,
            isBatch: true
        )
        XCTAssertEqual(midBatchPolicy.cacheLimitBytes, 512 * 1_024 * 1_024)
        XCTAssertFalse(midBatchPolicy.clearCacheAfterGeneration)
        XCTAssertEqual(midBatchPolicy.unloadAfterIdleSeconds, 300)

        let iPhonePolicy = NativeMemoryPolicyResolver.policy(
            deviceClass: .iPhonePro,
            mode: .clone,
            isBatch: false
        )
        XCTAssertEqual(iPhonePolicy.cacheLimitBytes, 128 * 1_024 * 1_024)
        XCTAssertTrue(iPhonePolicy.clearCacheAfterGeneration)
        XCTAssertEqual(iPhonePolicy.unloadAfterIdleSeconds, 30)
    }

    func testModelPrewarmStateDoesNotPersistAcrossCoordinatorInstances() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let modelsRoot = root.appendingPathComponent("models", isDirectory: true)
        let hubCacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let model = ModelDescriptor(
            id: "pro_custom",
            name: "Custom Voice",
            tier: "pro",
            folder: "Qwen3-TTS-Custom-Model",
            mode: .custom,
            huggingFaceRepo: "example/Qwen3-TTS-Custom",
            artifactVersion: "test",
            iosDownloadEligible: false,
            estimatedDownloadBytes: nil,
            outputSubfolder: "CustomVoice",
            requiredRelativePaths: Self.fakeQwenRequiredPaths
        )
        let descriptor = ModelAssetDescriptor(
            model: model,
            version: "test-version",
            artifacts: Self.fakeQwenRequiredPaths.map {
                ModelAssetArtifact(relativePath: $0, scope: .modelSpecific)
            }
        )
        let store = TestModelAssetStore(rootDirectory: modelsRoot, descriptors: [descriptor])
        let modelRoot = store.localRoot(for: descriptor)
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        try Self.writeFakeQwenModelFiles(to: modelRoot, family: "CustomVoice")

        let stalePersistedKeyFile = modelRoot.appendingPathComponent(".qvoice_prewarm_keys.json")
        try JSONEncoder().encode(["custom|stale"])
            .write(to: stalePersistedKeyFile)

        let firstCoordinator = MLXModelLoadCoordinator(
            modelAssetStore: store,
            hubCacheDirectory: hubCacheRoot,
            modelLoader: { _, _, _ in UnsafeSpeechGenerationModel() }
        )
        _ = try await firstCoordinator.loadModel(id: "pro_custom", capabilityProfile: .customOnly)
        let restoredStaleKey = await firstCoordinator.isPrewarmed(identityKey: "custom|stale")
        XCTAssertFalse(
            restoredStaleKey,
            "Prewarm state is volatile model-process state and must not be restored from stale disk markers."
        )

        await firstCoordinator.markPrewarmed(identityKey: "custom|current")
        let markedCurrentKey = await firstCoordinator.isPrewarmed(identityKey: "custom|current")
        XCTAssertTrue(markedCurrentKey)

        let secondCoordinator = MLXModelLoadCoordinator(
            modelAssetStore: store,
            hubCacheDirectory: hubCacheRoot,
            modelLoader: { _, _, _ in UnsafeSpeechGenerationModel() }
        )
        _ = try await secondCoordinator.loadModel(id: "pro_custom", capabilityProfile: .customOnly)
        let restoredCurrentKey = await secondCoordinator.isPrewarmed(identityKey: "custom|current")
        XCTAssertFalse(
            restoredCurrentKey,
            "A fresh helper/client must explicitly warm again instead of inheriting volatile prewarm keys."
        )
    }

    func testPreparedQwenCacheHitAvoidsOverlayRebuildAfterFirstLoad() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let modelsRoot = root.appendingPathComponent("models", isDirectory: true)
        let hubCacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let model = ModelDescriptor(
            id: "pro_custom",
            name: "Custom Voice",
            tier: "pro",
            folder: "Qwen3-TTS-Custom-Model",
            mode: .custom,
            huggingFaceRepo: "example/Qwen3-TTS-Custom",
            artifactVersion: "test",
            iosDownloadEligible: false,
            estimatedDownloadBytes: nil,
            outputSubfolder: "CustomVoice",
            requiredRelativePaths: Self.fakeQwenRequiredPaths
        )
        let descriptor = ModelAssetDescriptor(
            model: model,
            version: "test-version",
            artifacts: Self.fakeQwenRequiredPaths.map {
                ModelAssetArtifact(relativePath: $0, scope: .modelSpecific)
            }
        )
        let store = TestModelAssetStore(rootDirectory: modelsRoot, descriptors: [descriptor])
        let modelRoot = store.localRoot(for: descriptor)
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        try Self.writeFakeQwenModelFiles(to: modelRoot, family: "CustomVoice")

        let firstCoordinator = MLXModelLoadCoordinator(
            modelAssetStore: store,
            hubCacheDirectory: hubCacheRoot,
            modelLoader: { _, metadata, _ in
                XCTAssertFalse(metadata.trustedPreparedCheckpoint)
                return UnsafeSpeechGenerationModel()
            }
        )
        let first = try await firstCoordinator.loadModel(id: "pro_custom", capabilityProfile: .customOnly)
        XCTAssertEqual(first.booleanFlags["prepared_model_cache_hit"], false)
        XCTAssertEqual(first.booleanFlags["prepared_overlay_rebuilt"], true)

        let secondCoordinator = MLXModelLoadCoordinator(
            modelAssetStore: store,
            hubCacheDirectory: hubCacheRoot,
            modelLoader: { _, metadata, _ in
                XCTAssertTrue(metadata.trustedPreparedCheckpoint)
                return UnsafeSpeechGenerationModel()
            }
        )
        let second = try await secondCoordinator.loadModel(id: "pro_custom", capabilityProfile: .customOnly)
        XCTAssertEqual(second.booleanFlags["prepared_model_cache_hit"], true)
        XCTAssertEqual(second.booleanFlags["prepared_overlay_cache_hit"], true)
        XCTAssertEqual(second.booleanFlags["prepared_overlay_rebuilt"], false)
    }

    func testQwen3RuntimeProfileValidatesContractMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Resources/qwenvoice_contract.json")
        let registry = try ContractBackedModelRegistry(manifestURL: manifestURL)
            .resolvedForPlatform(.macOS)

        for model in registry.models {
            let descriptor = ModelAssetDescriptor(
                model: model,
                version: "test-\(model.id)",
                artifacts: model.requiredRelativePaths.map {
                    ModelAssetArtifact(relativePath: $0, scope: .modelSpecific)
                }
            )
            let modelRoot = root.appendingPathComponent(model.folder, isDirectory: true)
            try Self.writeFakeQwenModelFiles(
                to: modelRoot,
                family: Self.fakeFamilyName(for: model.mode)
            )

            let profile = try Qwen3TTSRuntimeProfile.load(
                from: modelRoot,
                descriptor: descriptor
            )
            XCTAssertEqual(profile.modelType, "qwen3_tts")
            XCTAssertEqual(profile.modeCapability, model.mode)
            XCTAssertEqual(profile.sampleRate, 24_000)
            XCTAssertTrue(profile.supportsStreaming)
            XCTAssertEqual(profile.tokenizerType, Qwen3TTSRuntimeProfile.canonicalTokenizerType)
        }
    }

    func testQwen3RuntimeProfileRejectsModeFamilyMismatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = ModelDescriptor(
            id: "bad_design",
            name: "Bad Design",
            tier: "pro",
            folder: "Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
            mode: .design,
            huggingFaceRepo: "example/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
            artifactVersion: "test",
            iosDownloadEligible: false,
            estimatedDownloadBytes: nil,
            outputSubfolder: "VoiceDesign",
            requiredRelativePaths: Qwen3TTSRuntimeProfile.criticalRequiredComponents
        )
        let descriptor = ModelAssetDescriptor(
            model: model,
            version: "test-version",
            artifacts: model.requiredRelativePaths.map {
                ModelAssetArtifact(relativePath: $0, scope: .modelSpecific)
            }
        )
        let modelRoot = root.appendingPathComponent(model.folder, isDirectory: true)
        try Self.writeFakeQwenModelFiles(to: modelRoot, family: "CustomVoice")

        XCTAssertThrowsError(
            try Qwen3TTSRuntimeProfile.load(from: modelRoot, descriptor: descriptor)
        )
    }

    func testBenchmarkGenerationParameterOverridesAreLiveAuditOnly() {
        let defaults = GenerateParameters(
            maxTokens: 16,
            temperature: 0.9,
            topP: 1.0,
            repetitionPenalty: 1.05
        )
        let productParameters = Qwen3BenchmarkGenerationParameterOverrides.resolve(
            defaultParameters: defaults,
            environment: [
                "QWENVOICE_QWEN3_BENCHMARK_MAX_TOKENS": "8",
                "QWENVOICE_QWEN3_BENCHMARK_TOP_P": "0.8",
            ]
        )
        XCTAssertEqual(productParameters.maxTokens, defaults.maxTokens)
        XCTAssertEqual(productParameters.topP, defaults.topP)

        let benchmarkParameters = Qwen3BenchmarkGenerationParameterOverrides.resolve(
            defaultParameters: defaults,
            environment: [
                "QWENVOICE_AUDIO_QC_LIVE": "1",
                "QWENVOICE_QWEN3_BENCHMARK_MAX_TOKENS": "8",
                "QWENVOICE_QWEN3_BENCHMARK_TOP_P": "0.8",
            ]
        )
        XCTAssertEqual(benchmarkParameters.maxTokens, 8)
        XCTAssertEqual(benchmarkParameters.topP, 0.8)
    }

    func testCustomVoiceGenerationParametersUseConservativeProductSampling() {
        let defaults = GenerateParameters(
            maxTokens: 16,
            temperature: 0.9,
            topP: 1.0,
            repetitionPenalty: 1.05
        )

        let productParameters = Qwen3CustomVoiceGenerationParameterPolicy.resolve(
            defaultParameters: defaults,
            environment: [:]
        )

        XCTAssertEqual(productParameters.maxTokens, defaults.maxTokens)
        XCTAssertEqual(productParameters.temperature, 0.7, accuracy: 0.0001)
        XCTAssertEqual(productParameters.topP, 0.9, accuracy: 0.0001)
        XCTAssertEqual(productParameters.repetitionPenalty, defaults.repetitionPenalty)
    }

    func testCustomVoiceBenchmarkOverridesCanStillReplaceProductSampling() {
        let defaults = GenerateParameters(
            maxTokens: 16,
            temperature: 0.9,
            topP: 1.0,
            repetitionPenalty: 1.05
        )

        let benchmarkParameters = Qwen3CustomVoiceGenerationParameterPolicy.resolve(
            defaultParameters: defaults,
            environment: [
                "QWENVOICE_AUDIO_QC_LIVE": "1",
                "QWENVOICE_QWEN3_BENCHMARK_TEMPERATURE": "0.6",
                "QWENVOICE_QWEN3_BENCHMARK_TOP_P": "0.85",
            ]
        )

        XCTAssertEqual(benchmarkParameters.temperature, 0.6, accuracy: 0.0001)
        XCTAssertEqual(benchmarkParameters.topP, 0.85, accuracy: 0.0001)
    }

    func testQwenPromptContractRejectsVoiceImitationPrompts() {
        let request = GenerationRequest(
            modelID: "pro_design",
            text: "Hello",
            outputPath: "/tmp/design.wav",
            payload: .design(
                voiceDescription: "Sound exactly like a famous celebrity.",
                deliveryStyle: nil
            )
        )

        XCTAssertThrowsError(try GenerationSemantics.validateQwenPromptContract(for: request))
    }

    func testNativeModelLoadRejectsNonQwenModelTypeBeforeLoaderRuns() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let modelsRoot = root.appendingPathComponent("models", isDirectory: true)
        let hubCacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let model = ModelDescriptor(
            id: "legacy_echo",
            name: "Legacy Echo",
            tier: "legacy",
            folder: "Echo-Model",
            mode: .custom,
            huggingFaceRepo: "example/echo",
            artifactVersion: "test",
            iosDownloadEligible: false,
            estimatedDownloadBytes: nil,
            outputSubfolder: "CustomVoice",
            requiredRelativePaths: ["config.json"]
        )
        let descriptor = ModelAssetDescriptor(
            model: model,
            version: "test-version",
            artifacts: [
                ModelAssetArtifact(relativePath: "config.json", scope: .modelSpecific)
            ]
        )
        let store = TestModelAssetStore(rootDirectory: modelsRoot, descriptors: [descriptor])
        let modelRoot = store.localRoot(for: descriptor)
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        try Data(#"{"model_type":"echo_tts"}"#.utf8)
            .write(to: modelRoot.appendingPathComponent("config.json"))

        let counter = BackendLoadCounter()
        let coordinator = MLXModelLoadCoordinator(
            modelAssetStore: store,
            hubCacheDirectory: hubCacheRoot,
            modelLoader: { _, _, _ in
                await counter.recordLoad()
                return UnsafeSpeechGenerationModel()
            }
        )

        do {
            _ = try await coordinator.loadModel(id: "legacy_echo", capabilityProfile: .customOnly)
            XCTFail("Non-Qwen3-TTS model metadata must be rejected before loading.")
        } catch {
            let loadCount = await counter.currentCount()
            XCTAssertEqual(loadCount, 0)
            XCTAssertTrue(
                String(describing: error).contains("qwen3_tts")
                    || error.localizedDescription.contains("Qwen3-TTS"),
                "Unexpected error for non-Qwen model: \(error)"
            )
        }
    }
}

private extension BackendPerformanceContractTests {
    static var fakeQwenRequiredPaths: [String] {
        Qwen3TTSRuntimeProfile.criticalRequiredComponents + ["tokenizer.json"]
    }

    static func fakeFamilyName(for mode: GenerationMode) -> String {
        switch mode {
        case .custom:
            return "CustomVoice"
        case .design:
            return "VoiceDesign"
        case .clone:
            return "Base"
        }
    }

    static func writeFakeQwenModelFiles(to modelRoot: URL, family: String) throws {
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        let config = """
        {
          "model_type": "qwen3_tts",
          "tokenizer_type": "qwen3_tts_tokenizer_12hz",
          "tts_model_type": "\(family)",
          "sample_rate": 24000,
          "talker_config": {
            "codec_language_id": {
              "english": 1,
              "chinese": 2
            },
            "spk_id": {
              "vivian": [1]
            }
          },
          "tokenizer_config": {
            "output_sample_rate": 24000
          }
        }
        """
        let generationConfig = """
        {
          "max_new_tokens": 4096,
          "temperature": 0.9,
          "top_p": 1.0,
          "repetition_penalty": 1.05
        }
        """
        for relativePath in fakeQwenRequiredPaths {
            let fileURL = modelRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload: Data
            switch relativePath {
            case "config.json":
                payload = Data(config.utf8)
            case "generation_config.json":
                payload = Data(generationConfig.utf8)
            case "tokenizer.json":
                payload = Data(#"{"model":{"type":"BPE"},"pre_tokenizer":{"type":"ByteLevel"}}"#.utf8)
            default:
                payload = Data(relativePath.utf8)
            }
            try payload.write(to: fileURL)
        }
    }
}

private struct TestModelAssetStore: ModelAssetStore {
    let rootDirectory: URL
    let descriptors: [ModelAssetDescriptor]

    func descriptor(id: String) -> ModelAssetDescriptor? {
        descriptors.first { $0.id == id }
    }

    func localRoot(for descriptor: ModelAssetDescriptor) -> URL {
        rootDirectory.appendingPathComponent(descriptor.installFolder, isDirectory: true)
    }

    func localURL(for descriptor: ModelAssetDescriptor, artifact: ModelAssetArtifact) -> URL {
        localRoot(for: descriptor).appendingPathComponent(artifact.relativePath)
    }

    func integrity(for descriptor: ModelAssetDescriptor) -> AssetIntegrity {
        AssetIntegrity(
            status: .verified,
            localRootPath: localRoot(for: descriptor).path,
            missingRelativePaths: [],
            presentRelativePaths: descriptor.artifacts.map(\.relativePath),
            sizeBytes: 1
        )
    }

    func state(for descriptor: ModelAssetDescriptor) -> ModelAssetState {
        .available(integrity(for: descriptor))
    }
}

private actor BackendLoadCounter {
    private var count = 0

    func recordLoad() {
        count += 1
    }

    func currentCount() -> Int {
        count
    }
}
