import Foundation
import XCTest

/// End-to-end smoke test for the macOS live-preview pipeline.
///
/// Drives the Custom Voice generate flow with the stub backend
/// (`UITestStubMacEngine` / `StubBackendTransport`) and asserts that:
///
/// 1. The generate button is reachable and enabled after text entry.
/// 2. The live-preview badge appears — meaning `AudioPlayerViewModel`
///    received and decoded at least one chunk via `appendLiveChunk` →
///    `loadPCMBuffer`.
/// 3. No "could not decode" error string surfaces in the player view.
///
/// This test does NOT require real MLX models or the production engine —
/// the stub backend emits three synthetic 24 kHz Int16 WAV chunks over
/// ~1 s. The point is to exercise the full user-facing path:
/// `button click → GenerationRequest → chunk event → UI decoder → player`.
///
/// Against commit `c19e312` (before the AVAudioFile finalization fix),
/// the real engine's `PCM16ChunkFileWriter` race could surface the
/// "Live audio preview could not decode the latest chunk." error in the
/// player — which was observed manually by a user before it was caught
/// by any automated gate. This harness closes that gap: the next time the
/// accessibility identifiers, sidebar player, or chunk event flow break,
/// CI catches it instead of a human.
final class LivePreviewSmokeTests: XCTestCase {

    private var app: XCUIApplication!
    private var fixtureRoot: URL?
    private var ownsFixture = false

    override func setUpWithError() throws {
        continueAfterFailure = false

        let fixtureURL = try resolveOrCreateFixtureRoot()
        fixtureRoot = fixtureURL

        app = XCUIApplication()
        app.launchArguments = [
            "--uitest",
            "--uitest-disable-animations",
            "--uitest-fast-idle",
            "--uitest-screen=customVoice",
        ]
        // Reuse the same env keys the Python harness (`ui_test_support.py`)
        // sets when launching the app directly — keeping one codified path.
        app.launchEnvironment["QWENVOICE_UI_TEST"] = "1"
        app.launchEnvironment["QWENVOICE_UI_TEST_BACKEND_MODE"] = "stub"
        app.launchEnvironment["QWENVOICE_UI_TEST_FIXTURE_ROOT"] = fixtureURL.path
        app.launchEnvironment["QWENVOICE_UI_TEST_SETUP_SCENARIO"] = "success"
        app.launchEnvironment["QWENVOICE_UI_TEST_SETUP_DELAY_MS"] = "1"
        app.launchEnvironment["QWENVOICE_UI_TEST_DEFAULTS_SUITE"]
            = "VocelloUITests.\(UUID().uuidString)"
        app.launch()
        // On macOS, XCUIApplication.launch() starts the process but doesn't
        // guarantee foreground focus — which in turn gates whether the
        // SwiftUI WindowGroup's window shows up in the accessibility tree.
        // Explicitly activate so the window registers for queries.
        app.activate()
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning {
            app.terminate()
        }
        if ownsFixture, let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    // MARK: - Tests

    /// Drives the Custom Voice generate flow and asserts that chunks arrive,
    /// the player enters live-preview state, and no decode error surfaces.
    func testCustomVoiceGenerationEntersLivePreviewWithoutDecodeError() throws {
        // Wait for the SwiftUI WindowGroup to materialize a window. App
        // process running != window rendered; on macOS the window can take a
        // few hundred ms after `launch()` returns.
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Vocello.app never reached runningForeground state."
        )
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(
            mainWindow.waitForExistence(timeout: 15),
            "Vocello.app has no windows after launch."
        )

        // The app should boot directly onto Custom Voice thanks to
        // `--uitest-screen=customVoice`. Sanity-check the screen root
        // identifier before touching anything else, so a layout regression
        // produces a clearer error than a missing text field further down.
        let customVoiceScreen = firstElement(matchingIdentifier: "screen_customVoice")
        if !customVoiceScreen.waitForExistence(timeout: 20) {
            // Attach the live accessibility hierarchy to the test result so
            // we can see WHAT the app is showing when this assertion fires.
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "app-accessibility-hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("Custom Voice screen did not appear (screen_customVoice missing).")
            return
        }

        // Type into the script editor.
        let scriptEditor = firstElement(matchingIdentifier: "textInput_textEditor")
        XCTAssertTrue(
            scriptEditor.waitForExistence(timeout: 10),
            "textInput_textEditor never appeared."
        )
        scriptEditor.click()
        scriptEditor.typeText("Hey there")

        // Tap Generate.
        let generate = app.buttons["textInput_generateButton"]
        XCTAssertTrue(
            generate.waitForExistence(timeout: 5),
            "textInput_generateButton never appeared."
        )
        XCTAssertTrue(
            generate.isEnabled,
            "textInput_generateButton is disabled after text entry."
        )
        generate.click()

        // The live badge appears only after `appendLiveChunk` has consumed at
        // least one chunk. This is the strongest positive signal that the
        // decode pipeline is alive.
        let liveBadge = firstElement(matchingIdentifier: "sidebarPlayer_liveBadge")
        XCTAssertTrue(
            liveBadge.waitForExistence(timeout: 20),
            """
            sidebarPlayer_liveBadge never appeared. Either generation failed \
            outright, chunks never arrived at the AudioPlayerViewModel, or \
            loadPCMBuffer returned nil for every chunk.
            """
        )

        // Negative assertion: the player should NOT be displaying the
        // "could not decode" error. This catches the regression class we saw
        // when chunk WAV files weren't finalized before the consumer opened
        // them.
        let decodeErrorPredicate = NSPredicate(
            format: "label CONTAINS[c] %@",
            "could not decode"
        )
        let decodeErrorMatches = app.staticTexts.matching(decodeErrorPredicate)
        if decodeErrorMatches.count > 0 {
            let labels = (0..<decodeErrorMatches.count)
                .map { decodeErrorMatches.element(boundBy: $0).label }
                .joined(separator: " | ")
            XCTFail(
                "Player surfaced a decode error: \(labels)"
            )
        }
    }

    // MARK: - Fixture setup

    /// Resolve a stub-model fixture root. When the harness already staged
    /// one via the `QWENVOICE_UI_TEST_FIXTURE_ROOT` env var, reuse it so the
    /// harness owns cleanup. Otherwise create a temp fixture from the
    /// bundled contract.
    private func resolveOrCreateFixtureRoot() throws -> URL {
        if let inherited = ProcessInfo.processInfo
            .environment["QWENVOICE_UI_TEST_FIXTURE_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !inherited.isEmpty {
            return URL(fileURLWithPath: inherited, isDirectory: true)
        }
        ownsFixture = true
        return try createFixtureRoot()
    }

    /// Create a self-contained temp fixture that mirrors what
    /// `scripts/harness_lib/ui_test_support.py:_install_stub_models` produces:
    /// empty placeholder files at every required relative path listed in the
    /// contract, enough to satisfy `TTSModel.isAvailable(in:)` but without
    /// any actual model weights.
    private func createFixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "qwenvoice-ui-\(UUID().uuidString)",
                isDirectory: true
            )
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // App-Support subtree the app expects.
        let baseRelatives = [
            "models",
            "outputs/CustomVoice",
            "outputs/VoiceDesign",
            "outputs/Clones",
            "voices",
            "cache/normalized_clone_refs",
            "cache/stream_sessions",
        ]
        for relative in baseRelatives {
            try fm.createDirectory(
                at: root.appendingPathComponent(relative, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        // Stage stub model files from the bundled contract.
        let contractURL = try locateBundledContract()
        let contract = try JSONSerialization.jsonObject(
            with: Data(contentsOf: contractURL)
        ) as? [String: Any] ?? [:]
        let models = contract["models"] as? [[String: Any]] ?? []
        let modelsRoot = root.appendingPathComponent("models", isDirectory: true)
        for model in models {
            guard let folder = model["folder"] as? String,
                  !folder.isEmpty else { continue }
            let modelDir = modelsRoot.appendingPathComponent(folder, isDirectory: true)
            try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
            let requiredPaths = model["requiredRelativePaths"] as? [String] ?? []
            for relative in requiredPaths {
                let target = modelDir.appendingPathComponent(relative)
                try fm.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !fm.fileExists(atPath: target.path) {
                    fm.createFile(atPath: target.path, contents: Data())
                }
            }
        }
        return root
    }

    private func locateBundledContract() throws -> URL {
        let bundle = Bundle(for: type(of: self))
        if let url = bundle.url(
            forResource: "qwenvoice_contract",
            withExtension: "json"
        ) {
            return url
        }
        // Fall back to the repo-relative path (works for `xcodebuild test`
        // invocations where the resource ends up beside the test bundle).
        let testFile = URL(fileURLWithPath: #filePath)
        let candidate = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Resources/qwenvoice_contract.json")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    // MARK: - Query helpers

    /// Look the identifier up across ALL element types. `descendants(matching:
    /// .any)` lets `waitForExistence` block until any element in the tree
    /// with that identifier appears, regardless of whether SwiftUI maps the
    /// underlying view to a text field, button, or generic container.
    private func firstElement(matchingIdentifier identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
