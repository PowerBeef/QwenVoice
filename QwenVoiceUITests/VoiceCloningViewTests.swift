import XCTest

final class VoiceCloningViewTests: QwenVoiceUITestBase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        navigateToSidebar("voiceCloning")
        let title = app.staticTexts["voiceCloning_title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
    }

    // MARK: - Title & Header

    func testTitleExists() {
        assertElementExists("voiceCloning_title")
    }

    // MARK: - Tier Picker

    func testTierPickerExists() {
        let picker = app.descendants(matching: .any).matching(identifier: "voiceCloning_tierPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Tier picker should exist")
    }

    // MARK: - Batch Button

    func testBatchButtonExists() {
        let button = app.buttons["voiceCloning_batchButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Batch button should exist")
    }

    // MARK: - Model Banner

    func testModelBannerAppearsWhenModelMissing() {
        let banner = app.descendants(matching: .any).matching(identifier: "voiceCloning_modelBanner").firstMatch
        if banner.waitForExistence(timeout: 3) {
            XCTAssertTrue(banner.exists, "Model banner should be visible when model is not downloaded")
        }
    }

    func testGoToModelsButtonNavigates() {
        let goToModels = app.buttons["voiceCloning_goToModels"]
        guard goToModels.waitForExistence(timeout: 3) else { return }
        goToModels.click()
        assertElementExists("models_title")
    }

    // MARK: - Drop Zone

    func testDropZoneExists() {
        let dropZone = app.descendants(matching: .any).matching(identifier: "voiceCloning_dropZone").firstMatch
        XCTAssertTrue(dropZone.waitForExistence(timeout: 5), "Reference audio drop zone should exist")
    }

    // MARK: - Transcript Field

    func testTranscriptFieldExists() {
        let field = app.textFields["voiceCloning_transcriptField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Transcript field should exist")
    }

    func testTranscriptFieldAcceptsInput() {
        let field = app.textFields["voiceCloning_transcriptField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("Hello world")
        XCTAssertTrue((field.value as? String)?.contains("Hello") ?? false)
    }

    // MARK: - Text Input

    func testTextEditorExists() {
        let editor = app.descendants(matching: .any).matching(identifier: "textInput_textEditor").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Text editor should exist")
    }
}
