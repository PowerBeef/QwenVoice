import Foundation
@preconcurrency import XCTest

/// Explicit, opt-in physical-device proof for background model delivery. This method is selected
/// directly by `scripts/ui_test.sh ios model-download`; smoke, benchmarks, CI, and release never
/// execute it. All actions use genuine visible Settings controls.
@MainActor
final class VocelloiOSModelDownloadUITests: VocelloiOSUITestCase {
    private let isolatedSupportRoot = "model-download-acceptance"
    private let modelID = "pro_custom"

    func testIsolatedBackgroundDownloadAdoptionAndCleanup() {
        beginSession()
        defer { endSession() }
        select(tab: .settings)
        assertCanonicalModelDeliveryIsIdle()

        let environment = ["QVOICE_APP_SUPPORT_DIR": isolatedSupportRoot]
        launchApp(additionalEnvironment: environment)

        select(tab: .settings)
        XCTAssertFalse(
            element("iosModelDelete_\(modelID)").exists,
            "The isolated root must begin without Custom installed; refusing to delete an ambiguous model"
        )

        let install = element("iosModelDownload_\(modelID)")
        XCTAssertTrue(VocelloUIWait.exists(install, timeout: 60))
        XCTAssertTrue(VocelloUIPrimaryAction.perform(on: install, timeout: 20))

        let progress = element("iosModelProgress_\(modelID)")
        XCTAssertTrue(VocelloUIWait.exists(progress, timeout: 120))
        XCTAssertTrue(VocelloUIWait.condition("model download to make measurable progress", timeout: 600) {
            self.progressFraction(progress) > 0
        })
        let beforeRelaunch = progressFraction(progress)
        VocelloUIScreenshot.attach(app, named: "ios-model-download-before-relaunch")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(VocelloUIWait.condition("Vocello to enter the background", timeout: 30) {
            self.app.state == .runningBackground || self.app.state == .runningBackgroundSuspended
        })
        app.terminate()
        launchApp(additionalEnvironment: environment)
        select(tab: .settings)

        let installed = element("iosModelDelete_\(modelID)")
        let restoredProgress = element("iosModelProgress_\(modelID)")
        XCTAssertTrue(VocelloUIWait.condition("adopted download progress or completed install", timeout: 120) {
            if installed.exists { return true }
            guard restoredProgress.exists else { return false }
            return self.progressFraction(restoredProgress) >= beforeRelaunch
        })
        XCTAssertTrue(VocelloUIWait.exists(installed, timeout: 3_600))
        VocelloUIScreenshot.attach(app, named: "ios-model-download-installed")

        XCTAssertTrue(VocelloUIPrimaryAction.perform(on: installed, timeout: 20))
        let confirmDelete = element("deleteModelSheet_confirm")
        XCTAssertTrue(VocelloUIWait.exists(confirmDelete, timeout: 20))
        XCTAssertTrue(VocelloUIPrimaryAction.perform(on: confirmDelete, timeout: 20))
        XCTAssertTrue(VocelloUIWait.exists(element("iosModelDownload_\(modelID)"), timeout: 120))
        VocelloUIScreenshot.attach(app, named: "ios-model-download-isolated-cleanup")

        // Leave the isolated root, then prove the user's canonical installation
        // is still present through the same genuine Settings surface.
        launchApp()
        select(tab: .settings)
        assertCanonicalModelDeliveryIsIdle()
        VocelloUIScreenshot.attach(app, named: "ios-model-download-canonical-preserved")
    }

    /// Switching to an isolated support root is safe only after the genuine
    /// canonical Settings surface proves every production model is installed
    /// and no canonical transfer control is active.
    private func assertCanonicalModelDeliveryIsIdle() {
        for canonicalModelID in ["pro_custom", "pro_design", "pro_clone"] {
            let installed = element("iosModelDelete_\(canonicalModelID)")
            XCTAssertTrue(
                VocelloUIWait.exists(installed, timeout: 60),
                "The isolated delivery proof requires canonical \(canonicalModelID) installed"
            )
            for activeControl in ["Download", "Cancel", "Retry", "Repair"] {
                XCTAssertFalse(
                    element("iosModel\(activeControl)_\(canonicalModelID)").exists,
                    "Canonical \(canonicalModelID) must not have an active delivery operation"
                )
            }
            XCTAssertFalse(element("iosModelProgress_\(canonicalModelID)").exists)
        }
    }

    private func progressFraction(_ element: XCUIElement) -> Double {
        guard element.exists else { return 0 }
        if let number = element.value as? NSNumber {
            return number.doubleValue
        }
        guard let value = element.value as? String else { return 0 }
        let numeric = value
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(numeric) else { return 0 }
        return value.contains("%") ? parsed / 100 : parsed
    }
}
