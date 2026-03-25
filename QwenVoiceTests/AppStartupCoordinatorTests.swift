import AppKit
import XCTest
@testable import QwenVoice

private final class MainCapableTestWindow: NSWindow {
    override var canBecomeMain: Bool { true }
}

final class AppStartupCoordinatorTests: XCTestCase {
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
