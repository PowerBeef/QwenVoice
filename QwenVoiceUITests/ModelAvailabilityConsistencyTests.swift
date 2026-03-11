import XCTest

final class ModelAvailabilityConsistencyTests: QwenVoiceUITestBase {
    override class var additionalLaunchEnvironment: [String: String] {
        guard let fixtureRoot else { return [:] }
        return ["QWENVOICE_APP_SUPPORT_DIR": fixtureRoot.path]
    }

    private static var fixtureRoot: URL?

    private static let defaultAppSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("QwenVoice", isDirectory: true)

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

        let designMode = waitForElement("customVoice_mode_design", timeout: 10)
        designMode.click()

        let banner = waitForElement("customVoice_modelBanner", timeout: 5)
        XCTAssertTrue(banner.exists, "Custom speaker mode should switch to the incomplete Voice Design model fixture")

        let voiceField = waitForElement("customVoice_voiceDescriptionField", type: .textField)
        voiceField.click()
        voiceField.typeText("A warm narrator voice")

        let batchButton = waitForElement("textInput_batchButton", type: .button)
        XCTAssertFalse(batchButton.isEnabled, "Batch generation should stay disabled when the active model is incomplete")
    }

    func testVoiceCloningShowsBannerForIncompleteFixture() {
        ensureOnScreen(.voiceCloning)

        let banner = waitForElement("voiceCloning_modelBanner", timeout: 5)
        XCTAssertTrue(banner.exists, "Voice Cloning should surface the incomplete clone model fixture as unavailable")
    }

    func testModelsViewDistinguishesCompleteAndIncompleteFixtures() {
        ensureOnScreen(.models, timeout: 10)

        let customModelID = UITestContractManifest.current.model(mode: "custom")?.id ?? "pro_custom"
        let designModelID = UITestContractManifest.current.model(mode: "design")?.id ?? "pro_design"
        let cloneModelID = UITestContractManifest.current.model(mode: "clone")?.id ?? "pro_clone"

        XCTAssertTrue(
            waitForElement("models_delete_\(customModelID)", type: .button, timeout: 10).exists,
            "Complete fixtures should resolve to the ready/delete state"
        )
        XCTAssertTrue(
            waitForElement("models_download_\(designModelID)", type: .button, timeout: 10).exists,
            "Incomplete fixtures should resolve to the download state"
        )
        XCTAssertTrue(
            waitForElement("models_download_\(cloneModelID)", type: .button, timeout: 10).exists,
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
            mode: "custom",
            relativePaths: contractModel(mode: "custom")?.requiredRelativePaths ?? []
        )
        seedModel(
            mode: "design",
            relativePaths: Array((contractModel(mode: "design")?.requiredRelativePaths ?? []).prefix(1))
        )
        seedModel(
            mode: "clone",
            relativePaths: Array((contractModel(mode: "clone")?.requiredRelativePaths ?? []).prefix(1))
        )
    }

    private class func linkExistingPythonEnvironmentIfPresent() {
        guard let fixtureRoot else { return }

        let pythonSource = defaultAppSupportDir.appendingPathComponent("python", isDirectory: true)
        guard FileManager.default.fileExists(atPath: pythonSource.path) else { return }

        let pythonDestination = fixtureRoot.appendingPathComponent("python", isDirectory: true)
        try? FileManager.default.createSymbolicLink(at: pythonDestination, withDestinationURL: pythonSource)
    }

    private class func contractModel(mode: String) -> UITestContractModel? {
        UITestContractManifest.current.model(mode: mode)
    }

    private class func seedModel(mode: String, relativePaths: [String]) {
        guard let fixtureRoot else { return }
        guard let model = contractModel(mode: mode) else { return }

        let modelRoot = fixtureRoot
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(model.folder, isDirectory: true)

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
