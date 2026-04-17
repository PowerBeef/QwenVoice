import UniformTypeIdentifiers
import XCTest
@testable import QwenVoice

final class VoiceCloningReferenceAudioSupportTests: XCTestCase {
    func testAllowedFileExtensionsIncludeWebM() {
        XCTAssertTrue(
            VoiceCloningReferenceAudioSupport.allowedFileExtensions.contains("webm")
        )
    }

    func testSupportedFormatDescriptionMentionsWebM() {
        XCTAssertEqual(
            VoiceCloningReferenceAudioSupport.supportedFormatDescription,
            "WAV, MP3, AIFF, M4A, FLAC, OGG, or WebM"
        )
    }

    func testOpenPanelContentTypesIncludeWebMWhenResolvable() {
        guard let webMType = VoiceCloningReferenceAudioSupport.webMType else {
            XCTFail("Expected a resolvable UTType for .webm reference audio")
            return
        }

        XCTAssertTrue(
            VoiceCloningReferenceAudioSupport.openPanelContentTypes.contains(webMType)
        )
    }
}
