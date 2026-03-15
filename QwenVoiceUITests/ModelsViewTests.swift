import XCTest

final class ModelsViewTests: QwenVoiceUITestBase {
    override class var initialScreen: UITestScreen? { .models }

    func testModelsScreenAvailability() {
        _ = waitForScreen(.models)

        let firstModelID = UITestContractManifest.current.models.first?.id ?? "pro_custom"
        let firstCard = app.descendants(matching: .any).matching(identifier: "models_card_\(firstModelID)").firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 10), "Model cards should load after refresh")
    }

    func testModelCardsAndActionsArePresent() {
        _ = waitForScreen(.models)

        for model in UITestContractManifest.current.models {
            let modelId = model.id
            let card = waitForElement("models_card_\(modelId)", timeout: 10)
            let cardSummary = [card.label, card.value as? String]
                .compactMap { $0 }
                .joined(separator: " ")
            XCTAssertTrue(
                cardSummary.contains(model.name) || card.staticTexts[model.name].exists,
                "Model '\(modelId)' should show its contract name"
            )
            let checking = app.descendants(matching: .any).matching(identifier: "models_checking_\(modelId)").firstMatch
            let download = app.descendants(matching: .any).matching(identifier: "models_download_\(modelId)").firstMatch
            let delete = app.descendants(matching: .any).matching(identifier: "models_delete_\(modelId)").firstMatch
            let retry = app.descendants(matching: .any).matching(identifier: "models_retry_\(modelId)").firstMatch
            let hasVisibleState = checking.exists || download.exists || delete.exists || retry.exists
            let hasAction = card.descendants(matching: .button).firstMatch.exists
            XCTAssertTrue(hasVisibleState || hasAction, "Model '\(modelId)' should expose a visible state or action")
        }
    }
}
