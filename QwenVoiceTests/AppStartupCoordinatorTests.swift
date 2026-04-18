import AppKit
import XCTest
@testable import QwenVoice

private final class MainCapableTestWindow: NSWindow {
    override var canBecomeMain: Bool { true }
}

final class AppStartupCoordinatorTests: XCTestCase {
    func testLaunchActionPrefersStubRuntimeWhenStubModeIsExplicit() {
        let action = EnvironmentSetupStateMachine().launchAction(
            machineIdentifier: "arm64",
            bundledPythonPath: "/Applications/QwenVoice.app/Contents/Resources/python/bin/python3",
            bundledRuntimeExists: true,
            isStubBackendMode: true,
            uiTestLiveOverridePythonPath: "/tmp/ui-test/python3",
            venvPythonPath: "/tmp/dev-venv/python3",
            isMarkerValid: true
        )

        XCTAssertEqual(action, .runStub)
    }

    func testLaunchActionFallsBackToStubBeforeUITestLiveOrDevVenv() {
        let action = EnvironmentSetupStateMachine().launchAction(
            machineIdentifier: "arm64",
            bundledPythonPath: nil,
            bundledRuntimeExists: false,
            isStubBackendMode: true,
            uiTestLiveOverridePythonPath: "/tmp/ui-test/python3",
            venvPythonPath: "/tmp/dev-venv/python3",
            isMarkerValid: true
        )

        XCTAssertEqual(action, .runStub)
    }

    func testLaunchActionUsesSlowPathWhenNoReadyRuntimeExists() {
        let action = EnvironmentSetupStateMachine().launchAction(
            machineIdentifier: "arm64",
            bundledPythonPath: nil,
            bundledRuntimeExists: false,
            isStubBackendMode: false,
            uiTestLiveOverridePythonPath: nil,
            venvPythonPath: "/tmp/missing-venv/python3",
            isMarkerValid: false
        )

        XCTAssertEqual(action, .runSlowPath)
    }

    func testShouldStartSetupTaskBlocksDuplicateCheckingState() {
        XCTAssertFalse(
            PythonEnvironmentManager.shouldStartSetupTask(
                for: .checking,
                hasInFlightTask: true
            )
        )
        XCTAssertFalse(
            PythonEnvironmentManager.shouldStartSetupTask(
                for: .settingUp(.findingPython),
                hasInFlightTask: true
            )
        )
        XCTAssertTrue(
            PythonEnvironmentManager.shouldStartSetupTask(
                for: .failed(message: "retry"),
                hasInFlightTask: true
            )
        )
        XCTAssertFalse(
            PythonEnvironmentManager.shouldStartSetupTask(
                for: .ready(pythonPath: "/tmp/python3"),
                hasInFlightTask: false
            )
        )
    }

    func testRuntimeSourcePrefersBundledRuntimeForPackagedPath() {
        let source = UITestAutomationSupport.runtimeSource(
            for: "/Applications/QwenVoice.app/Contents/Resources/python/bin/python3",
            bundledRuntimeRoot: "/Applications/QwenVoice.app/Contents/Resources/python",
            devVenvRoot: "/Users/test/Library/Application Support/QwenVoice/python",
            stubPythonPath: UITestAutomationSupport.stubPythonPath()
        )

        XCTAssertEqual(source, .bundled)
    }

    func testRuntimeSourceIdentifiesDevVenvAndStub() {
        XCTAssertEqual(
            UITestAutomationSupport.runtimeSource(
                for: "/Users/test/Library/Application Support/QwenVoice/python/bin/python3",
                bundledRuntimeRoot: "/Applications/QwenVoice.app/Contents/Resources/python",
                devVenvRoot: "/Users/test/Library/Application Support/QwenVoice/python",
                stubPythonPath: UITestAutomationSupport.stubPythonPath()
            ),
            .devVenv
        )

        XCTAssertEqual(
            UITestAutomationSupport.runtimeSource(
                for: UITestAutomationSupport.stubPythonPath(),
                bundledRuntimeRoot: "/Applications/QwenVoice.app/Contents/Resources/python",
                devVenvRoot: "/Users/test/Library/Application Support/QwenVoice/python",
                stubPythonPath: UITestAutomationSupport.stubPythonPath()
            ),
            .stub
        )
    }

    func testRuntimeSourceReturnsNoneWhenPythonPathIsMissing() {
        XCTAssertEqual(
            UITestAutomationSupport.runtimeSource(
                for: nil,
                bundledRuntimeRoot: "/Applications/QwenVoice.app/Contents/Resources/python",
                devVenvRoot: "/Users/test/Library/Application Support/QwenVoice/python",
                stubPythonPath: UITestAutomationSupport.stubPythonPath()
            ),
            .none
        )
    }

    func testLaunchDiagnosticsAreDisabledForUITestOrDerivedDataSourceBuilds() {
        XCTAssertFalse(
            AppLaunchPreflight.shouldShowDiagnostics(
                isUITest: true,
                bundlePath: "/Applications/QwenVoice.app"
            )
        )

        XCTAssertFalse(
            AppLaunchPreflight.shouldShowDiagnostics(
                isUITest: false,
                bundlePath: "/Users/test/Library/Developer/Xcode/DerivedData/QwenVoice/Build/Products/Debug/QwenVoice.app"
            )
        )
    }

    @MainActor
    func testTrackedMainWindowsIgnoresNonContentWindows() {
        let mainWindow = MainCapableTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        mainWindow.identifier = UITestWindowCoordinator.mainContentWindowIdentifier

        let settingsWindow = MainCapableTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.identifier = NSUserInterfaceItemIdentifier("QwenVoiceSettingsWindow")

        let tracked = UITestWindowCoordinator.trackedMainWindows(
            in: [settingsWindow, mainWindow]
        )

        XCTAssertEqual(tracked.count, 1)
        XCTAssertEqual(tracked.first?.identifier, UITestWindowCoordinator.mainContentWindowIdentifier)
    }
}
