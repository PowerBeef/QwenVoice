import XCTest

final class ModelsViewTests: QwenVoiceUITestBase {
    override class var initialScreen: UITestScreen? { .models }

    func testModelsScreenAvailability() {
        _ = waitForScreen(.models)
        assertElementExists("models_title")

        let firstCard = app.descendants(matching: .any).matching(identifier: "models_card_pro_custom").firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 10), "Model cards should load after refresh")
    }

    func testModelCardsAndActionsArePresent() {
        _ = waitForScreen(.models)

        let modelIds = ["pro_custom", "pro_design", "pro_clone"]
        for modelId in modelIds {
            let card = waitForElement("models_card_\(modelId)", timeout: 10)
            let download = app.descendants(matching: .any).matching(identifier: "models_download_\(modelId)").firstMatch
            let delete = app.descendants(matching: .any).matching(identifier: "models_delete_\(modelId)").firstMatch
            let retry = app.descendants(matching: .any).matching(identifier: "models_retry_\(modelId)").firstMatch
            let hasAction = download.exists || delete.exists || retry.exists || card.descendants(matching: .button).firstMatch.exists
            XCTAssertTrue(hasAction, "Model '\(modelId)' should expose at least one action")
        }
    }
}
