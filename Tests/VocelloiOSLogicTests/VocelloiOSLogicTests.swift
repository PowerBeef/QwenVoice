import Foundation
import QwenVoiceCore
import XCTest

/// Pure iOS policy tests. This bundle has no application host, performs no
/// network requests, loads no model, and is never routed through Simulator.
final class VocelloiOSLogicTests: XCTestCase {
    private let immutableRevision = String(repeating: "a", count: 40)
    private let digest = String(repeating: "b", count: 64)

    func testCatalogValidationAcceptsPinnedHTTPSArtifact() throws {
        let configuration = IOSModelDeliveryConfiguration(
            catalogURL: try XCTUnwrap(URL(string: "bundle://vocello/ios/catalog/v1/models.json")),
            allowedHosts: ["huggingface.co"],
            backgroundSessionIdentifier: "com.patricedery.vocello.logic-tests"
        )
        let entry = IOSModelCatalogEntry(
            modelID: "model-speed",
            artifactVersion: "v1",
            totalBytes: 42,
            baseURL: try XCTUnwrap(URL(string: "https://huggingface.co/example/model/resolve/\(immutableRevision)/")),
            files: [
                IOSModelCatalogFile(
                    relativePath: "weights/model.safetensors",
                    sizeBytes: 42,
                    sha256: digest,
                    url: nil
                ),
            ]
        )

        XCTAssertNoThrow(try IOSModelDeliverySupport.validate(entry: entry, configuration: configuration))
        XCTAssertEqual(
            try IOSModelDeliverySupport.downloadURL(
                for: entry.files[0],
                entry: entry,
                configuration: configuration
            ).scheme,
            "https"
        )
    }

    func testCatalogValidationRejectsMutableOrUnsafeArtifactRoute() throws {
        let configuration = IOSModelDeliveryConfiguration(
            catalogURL: try XCTUnwrap(URL(string: "bundle://vocello/ios/catalog/v1/models.json")),
            allowedHosts: ["huggingface.co"],
            backgroundSessionIdentifier: "com.patricedery.vocello.logic-tests"
        )
        let entry = IOSModelCatalogEntry(
            modelID: "model-speed",
            artifactVersion: "v1",
            totalBytes: 42,
            baseURL: try XCTUnwrap(URL(string: "http://huggingface.co/example/model/resolve/main/")),
            files: [
                IOSModelCatalogFile(
                    relativePath: "weights/model.safetensors",
                    sizeBytes: 42,
                    sha256: digest,
                    url: nil
                ),
            ]
        )

        XCTAssertThrowsError(try IOSModelDeliverySupport.validate(entry: entry, configuration: configuration))
    }

    func testLedgerRoundTripPreservesTerminalAndByteState() throws {
        let request = IOSModelDownloadLedger.Request(
            logicalRequestID: "request-a",
            modelID: "model-speed",
            artifactVersion: "v1",
            repo: "example/model",
            revision: immutableRevision,
            targetFolder: "model-speed",
            expectedFiles: ["weights/model.safetensors"],
            verifiedFiles: [
                IOSModelDownloadLedger.VerifiedFile(
                    relativePath: "weights/model.safetensors",
                    expectedSize: 42,
                    sha256: digest
                ),
            ],
            retryCount: 1,
            receivedBytes: 42,
            totalBytes: 42,
            status: .installed
        )
        let ledger = try IOSModelDownloadLedger(requests: [request]).validated()
        let decoded = try JSONDecoder().decode(
            IOSModelDownloadLedger.self,
            from: JSONEncoder().encode(ledger)
        )

        XCTAssertEqual(try decoded.validated(), ledger)
        XCTAssertEqual(decoded.requests.first?.status, .installed)
    }

    func testMemoryPolicyClassifiesHeadroomAndTrimDeterministically() {
        let policy = IOSMemoryBudgetPolicy.iPhoneShippingDefault
        let mebibyte = UInt64(1_048_576)
        let healthy = snapshot(headroom: 900 * mebibyte, footprint: 2_000 * mebibyte)
        let guarded = snapshot(headroom: 500 * mebibyte, footprint: 2_000 * mebibyte)
        let critical = snapshot(headroom: 300 * mebibyte, footprint: 2_000 * mebibyte)

        XCTAssertEqual(policy.band(for: healthy), .healthy)
        XCTAssertEqual(policy.band(for: guarded), .guarded)
        XCTAssertEqual(policy.band(for: critical), .critical)
        XCTAssertEqual(policy.trimLevelForPressureEvent(snapshot: guarded, isBackgroundTransition: false), .hardTrim)
        XCTAssertEqual(policy.trimLevelForPressureEvent(snapshot: healthy, isBackgroundTransition: true), .fullUnload)
    }

    func testCancellationReasonIsTypedAndRoundTrips() throws {
        let summary = GenerationCancellationSummary(
            generationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
            reason: .memoryPressure
        )
        let decoded = try JSONDecoder().decode(
            GenerationCancellationSummary.self,
            from: JSONEncoder().encode(summary)
        )

        XCTAssertEqual(decoded, summary)
        XCTAssertEqual(decoded.reason, .memoryPressure)
    }

    func testAppSupportOverrideRequiresExplicitDebugGateAndAbsolutePath() {
        let override = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocello-ios-logic", isDirectory: true)
            .standardizedFileURL

        XCTAssertNotEqual(
            AppPaths.resolvedAppSupportDir(environment: [
                AppPaths.appSupportOverrideEnvironmentKey: override.path,
            ]),
            override
        )
        XCTAssertNotEqual(
            AppPaths.resolvedAppSupportDir(environment: [
                "QWENVOICE_DEBUG": "1",
                AppPaths.appSupportOverrideEnvironmentKey: "relative/path",
            ]),
            URL(fileURLWithPath: "relative/path", isDirectory: true).standardizedFileURL
        )
        XCTAssertEqual(
            AppPaths.resolvedAppSupportDir(environment: [
                "QWENVOICE_DEBUG": "1",
                AppPaths.appSupportOverrideEnvironmentKey: override.path,
            ]),
            override
        )
    }

    func testFailureDiagnosticsRedactPrivateRoutes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelDownloadDiagnosticsStore(directory: root)
        store.recordFailure(
            classification: "network/failure",
            message: "request https://example.invalid/private failed in /private/var/mobile/fixture"
        )

        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first
        )
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("example.invalid"))
        XCTAssertFalse(text.contains("/private/var"))
        XCTAssertTrue(text.contains("redacted-url"))
        XCTAssertTrue(text.contains("redacted-path"))
    }

    private func snapshot(headroom: UInt64, footprint: UInt64) -> IOSMemorySnapshot {
        IOSMemorySnapshot(
            processRole: .app,
            pid: 1,
            capturedAtUptimeSeconds: 1,
            totalDeviceRAMBytes: 8_000 * 1_048_576,
            availableHeadroomBytes: headroom,
            residentBytes: footprint,
            physFootprintBytes: footprint,
            compressedBytes: 0,
            gpuAllocatedBytes: nil,
            gpuRecommendedWorkingSetBytes: nil,
            hasUnifiedMemory: true
        )
    }
}
