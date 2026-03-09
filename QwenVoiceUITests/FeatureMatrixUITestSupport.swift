import XCTest
import Foundation

enum FeatureMatrixSetupScenario: String {
    case success
    case failOnce = "fail_once"
}

final class StubFeatureFixture {
    private enum EnvironmentKeys {
        static let uiTest = "QWENVOICE_UI_TEST"
        static let backendMode = "QWENVOICE_UI_TEST_BACKEND_MODE"
        static let appSupportDir = "QWENVOICE_APP_SUPPORT_DIR"
        static let fixtureRoot = "QWENVOICE_UI_TEST_FIXTURE_ROOT"
        static let importAudioPath = "QWENVOICE_UI_TEST_IMPORT_AUDIO_PATH"
        static let enrollAudioPath = "QWENVOICE_UI_TEST_ENROLL_AUDIO_PATH"
        static let outputDirectory = "QWENVOICE_UI_TEST_OUTPUT_DIRECTORY"
        static let defaultsSuite = "QWENVOICE_UI_TEST_DEFAULTS_SUITE"
        static let setupScenario = "QWENVOICE_UI_TEST_SETUP_SCENARIO"
        static let setupDelay = "QWENVOICE_UI_TEST_SETUP_DELAY_MS"
    }

    let root: URL
    let defaultsSuiteName: String
    let importAudioURL: URL
    let enrollAudioURL: URL
    let outputDirectoryURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QwenVoiceFeatureMatrix-\(UUID().uuidString)", isDirectory: true)
        defaultsSuiteName = "QwenVoiceUITests.\(UUID().uuidString)"
        importAudioURL = root.appendingPathComponent("fixtures/import-reference.wav")
        enrollAudioURL = root.appendingPathComponent("fixtures/enroll-reference.wav")
        outputDirectoryURL = root.appendingPathComponent("exports", isDirectory: true)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("voices", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("outputs", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cache/stream_sessions", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("fixtures", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)

        try writeFixtureWave(to: importAudioURL, frequency: 310)
        try writeFixtureWave(to: enrollAudioURL, frequency: 260)
        try createEmptyHistoryDatabase()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
    }

    func installModel(mode: String) {
        guard let model = UITestContractManifest.current.model(mode: mode) else { return }
        let modelRoot = root.appendingPathComponent("models/\(model.folder)", isDirectory: true)
        for relativePath in model.requiredRelativePaths {
            let fileURL = modelRoot.appendingPathComponent(relativePath)
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        }
    }

    func installAllModels() {
        for model in UITestContractManifest.current.models {
            installModel(mode: model.mode)
        }
    }

    func seedVoice(name: String = "fixture_voice", transcript: String? = "Fixture transcript") {
        let wavURL = root.appendingPathComponent("voices/\(name).wav")
        let transcriptURL = root.appendingPathComponent("voices/\(name).txt")

        try? writeFixtureWave(to: wavURL, frequency: 190)
        if let transcript {
            try? transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        }
    }

    func seedHistoryEntry(
        text: String,
        mode: String,
        voice: String,
        duration: Double = 1.0,
        fileName: String
    ) throws {
        let outputSubfolder = UITestContractManifest.current.model(mode: mode)?.outputSubfolder ?? "CustomVoice"
        let audioURL = root
            .appendingPathComponent("outputs/\(outputSubfolder)", isDirectory: true)
            .appendingPathComponent(fileName)
        try FileManager.default.createDirectory(at: audioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeFixtureWave(to: audioURL, frequency: 220)

        let escapedAudioPath = audioURL.path.replacingOccurrences(of: "'", with: "''")
        let escapedText = text.replacingOccurrences(of: "'", with: "''")
        let escapedVoice = voice.replacingOccurrences(of: "'", with: "''")
        let sql = """
        INSERT INTO generations (
            text, mode, modelTier, voice, emotion, speed, audioPath, duration, createdAt
        ) VALUES (
            '\(escapedText)', '\(mode)', 'pro', '\(escapedVoice)', NULL, NULL, '\(escapedAudioPath)', \(duration), '2026-03-09 12:00:00'
        );
        """
        try runSQLite(sql: sql)
    }

    func defaults(_ configure: (UserDefaults) -> Void) {
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        configure(defaults)
        defaults.synchronize()
    }

    func environment(
        setupScenario: FeatureMatrixSetupScenario = .success,
        additional: [String: String] = [:]
    ) -> [String: String] {
        [
            EnvironmentKeys.uiTest: "1",
            EnvironmentKeys.backendMode: "stub",
            EnvironmentKeys.appSupportDir: root.path,
            EnvironmentKeys.fixtureRoot: root.path,
            EnvironmentKeys.importAudioPath: importAudioURL.path,
            EnvironmentKeys.enrollAudioPath: enrollAudioURL.path,
            EnvironmentKeys.outputDirectory: outputDirectoryURL.path,
            EnvironmentKeys.defaultsSuite: defaultsSuiteName,
            EnvironmentKeys.setupScenario: setupScenario.rawValue,
            EnvironmentKeys.setupDelay: "300",
        ].merging(additional) { _, new in new }
    }

    private func createEmptyHistoryDatabase() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
        INSERT OR IGNORE INTO grdb_migrations(identifier) VALUES ('v1_create_generations');
        INSERT OR IGNORE INTO grdb_migrations(identifier) VALUES ('v2_add_sortOrder');
        INSERT OR IGNORE INTO grdb_migrations(identifier) VALUES ('v3_drop_sortOrder');
        CREATE TABLE IF NOT EXISTS generations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            text TEXT NOT NULL,
            mode TEXT NOT NULL,
            modelTier TEXT NOT NULL,
            voice TEXT,
            emotion TEXT,
            speed DOUBLE,
            audioPath TEXT NOT NULL,
            duration DOUBLE,
            createdAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        """
        try runSQLite(sql: sql)
    }

    private func runSQLite(sql: String) throws {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [root.appendingPathComponent("history.sqlite").path, sql]
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "sqlite3 failed"
            throw NSError(domain: "StubFeatureFixture", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
    }

    private func writeFixtureWave(to url: URL, frequency: Int) throws {
        let sampleRate = 24_000
        let durationSeconds = 0.75
        let frameCount = Int(Double(sampleRate) * durationSeconds)
        let amplitude = 0.30

        var data = Data()
        let samples: [Int16] = (0..<frameCount).map { frame in
            let time = Double(frame) / Double(sampleRate)
            let value = sin((2.0 * .pi * Double(frequency)) * time) * amplitude
            return Int16(max(-32767, min(32767, Int(value * Double(Int16.max)))))
        }

        let bytesPerSample = 2
        let dataSize = UInt32(samples.count * bytesPerSample)
        let chunkSize = UInt32(36) + dataSize

        data.append("RIFF".data(using: .ascii)!)
        data.append(Self.bytes(chunkSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(Self.bytes(UInt32(16)))
        data.append(Self.bytes(UInt16(1)))
        data.append(Self.bytes(UInt16(1)))
        data.append(Self.bytes(UInt32(sampleRate)))
        data.append(Self.bytes(UInt32(sampleRate * bytesPerSample)))
        data.append(Self.bytes(UInt16(bytesPerSample)))
        data.append(Self.bytes(UInt16(16)))
        data.append("data".data(using: .ascii)!)
        data.append(Self.bytes(dataSize))
        for sample in samples {
            data.append(Self.bytes(UInt16(bitPattern: sample)))
        }

        try data.write(to: url, options: .atomic)
    }

    private static func bytes<T: FixedWidthInteger>(_ value: T) -> Data {
        var littleEndian = value.littleEndian
        return Data(bytes: &littleEndian, count: MemoryLayout<T>.size)
    }
}

class FeatureMatrixUITestBase: QwenVoiceUITestBase {
    override class var launchPolicy: UITestLaunchPolicy { .freshPerTest }

    private(set) var fixture: StubFeatureFixture!

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try StubFeatureFixture()
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning {
            app.terminate()
        }
        let failureCount = testRun?.failureCount ?? 0
        let unexpectedCount = testRun?.unexpectedExceptionCount ?? 0
        if failureCount == 0 && unexpectedCount == 0 {
            fixture?.cleanup()
        } else if let fixture {
            print("[FeatureMatrixUITestBase] Preserving failed fixture root at \(fixture.root.path)")
        }
        fixture = nil
    }

    func launchStubApp(
        initialScreen: UITestScreen? = nil,
        setupScenario: FeatureMatrixSetupScenario = .success,
        additionalEnvironment: [String: String] = [:]
    ) {
        relaunchFreshApp(
            initialScreen: initialScreen,
            additionalEnvironment: fixture.environment(
                setupScenario: setupScenario,
                additional: additionalEnvironment
            )
        )
    }

    func assertEventMarkerExists(_ name: String, timeout: TimeInterval = 5) {
        let marker = fixture.root.appendingPathComponent(".stub-events/\(name).txt")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: marker.path) {
                return
            }
            usleep(200_000)
        }
        XCTFail("Expected stub event marker '\(name)' to exist")
    }
}
