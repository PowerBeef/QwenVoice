import XCTest

final class ModelsViewTests: QwenVoiceUITestBase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        navigateToSidebar("models")
        let title = app.staticTexts["models_title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        // Give the async refresh time to populate model statuses
        sleep(1)
    }

    // MARK: - Title

    func testTitleExists() {
        assertElementExists("models_title")
    }

    // MARK: - Sections

    // MARK: - Model Cards

    func testAllModelCardsExist() {
        let modelIds = [
            "pro_custom", "pro_design", "pro_clone"
        ]
        for modelId in modelIds {
            let card = app.descendants(matching: .any).matching(identifier: "models_card_\(modelId)").firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 5), "Model card '\(modelId)' should exist")
        }
    }

    // MARK: - Download/Delete Buttons

    func testDownloadOrDeleteButtonsExist() {
        // Each model should have either a download or delete button.
        // Use broad descendant matching since buttons may be nested in cards.
        let modelIds = [
            "pro_custom", "pro_design", "pro_clone"
        ]
        for modelId in modelIds {
            let download = app.descendants(matching: .any).matching(identifier: "models_download_\(modelId)").firstMatch
            let delete = app.descendants(matching: .any).matching(identifier: "models_delete_\(modelId)").firstMatch
            let hasButton = download.waitForExistence(timeout: 3) || delete.exists
            XCTAssertTrue(hasButton, "Model '\(modelId)' should have a download or delete button")
        }
    }
}
