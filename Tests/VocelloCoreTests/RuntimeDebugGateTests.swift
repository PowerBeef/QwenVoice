import XCTest
@testable import QwenVoiceCore

final class RuntimeDebugGateTests: XCTestCase {
    func testIndividualOverrideIsInertWithoutMasterGate() {
        let environment = ["QWENVOICE_STREAMING_OUTPUT_POLICY": "files"]

        XCTAssertFalse(RuntimeDebugGate.isEnabled(environment: environment))
        XCTAssertNil(RuntimeDebugGate.value(
            for: "QWENVOICE_STREAMING_OUTPUT_POLICY",
            environment: environment
        ))
        XCTAssertEqual(
            NativeStreamingOutputPolicy.current(environment: environment),
            .pcmPreview
        )
    }

    func testMasterGateEnablesRegisteredOverride() {
        let environment = [
            "QWENVOICE_DEBUG": "true",
            "QWENVOICE_STREAMING_OUTPUT_POLICY": "files",
        ]

        XCTAssertTrue(RuntimeDebugGate.isEnabled(environment: environment))
        XCTAssertEqual(
            RuntimeDebugGate.value(
                for: "QWENVOICE_STREAMING_OUTPUT_POLICY",
                environment: environment
            ),
            "files"
        )
        XCTAssertEqual(
            NativeStreamingOutputPolicy.current(environment: environment),
            .pcmPreviewAndFileArtifacts
        )
    }

    func testMasterGateParsingIsExplicit() {
        XCTAssertFalse(RuntimeDebugGate.isEnabled(environment: ["QWENVOICE_DEBUG": "enabled"]))
        XCTAssertTrue(RuntimeDebugGate.isEnabled(environment: ["QWENVOICE_DEBUG": "YES"]))
    }

    func testForceColdIsInertWhenTelemetryIsEnabledWithoutMasterGate() {
        let environment = [
            "QWENVOICE_NATIVE_TELEMETRY_MODE": "verbose",
            "QWENVOICE_BENCH_FORCE_COLD": "1",
        ]

        XCTAssertFalse(BenchForceColdPolicy.isRequested(
            environment: environment,
            telemetryEnabled: true
        ))
    }

    func testForceColdIsEnabledOnlyWhenTelemetryAndMasterGateAreEnabled() {
        let environment = [
            "QWENVOICE_DEBUG": "1",
            "QWENVOICE_NATIVE_TELEMETRY_MODE": "verbose",
            "QWENVOICE_BENCH_FORCE_COLD": "true",
        ]

        XCTAssertTrue(BenchForceColdPolicy.isRequested(
            environment: environment,
            telemetryEnabled: true
        ))
        XCTAssertFalse(BenchForceColdPolicy.isRequested(
            environment: environment,
            telemetryEnabled: false
        ))
    }
}
