import XCTest

/// XCUITest that drives the real device UI to benchmark all generation modes.
/// Installs models if needed, then generates audio with timing for each scenario.
/// Results are printed as structured JSON for machine parsing.
///
/// Run: xcodebuild test -scheme QVoiceBenchmarkUITests -destination 'id=<udid>'
///   -only-testing:QVoiceBenchmarkUITests/BenchmarkUITests/testFullBenchmarkSuite
final class BenchmarkUITests: XCTestCase {
    private static let worstCaseTelemetryRequestID = "worst_case_ui_design"
    private static let worstCaseTelemetryOutputDir = "ui_benchmark_telemetry"
    private static let worstCaseMaxDurationSeconds: TimeInterval = 180
    private static let sharedScriptLimit = 150
    private static let customScriptLimit = sharedScriptLimit
    private static let designScriptLimit = sharedScriptLimit
    private static let cloneScriptLimit = sharedScriptLimit
    private static let worstCaseVoiceDescription = "A clear, confident female narrator with an articulate broadcast-quality voice, natural phrasing, gentle warmth, crisp diction, steady pacing, and subtle emotional shading that remains believable over long-form storytelling. She should sound polished and intelligent, with a smooth conversational cadence, controlled breath support, and enough variation to keep an extended explanation engaging without becoming theatrical or exaggerated."
    private static let boundedStressLongText = makeScript(length: designScriptLimit)

    private struct BenchmarkFailure: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? {
            message
        }
    }

    private enum RootNavigationTab: String {
        case generate
        case library
        case settings

        var title: String {
            switch self {
            case .generate:
                return "Generate"
            case .library:
                return "Library"
            case .settings:
                return "Settings"
            }
        }

        var dockAccessibilityIdentifier: String {
            "rootTab_\(rawValue)"
        }
    }

    private var app: XCUIApplication!

    /// Structured result for each benchmark scenario.
    private struct ScenarioResult: Codable {
        let scenarioID: String
        let wallTimeSeconds: Double
        let succeeded: Bool
        let error: String?
    }

    private var results: [ScenarioResult] = []

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        configureLaunchEnvironment()
        app.launch()
        XCTAssertTrue(waitForRootNavigation(timeout: 15), "App didn't launch")
    }

    // MARK: - Main Benchmark Suite

    func testFullBenchmarkSuite() {
        // ── Step 1: Install all models if needed ─────────────────────
        navigateToSettings()
        installModelIfNeeded("pro_custom", label: "Custom Voice")
        installModelIfNeeded("pro_design", label: "Voice Design")
        installModelIfNeeded("pro_clone", label: "Voice Cloning")

        // ── Step 2: Benchmark Custom Voice ───────────────────────────
        navigateToGenerate()
        do {
            try selectGenerateSection("Custom")
        } catch {
            XCTFail(localizedMessage(for: error))
            return
        }

        benchmark(id: "custom_short") {
            try clearAndType(text: "Hello world.")
            try tapGenerate()
            try waitForGenerationComplete(timeout: 120)
        }

        benchmark(id: "custom_long") {
            try clearAndType(text: "Artificial intelligence has transformed how we interact with technology. Large language models can now understand context, generate creative content, and assist with complex reasoning tasks.")
            try tapGenerate()
            try waitForGenerationComplete(timeout: 300)
        }

        // ── Step 3: Benchmark Voice Design ───────────────────────────
        do {
            try selectGenerateSection("Design")
            try setVoiceDesignBrief("A clear, steady female narrator with a natural conversational tone.")
        } catch {
            XCTFail(localizedMessage(for: error))
            return
        }

        benchmark(id: "design_short") {
            try clearAndType(text: "Hello world.")
            try tapGenerate()
            try waitForGenerationComplete(timeout: 120)
        }

        benchmark(id: "design_long") {
            try clearAndType(text: "Artificial intelligence has transformed how we interact with technology. Large language models can now understand context, generate creative content, and assist with complex reasoning tasks.")
            try tapGenerate()
            try waitForGenerationComplete(timeout: 300)
        }

        printResults()
        print("🏁 BENCHMARK_COMPLETE")
    }

    // MARK: - Cold vs Warm Benchmark

    /// Measures cold-start (first generation after app launch) vs warm (subsequent generation).
    /// The first generation forces a full model load + prewarm; the second reuses the cached model.
    func testColdVsWarmGeneration() {
        navigateToSettings()
        installModelIfNeeded("pro_custom", label: "Custom Voice")

        navigateToGenerate()
        do {
            try selectGenerateSection("Custom")
        } catch {
            XCTFail(localizedMessage(for: error))
            return
        }

        // First generation after app launch = cold (model not yet loaded by engine)
        benchmark(id: "cold_custom_short") {
            try clearAndType(text: "Hello world.")
            try tapGenerate()
            try waitForGenerationComplete(timeout: 180)
        }

        // Second generation = warm (model already in memory)
        benchmark(id: "warm_custom_short") {
            try clearAndType(text: "Hello world.")
            try tapGenerate()
            try waitForGenerationComplete(timeout: 120)
        }

        printResults()
        print("🏁 COLD_WARM_BENCHMARK_COMPLETE")
    }

    // MARK: - Signpost Performance Test

    /// Uses XCTOSSignpostMetric to measure "Preview To First Chunk" latency using Apple's
    /// built-in performance regression framework. Runs multiple iterations and captures
    /// clock time and memory alongside the signpost interval.
    func testMeasureFirstChunkLatency() {
        navigateToSettings()
        installModelIfNeeded("pro_custom", label: "Custom Voice")

        navigateToGenerate()
        do {
            try selectGenerateSection("Custom")
        } catch {
            XCTFail(localizedMessage(for: error))
            return
        }

        // Warm up the model with an initial generation so measure() captures steady-state
        do {
            try clearAndType(text: "Warmup.")
            try tapGenerate()
            try waitForGenerationComplete(timeout: 120)
        } catch {
            XCTFail(localizedMessage(for: error))
            return
        }

        let signpostMetric = XCTOSSignpostMetric(
            subsystem: "com.qvoice.app",
            category: "performance",
            name: "Preview To First Chunk"
        )

        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(metrics: [signpostMetric, XCTClockMetric()], options: options) {
            do {
                try clearAndType(text: "Hello world.")
                try tapGenerate()
                try waitForGenerationComplete(timeout: 120)
            } catch {
                XCTFail(self.localizedMessage(for: error))
            }
        }
    }

    func testWorstCaseVoiceDesignUIRun() {
        navigateToSettings()
        installModelIfNeeded("pro_design", label: "Voice Design")

        navigateToGenerate()
        do {
            try selectGenerateSection("Design")
            try setVoiceDesignBrief(Self.worstCaseVoiceDescription)
            try clearAndType(text: "Warmup run to load the model before the worst-case UI measurement.")
            try tapGenerate()
            try waitForGenerationComplete(timeout: 300)
        } catch {
            XCTFail(localizedMessage(for: error))
            return
        }

        benchmark(id: "worst_case_design_ui_long_warm") {
            try setVoiceDesignBrief(Self.worstCaseVoiceDescription)
            try clearAndType(text: Self.boundedStressLongText)
            try tapGenerate()
            try waitForGenerationComplete(
                timeout: Self.worstCaseMaxDurationSeconds,
                terminateAppOnTimeout: true
            )
        }

        printResults()
        print("📦 UI_TELEMETRY_REQUEST_ID: \(Self.worstCaseTelemetryRequestID)")
        print("🏁 WORST_CASE_UI_BENCHMARK_COMPLETE")
    }

    func testScriptLengthLimitsAcrossGenerationModes() {
        navigateToSettings()
        installModelIfNeeded("pro_custom", label: "Custom Voice")
        installModelIfNeeded("pro_design", label: "Voice Design")
        installModelIfNeeded("pro_clone", label: "Voice Cloning")

        do {
            relaunchForTextLimitValidation(
                section: "custom",
                scriptText: Self.makeScript(length: Self.customScriptLimit)
            )
            navigateToGenerate()
            try assertScriptLimitState(
                count: Self.customScriptLimit,
                limit: Self.customScriptLimit,
                isOverLimit: false,
                isGenerateEnabled: true
            )

            relaunchForTextLimitValidation(
                section: "custom",
                scriptText: Self.makeScript(length: Self.customScriptLimit + 1)
            )
            navigateToGenerate()
            try assertScriptLimitState(
                count: Self.customScriptLimit + 1,
                limit: Self.customScriptLimit,
                isOverLimit: true,
                isGenerateEnabled: false
            )

            relaunchForTextLimitValidation(
                section: "custom",
                scriptText: "   \n  "
            )
            navigateToGenerate()
            try assertScriptLimitState(
                count: 6,
                limit: Self.customScriptLimit,
                isOverLimit: false,
                isGenerateEnabled: false
            )

            relaunchForTextLimitValidation(
                section: "design",
                scriptText: Self.makeScript(length: Self.designScriptLimit),
                voiceBrief: "A clear, steady female narrator with a natural conversational tone."
            )
            navigateToGenerate()
            try assertScriptLimitState(
                count: Self.designScriptLimit,
                limit: Self.designScriptLimit,
                isOverLimit: false,
                isGenerateEnabled: true
            )

            relaunchForTextLimitValidation(
                section: "design",
                scriptText: Self.makeScript(length: Self.designScriptLimit + 1),
                voiceBrief: "A clear, steady female narrator with a natural conversational tone."
            )
            navigateToGenerate()
            try assertScriptLimitState(
                count: Self.designScriptLimit + 1,
                limit: Self.designScriptLimit,
                isOverLimit: true,
                isGenerateEnabled: false
            )

            relaunchForTextLimitValidation(
                section: "clone",
                scriptText: Self.makeScript(length: Self.cloneScriptLimit)
            )
            navigateToGenerate()
            try assertScriptLimitState(
                count: Self.cloneScriptLimit,
                limit: Self.cloneScriptLimit,
                isOverLimit: false,
                isGenerateEnabled: nil
            )

            relaunchForTextLimitValidation(
                section: "clone",
                scriptText: Self.makeScript(length: Self.cloneScriptLimit + 1)
            )
            navigateToGenerate()
            try assertScriptLimitState(
                count: Self.cloneScriptLimit + 1,
                limit: Self.cloneScriptLimit,
                isOverLimit: true,
                isGenerateEnabled: false
            )
        } catch {
            XCTFail(localizedMessage(for: error))
        }
    }

    func testWarmCloneSmokeAtSharedLimit() {
        navigateToSettings()
        installModelIfNeeded("pro_design", label: "Voice Design")
        installModelIfNeeded("pro_clone", label: "Voice Cloning")

        navigateToGenerate()
        do {
            try selectGenerateSection("Design")
            try setVoiceDesignBrief("A clear, steady female narrator with a natural conversational tone.")
            try clearAndType(text: "Create a short sample voice that we can route into Clone for a warm UI smoke test.")
            try tapGenerate()
            try waitForGenerationComplete(timeout: 120)
            try saveGeneratedVoice()
            try useFirstSavedVoiceInClone()
            try clearAndType(text: Self.makeScript(length: Self.cloneScriptLimit))
            try tapGenerate()
            try waitForGenerationComplete(timeout: 120)
        } catch {
            XCTFail(localizedMessage(for: error))
        }
    }

    func testPreviewExportRoutesProduceSceneArtifacts() {
        let outputRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qvoice-swiftui-preview-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let routes = [
            "generate/custom/default",
            "generate/design/default",
            "generate/clone/default",
            "settings/default"
        ]

        for route in routes {
            do {
                try relaunchForPreviewExport(
                    route: route,
                    variant: "default",
                    outputRoot: outputRoot,
                    captureScreenshot: true
                )
                try assertPreviewArtifactsExist(
                    route: route,
                    variant: "default",
                    outputRoot: outputRoot
                )
            } catch {
                XCTFail("[\(route)] \(localizedMessage(for: error))")
                return
            }
        }
    }

    private func relaunchForTextLimitValidation(
        section: String,
        scriptText: String,
        voiceBrief: String? = nil
    ) {
        app.terminate()
        app.launchEnvironment["QVOICE_UI_TEST_SECTION"] = section
        app.launchEnvironment["QVOICE_UI_TEST_SCRIPT_TEXT"] = scriptText
        if let voiceBrief {
            app.launchEnvironment["QVOICE_UI_TEST_VOICE_BRIEF"] = voiceBrief
        } else {
            app.launchEnvironment.removeValue(forKey: "QVOICE_UI_TEST_VOICE_BRIEF")
        }
        app.launch()
        XCTAssertTrue(waitForRootNavigation(timeout: 15), "App didn't relaunch")
    }

    private func relaunchForPreviewExport(
        route: String,
        variant: String,
        outputRoot: URL,
        captureScreenshot: Bool
    ) throws {
        app.terminate()
        app.launchEnvironment["QVOICE_PREVIEW_ROUTE"] = route
        app.launchEnvironment["QVOICE_PREVIEW_VARIANT"] = variant
        app.launchEnvironment["QVOICE_PREVIEW_OUTPUT_DIR"] = outputRoot.path
        app.launchEnvironment["QVOICE_PREVIEW_CAPTURE_SCREENSHOT"] = captureScreenshot ? "1" : "0"
        app.launch()

        guard app.wait(for: .runningForeground, timeout: 20) else {
            throw BenchmarkFailure("App did not relaunch into preview mode for route \(route).")
        }
    }

    private func assertPreviewArtifactsExist(
        route: String,
        variant: String,
        outputRoot: URL
    ) throws {
        let normalizedRoute = route.hasSuffix("/\(variant)")
            ? String(route.dropLast(variant.count + 1))
            : route
        let routeDirectory = normalizedRoute
            .split(separator: "/")
            .map(String.init)
            .reduce(outputRoot.appendingPathComponent("routes", isDirectory: true)) { partial, component in
                partial.appendingPathComponent(component, isDirectory: true)
            }
            .appendingPathComponent(variant, isDirectory: true)

        let manifestURL = outputRoot.appendingPathComponent("manifest.json")
        let sceneURL = routeDirectory.appendingPathComponent("scene.json")
        let screenshotURL = routeDirectory.appendingPathComponent("native.png")

        try waitForFile(manifestURL, timeout: 20)
        try waitForFile(sceneURL, timeout: 20)
        try waitForFile(screenshotURL, timeout: 20)
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        let fileManager = FileManager.default

        while Date() < deadline {
            if fileManager.fileExists(atPath: url.path) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        throw BenchmarkFailure("Expected file was not written: \(url.path)")
    }

    // MARK: - Navigation

    @discardableResult
    private func rootNavigationButton(
        _ tab: RootNavigationTab,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let perCandidateTimeout = max(timeout / 3, 1)
        let candidates = [
            app.buttons[tab.dockAccessibilityIdentifier],
            app.tabBars.buttons[tab.title],
            app.buttons[tab.title]
        ]

        for candidate in candidates {
            if candidate.exists || candidate.waitForExistence(timeout: perCandidateTimeout) {
                return candidate
            }
        }

        return nil
    }

    private func waitForRootNavigation(timeout: TimeInterval) -> Bool {
        rootNavigationButton(.generate, timeout: timeout) != nil
    }

    private func navigateToSettings() {
        guard let settingsTab = rootNavigationButton(.settings, timeout: 10) else {
            XCTFail("Settings tab not found")
            return
        }
        settingsTab.tap()
        let anyModelRow = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH 'iosModelRow_'")
        ).firstMatch
        let loaded = anyModelRow.waitForExistence(timeout: 15)
        print("▶️ Settings loaded, model rows visible: \(loaded)")
    }

    private func navigateToGenerate() {
        guard let generateTab = rootNavigationButton(.generate, timeout: 10) else {
            XCTFail("Generate tab not found")
            return
        }
        generateTab.tap()
        Thread.sleep(forTimeInterval: 1)
    }

    private func navigateToLibrary() {
        guard let libraryTab = rootNavigationButton(.library, timeout: 10) else {
            XCTFail("Library tab not found")
            return
        }
        libraryTab.tap()
        Thread.sleep(forTimeInterval: 1)
    }

    private func selectGenerateSection(_ name: String) throws {
        let button = app.buttons["generateSection_\(name.lowercased())"].firstMatch.exists
            ? app.buttons["generateSection_\(name.lowercased())"]
            : app.segmentedControls.buttons[name]
        guard button.waitForExistence(timeout: 5) else {
            throw BenchmarkFailure("Generate section '\(name)' not found.")
        }
        button.tap()
        Thread.sleep(forTimeInterval: 1)
    }

    // MARK: - Model Installation

    private func installModelIfNeeded(_ modelID: String, label: String) {
        let downloadButton = app.buttons["iosModelDownload_\(modelID)"]
        let retryButton = app.buttons["iosModelRetry_\(modelID)"]
        let deleteButton = app.buttons["iosModelDelete_\(modelID)"]

        let deadline = Date().addingTimeInterval(30)
        var actionButton: XCUIElement?

        while Date() < deadline {
            if deleteButton.exists {
                print("✅ \(label) already installed")
                return
            }
            if downloadButton.exists {
                actionButton = downloadButton
                break
            }
            if retryButton.exists {
                actionButton = retryButton
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }

        guard let button = actionButton else {
            print("⚠️ \(label) — no install button found after 30s, assuming installed or unavailable")
            return
        }

        print("⬇️ Downloading \(label)...")
        button.tap()

        let installed = deleteButton.waitForExistence(timeout: 600)
        XCTAssertTrue(installed, "\(label) download timed out after 10 minutes")
        if installed {
            print("✅ \(label) installed")
        }
    }

    // MARK: - Generation

    private func clearAndType(text: String) throws {
        let textEditor = try locateTextEditor()
        textEditor.tap()
        Thread.sleep(forTimeInterval: 0.3)

        // Triple-tap to select all existing text in the UITextView
        textEditor.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        Thread.sleep(forTimeInterval: 0.3)

        // Typing replaces the selection; if there was no text, triple-tap is harmless
        textEditor.typeText(text)
    }

    private func setVoiceDesignBrief(_ brief: String) throws {
        let field = app.textFields["voiceDesign_voiceDescriptionField"]
        guard field.waitForExistence(timeout: 5) else {
            throw BenchmarkFailure("Voice Design brief field not found.")
        }

        let currentValue = (field.value as? String) ?? ""
        if currentValue == brief {
            return
        }

        field.tap()
        Thread.sleep(forTimeInterval: 0.3)
        let deleteCount = max(min(currentValue.count + 8, 120), 8)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: deleteCount))
        field.typeText(brief)
    }

    private func appendText(_ text: String) throws {
        let textEditor = try locateTextEditor()
        textEditor.tap()
        Thread.sleep(forTimeInterval: 0.3)
        textEditor.typeText(text)
    }

    private func locateTextEditor() throws -> XCUIElement {
        let textEditor = app.textViews["textInput_textEditor"]
        if textEditor.waitForExistence(timeout: 2) {
            return textEditor
        }

        for _ in 0..<5 {
            app.swipeUp()
            if textEditor.waitForExistence(timeout: 1) {
                return textEditor
            }
        }

        for _ in 0..<3 {
            app.swipeDown()
            if textEditor.waitForExistence(timeout: 1) {
                return textEditor
            }
        }

        throw BenchmarkFailure("Text editor not found.")
    }

    private func tapGenerate() throws {
        let button = app.buttons["textInput_generateButton"]
        guard button.waitForExistence(timeout: 5) else {
            throw BenchmarkFailure("Generate button not found.")
        }
        guard button.isEnabled else {
            throw BenchmarkFailure("Generate button is disabled — model may not be installed.")
        }
        button.tap()
    }

    private func saveGeneratedVoice() throws {
        let button = app.buttons["voiceDesign_saveVoiceButton"]
        guard button.waitForExistence(timeout: 10) else {
            throw BenchmarkFailure("Save Generated Voice button not found.")
        }
        button.tap()

        let saveButton = app.buttons["Save"]
        guard saveButton.waitForExistence(timeout: 10) else {
            throw BenchmarkFailure("Save button not found in Save Generated Voice sheet.")
        }
        guard saveButton.isEnabled else {
            throw BenchmarkFailure("Save button is disabled in Save Generated Voice sheet.")
        }
        saveButton.tap()

        let saveButtonGone = NSPredicate(format: "exists == false")
        let expectation = expectation(for: saveButtonGone, evaluatedWith: saveButton)
        let result = XCTWaiter.wait(for: [expectation], timeout: 20)
        guard result == .completed else {
            throw BenchmarkFailure("Save Generated Voice sheet did not dismiss.")
        }
    }

    private func useFirstSavedVoiceInClone() throws {
        navigateToLibrary()
        let voicesButton = app.buttons["Voices"].firstMatch
        let savedVoicesButton = app.buttons["Saved Voices"].firstMatch
        if voicesButton.waitForExistence(timeout: 5) {
            voicesButton.tap()
        } else if savedVoicesButton.waitForExistence(timeout: 5) {
            savedVoicesButton.tap()
        }

        let button = app.buttons["Use in Clone"].firstMatch
        guard button.waitForExistence(timeout: 30) else {
            throw BenchmarkFailure("Use in Clone button not found in Library.")
        }
        button.tap()

        let textEditor = app.textViews["textInput_textEditor"]
        guard textEditor.waitForExistence(timeout: 15) else {
            throw BenchmarkFailure("Clone screen did not open after using a saved voice.")
        }
    }

    private func waitForGenerationComplete(
        timeout: TimeInterval,
        terminateAppOnTimeout: Bool = false
    ) throws {
        let button = app.buttons["textInput_generateButton"]
        let startTime = Date()
        var didStart = false

        // Wait for generation to start (button becomes disabled)
        while button.isEnabled && Date().timeIntervalSince(startTime) < 10 {
            Thread.sleep(forTimeInterval: 0.3)
        }
        didStart = !button.isEnabled
        guard didStart else {
            throw BenchmarkFailure("Generation did not start within 10 seconds.")
        }

        // Wait for generation to finish (button becomes enabled again)
        while !button.isEnabled && Date().timeIntervalSince(startTime) < timeout {
            Thread.sleep(forTimeInterval: 0.5)
        }

        let elapsed = Date().timeIntervalSince(startTime)
        guard button.isEnabled else {
            if terminateAppOnTimeout {
                print("🛑 Generation exceeded \(Int(timeout))s; terminating app to avoid a runaway UI benchmark.")
                app.terminate()
            }
            throw BenchmarkFailure("Generation did not complete within \(Int(timeout)) seconds.")
        }
        print("⏱️ Generation completed in \(String(format: "%.1f", elapsed))s")
    }

    private func assertScriptLimitState(
        count: Int,
        limit: Int,
        isOverLimit: Bool,
        isGenerateEnabled: Bool?
    ) throws {
        let counterText = "\(count)/\(limit)"
        let expectedMessage = isOverLimit
            ? "Shorten the script to \(limit) characters or less for on-device generation."
            : (count == limit
                ? "At the on-device limit for this mode."
                : "\(limit - count) characters remaining for on-device generation.")
        try revealScriptLimitStatus(counterText: counterText, helperMessage: expectedMessage)

        let countLabel = app.staticTexts[counterText]
        guard countLabel.waitForExistence(timeout: 5) else {
            throw BenchmarkFailure("Script length counter did not appear.")
        }

        let messageLabel = app.staticTexts[expectedMessage]
        guard messageLabel.waitForExistence(timeout: 5) else {
            throw BenchmarkFailure("Script length helper message did not appear.")
        }

        if let isGenerateEnabled {
            let button = app.buttons["textInput_generateButton"]
            guard button.waitForExistence(timeout: 5) else {
                throw BenchmarkFailure("Generate button not found.")
            }
            XCTAssertEqual(button.isEnabled, isGenerateEnabled)
        }
    }

    private func revealScriptLimitStatus(counterText: String, helperMessage: String) throws {
        let countLabel = app.staticTexts[counterText]
        let messageLabel = app.staticTexts[helperMessage]
        if countLabel.waitForExistence(timeout: 1) || messageLabel.waitForExistence(timeout: 1) {
            return
        }

        for _ in 0..<4 {
            app.swipeUp()
            if countLabel.waitForExistence(timeout: 1) || messageLabel.waitForExistence(timeout: 1) {
                return
            }
        }

        for _ in 0..<2 {
            app.swipeDown()
            if countLabel.waitForExistence(timeout: 1) || messageLabel.waitForExistence(timeout: 1) {
                return
            }
        }

        if countLabel.exists || messageLabel.exists {
            return
        }

        throw BenchmarkFailure("Script length status row did not appear.")
    }

    // MARK: - Benchmark Timing & Results

    private func benchmark(id: String, block: () throws -> Void) {
        let start = Date()
        print("▶️ [\(id)] Starting...")
        var error: String?

        do {
            try block()
        } catch let caughtError {
            let message = localizedMessage(for: caughtError)
            error = message
            record(
                XCTIssue(
                    type: .assertionFailure,
                    compactDescription: "[\(id)] \(message)"
                )
            )
        }

        let elapsed = Date().timeIntervalSince(start)
        let succeeded = error == nil
        results.append(ScenarioResult(
            scenarioID: id,
            wallTimeSeconds: elapsed,
            succeeded: succeeded,
            error: error
        ))

        if succeeded {
            print("✅ [\(id)] Completed in \(String(format: "%.1f", elapsed))s")
        } else {
            print("❌ [\(id)] Failed in \(String(format: "%.1f", elapsed))s — \(error ?? "unknown")")
        }
    }

    private func localizedMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let message = localizedError.errorDescription {
            return message
        }
        return error.localizedDescription
    }

    private func printResults() {
        guard !results.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(results),
              let json = String(data: data, encoding: .utf8) else { return }
        print("📊 BENCHMARK_RESULTS_JSON: \(json)")
    }

    private func configureLaunchEnvironment() {
        guard name.contains("testWorstCaseVoiceDesignUIRun") else {
            return
        }

        app.launchEnvironment["QVOICE_UI_TEST_REQUEST_ID"] = Self.worstCaseTelemetryRequestID
        app.launchEnvironment["QVOICE_UI_TEST_TELEMETRY_OUTPUT_DIR"] = Self.worstCaseTelemetryOutputDir
        app.launchEnvironment["QVOICE_UI_TEST_SAMPLE_INTERVAL_MS"] = "50"
        app.launchEnvironment["QVOICE_UI_TEST_TELEMETRY_LABEL"] = "worst_case_design_ui"
    }

    private static func makeScript(length: Int) -> String {
        precondition(length > 0)

        let sentence = "Artificial intelligence on iPhone demands careful memory, latency, and streaming discipline."
        var text = ""

        while text.count < length {
            if !text.isEmpty {
                text.append(" ")
            }
            text.append(sentence)
        }

        if text.count > length {
            text = String(text.prefix(length))
        }

        return text
    }
}
