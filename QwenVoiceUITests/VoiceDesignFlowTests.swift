import XCTest

final class VoiceDesignFlowTests: FeatureMatrixUITestBase {
    func testVoiceDesignGenerationCreatesHistoryEntry() throws {
        fixture.installModel(mode: "custom")
        fixture.installModel(mode: "design")

        launchStubApp(initialScreen: .voiceDesign)
        _ = waitForScreen(.voiceDesign, timeout: 15)
        _ = waitForBackendIdle(timeout: 10)
        app.activate()

        let voiceDescription = waitForElement("voiceDesign_voiceDescriptionField", timeout: 5)
        voiceDescription.click()
        app.activate()
        voiceDescription.typeText("Warm narrator.")

        let editor = waitForElement("textInput_textEditor", timeout: 5)
        XCTAssertTrue(editor.isHittable, "Voice Design should surface the composer above the fold")
        app.activate()
        editor.click()
        editor.typeText("Voice design test generation.")

        let generate = waitForElementToBecomeEnabled("textInput_generateButton", type: .button, timeout: 5)
        generate.click()
        XCTAssertTrue(waitForElement("sidebarPlayer_bar", timeout: 10).exists)

        ensureOnScreen(.history, timeout: 10)
        XCTAssertTrue(
            app.staticTexts["Voice design test generation."].firstMatch.waitForExistence(timeout: 10)
                || app.staticTexts["Voice design test generation..."].firstMatch.waitForExistence(timeout: 10)
        )
    }

    func testVoiceDesignBriefResetsOnFreshLaunch() {
        fixture.installModel(mode: "custom")
        fixture.installModel(mode: "design")

        launchStubApp(initialScreen: .voiceDesign)
        _ = waitForScreen(.voiceDesign, timeout: 15)

        let voiceDescription = waitForElement("voiceDesign_voiceDescriptionField", timeout: 5)
        voiceDescription.click()
        app.activate()
        voiceDescription.typeText("Session scoped draft")

        ensureOnScreen(.customVoice, timeout: 10)
        _ = waitForScreen(.customVoice, timeout: 5)
        ensureOnScreen(.voiceDesign, timeout: 10)
        _ = waitForScreen(.voiceDesign, timeout: 5)

        let persistedBrief = waitForElement("voiceDesign_voiceDescriptionValue", timeout: 5)
        let persistedText = [persistedBrief.label, persistedBrief.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTAssertTrue(
            persistedText.contains("Session scoped draft"),
            "Voice Design brief should persist while the main-window screen cache stays alive"
        )

        relaunchFreshApp(
            initialScreen: .voiceDesign,
            additionalEnvironment: fixture.environment(setupScenario: .success)
        )
        _ = waitForScreen(.voiceDesign, timeout: 15)

        let relaunchedField = waitForElement("voiceDesign_voiceDescriptionField", timeout: 5)
        let relaunchedValue = [relaunchedField.value as? String, relaunchedField.label]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTAssertFalse(
            relaunchedValue.contains("Session scoped draft"),
            "Voice Design brief should reset on a fresh app launch"
        )
    }
}
