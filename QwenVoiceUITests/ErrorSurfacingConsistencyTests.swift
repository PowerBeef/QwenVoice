import XCTest

final class ErrorSurfacingConsistencyTests: QwenVoiceUITestBase {
    override class var launchPolicy: UITestLaunchPolicy { .freshPerTest }

    private enum FaultKey: String {
        case listVoices = "QWENVOICE_UI_TEST_FAULT_LIST_VOICES"
        case historyFetch = "QWENVOICE_UI_TEST_FAULT_HISTORY_FETCH"
        case historyDeleteDatabase = "QWENVOICE_UI_TEST_FAULT_HISTORY_DELETE_DB"
        case historyDeleteAudio = "QWENVOICE_UI_TEST_FAULT_HISTORY_DELETE_AUDIO"
        case voiceTranscriptRead = "QWENVOICE_UI_TEST_FAULT_VOICE_TRANSCRIPT_READ"
    }

    private var fixtureRoot: URL?

    private static let appSupportOverrideEnvironmentKey = "QWENVOICE_APP_SUPPORT_DIR"
    private static let defaultAppSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("QwenVoice", isDirectory: true)
    private static let cloneModelFolder = "Qwen3-TTS-12Hz-1.7B-Base-8bit"
    private static let requiredCloneModelPaths = [
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

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        fixtureRoot = nil
    }

    func testVoicesViewShowsLoadErrorState() throws {
        try launchFixtureApp(
            on: .voices,
            faults: [.listVoices]
        )

        XCTAssertTrue(waitForElement("voices_errorState", timeout: 10).exists)
        XCTAssertTrue(app.buttons["Try Again"].firstMatch.waitForExistence(timeout: 5))

        let emptyState = app.descendants(matching: .any).matching(identifier: "voices_emptyState").firstMatch
        XCTAssertFalse(emptyState.exists, "Voices should surface a load error state instead of the empty state")
    }

    func testVoiceCloningShowsSavedVoicesWarningWhenListFails() throws {
        try launchFixtureApp(
            on: .voiceCloning,
            faults: [.listVoices]
        )

        XCTAssertTrue(waitForElement("voiceCloning_savedVoicesWarning", timeout: 10).exists)
        XCTAssertTrue(waitForElement("voiceCloning_dropZone", timeout: 5).isEnabled)

        let transcript = waitForElement("voiceCloning_transcriptField", type: .textField, timeout: 5)
        XCTAssertTrue(transcript.isEnabled, "Transcript entry should remain usable when saved voices fail to load")
    }

    func testVoiceCloningSurfacesTranscriptReadFailure() throws {
        try launchFixtureApp(
            on: .voiceCloning,
            faults: [.voiceTranscriptRead]
        )

        let savedVoice = waitForElement("voiceCloning_savedVoice_fixture_voice", type: .button, timeout: 10)
        savedVoice.click()

        XCTAssertTrue(app.staticTexts["fixture_voice.wav"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForElement("voiceCloning_transcriptWarning", timeout: 5).exists)

        let transcriptField = waitForElement("voiceCloning_transcriptField", type: .textField, timeout: 5)
        let transcriptValue = transcriptField.value as? String ?? ""
        XCTAssertFalse(
            transcriptValue.contains("Fixture transcript"),
            "Transcript text should stay empty when the saved transcript cannot be read"
        )
    }

    func testHistoryDeleteShowsDatabaseFailureAlert() throws {
        try launchFixtureApp(
            on: .history,
            faults: [.historyDeleteDatabase]
        )

        let rowText = app.staticTexts["History fixture entry"].firstMatch
        XCTAssertTrue(rowText.waitForExistence(timeout: 10))

        waitForElement("historyRow_delete", type: .button, timeout: 5).click()
        clickDeleteConfirmation()

        XCTAssertTrue(rowText.waitForExistence(timeout: 5), "The row should remain visible after a database delete failure")
        assertAlertSheetPresent()
    }

    func testHistoryDeleteShowsAudioCleanupWarning() throws {
        try launchFixtureApp(
            on: .history,
            faults: [.historyDeleteAudio]
        )

        let rowText = app.staticTexts["History fixture entry"].firstMatch
        XCTAssertTrue(rowText.waitForExistence(timeout: 10))

        waitForElement("historyRow_delete", type: .button, timeout: 5).click()
        clickDeleteConfirmation()

        XCTAssertTrue(rowText.waitForNonExistence(timeout: 5), "The row should be removed after the history entry is deleted")
        assertAlertSheetPresent()
    }

    func testHistoryRefreshShowsAlertWhileKeepingRows() throws {
        try launchFixtureApp(
            on: .history,
            faults: [.historyFetch]
        )

        let rowText = app.staticTexts["History fixture entry"].firstMatch
        XCTAssertTrue(rowText.waitForExistence(timeout: 10))

        navigateToSidebar(.voices)
        navigateToSidebar(.history)

        XCTAssertTrue(rowText.waitForExistence(timeout: 5), "Loaded rows should remain visible after a refresh failure")
        assertAlertSheetPresent()
    }

    private func launchFixtureApp(on screen: UITestScreen, faults: [FaultKey]) throws {
        let root = try makeFixtureRoot()
        fixtureRoot = root

        var environment = [
            Self.appSupportOverrideEnvironmentKey: root.path,
        ]
        for fault in faults {
            environment[fault.rawValue] = "1"
        }

        relaunchFreshApp(initialScreen: screen, additionalEnvironment: environment)
        waitForMainUI()
        _ = waitForScreen(screen, timeout: 10)
    }

    private func makeFixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QwenVoiceErrorFixtures-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("voices", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("models", isDirectory: true),
            withIntermediateDirectories: true
        )

        linkExistingPythonEnvironmentIfPresent(to: root)
        try seedCloneModel(at: root)
        seedVoiceFixture(at: root)
        try seedHistoryFixture(at: root)
        return root
    }

    private func seedCloneModel(at root: URL) throws {
        let modelRoot = root
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(Self.cloneModelFolder, isDirectory: true)

        for relativePath in Self.requiredCloneModelPaths {
            let fileURL = modelRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        }
    }

    private func seedVoiceFixture(at root: URL) {
        let voicesDir = root.appendingPathComponent("voices", isDirectory: true)
        let wavPath = voicesDir.appendingPathComponent("fixture_voice.wav")
        let transcriptPath = voicesDir.appendingPathComponent("fixture_voice.txt")

        FileManager.default.createFile(atPath: wavPath.path, contents: Data())
        FileManager.default.createFile(
            atPath: transcriptPath.path,
            contents: Data("Fixture transcript".utf8)
        )
    }

    private func seedHistoryFixture(at root: URL) throws {
        let audioPath = root
            .appendingPathComponent("outputs", isDirectory: true)
            .appendingPathComponent("Clones", isDirectory: true)
            .appendingPathComponent("history-fixture.wav")

        try FileManager.default.createDirectory(
            at: audioPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: audioPath.path, contents: Data())

        let dbPath = root.appendingPathComponent("history.sqlite").path
        let escapedAudioPath = audioPath.path.replacingOccurrences(of: "'", with: "''")
        let sql = """
        CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
        INSERT INTO grdb_migrations(identifier) VALUES ('v1_create_generations');
        INSERT INTO grdb_migrations(identifier) VALUES ('v2_add_sortOrder');
        CREATE TABLE generations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            text TEXT NOT NULL,
            mode TEXT NOT NULL,
            modelTier TEXT NOT NULL,
            voice TEXT,
            emotion TEXT,
            speed DOUBLE,
            audioPath TEXT NOT NULL,
            duration DOUBLE,
            createdAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            sortOrder INTEGER DEFAULT 0
        );
        INSERT INTO generations (
            text, mode, modelTier, voice, emotion, speed, audioPath, duration, createdAt, sortOrder
        ) VALUES (
            'History fixture entry', 'clone', 'pro', 'fixture_voice', NULL, NULL, '\(escapedAudioPath)', 1.2, '2026-03-05 12:00:00', 0
        );
        """

        try runSQLite3(databasePath: dbPath, sql: sql)
    }

    private func linkExistingPythonEnvironmentIfPresent(to root: URL) {
        let source = Self.defaultAppSupportDir.appendingPathComponent("python", isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else { return }

        let destination = root.appendingPathComponent("python", isDirectory: true)
        try? FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
    }

    private func runSQLite3(databasePath: String, sql: String) throws {
        let process = Process()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databasePath, sql]
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "Unknown sqlite3 error"
            throw NSError(
                domain: "ErrorSurfacingConsistencyTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
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

        XCTFail("Main UI shell did not appear within \(Int(timeout))s under the fixture app-support override.")
    }

    private func clickDeleteConfirmation(timeout: TimeInterval = 5) {
        let deleteButton = app.sheets.firstMatch.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: timeout), "Delete confirmation button should appear in the alert sheet")
        deleteButton.click()
    }

    private func assertAlertSheetPresent(timeout: TimeInterval = 5) {
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: timeout), "An alert sheet should appear")
    }
}
