import XCTest

/// One explicit physical-device journey. It exercises visible production UI
/// in a single app session and performs exactly one Custom generation.
@MainActor
final class VocelloiOSSmokeUITests: VocelloiOSUITestCase {
    func testPhysicalDeviceSmokeJourney() {
        beginSession()
        defer { endSession() }

        XCTAssertTrue(VocelloUIWait.exists(element("generateSection_custom"), timeout: 20))
        XCTAssertTrue(VocelloUIWait.exists(element("textInput_textEditor"), timeout: 20))

        for mode in VocelloUIBenchMatrix.Mode.allCases {
            select(mode: mode)
        }

        for tab in VocelloiOSTab.allCases {
            select(tab: tab)
        }

        assertVisibleModelReadiness()
        VocelloUIScreenshot.attach(app, named: "ios-smoke-models-ready")

        _ = assertRequiredCloneVoice()
        VocelloUIScreenshot.attach(app, named: "ios-smoke-clone-voice-ready")

        prepare(mode: .custom)
        replaceScript(with: "The train left the station at dawn.")
        generateAndWaitForCompletedPlayer(timeout: 240)
        VocelloUIScreenshot.attach(app, named: "ios-smoke-custom-complete")

        select(tab: .history)
        XCTAssertTrue(VocelloUIWait.exists(element("historySearchField"), timeout: 30))
        let generatedHistoryRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "historyRow_"))
            .firstMatch
        XCTAssertTrue(
            VocelloUIWait.exists(generatedHistoryRow, timeout: 30),
            "The completed Custom take must be visible in History"
        )
        VocelloUIScreenshot.attach(app, named: "ios-smoke-history")
    }
}
