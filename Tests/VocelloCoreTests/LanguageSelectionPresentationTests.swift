import QwenVoiceCore
import XCTest

final class LanguageSelectionPresentationTests: XCTestCase {
    func testEffectiveFollowsDetectionWhileAutoSelected() {
        XCTAssertEqual(
            LanguageSelectionPresentation.effective(selected: .auto, detected: .french),
            .french
        )
        XCTAssertEqual(
            LanguageSelectionPresentation.effective(selected: .auto, detected: .auto),
            .auto
        )
        XCTAssertEqual(
            LanguageSelectionPresentation.effective(selected: .german, detected: .french),
            .german
        )
    }

    func testButtonLabelUsesEffectiveLanguageName() {
        XCTAssertEqual(
            LanguageSelectionPresentation.buttonLabel(selected: .auto, detected: .french),
            Qwen3SupportedLanguage.french.displayName
        )
        XCTAssertEqual(
            LanguageSelectionPresentation.buttonLabel(selected: .auto, detected: .auto),
            Qwen3SupportedLanguage.auto.displayName
        )
        XCTAssertEqual(
            LanguageSelectionPresentation.buttonLabel(selected: .spanish, detected: .french),
            Qwen3SupportedLanguage.spanish.displayName
        )
    }

    func testIsFollowingDetection() {
        XCTAssertTrue(
            LanguageSelectionPresentation.isFollowingDetection(selected: .auto, detected: .english)
        )
        XCTAssertFalse(
            LanguageSelectionPresentation.isFollowingDetection(selected: .auto, detected: .auto)
        )
        XCTAssertFalse(
            LanguageSelectionPresentation.isFollowingDetection(selected: .french, detected: .english)
        )
    }
}
