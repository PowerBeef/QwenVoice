import Foundation
import XCTest

/// Ordered, configurable physical-device benchmark. The default configuration
/// is the exact shared 29-take matrix; Clone is a hard prerequisite and is
/// never skipped.
@MainActor
final class VocelloiOSBenchmarkUITests: VocelloiOSUITestCase {
    func testOrderedConfigurableMatrix() throws {
        beginSession()
        defer { endSession() }

        let processEnvironment = ProcessInfo.processInfo.environment
        let configuration = try VocelloUIBenchMatrix.Configuration(
            environment: processEnvironment,
            keyPrefix: "QVOICE_IOS_BENCH"
        )
        let takes = VocelloUIBenchMatrix.takes(configuration: configuration)
        let runID = processEnvironment["QVOICE_IOS_BENCH_RUN_ID"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "ios-xcui-benchmark-\(UUID().uuidString.lowercased())"
        let label = processEnvironment["QVOICE_IOS_BENCH_LABEL"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? runID

        XCTAssertFalse(takes.isEmpty)
        if configuration == VocelloUIBenchMatrix.defaultConfiguration {
            XCTAssertEqual(takes, VocelloUIBenchMatrix.defaultTakes)
            XCTAssertEqual(takes.count, 29)
        }

        // Readiness is observed through Settings and Saved Voices before the
        // first generation; no headless inventory or model repair is invoked.
        assertVisibleModelReadiness()
        _ = assertRequiredCloneVoice()
        let autoplayWasEnabled = ensureAutoplayEnabled()
        defer { restoreAutoplayPreference(originallyEnabled: autoplayWasEnabled) }

        var previousTake: VocelloUIBenchMatrix.Take?
        var preparedMode: VocelloUIBenchMatrix.Mode?
        var completedCount = 0
        var generationMap: [[String: Any]] = []

        for (offset, take) in takes.enumerated() {
            // BenchForceColdPolicy consumes its flag once. A mode's cold take
            // and warm grid therefore remain in one process; only a mode
            // boundary starts a new process. Clone starts warm by definition.
            let requiresNewSession = previousTake == nil
                || previousTake?.mode != take.mode

            if requiresNewSession {
                launchApp(additionalEnvironment: [
                    "QVOICE_MAC_BENCH_RUN_ID": runID,
                    "QVOICE_IOS_BENCH_LABEL": label,
                    "QWENVOICE_BENCH_FORCE_COLD": take.warmState == .cold ? "1" : "0",
                ])
                preparedMode = nil
            }

            if preparedMode != take.mode {
                prepare(mode: take.mode)
                preparedMode = take.mode
            }

            let takeNumber = offset + 1
            print("[ios-xcui-benchmark] begin \(takeNumber)/\(takes.count) \(take.cellID)")
            XCTContext.runActivity(named: "Take \(takeNumber): \(take.cellID)") { _ in
                replaceScript(with: take.text)
                let generationID = generateAndWaitForCompletedPlayer(timeout: timeout(for: take))
                generationMap.append([
                    "takeIndex": takeNumber,
                    "cell": take.cellID,
                    "generationID": generationID,
                ])

                if take.warmState == .cold || offset == 0 || offset == takes.count - 1 {
                    VocelloUIScreenshot.attach(
                        app,
                        named: "ios-benchmark-\(takeNumber)-\(sanitized(take.cellID))"
                    )
                }

                dismissCompletedPlayerAndAssertGenerateReady()
            }
            print("[ios-xcui-benchmark] complete \(takeNumber)/\(takes.count) \(take.cellID)")
            completedCount += 1
            previousTake = take
        }

        XCTAssertEqual(completedCount, takes.count)
        let mapPayload: [String: Any] = [
            "schemaVersion": 1,
            "runID": runID,
            "takes": generationMap,
        ]
        let mapData = try JSONSerialization.data(withJSONObject: mapPayload, options: [.sortedKeys])
        let mapAttachment = XCTAttachment(data: mapData, uniformTypeIdentifier: "public.json")
        mapAttachment.name = "ios-benchmark-generation-map.json"
        mapAttachment.lifetime = .keepAlways
        add(mapAttachment)
        print("VOCELLO-BENCH-UI-MANIFEST ran=\(completedCount) runID=\(runID) skippedClone=false")
    }

    private func sanitized(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "#", with: "-")
    }
}
