import Foundation
import XCTest
@testable import QwenVoiceCore

/// Smoke tests for the Session 5b mock infrastructure
/// (`MockMLXModelCoordinator` + `MLXTTSEngine.makeForTesting`). These
/// validate that `MLXTTSEngine` can be driven through its internal
/// load-coordinator seam without touching MLX, so the bulk test port in
/// Session 5c can rely on the recipe.
///
/// Coverage here is intentionally minimal — the goal is to prove the
/// seam works end-to-end, not to duplicate the 19 tests in
/// `NativeMLXMacEngineTests` (those land against the same recipe in
/// Session 5c).
@MainActor
final class MLXTTSEngineMockBackedTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        temporaryRoot = try Self.makeTemporaryRoot()
    }

    override func tearDown() async throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
        try await super.tearDown()
    }

    func testEngineSurfacesMockLoadFailureAndKeepsCurrentLoadedModelIDNil() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator()
        let engine = MLXTTSEngine.makeForTesting(
            modelRegistry: registry,
            rootDirectory: temporaryRoot,
            loadCoordinator: coordinator
        )
        try await engine.initialize(appSupportDirectory: temporaryRoot)

        XCTAssertEqual(engine.loadState, .idle)
        let preLoadID = await engine.currentLoadedModelID()
        XCTAssertNil(preLoadID)

        var didThrow = false
        do {
            try await engine.loadModel(id: "qwen3_custom_voice")
        } catch {
            didThrow = true
        }
        XCTAssertTrue(didThrow, "Expected loadModel to throw when the mock coordinator's loadHandler is nil.")

        XCTAssertEqual(coordinator.loadCalls.count, 1)
        XCTAssertEqual(coordinator.loadCalls.first?.modelID, "qwen3_custom_voice")
        let postLoadID = await engine.currentLoadedModelID()
        XCTAssertNil(postLoadID)
        if case .failed = engine.loadState {
            // Expected
        } else {
            XCTFail("Expected loadState to be .failed after the mock coordinator threw, got \(engine.loadState)")
        }
        XCTAssertNotNil(engine.visibleErrorMessage)
    }

    func testEngineUnloadInvokesMockCoordinatorAndClearsLoadState() async throws {
        let registry = try ContractBackedModelRegistry(
            manifestURL: try Self.bundledManifestURL()
        )
        let coordinator = MockMLXModelCoordinator()
        let engine = MLXTTSEngine.makeForTesting(
            modelRegistry: registry,
            rootDirectory: temporaryRoot,
            loadCoordinator: coordinator
        )
        try await engine.initialize(appSupportDirectory: temporaryRoot)

        try await engine.unloadModel()

        XCTAssertEqual(coordinator.unloadCallCount, 1)
        XCTAssertEqual(engine.loadState, .idle)
        let loadedID = await engine.currentLoadedModelID()
        XCTAssertNil(loadedID)
    }

    // MARK: - Helpers

    private static func makeTemporaryRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXTTSEngineMockBackedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func bundledManifestURL() throws -> URL {
        let bundles = [Bundle.main, Bundle(for: BundleLocator.self)] + Bundle.allBundles + Bundle.allFrameworks
        for bundle in bundles {
            if let url = bundle.url(forResource: "qwenvoice_contract", withExtension: "json") {
                return url
            }
        }
        throw NSError(
            domain: "MLXTTSEngineMockBackedTests",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate qwenvoice_contract.json in any test bundle."]
        )
    }

    private final class BundleLocator: NSObject {}
}
