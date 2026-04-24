import XCTest
import QwenVoiceNative
@testable import QwenVoice

final class AppEngineSelectionTests: XCTestCase {
    func testAppEngineSelectionAlwaysResolvesToNative() {
        XCTAssertEqual(AppEngineSelection(environment: [:]), .native)
        XCTAssertEqual(AppEngineSelection.current(), .native)
    }

    func testAppEngineSelectionRequiresManualInitialization() {
        let selection = AppEngineSelection.current()
        XCTAssertEqual(selection.effectiveSelection(isStubBackendMode: false), .native)
        XCTAssertTrue(selection.requiresManualInitialization(isStubBackendMode: false))
        XCTAssertTrue(selection.requiresManualInitialization(isStubBackendMode: true))
    }

    func testXCTestHostSuppressesAppEngineAutoStartOutsideUITestLaunches() {
        let xctestEnvironment = [
            "XCTestConfigurationFilePath": "/tmp/QwenVoiceTests.xctestconfiguration",
        ]

        XCTAssertTrue(
            UITestAutomationSupport.shouldSuppressAppEngineAutoStart(
                environment: xctestEnvironment,
                arguments: []
            )
        )
        XCTAssertFalse(
            UITestAutomationSupport.shouldSuppressAppEngineAutoStart(
                environment: xctestEnvironment.merging(["QWENVOICE_UI_TEST": "1"]) { _, new in new },
                arguments: []
            )
        )
        XCTAssertFalse(
            UITestAutomationSupport.shouldSuppressAppEngineAutoStart(
                environment: xctestEnvironment,
                arguments: ["--uitest"]
            )
        )
        XCTAssertFalse(
            UITestAutomationSupport.shouldSuppressAppEngineAutoStart(
                environment: [:],
                arguments: []
            )
        )
    }

    @MainActor
    func testAppEngineSelectionResolvesNativeRunningSidebarStatusForLivePreview() {
        let status = AppEngineSelection.current().resolveSidebarStatus(
            ttsEngineSnapshot: TTSEngineSnapshot(
                isReady: true,
                loadState: .running(
                    modelID: "pro_custom",
                    label: "Hello there buddy",
                    fraction: 0.45
                ),
                clonePreparationState: .idle,
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
        let status = AppEngineSelection.current().resolveSidebarStatus(
            ttsEngineSnapshot: TTSEngineSnapshot(
                isReady: true,
                loadState: .loaded(modelID: "pro_custom"),
                clonePreparationState: .idle,
                visibleErrorMessage: nil
            ),
            prefersInlinePresentation: false
        )

        XCTAssertEqual(status, .idle)
    }

    @MainActor
    func testAppEngineSelectionResolvesNativeVisibleErrors() {
        let status = AppEngineSelection.current().resolveSidebarStatus(
            ttsEngineSnapshot: TTSEngineSnapshot(
                isReady: true,
                loadState: .loaded(modelID: "pro_custom"),
                clonePreparationState: .idle,
                visibleErrorMessage: "Native preview failed"
            ),
            prefersInlinePresentation: false
        )

        XCTAssertEqual(status, .error("Native preview failed"))
    }

    @MainActor
    func testAppEngineSelectionBuildsNativeEngineByDefault() {
        let engine = AppEngineSelection.current().makeEngine()
        XCTAssertTrue(engine is XPCNativeEngineClient)
    }

    @MainActor
    func testAppEngineSelectionBuildsNativeStubEngineForStubBackendMode() {
        let engine = AppEngineSelection.current().makeEngine(isStubBackendMode: true)
        XCTAssertTrue(engine is UITestStubMacEngine)
    }
}
