import XCTest

/// Cold-start generation test.
///
/// Unlike the rest of the UI suite, this test intentionally kills any warm app and
/// launches a fresh instance with the engine enabled. It types a short script in the
/// Studio and waits for real audio generation to complete. This is the exception to the
/// "app stays alive" rule, used to prove that a cold launch + model load + generation
/// end-to-end still works on device.
final class VocelloiOSColdGenerationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        // Guarantee a cold start: terminate any app the shared coordinator may be holding.
        VocelloUITestApp.shared.forceTerminate()

        app = XCUIApplication()
        // Do NOT set QVOICE_IOS_DISABLE_ENGINE — we want the real model load + generation.
        // Enable durable telemetry so the engine layer writes diagnostics we can pull.
        app.launchEnvironment["QWENVOICE_DEBUG"] = "1"
        app.launch()
        dismissOnboardingIfPresent()
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    func testColdGenerationCompletes() {
        XCTAssertTrue(
            app.descendants(matching: .any)["rootTab_studio"].waitForExistence(timeout: 10),
            "Studio tab should be visible after cold launch"
        )
        captureScreenshot(named: "cold-launch-studio")

        let installButton = app.descendants(matching: .any)["textInput_installModelButton"]
        XCTAssertFalse(
            installButton.exists,
            "model must already be installed on the device for the cold-generation test"
        )

        // Make sure we are in Custom mode. The app persists the last-used mode, so a
        // previous test may have left it in Design/Clone, where Generate is disabled.
        let customMode = app.descendants(matching: .any)["generateSection_custom"]
        XCTAssertTrue(customMode.waitForExistence(timeout: 10), "Custom mode segment should exist")
        if !customMode.isSelected {
            customMode.tap()
        }

        // The custom text editor is a UIViewRepresentable; relying on a single identifier
        // has proven brittle. Use the only editable text view in the Studio, and fall back
        // to the visible placeholder if the runtime does not expose the view directly.
        let editor: XCUIElement
        let editorByID = app.descendants(matching: .any)["textInput_textEditor"]
        if editorByID.waitForExistence(timeout: 5) {
            editor = editorByID
        } else {
            let firstTextView = app.textViews.firstMatch
            XCTAssertTrue(firstTextView.waitForExistence(timeout: 10), "Studio text view should exist")
            editor = firstTextView
        }

        editor.tap()
        editor.typeText("Hello from Vocello cold start.")
        captureScreenshot(named: "cold-typed")

        // The text editor's Return key is configured as "Done" and dismisses the
        // keyboard instead of inserting a newline. The Generate button sits below
        // the composer in a layout that ignores the keyboard, so we must dismiss
        // the keyboard before tapping it; otherwise the tap lands on a keyboard key.
        editor.typeText("\n")
        XCTAssertTrue(
            app.keyboards.element.waitForNonExistence(timeout: 10),
            "Keyboard should dismiss after pressing Return/Done"
        )
        captureScreenshot(named: "cold-keyboard-dismissed")

        // The primary CTA is shadowed by the screen-level identifier, so match by label.
        let generate = app.buttons.matching(NSPredicate(format: "label == %@", "Generate")).firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 10), "Generate button should exist")
        XCTAssertTrue(generate.isEnabled, "Generate button should be enabled after typing")
        generate.tap()
        captureScreenshot(named: "cold-generate-tapped")

        let completePlayer = app.descendants(matching: .any)["studio_inlinePlayer"]
        let completeByVoiceName = app.staticTexts.matching(NSPredicate(format: "label == %@", "Aiden")).firstMatch
        let completeBySubtitle = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Just now")).firstMatch
        let completeByPlay = app.buttons.matching(NSPredicate(format: "label == %@", "Play")).firstMatch
        let errorByID = app.descendants(matching: .any)["textInput_generationError"]
        let errorByLabel = app.buttons.matching(NSPredicate(format: "label == %@", "Generation failed")).firstMatch

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if completePlayer.exists || completeByVoiceName.exists || completeBySubtitle.exists || completeByPlay.exists {
                captureScreenshot(named: "cold-generation-complete")
                return
            }
            if errorByID.exists || errorByLabel.exists {
                captureScreenshot(named: "cold-generation-error")
                XCTFail("Generation failed during cold start")
                return
            }
            usleep(500_000)
        }
        captureScreenshot(named: "cold-generation-timeout")
        XCTFail("Cold generation did not complete within 120 seconds")
    }

    // MARK: - Helpers

    private func captureScreenshot(named name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Screenshot: \(name)") { activity in
            activity.add(attachment)
        }

        if let dir = ProcessInfo.processInfo.environment["UI_TEST_SCREENSHOT_DIR"] {
            let fileManager = FileManager.default
            try? fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = (dir as NSString).appendingPathComponent("\(name).png")
            do {
                try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: path))
            } catch {
                print("[ColdGenerationUITest] could not write screenshot to \(path): \(error)")
            }
        }
    }

    /// First-run onboarding (3 pages) sits in front of the tabs on a fresh install.
    private func dismissOnboardingIfPresent() {
        let studio = app.descendants(matching: .any)["rootTab_studio"]
        let skip = app.descendants(matching: .any)["onboarding_skip"]
        let cta = app.descendants(matching: .any)["onboarding_cta"]
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
