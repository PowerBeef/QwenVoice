import Foundation
import XCTest

final class VoiceCloningViewTests: QwenVoiceUITestBase {
    private let importAudioPathEnvironmentKey = "QWENVOICE_UI_TEST_IMPORT_AUDIO_PATH"

    override var initialScreen: String? { "voiceCloning" }
    override nonisolated func additionalLaunchEnvironment(fixtureRoot: String?) -> [String: String] {
        guard let fixtureRoot else { return [:] }
        let fixtureDirectory = (fixtureRoot as NSString).appendingPathComponent("fixtures")
        let audioPath = (fixtureDirectory as NSString).appendingPathComponent("import-reference.wav")
        return [importAudioPathEnvironmentKey: audioPath]
    }

    override nonisolated func prepareFixtureRoot(_ root: String) {
        let fixtureDirectory = (root as NSString).appendingPathComponent("fixtures")
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: fixtureDirectory, isDirectory: true),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let audioPath = (fixtureDirectory as NSString).appendingPathComponent("import-reference.wav")
        StubFixtureSupport.createMinimalWAV(at: audioPath)
    }

    func testCoreLayoutElements() {
        waitForScreen("screen_voiceCloning")
        assertElementExists("textInput_textEditor")
        assertElementExists("textInput_generateButton")
    }

    func testImportButtonExists() {
        waitForScreen("screen_voiceCloning")
        assertElementExists("voiceCloning_importButton")
    }

    func testDraftsPersistAcrossSidebarSwitches() {
        let transcript = "Reference transcript"

        waitForScreen("screen_voiceCloning")
        clickElement("voiceCloning_importButton")
        assertElementExists("voiceCloning_activeReference")
        typeInTextField("voiceCloning_transcriptInput", text: transcript)

        clickElement("sidebar_models")
        assertElementExists("models_title")

        clickElement("sidebar_voiceCloning")
        assertElementExists("voiceCloning_importButton")

        assertElementExists("voiceCloning_activeReference")
        assertStringValue(transcript, for: "voiceCloning_transcriptInput")
    }

    func testScreenshotCapture() {
        waitForScreen("screen_voiceCloning")
        captureScreenshot(name: "screenshot_voiceCloning_default")
    }
}
