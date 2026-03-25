import XCTest

final class SidebarNavigationTests: QwenVoiceUITestBase {
    private let screens: [(sidebarID: String, screenID: String)] = [
        ("sidebar_customVoice", "screen_customVoice"),
        ("sidebar_voiceDesign", "screen_voiceDesign"),
        ("sidebar_voiceCloning", "screen_voiceCloning"),
        ("sidebar_history", "screen_history"),
        ("sidebar_voices", "screen_voices"),
        ("sidebar_models", "screen_models"),
    ]

    func testSidebarNavigationAcrossAllScreens() {
        for (sidebarID, screenID) in screens {
            navigateTo(sidebarID, expectScreen: screenID)
        }
    }

    func testDefaultScreenIsCustomVoice() {
        waitForScreen("screen_customVoice")
    }

    func testSidebarItemsExist() {
        for (sidebarID, _) in screens {
            let element = app.descendants(matching: .any)[sidebarID]
            XCTAssertTrue(element.waitForExistence(timeout: 3), "Sidebar item \(sidebarID) should exist")
        }
    }

    func testRoundTripNavigation() {
        // Navigate away and back
        navigateTo("sidebar_history", expectScreen: "screen_history")
        navigateTo("sidebar_customVoice", expectScreen: "screen_customVoice")
    }

    func testRepeatedSidebarNavigationTracksActiveScreen() {
        let navigationLoop: [(sidebarID: String, elementID: String)] = [
            ("sidebar_voiceDesign", "voiceDesign_voiceDescriptionField"),
            ("sidebar_models", "models_title"),
            ("sidebar_voiceCloning", "voiceCloning_importButton"),
            ("sidebar_customVoice", "customVoice_speakerPicker"),
        ]

        for _ in 0..<2 {
            for (sidebarID, elementID) in navigationLoop {
                clickElement(sidebarID)
                assertElementExists(elementID)
            }
        }
    }
}
