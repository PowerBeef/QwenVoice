import XCTest

final class PerformanceAuditTests: QwenVoiceUITestBase {
    @MainActor
    func testAppLaunchToReady() {
        app.terminate()
        sleep(1)

        configureAppForLaunch()

        let start = Date()
        app.launch()

        let foreground = app.wait(for: .runningForeground, timeout: 10)
        XCTAssertTrue(foreground, "App should reach foreground")
        waitForReadiness(timeout: 60)
        let elapsed = Date().timeIntervalSince(start) * 1000

        let attachment = XCTAttachment(string: "{\"launch_to_ready_ms\": \(Int(elapsed)), \"backend_mode\": \"\(uiTestBackendMode.rawValue)\", \"data_root\": \"\(uiTestDataRoot.rawValue)\"}")
        attachment.name = "perf_launch_timing"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testSidebarNavigationLatency() {
        let screens: [(String, String)] = [
            ("sidebar_voiceDesign", "screen_voiceDesign"),
            ("sidebar_voiceCloning", "screen_voiceCloning"),
            ("sidebar_history", "screen_history"),
            ("sidebar_models", "screen_models"),
            ("sidebar_customVoice", "screen_customVoice"),
        ]

        var timings: [String: [Int]] = [:]

        for _ in 0..<2 {
            for (sidebarID, screenID) in screens {
                let start = Date()
                navigateToExpectingActiveScreen(sidebarID, expectScreen: screenID, timeout: 15)
                let elapsed = Date().timeIntervalSince(start) * 1000
                timings[screenID, default: []].append(Int(elapsed))
            }
        }

        if let data = try? JSONSerialization.data(withJSONObject: timings),
           let json = String(data: data, encoding: .utf8) {
            let attachment = XCTAttachment(string: json)
            attachment.name = "perf_navigation_timings"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
