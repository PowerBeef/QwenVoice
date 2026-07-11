@preconcurrency import XCTest

@MainActor
final class VocelloMacSmokeUITests: VocelloMacUITestCase {
    func testSmokeJourney() {
        beginSession()
        defer { endSession() }

        for screen in VocelloMacScreen.allCases {
            navigate(to: screen)
        }

        assertVisibleSpeedModelReadiness()
        assertSavedCloneVoice()

        prepare(mode: .custom)
        replaceScript(with: "Automated Custom Voice smoke generation.")
        generateAndWaitForCompletion(mode: .custom, timeout: 240)
        VocelloUIScreenshot.attach(app, named: "mac-smoke-custom-complete")

        navigate(to: .history)
        XCTAssertTrue(VocelloUIWait.exists(element("history_searchField"), timeout: 20))
        XCTAssertTrue(VocelloUIWait.exists(element("history_sortPicker"), timeout: 20))
        VocelloUIScreenshot.attach(app, named: "mac-smoke-history")
    }
}
