import XCTest

final class SidebarPlayerTests: FeatureMatrixUITestBase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture.installModel(mode: "custom")
    }

    func testLivePlayerAppearsDuringStreamingGeneration() {
        launchStubApp(initialScreen: .customVoice)
        _ = waitForScreen(.customVoice, timeout: 15)
        _ = waitForBackendIdle(timeout: 10)

        let editor = waitForElement("textInput_textEditor", timeout: 5)
        XCTAssertTrue(editor.isEnabled)
        editor.click()
        editor.typeText("Sidebar live stream test.")
        let generate = waitForElementToBecomeEnabled("textInput_generateButton", type: .button, timeout: 5)
        generate.click()

        XCTAssertTrue(waitForElement("sidebarPlayer_bar", timeout: 10).exists)
        XCTAssertTrue(waitForElement("sidebarPlayer_liveBadge", timeout: 10).exists)
        XCTAssertTrue(waitForElement("sidebarPlayer_waveform", timeout: 5).exists)

        let playPause = waitForElement("sidebarPlayer_playPause", timeout: 5)
        playPause.click()
        XCTAssertTrue(playPause.exists)

        waitForElement("sidebarPlayer_dismiss", type: .button, timeout: 5).click()
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "sidebarPlayer_bar").firstMatch.exists)
    }

    func testPlayerTransitionsToFinalFileWhenAutoplayIsOff() {
        fixture.defaults { $0.set(false, forKey: "autoPlay") }
        launchStubApp(initialScreen: .customVoice)
        _ = waitForScreen(.customVoice, timeout: 15)
        _ = waitForBackendIdle(timeout: 10)

        let editor = waitForElement("textInput_textEditor", timeout: 5)
        XCTAssertTrue(editor.isEnabled)
        editor.click()
        editor.typeText("Sidebar final playback test.")
        let generate = waitForElementToBecomeEnabled("textInput_generateButton", type: .button, timeout: 5)
        generate.click()

        _ = waitForElement("sidebarPlayer_bar", timeout: 10)
        XCTAssertTrue(waitForElement("sidebarPlayer_waveform", timeout: 5).exists)
        let deadline = Date().addingTimeInterval(10)
        var timeLabel = waitForElement("sidebarPlayer_time", timeout: 5).label
        while Date() < deadline && timeLabel.contains("Live") {
            usleep(200_000)
            timeLabel = app.descendants(matching: .any).matching(identifier: "sidebarPlayer_time").firstMatch.label
        }

        XCTAssertFalse(timeLabel.contains("Live"))
    }
}
