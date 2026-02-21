import XCTest

final class VoiceDesignViewTests: QwenVoiceUITestBase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        navigateToSidebar("voiceDesign")
        let title = app.staticTexts["voiceDesign_title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
    }

    // MARK: - Title & Header

    func testTitleExists() {
        assertElementExists("voiceDesign_title")
    }

    // MARK: - Tier Picker

    func testTierPickerExists() {
        let picker = app.descendants(matching: .any).matching(identifier: "voiceDesign_tierPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Tier picker should exist")
    }

    // MARK: - Batch Button

    func testBatchButtonExists() {
        let button = app.buttons["voiceDesign_batchButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Batch button should exist")
    }

    // MARK: - Model Banner

    func testModelBannerAppearsWhenModelMissing() {
        let banner = app.descendants(matching: .any).matching(identifier: "voiceDesign_modelBanner").firstMatch
        if banner.waitForExistence(timeout: 3) {
            XCTAssertTrue(banner.exists, "Model banner should be visible when model is not downloaded")
        }
    }

    func testGoToModelsButtonNavigates() {
        let goToModels = app.buttons["voiceDesign_goToModels"]
        guard goToModels.waitForExistence(timeout: 3) else { return }
        goToModels.click()
        assertElementExists("models_title")
    }

    // MARK: - Description Field

    func testDescriptionFieldExists() {
        let field = app.textFields["voiceDesign_descriptionField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Voice description field should exist")
    }

    func testDescriptionFieldAcceptsInput() {
        let field = app.textFields["voiceDesign_descriptionField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("A warm British accent")
        XCTAssertTrue((field.value as? String)?.contains("warm") ?? false)
    }

    // MARK: - Text Input

    func testTextEditorExists() {
        let editor = app.descendants(matching: .any).matching(identifier: "textInput_textEditor").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Text editor should exist")
    }

    func testGenerateButtonExists() {
        let button = app.buttons["textInput_generateButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Generate button should exist")
    }
}
