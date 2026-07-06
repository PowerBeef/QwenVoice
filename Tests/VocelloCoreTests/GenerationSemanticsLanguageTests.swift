import QwenVoiceCore
import XCTest

final class GenerationSemanticsLanguageTests: XCTestCase {
    func testPinnedLanguageWinsOverScriptDetection() {
        let request = LanguageTestSupport.makeRequest(
            mode: .custom,
            text: LanguageFixtures.french,
            languageHint: Qwen3SupportedLanguage.english.rawValue
        )
        XCTAssertEqual(
            GenerationSemantics.qwenLanguageHint(for: request),
            Qwen3SupportedLanguage.english.rawValue
        )
    }

    func testCustomAutoDetectsFrenchScript() {
        let request = LanguageTestSupport.makeRequest(
            mode: .custom,
            text: LanguageFixtures.french,
            languageHint: Qwen3SupportedLanguage.auto.rawValue
        )
        XCTAssertEqual(
            GenerationSemantics.qwenLanguageHint(for: request),
            Qwen3SupportedLanguage.french.rawValue
        )
    }

    func testCustomAutoFallsBackToEnglishWhenUndetected() {
        let request = LanguageTestSupport.makeRequest(
            mode: .custom,
            text: LanguageFixtures.tooShort,
            languageHint: Qwen3SupportedLanguage.auto.rawValue
        )
        XCTAssertEqual(
            GenerationSemantics.qwenLanguageHint(for: request),
            GenerationSemantics.canonicalCustomWarmLanguage
        )
    }

    func testDesignAutoFallsBackToAutoWhenUndetected() {
        let request = LanguageTestSupport.makeRequest(
            mode: .design,
            text: LanguageFixtures.ambiguousLatin,
            languageHint: Qwen3SupportedLanguage.auto.rawValue
        )
        XCTAssertEqual(
            GenerationSemantics.qwenLanguageHint(for: request),
            Qwen3SupportedLanguage.auto.rawValue
        )
    }

    func testDesignAutoDetectsSpanishScript() {
        let request = LanguageTestSupport.makeRequest(
            mode: .design,
            text: LanguageFixtures.spanish,
            languageHint: Qwen3SupportedLanguage.auto.rawValue
        )
        XCTAssertEqual(
            GenerationSemantics.qwenLanguageHint(for: request),
            Qwen3SupportedLanguage.spanish.rawValue
        )
    }

    func testCloneUsesResolvedTranscriptBeforeTargetText() {
        let request = LanguageTestSupport.makeRequest(
            mode: .clone,
            text: LanguageFixtures.english,
            languageHint: Qwen3SupportedLanguage.auto.rawValue
        )
        XCTAssertEqual(
            GenerationSemantics.qwenLanguageHint(
                for: request,
                resolvedCloneTranscript: LanguageFixtures.french
            ),
            Qwen3SupportedLanguage.french.rawValue
        )
    }

    func testCloneAutoDetectsFromTargetTextWhenTranscriptMissing() {
        let request = LanguageTestSupport.makeRequest(
            mode: .clone,
            text: LanguageFixtures.german,
            languageHint: Qwen3SupportedLanguage.auto.rawValue
        )
        XCTAssertEqual(
            GenerationSemantics.qwenLanguageHint(for: request),
            Qwen3SupportedLanguage.german.rawValue
        )
    }

    func testUnicodeFastPaths() {
        let cases: [(String, Qwen3SupportedLanguage)] = [
            (LanguageFixtures.japanese, .japanese),
            (LanguageFixtures.korean, .korean),
            (LanguageFixtures.russian, .russian),
            (LanguageFixtures.chinese, .chinese),
        ]
        for (text, expected) in cases {
            let request = LanguageTestSupport.makeRequest(
                mode: .custom,
                text: text,
                languageHint: Qwen3SupportedLanguage.auto.rawValue
            )
            XCTAssertEqual(
                GenerationSemantics.qwenLanguageHint(for: request),
                expected.rawValue,
                "expected \(expected.rawValue) for script snippet"
            )
        }
    }

    func testOmittedLanguageHintBehavesLikeAutoForCustom() {
        let request = LanguageTestSupport.makeRequest(
            mode: .custom,
            text: LanguageFixtures.italian,
            languageHint: nil
        )
        XCTAssertEqual(
            GenerationSemantics.qwenLanguageHint(for: request),
            Qwen3SupportedLanguage.italian.rawValue
        )
    }
}
