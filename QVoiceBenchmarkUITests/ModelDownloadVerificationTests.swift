import XCTest

/// Dedicated XCUITest that verifies all download-eligible models can be downloaded and installed.
/// Handles app crashes/restarts during large downloads by re-launching and re-checking state.
/// Run: xcodebuild test -scheme QVoiceModelVerification -destination 'id=<udid>'
///   or: xcodebuild test-without-building ... -only-testing:QVoiceBenchmarkUITests/ModelDownloadVerificationTests
final class ModelDownloadVerificationTests: XCTestCase {

    /// Download-eligible model IDs and their display labels.
    private static let downloadableModels: [(id: String, label: String)] = [
        ("pro_custom", "Custom Voice"),
        ("pro_design", "Voice Design"),
        ("pro_clone", "Voice Cloning"),
    ]

    /// Maximum time to wait for a single model download (15 minutes).
    private static let downloadTimeout: TimeInterval = 900

    /// How often to poll model state during download (seconds).
    private static let pollInterval: TimeInterval = 5

    /// How long to leave the app in the background during the explicit
    /// multi-file install resilience scenario.
    private static let backgroundObservationWindow: TimeInterval = 20

    /// Maximum number of app re-launches to tolerate per model.
    private static let maxRelaunchAttempts = 3

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        launchApp()
    }

    // MARK: - Tests

    /// Verifies that all download-eligible models are installed, downloading any that are missing.
    func testAllDownloadEligibleModelsInstalled() {
        for model in Self.downloadableModels {
            verifyOrInstallModel(model.id, label: model.label)
        }
        print("🏁 MODEL_VERIFICATION_COMPLETE — all download-eligible models installed")
    }

    /// Verifies the Custom Voice model individually.
    func testCustomVoiceModelDownload() {
        verifyOrInstallModel("pro_custom", label: "Custom Voice")
    }

    /// Verifies the Voice Design model individually.
    func testVoiceDesignModelDownload() {
        verifyOrInstallModel("pro_design", label: "Voice Design")
    }

    /// Verifies the Voice Cloning model individually.
    func testVoiceCloningModelDownload() {
        verifyOrInstallModel("pro_clone", label: "Voice Cloning")
    }

    /// Starts a fresh Voice Cloning install, backgrounds the app mid-download,
    /// then verifies the install still completes after the app is resumed.
    func testVoiceCloningDownloadSurvivesBackgroundTransition() {
        let modelID = "pro_clone"
        let label = "Voice Cloning"

        guard ensureAppOnSettings() else {
            XCTFail("[\(label)] could not navigate to Settings")
            return
        }

        removeModelIfInstalled(modelID, label: label)

        guard tapDownloadIfNeeded(modelID, label: label) else {
            return
        }

        let cancelButton = app.buttons["iosModelCancel_\(modelID)"]
        XCTAssertTrue(
            cancelButton.waitForExistence(timeout: 30),
            "[\(label)] download did not enter in-progress state before backgrounding"
        )

        print("🏠 [\(label)] backgrounding app during install...")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: Self.backgroundObservationWindow)

        print("🔄 [\(label)] resuming app after background window...")
        app.activate()
        guard navigateToSettings() else {
            XCTFail("[\(label)] could not return to Settings after backgrounding")
            return
        }

        _ = waitForInstallCompletion(modelID, label: label, startTime: Date())
    }

    // MARK: - App Lifecycle

    private func launchApp() {
        app.launch()
        let generateTab = app.tabBars.buttons["Generate"]
        XCTAssertTrue(generateTab.waitForExistence(timeout: 15), "App didn't launch")
    }

    /// Re-launch the app if it has terminated, then navigate back to Settings.
    /// Returns true if the app is running and Settings is visible.
    private func ensureAppOnSettings() -> Bool {
        if app.state == .notRunning || app.state == .unknown {
            print("🔄 App not running — re-launching...")
            launchApp()
        }
        return navigateToSettings()
    }

    // MARK: - Navigation

    @discardableResult
    private func navigateToSettings() -> Bool {
        let settingsTab = app.tabBars.buttons["Settings"]
        guard settingsTab.waitForExistence(timeout: 10) else {
            print("⚠️ Settings tab not found")
            return false
        }
        settingsTab.tap()

        let anyModelRow = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH 'iosModelRow_'")
        ).firstMatch
        let loaded = anyModelRow.waitForExistence(timeout: 15)
        if loaded {
            print("▶️ Settings loaded, model rows visible")
        }
        return loaded
    }

    // MARK: - Verification & Install

    /// Checks whether a model is installed. If not, downloads it with crash-resilient polling.
    private func verifyOrInstallModel(_ modelID: String, label: String) {
        guard ensureAppOnSettings() else {
            XCTFail("[\(label)] could not navigate to Settings")
            return
        }

        // Check if already installed before attempting download
        if isModelInstalled(modelID) {
            print("✅ [\(label)] already installed — verified")
            return
        }

        // Tap download/retry if available
        if !tapDownloadIfNeeded(modelID, label: label) {
            return
        }

        _ = waitForInstallCompletion(modelID, label: label, startTime: Date())
    }

    /// Returns true if the delete button is visible (model installed).
    private func isModelInstalled(_ modelID: String) -> Bool {
        let deleteButton = app.buttons["iosModelDelete_\(modelID)"]
        // Wait for model state to settle past "checking" spinner
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if deleteButton.exists { return true }
            // If download or retry appeared, it's not installed
            if app.buttons["iosModelDownload_\(modelID)"].exists { return false }
            if app.buttons["iosModelRetry_\(modelID)"].exists { return false }
            Thread.sleep(forTimeInterval: 1)
        }
        return deleteButton.exists
    }

    /// Finds and taps the download or retry button. Returns true if tapped.
    private func tapDownloadIfNeeded(_ modelID: String, label: String) -> Bool {
        let downloadButton = app.buttons["iosModelDownload_\(modelID)"]
        let retryButton = app.buttons["iosModelRetry_\(modelID)"]

        if downloadButton.exists {
            print("⬇️ [\(label)] not installed — starting download...")
            downloadButton.tap()
            return true
        }
        if retryButton.exists {
            print("🔄 [\(label)] previous attempt failed — retrying...")
            retryButton.tap()
            return true
        }

        XCTFail("[\(label)] no download or retry button found — model state unknown")
        return false
    }

    private func removeModelIfInstalled(_ modelID: String, label: String) {
        let deleteButton = app.buttons["iosModelDelete_\(modelID)"]
        guard deleteButton.waitForExistence(timeout: 5) else { return }

        print("🗑️ [\(label)] removing installed model before background-download scenario...")
        deleteButton.tap()

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if app.buttons["iosModelDownload_\(modelID)"].exists || app.buttons["iosModelRetry_\(modelID)"].exists {
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }

        XCTFail("[\(label)] delete did not return the model to a downloadable state")
    }

    @discardableResult
    private func waitForInstallCompletion(_ modelID: String, label: String, startTime: Date) -> Bool {
        var relaunchCount = 0

        while Date().timeIntervalSince(startTime) < Self.downloadTimeout {
            if app.state == .notRunning || app.state == .unknown {
                relaunchCount += 1
                if relaunchCount > Self.maxRelaunchAttempts {
                    XCTFail("[\(label)] app crashed \(relaunchCount) times during download")
                    return false
                }
                print("🔄 [\(label)] app exited during download — re-launching (attempt \(relaunchCount)/\(Self.maxRelaunchAttempts))...")
                launchApp()
                guard navigateToSettings() else {
                    XCTFail("[\(label)] could not return to Settings after re-launch")
                    return false
                }
                if isModelInstalled(modelID) {
                    print("✅ [\(label)] installed after re-launch")
                    return true
                }
                let retryButton = app.buttons["iosModelRetry_\(modelID)"]
                if retryButton.waitForExistence(timeout: 5) {
                    print("🔄 [\(label)] retrying after app restart...")
                    retryButton.tap()
                }
                continue
            }

            let deleteButton = app.buttons["iosModelDelete_\(modelID)"]
            if deleteButton.exists {
                let elapsed = Date().timeIntervalSince(startTime)
                print("✅ [\(label)] download and install verified (\(String(format: "%.0f", elapsed))s)")
                return true
            }

            let retryButton = app.buttons["iosModelRetry_\(modelID)"]
            if retryButton.exists {
                relaunchCount += 1
                if relaunchCount > Self.maxRelaunchAttempts {
                    XCTFail("[\(label)] download failed \(relaunchCount) times — giving up")
                    return false
                }
                print("🔄 [\(label)] download failed — retrying (attempt \(relaunchCount)/\(Self.maxRelaunchAttempts))...")
                retryButton.tap()
            }

            Thread.sleep(forTimeInterval: Self.pollInterval)
        }

        XCTFail("[\(label)] download timed out after \(Int(Self.downloadTimeout / 60)) minutes")
        return false
    }
}
