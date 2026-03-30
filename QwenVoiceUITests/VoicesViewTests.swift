import XCTest

final class VoicesViewTests: QwenVoiceUITestBase {
    override var initialScreen: String? { "voices" }

    func testVoicesScreenLoads() {
        waitForScreen("screen_voices")
    }

    func testScreenshotCapture() {
        waitForScreen("screen_voices")
        captureScreenshot(name: "screenshot_voices_empty")
    }
}

final class SavedVoiceToCloneHandoffTests: QwenVoiceUITestBase {
    override var initialScreen: String? { "voices" }
    override var uiTestBackendMode: UITestLaunchBackendMode { .stub }

    override nonisolated func prepareFixtureRoot(_ root: String) {
        mirrorInstalledModels(in: root)

        let voicesDirectory = (root as NSString).appendingPathComponent("voices")
        let audioPath = (voicesDirectory as NSString).appendingPathComponent("DesignedVoice.wav")
        let transcriptPath = (voicesDirectory as NSString).appendingPathComponent("DesignedVoice.txt")

        StubFixtureSupport.createMinimalWAV(at: audioPath)
        try? "Designed voice transcript".write(
            toFile: transcriptPath,
            atomically: true,
            encoding: .utf8
        )
    }

    func testOpenInCloningHydratesSavedVoiceTranscriptImmediately() {
        waitForScreen("screen_voices")
        assertElementEnabled("voicesRow_use_DesignedVoice", timeout: 5)

        clickElement("voicesRow_use_DesignedVoice")

        waitForActiveScreen("screen_voiceCloning")
        assertElementExists("voiceCloning_activeReference")
        assertStringValue("Designed voice transcript", for: "voiceCloning_transcriptInput")
    }
}
