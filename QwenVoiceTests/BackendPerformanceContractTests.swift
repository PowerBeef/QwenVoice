import XCTest
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
}
