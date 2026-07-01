import QwenVoiceCore
import XCTest

/// Catalog-driven macOS UI review captures (resting + post-generation states).
final class VocelloMacReviewUITests: VocelloMacHumanTestCase {
    private enum Capture: CaseIterable {
        case customResting
        case customReady
        case customPostGen
        case designReady
        case cloneReference
        case historyPopulated
        case voicesList
        case settingsModels

        var name: String {
            switch self {
            case .customResting: "review-custom-resting"
            case .customReady: "review-custom-ready"
            case .customPostGen: "review-custom-postgen"
            case .designReady: "review-design-ready"
            case .cloneReference: "review-clone-reference"
            case .historyPopulated: "review-history-populated"
            case .voicesList: "review-voices-list"
            case .settingsModels: "review-settings-models"
            }
        }

        var subset: ReviewSubset {
            switch self {
            case .customResting, .designReady, .voicesList, .settingsModels:
                .resting
            default:
                .full
            }
        }
    }

    private enum ReviewSubset: String {
        case resting
        case full
    }

    func testCaptureReviewCatalog() throws {
        let subset = ReviewSubset(
            rawValue: ProcessInfo.processInfo.environment["QVOICE_MAC_REVIEW_SUBSET"] ?? "full"
        ) ?? .full

        for capture in Capture.allCases {
            if subset == .resting && capture.subset != .resting { continue }
            try prepare(capture)
            VocelloMacTestSupport.captureScreenshot(app, named: capture.name)
        }
    }

    private func prepare(_ capture: Capture) throws {
        switch capture {
        case .customResting:
            navigateSidebar("customVoice")
            XCTAssertTrue(element("screen_customVoice").waitForExistence(timeout: 15))
        case .customReady:
            try skipIfDisabled("customVoice")
            navigateSidebar("customVoice")
            typeScript("Review ready state.")
            _ = VocelloMacUIQuery.waitForMarkerValue(
                app,
                identifier: "customVoice_readiness",
                contains: "ready=true",
                timeout: 30
            )
        case .customPostGen:
            try skipIfDisabled("customVoice")
            navigateSidebar("customVoice")
            typeScript("Review post-generation capture.")
            try generateAndWaitForPlayer(modeLabel: "Custom Voice")
        case .designReady:
            try skipIfDisabled("voiceDesign")
            navigateSidebar("voiceDesign")
            fillVoiceBrief()
            // Readiness requires BOTH a voice brief and script text (canGenerate
            // gates on draft.hasText && draft.hasVoiceDescription).
            typeScript("Review ready state.")
            _ = VocelloMacUIQuery.waitForMarkerValue(
                app,
                identifier: "voiceDesign_readiness",
                contains: "ready=true",
                timeout: 30
            )
        case .cloneReference:
            try skipIfDisabled("voiceCloning")
            openCloneVoiceFromSavedVoices(named: BenchMatrixSpec.defaultCloneVoice)
        case .historyPopulated:
            try skipIfDisabled("customVoice")
            navigateSidebar("customVoice")
            typeScript("History population capture.")
            try generateAndWaitForPlayer(modeLabel: "Custom Voice")
            navigateSidebar("history")
            XCTAssertTrue(element("screen_history").waitForExistence(timeout: 15))
        case .voicesList:
            try skipIfDisabled("voices")
            navigateSidebar("voices")
            XCTAssertTrue(element("screen_voices").waitForExistence(timeout: 15))
        case .settingsModels:
            navigateSidebar("settings")
            XCTAssertTrue(element("settings_modelDownloadsSummary").waitForExistence(timeout: 15))
        }
    }
}
