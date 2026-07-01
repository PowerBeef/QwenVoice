import XCTest

/// Shared app coordinator for warm `VocelloiOSUITests` classes (Smoke, Sheet, ReviewTour).
///
/// Launches the real in-process MLX engine on a paired iPhone. Cold-generation and
/// on-device download suites self-launch their own `XCUIApplication` when they need a
/// fresh instance or a download-specific setup.
final class VocelloUITestApp: @unchecked Sendable {
    static let shared = VocelloUITestApp()
    private init() {}

    private let lock = NSRecursiveLock()
    private var retainCount = 0
    private(set) var app: XCUIApplication!

    // MARK: - Lifecycle

    /// Called from warm test class `setUp` and by the observer as a fallback.
    func retainIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        if app != nil {
            ensureForeground()
            return
        }
        retainCount = max(retainCount, 1)
        launch()
    }

    /// Called by `VocelloUITestObserver` when the warm test bundle finishes.
    func release() {
        lock.lock()
        defer { lock.unlock() }
        retainCount -= 1
        if retainCount == 0 {
            terminate()
        }
    }

    /// Kill the shared app immediately and reset the coordinator. Used by the cold-
    /// generation test so it can launch a truly fresh instance.
    func forceTerminate() {
        lock.lock()
        defer { lock.unlock() }
        terminate()
        retainCount = 0
    }

    /// Per-test reset: make sure we are back on the Studio surface with no sheet open.
    /// This lets each test start from a clean, deterministic place without closing the app.
    func resetToStudio() {
        retainIfNeeded()
        ensureForeground()

        let studioTab = button("rootTab_studio")
        if studioTab.exists && !studioTab.isSelected {
            studioTab.tap()
        }

        // Dismiss any stuck sheet from a previous test/failure.
        // Voice, language, delivery, and voice-brief pickers use a Confirm header; other sheets have the X close button.
        let confirmIDs = ["voicePicker_confirm", "languagePicker_confirm", "deliveryPicker_confirm", "voiceBrief_confirm"]
        for id in confirmIDs {
            let confirm = element(id)
            if confirm.exists {
                confirm.tap()
                _ = confirm.waitForNonExistence(timeout: 5)
                break
            }
        }
        let close = element("bottomSheet_close")
        if close.exists {
            close.tap()
            _ = close.waitForNonExistence(timeout: 5)
        }

        XCTAssertTrue(
            waitFor("generateSection_custom", timeout: 10),
            "Studio surface should be reachable after reset"
        )
    }

    // MARK: - Element helpers

    func element(_ identifier: String) -> XCUIElement {
        retainIfNeeded()
        return app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Tab-bar buttons and other plain buttons are much cheaper to query than
    /// `descendants(matching: .any)` on the full hierarchy.
    func button(_ identifier: String) -> XCUIElement {
        retainIfNeeded()
        return app.buttons[identifier].firstMatch
    }

    func firstElement(prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .firstMatch
    }

    /// First element whose identifier begins with `prefix` but is not `excludingIdentifier`.
    /// Used when the first match is already selected and we need a different option.
    func firstElement(prefix: String, excludingIdentifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier != %@",
                prefix,
                excludingIdentifier
            ))
            .firstMatch
    }

    func button(labelPrefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix)).firstMatch
    }

    @discardableResult
    func waitFor(_ identifier: String, timeout: TimeInterval = 30) -> Bool {
        element(identifier).waitForExistence(timeout: timeout)
    }

    /// Waits for a confirmation-dialog button. `waitForExistence` already polls internally,
    /// so a single bounded wait covers the one-beat SwiftUI attach lag without a sleep loop.
    @discardableResult
    func waitForConfirmationButton(_ identifier: String, timeout: TimeInterval = 10) -> Bool {
        element(identifier).waitForExistence(timeout: timeout)
    }

    /// Dismiss first-run onboarding when present. Shared by warm and cold test paths.
    func dismissOnboardingIfPresent(timeout: TimeInterval = 25) {
        guard let app else { return }
        Self.dismissOnboardingIfPresent(in: app, timeout: timeout)
    }

    static func dismissOnboardingIfPresent(in app: XCUIApplication, timeout: TimeInterval = 25) {
        let studio = app.buttons["rootTab_studio"].firstMatch
        let skip = app.buttons["onboarding_skip"].firstMatch
        let cta = app.buttons["onboarding_cta"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        var ctaTaps = 0
        while Date() < deadline {
            if studio.exists { return }
            if skip.exists {
                skip.tap()
                _ = studio.waitForExistence(timeout: 6)
                return
            }
            if cta.exists {
                cta.tap()
                ctaTaps += 1
                if ctaTaps > 5 { return }
                usleep(400_000)
                continue
            }
            usleep(300_000)
        }
    }

    // MARK: - Screenshot diagnostics

    /// Captures the current app frame and attaches it to the test result.
    /// If `UI_TEST_SCREENSHOT_DIR` is set, also writes a PNG to disk for quick review.
    func captureScreenshot(named name: String) {
        let screenshot = app.screenshot()

        // Attach to the XCTest result bundle.
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Screenshot: \(name)") { activity in
            activity.add(attachment)
        }

        // Optional on-disk copy for device-side debugging.
        if let dir = ProcessInfo.processInfo.environment["UI_TEST_SCREENSHOT_DIR"] {
            let fileManager = FileManager.default
            try? fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = (dir as NSString).appendingPathComponent("\(name).png")
            do {
                try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: path))
            } catch {
                print("[VocelloUITestApp] could not write screenshot to \(path): \(error)")
            }
        }
    }

    // MARK: - Private

    private func launch() {
        app = XCUIApplication()
        // Skip first-run onboarding so warm tests start on the Studio surface deterministically.
        app.launchEnvironment["QVOICE_IOS_SKIP_ONBOARDING"] = "1"

        app.launch()
        dismissOnboardingIfPresent()

        // Do not assert the Studio surface here. The tab bar (rootTab_studio) is
        // the earliest stable signal that the app has finished launching; each
        // warm test calls resetToStudio(), which asserts the full Studio surface
        // before proceeding.
    }

    private func terminate() {
        guard let app = app else { return }
        if app.state == .runningForeground || app.state == .runningBackground {
            app.terminate()
        }
        self.app = nil
    }

    private func ensureForeground() {
        guard let app = app else { return }
        if app.state != .runningForeground {
            app.activate()
        }
    }
}

extension XCTestCase {
    /// Registers a best-effort monitor that auto-dismisses unexpected system alerts
    /// (permission prompts, automation/pairing dialogs) so a warm UI run doesn't stall on
    /// them. XCUITest invokes registered monitors when an interaction is interrupted, so the
    /// taps that `resetToStudio()` / each test perform give the monitor a chance to fire.
    /// The monitor is automatically removed when the test case finishes.
    @discardableResult
    func installSystemAlertMonitor() -> NSObjectProtocol {
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            let labels = ["Allow While Using App", "Allow Once", "Allow", "OK", "Continue"]
            for label in labels {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
    }
}
