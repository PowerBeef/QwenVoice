import XCTest
@testable import QwenVoiceNativeRuntime

@MainActor
final class NativeMLXMacEngineLiveTests: XCTestCase {
    func testNativeCustomSmokeWithInstalledModel() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["QWENVOICE_ENABLE_NATIVE_ENGINE_LIVE_TESTS"] == "1",
            "Set QWENVOICE_ENABLE_NATIVE_ENGINE_LIVE_TESTS=1 to run live native engine smoke tests."
        )

        let root = try NativeRuntimeTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = try NativeRuntimeTestSupport.bundledModelEntry(id: "pro_custom")
        let installedDirectory = NativeRuntimeTestSupport.installedModelDirectory(for: model)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: installedDirectory.path),
            "Install the pro_custom model at \(installedDirectory.path) before running live native engine tests."
        )

        let manifestURL = try NativeRuntimeTestSupport.writeManifest(at: root, models: [model])
        _ = try NativeRuntimeTestSupport.mirrorInstalledModel(
            model,
            into: root.appendingPathComponent("models", isDirectory: true)
        )

        let engine = NativeMLXMacEngine(runtime: MacNativeRuntime(manifestURL: manifestURL))
        try await engine.initialize(appSupportDirectory: root)

        let outputURL = root.appendingPathComponent("live-native-custom.wav")
        let request = GenerationRequest(
            modelID: model.id,
            text: "Hello from the live native custom smoke test. Please speak clearly and naturally.",
            outputPath: outputURL.path,
            shouldStream: true,
            streamingTitle: "Live Native Custom Smoke",
            payload: .custom(
                speakerID: "vivian",
                deliveryStyle: "Conversational"
            )
        )

        let result = try await engine.generate(request)

        XCTAssertEqual(result.audioPath, outputURL.path)
        XCTAssertGreaterThan(result.durationSeconds, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertNotNil(result.streamSessionDirectory)

        let sample = try XCTUnwrap(result.benchmarkSample)
        XCTAssertTrue(sample.streamingUsed)
        XCTAssertFalse(sample.telemetryStageMarks.isEmpty)
        XCTAssertFalse(sample.timingsMS.isEmpty)
    }
}
