import AVFoundation
import Combine
import XCTest

@testable import QwenVoice
@testable import QwenVoiceCore
@testable import QwenVoiceNative

/// Programmatic integration test for the macOS live-preview pipeline.
///
/// Wires the real components directly — no XCUITest, no TCC, no launched
/// process:
///
///     UITestStubMacEngine.generate()
///         → StubBackendTransport writes chunk_*.wav + emits .streamChunk
///             events to `GenerationChunkBroker.publish(event)`
///                 → AudioPlayerViewModel subscribes to the broker,
///                     handleGenerationChunk → appendLiveChunk →
///                     loadPCMBuffer (the AVAudioFile decode).
///
/// This is the path where the "Live audio preview could not decode the
/// latest chunk." error originates. Asserting `viewModel.playbackError`
/// stays `nil` through an entire stub generation protects against the
/// finalization race (fix landed in commit `7c8b187`) and any future
/// regression in the broker / AudioPlayerViewModel plumbing.
///
/// Runs under the `swift` harness layer. Unlike the XCUITest-based
/// `VocelloUITests/LivePreviewSmokeTests`, it requires neither
/// Accessibility permission nor a GUI session, so it's safe to run in
/// headless CI.
@MainActor
final class LivePreviewIntegrationTests: XCTestCase {

    private var fixtureRoot: URL!
    private var viewModel: AudioPlayerViewModel!
    private var engine: UITestStubMacEngine!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false

        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "qwenvoice-live-preview-\(UUID().uuidString)",
                isDirectory: true
            )
        try stageStubFixture(at: fixtureRoot)

        // AppPaths reads QWENVOICE_APP_SUPPORT_DIR at every access, so
        // setting it here reroutes both the engine's loadModel check and
        // the StubBackendTransport's output-path resolution into the
        // fixture.
        setenv("QWENVOICE_APP_SUPPORT_DIR", fixtureRoot.path, 1)

        // AudioPlayerViewModel suppresses its auto-subscribe when running
        // under XCTest (otherwise the test-host app's @StateObject
        // viewModel races with this one for chunk events and deletes the
        // files first). Explicitly opt in so THIS viewModel is the only
        // subscriber to GenerationChunkBroker for the duration of the test.
        viewModel = AudioPlayerViewModel()
        viewModel.startLivePreviewChunkSubscriptionForTesting()

        engine = UITestStubMacEngine()
        try await engine.initialize(appSupportDirectory: fixtureRoot)
    }

    override func tearDown() async throws {
        engine = nil
        viewModel = nil
        unsetenv("QWENVOICE_APP_SUPPORT_DIR")
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        try await super.tearDown()
    }

    // MARK: - Tests

    /// End-to-end pipeline test: stub backend emits chunks,
    /// `AudioPlayerViewModel` receives them through
    /// `GenerationChunkBroker`, and every chunk decodes cleanly.
    ///
    /// Asserts the strong invariants the pipeline MUST satisfy:
    ///   * Every stub chunk (3 total) reaches `appendLiveChunk` AND
    ///     decodes successfully — `livePreviewQueueDepth == 3`.
    ///   * `isLiveStream` flips to true on first chunk arrival.
    ///   * `currentTitle` propagates from the chunk event.
    ///   * `playbackError` stays nil — no decode error surfaces.
    ///
    /// The previous iteration of this test tolerated an intermittent
    /// decode-error condition that came from a cross-test-host
    /// duplicate-subscriber race: the app's own `@StateObject`
    /// `AudioPlayerViewModel` (constructed by `QwenVoiceApp` at test-host
    /// launch) was competing with the test-owned viewModel for chunks on
    /// the shared `GenerationChunkBroker`, and the first handler to run
    /// deleted the file before the second could open it. That race is
    /// fixed by suppressing the host viewModel's auto-subscribe under
    /// XCTest (see `AudioPlayerViewModel.init` + the new
    /// `startLivePreviewChunkSubscriptionForTesting()`), so this test now
    /// asserts the strict invariant.
    func testStubGenerationReachesLivePreviewViewModel() async throws {
        let request = GenerationRequest(
            modelID: "pro_custom",
            text: "Hey there",
            outputPath: fixtureRoot
                .appendingPathComponent("outputs/CustomVoice/integration-test.wav")
                .path,
            shouldStream: true,
            streamingTitle: "Hey there",
            payload: .custom(speakerID: "vivian", deliveryStyle: "Conversational")
        )

        _ = try await engine.generate(request)

        // After generate() returns, three chunk events have been published.
        // Combine delivers them via .receive(on: .main) so yield until all
        // three have decoded — or a decode error interrupts.
        try await waitUntil(timeoutSeconds: 2.0) {
            self.viewModel.playbackError != nil
                || self.viewModel.livePreviewQueueDepth >= 3
        }

        XCTAssertNil(
            viewModel.playbackError,
            """
            A decode error surfaced during stub streaming:
              \(viewModel.playbackError ?? "nil")
            `loadPCMBuffer(from:)` returned nil for at least one chunk, which
            means the file was unreadable at decode time. The most likely
            cause is a duplicate-subscriber race on GenerationChunkBroker
            (see AudioPlayerViewModel.init suppression + the test-only
            startLivePreviewChunkSubscriptionForTesting hook) — verify no
            other subscriber is alive for the duration of this test.
            """
        )
        XCTAssertEqual(
            viewModel.livePreviewQueueDepth, 3,
            "All three stub chunks should have decoded and been scheduled."
        )
        XCTAssertTrue(
            viewModel.isLiveStream,
            "Live stream flag should have flipped on first chunk arrival."
        )
        XCTAssertEqual(
            viewModel.currentTitle, "Hey there",
            "Live session title should have been propagated from the chunk event."
        )

        if let playbackError = viewModel.playbackError {
            // Retained as a safety net: if the assertion above ever fires
            // under a new regression, attach the state so the xcresult
            // contains enough data to diagnose without rerunning.
            let state = """
            playbackError: \(playbackError)
            livePreviewQueueDepth: \(viewModel.livePreviewQueueDepth)
            isLiveStream: \(viewModel.isLiveStream)
            livePreviewPhase: \(viewModel.livePreviewPhase.rawValue)
            currentTitle: \(viewModel.currentTitle)
            """
            let attachment = XCTAttachment(string: state)
            attachment.name = "live-preview-diagnostic-state"
            add(attachment)
        }
    }

    /// Parallel to `testStubGenerationReachesLivePreviewViewModel` but uses
    /// the `.design` payload (Voice Design mode). Proves the broker →
    /// viewModel chain is mode-agnostic: every streaming mode that exists
    /// in the `GenerationMode` enum routes through the same plumbing and
    /// exercises the same live-preview path in the UI.
    func testDesignModeStreamingReachesLivePreviewViewModel() async throws {
        let request = GenerationRequest(
            modelID: "pro_design",
            text: "Design mode preview",
            outputPath: fixtureRoot
                .appendingPathComponent("outputs/VoiceDesign/design-integration.wav")
                .path,
            shouldStream: true,
            streamingTitle: "Design mode preview",
            payload: .design(
                voiceDescription: "A calm narrator with warm, deliberate pacing.",
                deliveryStyle: "Warm"
            )
        )

        _ = try await engine.generate(request)

        try await waitUntil(timeoutSeconds: 2.0) {
            self.viewModel.playbackError != nil
                || self.viewModel.livePreviewQueueDepth >= 3
        }

        XCTAssertNil(
            viewModel.playbackError,
            "A decode error surfaced during Voice Design streaming: \(viewModel.playbackError ?? "nil")"
        )
        XCTAssertEqual(
            viewModel.livePreviewQueueDepth, 3,
            "All three stub chunks should have decoded in Voice Design mode."
        )
        XCTAssertTrue(
            viewModel.isLiveStream,
            "Live stream flag should have flipped for Voice Design streaming."
        )
        XCTAssertEqual(
            viewModel.currentTitle, "Design mode preview",
            "Live session title should have propagated from the Voice Design chunk event."
        )
    }

    /// Sanity: calling generate() without shouldStream must NOT trigger the
    /// live-preview path at all, so no chunks flow to the view model.
    func testNonStreamingGenerationDoesNotTouchLivePreview() async throws {
        let request = GenerationRequest(
            modelID: "pro_custom",
            text: "One shot",
            outputPath: fixtureRoot
                .appendingPathComponent("outputs/CustomVoice/oneshot.wav")
                .path,
            shouldStream: false,
            payload: .custom(speakerID: "vivian", deliveryStyle: nil)
        )

        _ = try await engine.generate(request)
        // Give any would-be Combine deliveries time to flush.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(viewModel.playbackError, "Non-streaming path should not surface a player error.")
        XCTAssertEqual(viewModel.livePreviewQueueDepth, 0)
        XCTAssertFalse(viewModel.isLiveStream)
    }

    // MARK: - Helpers

    private func waitUntil(
        timeoutSeconds: Double,
        check: () -> Bool
    ) async throws {
        let startedAt = Date()
        while Date().timeIntervalSince(startedAt) < timeoutSeconds {
            if check() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Mirror of the Python harness `_install_stub_models` +
    /// `_create_base_directories` logic, adapted to run inline inside an
    /// XCTest setUp. Populates the fixture with empty files at every
    /// required relative path so `TTSModel.isAvailable(in:)` returns true.
    private func stageStubFixture(at root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        for relative in [
            "models",
            "outputs/CustomVoice",
            "outputs/VoiceDesign",
            "outputs/Clones",
            "voices",
            "cache/normalized_clone_refs",
            "cache/stream_sessions",
        ] {
            try fm.createDirectory(
                at: root.appendingPathComponent(relative, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let contractURL = try locateContract()
        let contract = try JSONSerialization.jsonObject(
            with: Data(contentsOf: contractURL)
        ) as? [String: Any] ?? [:]
        let models = contract["models"] as? [[String: Any]] ?? []
        let modelsRoot = root.appendingPathComponent("models", isDirectory: true)
        for model in models {
            guard let folder = model["folder"] as? String, !folder.isEmpty else {
                continue
            }
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
    }

    private func locateContract() throws -> URL {
        // QwenVoiceTests links the QwenVoice target, which bundles
        // `qwenvoice_contract.json` as a resource. Probe the test bundle
        // first, then fall back to the repo-relative checkout path so the
        // test still runs when invoked out-of-tree.
        let bundles = [Bundle(for: type(of: self))] + Bundle.allBundles
        for bundle in bundles {
            if let url = bundle.url(
                forResource: "qwenvoice_contract",
                withExtension: "json"
            ) {
                return url
            }
        }
        let fallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Resources/qwenvoice_contract.json")
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        throw CocoaError(.fileReadNoSuchFile)
    }
}
