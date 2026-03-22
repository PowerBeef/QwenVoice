import XCTest

final class PerformanceAuditTests: QwenVoiceUITestBase {
    func testAppLaunchToReady() {
        // Base setUp() already launched and waited for readiness.
        // Terminate and re-launch to measure timing.
        app.terminate()
        sleep(1)

        app.launchArguments = ["--uitest", "--uitest-disable-animations", "--uitest-fast-idle"]
        app.launchEnvironment = [
            "QWENVOICE_UI_TEST": "1",
            "QWENVOICE_UI_TEST_BACKEND_MODE": "stub",
            "QWENVOICE_UI_TEST_SETUP_SCENARIO": "success",
            "QWENVOICE_UI_TEST_SETUP_DELAY_MS": "1",
        ]

        let start = Date()
        app.launch()

        let foreground = app.wait(for: .runningForeground, timeout: 10)
        XCTAssertTrue(foreground, "App should reach foreground")

        let marker = app.descendants(matching: .any)["mainWindow_ready"]
        let appeared = marker.waitForExistence(timeout: 15)
        let elapsed = Date().timeIntervalSince(start) * 1000

        XCTAssertTrue(appeared, "App should become ready")
        XCTAssertLessThan(elapsed, 5000, "Launch to ready should be under 5000ms (stub mode), was \(Int(elapsed))ms")

        let attachment = XCTAttachment(string: "{\"launch_to_ready_ms\": \(Int(elapsed))}")
        attachment.name = "perf_launch_timing"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSidebarNavigationLatency() {
        let screens: [(String, String)] = [
            ("sidebar_history", "screen_history"),
            ("sidebar_models", "screen_models"),
            ("sidebar_customVoice", "screen_customVoice"),
        ]

        var timings: [String: Int] = [:]

        for (sidebarID, screenID) in screens {
            let start = Date()
            navigateTo(sidebarID, expectScreen: screenID)
            let elapsed = Date().timeIntervalSince(start) * 1000
            timings[screenID] = Int(elapsed)
            XCTAssertLessThan(elapsed, 5000, "Navigation to \(screenID) should be under 5000ms, was \(Int(elapsed))ms")
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
