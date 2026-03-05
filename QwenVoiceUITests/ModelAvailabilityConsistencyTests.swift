import XCTest

final class ModelAvailabilityConsistencyTests: QwenVoiceUITestBase {
    override class var additionalLaunchEnvironment: [String: String] {
        guard let fixtureRoot else { return [:] }
        return ["QWENVOICE_APP_SUPPORT_DIR": fixtureRoot.path]
    }

    private static var fixtureRoot: URL?

    private static let defaultAppSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("QwenVoice", isDirectory: true)

    private static let requiredRelativePaths = [
        "README.md",
        "config.json",
        "generation_config.json",
        "merges.txt",
        "model.safetensors",
        "model.safetensors.index.json",
        "preprocessor_config.json",
        "speech_tokenizer/config.json",
        "speech_tokenizer/configuration.json",
        "speech_tokenizer/model.safetensors",
        "speech_tokenizer/preprocessor_config.json",
        "tokenizer_config.json",
        "vocab.json",
    ]

    override class func setUp() {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("QwenVoiceModelFixtures-\(UUID().uuidString)", isDirectory: true)
        seedFixtureModels()
        super.setUp()
    }

    override class func tearDown() {
        super.tearDown()
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        fixtureRoot = nil
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        waitForMainUI()
    }

    func testCustomVoiceUsesModeSpecificAvailability() {
        _ = waitForScreen(.customVoice, timeout: 10)

        let initialBanner = app.descendants(matching: .any).matching(identifier: "customVoice_modelBanner").firstMatch
        XCTAssertFalse(
            initialBanner.waitForExistence(timeout: 1),
            "Preset speaker mode should use the complete Custom Voice model fixture"
        )

        let customSpeaker = waitForElement("customVoice_speaker_custom", timeout: 10)
        customSpeaker.click()

        let banner = waitForElement("customVoice_modelBanner", timeout: 5)
        XCTAssertTrue(banner.exists, "Custom speaker mode should switch to the incomplete Voice Design model fixture")

        let voiceField = waitForElement("customVoice_voiceDescriptionField", type: .textField)
        voiceField.click()
        voiceField.typeText("A warm narrator voice")

        let batchButton = waitForElement("customVoice_batchButton", type: .button)
        XCTAssertFalse(batchButton.isEnabled, "Batch generation should stay disabled when the active model is incomplete")
    }

    func testVoiceCloningShowsBannerForIncompleteFixture() {
        ensureOnScreen(.voiceCloning)

        let banner = waitForElement("voiceCloning_modelBanner", timeout: 5)
        XCTAssertTrue(banner.exists, "Voice Cloning should surface the incomplete clone model fixture as unavailable")
    }

    func testModelsViewDistinguishesCompleteAndIncompleteFixtures() {
        ensureOnScreen(.models, timeout: 10)

        XCTAssertTrue(
            waitForElement("models_delete_pro_custom", type: .button, timeout: 10).exists,
            "Complete fixtures should resolve to the ready/delete state"
        )
        XCTAssertTrue(
            waitForElement("models_download_pro_design", type: .button, timeout: 10).exists,
            "Incomplete fixtures should resolve to the download state"
        )
        XCTAssertTrue(
            waitForElement("models_download_pro_clone", type: .button, timeout: 10).exists,
            "Incomplete clone fixtures should resolve to the download state"
        )
    }

    private class func seedFixtureModels() {
        guard let fixtureRoot else { return }

        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: fixtureRoot.appendingPathComponent("models", isDirectory: true), withIntermediateDirectories: true)
        linkExistingPythonEnvironmentIfPresent()

        seedModel(
            folder: "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
            relativePaths: requiredRelativePaths
        )
        seedModel(
            folder: "Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit",
            relativePaths: Array(requiredRelativePaths.prefix(1))
        )
        seedModel(
            folder: "Qwen3-TTS-12Hz-1.7B-Base-8bit",
            relativePaths: Array(requiredRelativePaths.prefix(1))
        )
    }

    private class func linkExistingPythonEnvironmentIfPresent() {
        guard let fixtureRoot else { return }

        let pythonSource = defaultAppSupportDir.appendingPathComponent("python", isDirectory: true)
        guard FileManager.default.fileExists(atPath: pythonSource.path) else { return }

        let pythonDestination = fixtureRoot.appendingPathComponent("python", isDirectory: true)
        try? FileManager.default.createSymbolicLink(at: pythonDestination, withDestinationURL: pythonSource)
    }

    private class func seedModel(folder: String, relativePaths: [String]) {
        guard let fixtureRoot else { return }

        let modelRoot = fixtureRoot
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)

        for relativePath in relativePaths {
            let fileURL = modelRoot.appendingPathComponent(relativePath)
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        }
    }

    private func waitForMainUI(timeout: TimeInterval = 90) {
        let sidebarRoot = app.descendants(matching: .any)
            .matching(identifier: UITestScreen.customVoice.sidebarIdentifier)
            .firstMatch
        let setupErrorTitle = app.descendants(matching: .any)
            .matching(identifier: "setup_errorTitle")
            .firstMatch
        let setupErrorMessage = app.descendants(matching: .any)
            .matching(identifier: "setup_errorMessage")
            .firstMatch

        let knownSetupStates = [
            "setup_checkingLabel",
            "setup_findingPythonLabel",
            "setup_creatingVenvLabel",
            "setup_progressLabel",
            "setup_updatingDepsLabel",
            "setup_startingLabel",
        ]

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sidebarRoot.exists {
                return
            }

            if setupErrorTitle.exists {
                let message = setupErrorMessage.exists ? setupErrorMessage.label : "Unknown setup error"
                XCTFail("App failed during setup under the fixture app-support override: \(message)")
                return
            }

            usleep(500_000)
        }

        let activeSetupState = knownSetupStates.first(where: {
            app.descendants(matching: .any).matching(identifier: $0).firstMatch.exists
        }) ?? "unknown"

        XCTFail(
            "Main UI shell did not replace setup within \(Int(timeout))s under the fixture app-support override. Last visible setup state: \(activeSetupState)."
        )
    }
}
