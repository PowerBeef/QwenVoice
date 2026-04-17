import XCTest
@testable import QwenVoiceNative

final class NativeModelLoadCoordinatorTests: XCTestCase {
    func testLoadModelDeduplicatesConcurrentRequestsForSameModel() async throws {
        let coordinator = NativeModelLoadCoordinator()
        let counter = LoadCounter()

        async let first: Void = coordinator.loadModel(id: "pro_custom") {
            await counter.recordLoad()
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        async let second: Void = coordinator.loadModel(id: "pro_custom") {
            await counter.recordLoad()
            try await Task.sleep(nanoseconds: 150_000_000)
        }

        _ = try await (first, second)

        let loadCount = await counter.currentCount()
        let loadedModelID = await coordinator.currentLoadedModelID()

        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(loadedModelID, "pro_custom")
    }

    func testEnsureModelLoadedIfNeededSkipsAlreadyLoadedModel() async throws {
        let coordinator = NativeModelLoadCoordinator()
        let counter = LoadCounter()

        try await coordinator.loadModel(id: "pro_design") {
            await counter.recordLoad()
        }
        try await coordinator.ensureModelLoadedIfNeeded(id: "pro_design") {
            await counter.recordLoad()
        }

        let loadCount = await counter.currentCount()
        let loadedModelID = await coordinator.currentLoadedModelID()

        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(loadedModelID, "pro_design")
    }

    func testPrewarmKeysResetOnModelSwitchAndUnload() async throws {
        let coordinator = NativeModelLoadCoordinator()
        let customRequest = GenerationRequest(
            modelID: "pro_custom",
            text: "Hello",
            outputPath: "/tmp/custom.wav",
            payload: .custom(speakerID: "vivian", deliveryStyle: "Warm")
        )

        try await coordinator.prewarmIfNeeded(
            identityKey: GenerationSemantics.prewarmIdentityKey(for: customRequest),
            modelID: "pro_custom"
        ) {}
        let initiallyPrewarmed = await coordinator.isPrewarmed(
            identityKey: GenerationSemantics.prewarmIdentityKey(for: customRequest)
        )
        XCTAssertTrue(initiallyPrewarmed)

        try await coordinator.loadModel(id: "pro_clone") {}
        let prewarmClearedOnSwitch = await coordinator.isPrewarmed(
            identityKey: GenerationSemantics.prewarmIdentityKey(for: customRequest)
        )
        XCTAssertFalse(prewarmClearedOnSwitch)

        await coordinator.markPrewarmed(
            identityKey: GenerationSemantics.prewarmIdentityKey(for: customRequest)
        )
        await coordinator.unloadModel()

        let unloadedModelID = await coordinator.currentLoadedModelID()
        let prewarmClearedOnUnload = await coordinator.isPrewarmed(
            identityKey: GenerationSemantics.prewarmIdentityKey(for: customRequest)
        )

        XCTAssertNil(unloadedModelID)
        XCTAssertFalse(prewarmClearedOnUnload)
    }
}

private actor LoadCounter {
    private(set) var count = 0

    func recordLoad() {
        count += 1
    }

    func currentCount() -> Int {
        count
    }
}
