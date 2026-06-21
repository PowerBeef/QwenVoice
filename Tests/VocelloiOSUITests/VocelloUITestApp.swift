import XCTest

/// Shared app coordinator for the whole `VocelloiOSUITests` target.
///
/// XCUITest's default pattern launches the app inside every test's `setUp()` and
/// terminates it in `tearDown()`. For Vocello that meant the app closed and reopened
/// between every single UI assertion, which is nothing like a real user session. This
/// singleton keeps the app alive across test cases; only a fresh `xcodebuild test` run
/// (new build / new process) or an explicit cold-generation test triggers a new launch.
final class VocelloUITestApp: @unchecked Sendable {
    static let shared = VocelloUITestApp()
    private init() {}

    private let lock = NSLock()
    private var retainCount = 0
    private(set) var app: XCUIApplication!

    // MARK: - Lifecycle

    /// Call from `override class func setUp()` in every UI test class that shares the
    /// warm app session. The first call launches the app; subsequent calls just ensure
    /// it is still in the foreground.
    func retain() {
        lock.lock()
        defer { lock.unlock() }
        retainCount += 1
        if retainCount == 1 {
            launch()
        } else {
            ensureForeground()
        }
    }

    /// Call from `override class func tearDown()` in every UI test class that called
    /// `retain()`. The last matching release terminates the app.
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
        ensureForeground()

        let studioTab = element("rootTab_studio")
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
        app.descendants(matching: .any)[identifier].firstMatch
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
        // UI-only smoke/sheet tests do not need the heavy model load.
        app.launchEnvironment["QVOICE_IOS_DISABLE_ENGINE"] = "1"
        // On the simulator these seed the fake engine so the Studio is populated.
        // On a real device they are ignored.
        app.launchEnvironment["QVOICE_SIM_FAKE_MODELS"] = "all"
        app.launchEnvironment["QVOICE_SIM_SEED_DATA"] = "voices,history"

        app.launch()
        dismissOnboardingIfPresent()

        XCTAssertTrue(
            waitFor("rootTab_studio", timeout: 30),
            "Studio tab should appear after launch"
        )
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

    /// First-run onboarding (3 pages) sits in front of the tabs on a fresh install.
    /// Poll for either the main UI or onboarding; Skip completes the whole flow, the CTA
    /// advances/completes as a fallback.
    private func dismissOnboardingIfPresent() {
        let studio = element("rootTab_studio")
        let skip = element("onboarding_skip")
        let cta = element("onboarding_cta")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if studio.exists { return }
            if skip.exists {
                skip.tap()
                _ = studio.waitForExistence(timeout: 6)
                return
            }
            if cta.exists { cta.tap() }
            usleep(300_000)
        }
    }
}
