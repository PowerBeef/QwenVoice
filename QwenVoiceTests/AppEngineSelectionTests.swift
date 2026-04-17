import XCTest
import QwenVoiceNative
@testable import QwenVoice

final class AppEngineSelectionTests: XCTestCase {
    func testAppEngineSelectionDefaultsToNative() {
        XCTAssertEqual(
            AppEngineSelection(environment: [:]),
            .native
        )
    }

    func testAppEngineSelectionHonorsExplicitOverrides() {
        XCTAssertEqual(
            AppEngineSelection(environment: [AppEngineSelection.environmentKey: "python"]),
            .python
        )
        XCTAssertEqual(
            AppEngineSelection(environment: [AppEngineSelection.environmentKey: "native"]),
            .native
        )
    }

    func testAppEngineSelectionFallsBackToNativeForInvalidOverride() {
        XCTAssertEqual(
            AppEngineSelection(environment: [AppEngineSelection.environmentKey: "invalid"]),
            .native
        )
    }

    func testAppEngineSelectionFallsBackToPythonForStubBackendMode() {
        let selection = AppEngineSelection(environment: [:])
        XCTAssertEqual(selection.effectiveSelection(isStubBackendMode: true), .python)
        XCTAssertFalse(selection.requiresManualInitialization(isStubBackendMode: true))
    }

    @MainActor
    func testAppEngineSelectionBuildsNativeEngineByDefault() {
        let engine = AppEngineSelection(environment: [:]).makeEngine(pythonBridge: PythonBridge())
        XCTAssertTrue(engine is NativeMLXMacEngine)
    }

    @MainActor
    func testAppEngineSelectionBuildsPythonEngineWhenRequested() {
        let engine = AppEngineSelection(environment: [AppEngineSelection.environmentKey: "python"])
            .makeEngine(pythonBridge: PythonBridge())
        XCTAssertTrue(engine is PythonBridgeMacTTSEngineAdapter)
    }

    @MainActor
    func testAppEngineSelectionBuildsPythonEngineForStubBackendMode() {
        let engine = AppEngineSelection(environment: [:]).makeEngine(
            pythonBridge: PythonBridge(),
            isStubBackendMode: true
        )
        XCTAssertTrue(engine is PythonBridgeMacTTSEngineAdapter)
    }
}
