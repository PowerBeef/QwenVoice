import Foundation
import Darwin
@preconcurrency import XCTest

@MainActor
final class VocelloMacBenchmarkUITests: VocelloMacUITestCase {
    private static let takeFile = URL(fileURLWithPath: "/tmp/vocello-bench-current-take.json")

    func testOrderedConfigurableMatrix() throws {
        beginSession()
        defer { endSession() }

        let processEnvironment = ProcessInfo.processInfo.environment
        let configuration = try VocelloUIBenchMatrix.Configuration(
            environment: processEnvironment,
            keyPrefix: "QVOICE_MAC_BENCH"
        )
        let takes = VocelloUIBenchMatrix.takes(configuration: configuration)
        let runID = processEnvironment["QVOICE_MAC_BENCH_RUN_ID"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "mac-xcui-benchmark-\(UUID().uuidString.lowercased())"
        let label = processEnvironment["QVOICE_MAC_BENCH_LABEL"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? runID

        XCTAssertFalse(takes.isEmpty)
        if configuration == VocelloUIBenchMatrix.defaultConfiguration {
            XCTAssertEqual(takes, VocelloUIBenchMatrix.defaultTakes)
            XCTAssertEqual(takes.count, 29)
        }

        assertVisibleSpeedModelReadiness()
        assertSavedCloneVoice()
        let autoplayWasEnabled = ensureAutoplayEnabled()
        defer { restoreAutoplayPreference(originallyEnabled: autoplayWasEnabled) }

        var preparedMode: VocelloUIBenchMatrix.Mode?
        for (offset, take) in takes.enumerated() {
            let takeIndex = offset + 1
            guard publishCurrentTakeManifest(
                runID: runID,
                takeIndex: takeIndex,
                cell: take.cellID,
                intendedWarmState: take.warmState.rawValue
            ) else {
                return
            }

            let previous = offset > 0 ? takes[offset - 1] : nil
            let requiresNewSession = offset == 0
                || take.warmState == .cold
                || (take.mode == .clone && previous?.mode != .clone)
            if requiresNewSession {
                relaunchApp(
                    additionalEnvironment: launchEnvironment(
                        runID: runID,
                        label: label,
                        takeIndex: takeIndex,
                        take: take
                    )
                )
                preparedMode = nil
            }

            if preparedMode != take.mode {
                prepare(mode: take.mode)
                preparedMode = take.mode
            }

            XCTContext.runActivity(named: "Take \(takeIndex): \(take.cellID)") { _ in
                replaceScript(with: take.text)
                generateAndWaitForCompletion(mode: take.mode, timeout: timeout(for: take))

                if take.warmState == .cold || offset == 0 || offset == takes.count - 1 {
                    VocelloUIScreenshot.attach(
                        app,
                        named: "mac-benchmark-\(takeIndex)-\(sanitized(take.cellID))"
                    )
                }
            }
        }
    }

    private func launchEnvironment(
        runID: String,
        label: String,
        takeIndex: Int,
        take: VocelloUIBenchMatrix.Take
    ) -> [String: String] {
        var environment = [
            "QVOICE_MAC_BENCH_RUN_ID": runID,
            "QVOICE_MAC_BENCH_TAKE_INDEX": String(takeIndex),
            "QVOICE_MAC_BENCH_CELL": take.cellID,
            "QVOICE_MAC_BENCH_WARM_STATE": take.warmState.rawValue,
        ]
        environment["QVOICE_MAC_BENCH_LABEL"] = label
        environment["QWENVOICE_BENCH_FORCE_COLD"] = take.warmState == .cold ? "1" : "0"
        if take.mode != .clone {
            environment["QWENVOICE_SUPPRESS_WARMUP"] = "1"
        }
        return environment
    }

    private func publishCurrentTakeManifest(
        runID: String,
        takeIndex: Int,
        cell: String,
        intendedWarmState: String
    ) -> Bool {
        let payload = [
            "benchRunID": runID,
            "benchTakeIndex": String(takeIndex),
            "benchCell": cell,
            "benchWarmState": intendedWarmState,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            XCTFail("Could not encode benchmark take manifest")
            return false
        }
        print("VOCELLO_BENCH_TAKE_MANIFEST=\(data.base64EncodedString())")
        fflush(stdout)
        return VocelloUIWait.condition(
            "shell runner to publish take \(takeIndex) metadata",
            timeout: 10
        ) {
            (try? Data(contentsOf: Self.takeFile)) == data
        }
    }

    private func sanitized(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "#", with: "-")
    }
}
