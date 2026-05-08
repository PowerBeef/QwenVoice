import XCTest
@testable import QwenVoiceBackendCore

final class QwenVoiceBackendCoreTests: XCTestCase {
    func testBackendProvenanceRecordsUpstreamV012Seed() {
        XCTAssertEqual(
            QwenVoiceBackendProvenance.upstreamRepository,
            "https://github.com/Blaizzy/mlx-audio-swift"
        )
        XCTAssertEqual(QwenVoiceBackendProvenance.upstreamTag, "v0.1.2")
        XCTAssertEqual(
            QwenVoiceBackendProvenance.upstreamCommit,
            "fcbd04daa1bfebe881932f630af2ba6ce9af3274"
        )
        XCTAssertEqual(QwenVoiceBackendProvenance.upstreamCommit.count, 40)
        XCTAssertEqual(
            QwenVoiceBackendProvenance.officialQwen3Repository,
            "https://github.com/QwenLM/Qwen3-TTS"
        )
    }

    func testOfficialQwen3GenerationConfigurationMatchesQualityDefaults() {
        let configuration = Qwen3GenerationConfiguration.officialQualityDefault

        XCTAssertEqual(configuration.maxNewTokens, 2_048)
        XCTAssertEqual(configuration.minNewTokens, 2)
        XCTAssertEqual(configuration.temperature, 0.9, accuracy: 0.0001)
        XCTAssertEqual(configuration.topK, 50)
        XCTAssertEqual(configuration.topP, 1.0, accuracy: 0.0001)
        XCTAssertEqual(configuration.repetitionPenalty, 1.05, accuracy: 0.0001)
    }
}
