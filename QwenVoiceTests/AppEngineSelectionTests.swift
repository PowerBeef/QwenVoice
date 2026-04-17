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
    func testAppEngineSelectionResolvesNativeRunningSidebarStatusForLivePreview() {
        let selection = AppEngineSelection(environment: [:])
        let status = selection.resolveSidebarStatus(
            pythonBridge: PythonBridge(),
            ttsEngineSnapshot: TTSEngineSnapshot(
                isReady: true,
                loadState: .running(
                    modelID: "pro_custom",
                    label: "Hello there buddy",
                    fraction: 0.45
                ),
                clonePreparationState: .idle,
                latestEvent: nil,
                visibleErrorMessage: nil
            ),
            prefersInlinePresentation: true
        )

        guard case .running(let activity) = status else {
            return XCTFail("Expected running sidebar status")
        }
        XCTAssertEqual(activity.label, "Hello there buddy")
        XCTAssertEqual(activity.fraction, 0.45)
        XCTAssertEqual(activity.presentation, .inlinePlayer)
    }

    @MainActor
    func testAppEngineSelectionResolvesNativeLoadedSidebarStatusToIdle() {
        let selection = AppEngineSelection(environment: [:])
        let status = selection.resolveSidebarStatus(
            pythonBridge: PythonBridge(),
            ttsEngineSnapshot: TTSEngineSnapshot(
                isReady: true,
                loadState: .loaded(modelID: "pro_custom"),
                clonePreparationState: .idle,
                latestEvent: nil,
                visibleErrorMessage: nil
            ),
            prefersInlinePresentation: false
        )

        XCTAssertEqual(status, .idle)
    }

    @MainActor
    func testAppEngineSelectionResolvesNativeVisibleErrors() {
        let selection = AppEngineSelection(environment: [:])
        let status = selection.resolveSidebarStatus(
            pythonBridge: PythonBridge(),
            ttsEngineSnapshot: TTSEngineSnapshot(
                isReady: true,
                loadState: .loaded(modelID: "pro_custom"),
                clonePreparationState: .idle,
                latestEvent: nil,
                visibleErrorMessage: "Native preview failed"
            ),
            prefersInlinePresentation: false
        )

        XCTAssertEqual(status, .error("Native preview failed"))
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
