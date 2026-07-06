import QwenVoiceCore
import XCTest

final class Qwen3SupportedLanguageTests: XCTestCase {
    func testNormalizedAliases() {
        XCTAssertEqual(Qwen3SupportedLanguage.normalized(nil), .auto)
        XCTAssertEqual(Qwen3SupportedLanguage.normalized(""), .auto)
        XCTAssertEqual(Qwen3SupportedLanguage.normalized("automatic"), .auto)
        XCTAssertEqual(Qwen3SupportedLanguage.normalized("fr-FR"), .french)
        XCTAssertEqual(Qwen3SupportedLanguage.normalized("zh-Hans"), .chinese)
        XCTAssertEqual(Qwen3SupportedLanguage.normalized("mandarin"), .chinese)
        XCTAssertEqual(Qwen3SupportedLanguage.normalized("en_GB"), .english)
        XCTAssertEqual(Qwen3SupportedLanguage.normalized("jp"), .japanese)
        XCTAssertEqual(Qwen3SupportedLanguage.normalized("pt-BR"), .portuguese)
        XCTAssertEqual(Qwen3SupportedLanguage.normalized("unknown-lang"), .auto)
    }

    func testNativeLanguageFallsBackToEnglishForAuto() {
        XCTAssertEqual(Qwen3SupportedLanguage.nativeLanguage("auto"), .english)
        XCTAssertEqual(Qwen3SupportedLanguage.nativeLanguage(nil), .english)
        XCTAssertEqual(Qwen3SupportedLanguage.nativeLanguage("french"), .french)
    }

    func testSelectableCasesExcludeAuto() {
        XCTAssertFalse(Qwen3SupportedLanguage.selectableCases.contains(.auto))
        XCTAssertEqual(
            Qwen3SupportedLanguage.selectableCases.count,
            Qwen3SupportedLanguage.allCases.count - 1
        )
    }

    func testSelectableRawValuesRoundTripThroughNormalized() {
        for language in Qwen3SupportedLanguage.selectableCases {
            XCTAssertEqual(
                Qwen3SupportedLanguage.normalized(language.rawValue),
                language,
                "expected stable raw value for \(language.rawValue)"
            )
        }
    }
}
