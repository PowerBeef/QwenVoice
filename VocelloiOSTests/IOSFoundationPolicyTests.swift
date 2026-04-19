import XCTest
@testable import QVoiceiOS
@testable import QwenVoiceCore

final class IOSFoundationPolicyTests: XCTestCase {
    func testAppPathsResolveAbsoluteAndRelativeOverrides() {
        let absolute = AppPaths.resolvedAppSupportDir(
            environment: [AppPaths.appSupportOverrideEnvironmentKey: "/tmp/vocello-override"]
        )
        XCTAssertEqual(absolute.path, "/tmp/vocello-override")

        let relative = AppPaths.resolvedAppSupportDir(
            environment: [AppPaths.appSupportOverrideEnvironmentKey: "sandbox/dev"]
        )
        XCTAssertEqual(
            relative.path,
            AppPaths.managedAppSupportDir
                .appendingPathComponent("sandbox/dev", isDirectory: true)
                .path
        )
    }

    func testAppPathsShareAppGroupIdentifierWithFoundationExpectations() {
        XCTAssertEqual(AppPaths.sharedAppGroupIdentifier, "group.com.qvoice.shared")
    }

    func testCapabilityMatrixMatchesIOSFoundationExpectations() throws {
        let matrix = try loadMatrix()

        XCTAssertEqual(
            matrix.iOS.app.applicationGroups,
            [AppPaths.sharedAppGroupIdentifier]
        )
        XCTAssertEqual(
            matrix.iOS.app.engineCapabilities,
            EngineCapabilities(
                supportsBatchGeneration: false,
                supportsAudioPreparation: false,
                supportsInteractivePrefetch: false,
                supportsMemoryTrim: false,
                supportsPreparedVoiceManagement: true
            )
        )
        XCTAssertEqual(
            matrix.iOS.extension.engineCapabilities,
            EngineCapabilities.iOSExtensionDefault
        )
    }

    func testIOSMemoryBudgetPolicyBandsAdmissionAndTrimLevels() {
        let policy = IOSMemoryBudgetPolicy.iPhoneShippingDefault

        let healthySnapshot = IOSMemorySnapshot(
            totalDeviceRAMBytes: 8 * 1_073_741_824,
            availableHeadroomBytes: policy.healthyHeadroomBytes + 1,
            residentBytes: nil,
            physFootprintBytes: nil,
            compressedBytes: nil,
            gpuAllocatedBytes: 10,
            gpuRecommendedWorkingSetBytes: 1_000,
            hasUnifiedMemory: true
        )
        XCTAssertEqual(policy.band(for: healthySnapshot), .healthy)
        XCTAssertTrue(policy.allowsModelAdmission(for: .healthy))
        XCTAssertTrue(policy.allowsProactiveWarmOperations(for: .healthy))
        XCTAssertNil(policy.postGenerationTrimLevel(for: .healthy))

        let guardedSnapshot = IOSMemorySnapshot(
            totalDeviceRAMBytes: 8 * 1_073_741_824,
            availableHeadroomBytes: policy.guardedHeadroomBytes + 1,
            residentBytes: nil,
            physFootprintBytes: nil,
            compressedBytes: nil,
            gpuAllocatedBytes: 10,
            gpuRecommendedWorkingSetBytes: 1_000,
            hasUnifiedMemory: true
        )
        XCTAssertEqual(policy.band(for: guardedSnapshot), .guarded)
        XCTAssertTrue(policy.allowsModelAdmission(for: .guarded))
        XCTAssertFalse(policy.allowsProactiveWarmOperations(for: .guarded))
        XCTAssertEqual(policy.postGenerationTrimLevel(for: .guarded), .hardTrim)

        let criticalSnapshot = IOSMemorySnapshot(
            totalDeviceRAMBytes: 8 * 1_073_741_824,
            availableHeadroomBytes: policy.guardedHeadroomBytes - 1,
            residentBytes: nil,
            physFootprintBytes: nil,
            compressedBytes: nil,
            gpuAllocatedBytes: 900,
            gpuRecommendedWorkingSetBytes: 1_000,
            hasUnifiedMemory: true
        )
        XCTAssertEqual(policy.band(for: criticalSnapshot), .critical)
        XCTAssertFalse(policy.allowsModelAdmission(for: .critical))
        XCTAssertFalse(policy.allowsProactiveWarmOperations(for: .critical))
        XCTAssertEqual(policy.postGenerationTrimLevel(for: .critical), .fullUnload)
        XCTAssertEqual(
            policy.trimLevelForPressureEvent(
                snapshot: criticalSnapshot,
                isBackgroundTransition: false
            ),
            .fullUnload
        )
        XCTAssertEqual(
            policy.trimLevelForPressureEvent(
                snapshot: healthySnapshot,
                isBackgroundTransition: true
            ),
            .fullUnload
        )
    }

    private func loadMatrix() throws -> PlatformCapabilityMatrix {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let matrixURL = repoRoot
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("apple-platform-capability-matrix.json", isDirectory: false)
        let data = try Data(contentsOf: matrixURL)
        return try JSONDecoder().decode(PlatformCapabilityMatrix.self, from: data)
    }
}

private struct PlatformCapabilityMatrix: Decodable {
    let iOS: IOSPlatform

    private enum CodingKeys: String, CodingKey {
        case iOS = "iOS"
    }

    struct IOSPlatform: Decodable {
        let app: RuntimeSurface
        let `extension`: RuntimeSurface
    }

    struct RuntimeSurface: Decodable {
        let applicationGroups: [String]
        let engineCapabilities: EngineCapabilities
    }
}
