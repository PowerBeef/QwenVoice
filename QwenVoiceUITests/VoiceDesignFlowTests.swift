import XCTest

final class VoiceDesignFlowTests: FeatureMatrixUITestBase {
    override class var additionalLaunchEnvironment: [String: String] {
        ["QWENVOICE_UI_TEST_WINDOW_SIZE": "720x560"]
    }

    func testGenerationComposerBaselineMatchesAcrossModes() {
        fixture.installModel(mode: "custom")
        fixture.installModel(mode: "design")
        fixture.installModel(mode: "clone")

        let customMetrics = captureGenerationLayoutMetrics(
            screen: .customVoice
        )
        let designMetrics = captureGenerationLayoutMetrics(
            screen: .voiceDesign
        )
        let cloneMetrics = captureGenerationLayoutMetrics(
            screen: .voiceCloning
        )

        assertComposerBaseline(
            customMetrics,
            alignedWith: designMetrics,
            label: "Custom Voice vs Voice Design"
        )
        assertComposerBaseline(
            customMetrics,
            alignedWith: cloneMetrics,
            label: "Custom Voice vs Voice Cloning"
        )
    }

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
        let generateButton = waitForElement("textInput_generateButton", type: .button, timeout: 5)
        let batchButton = waitForElement("textInput_batchButton", type: .button, timeout: 5)
        assertElementAboveFold(editor)
        assertElementAboveFold(generateButton)
        assertElementAboveFold(batchButton)
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

    private func captureGenerationLayoutMetrics(
        screen: UITestScreen
    ) -> GenerationLayoutMetrics {
        launchStubApp(initialScreen: screen)
        _ = waitForScreen(screen, timeout: 15)
        _ = waitForBackendIdle(timeout: 10)

        let editor = waitForElement("textInput_textEditor", timeout: 5)
        let generateButton = waitForElement("textInput_generateButton", type: .button, timeout: 5)
        let batchButton = waitForElement("textInput_batchButton", type: .button, timeout: 5)

        assertElementAboveFold(editor)
        assertElementAboveFold(generateButton)
        assertElementAboveFold(batchButton)
        XCTAssertGreaterThan(
            editor.frame.height,
            150,
            "Generation screens should let the script editor grow beyond the compact embedded minimum when space is available"
        )

        return GenerationLayoutMetrics(
            editorMinY: editor.frame.minY,
            editorMaxY: editor.frame.maxY,
            editorHeight: editor.frame.height,
            generateMidY: generateButton.frame.midY,
            batchMidY: batchButton.frame.midY
        )
    }

    private func assertComposerBaseline(
        _ lhs: GenerationLayoutMetrics,
        alignedWith rhs: GenerationLayoutMetrics,
        tolerance: CGFloat = 8,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(
            abs(lhs.editorMinY - rhs.editorMinY),
            tolerance,
            "\(label): The speech input editor should start at a consistent vertical position",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            abs(lhs.editorMaxY - rhs.editorMaxY),
            tolerance,
            "\(label): The speech input bottom edge should align across generation modes",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            abs(lhs.generateMidY - rhs.generateMidY),
            tolerance,
            "\(label): Generate should stay on a consistent action row baseline",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            abs(lhs.batchMidY - rhs.batchMidY),
            tolerance,
            "\(label): Batch should stay on the same row across generation modes",
            file: file,
            line: line
        )
    }
}

private struct GenerationLayoutMetrics {
    let editorMinY: CGFloat
    let editorMaxY: CGFloat
    let editorHeight: CGFloat
    let generateMidY: CGFloat
    let batchMidY: CGFloat
}
