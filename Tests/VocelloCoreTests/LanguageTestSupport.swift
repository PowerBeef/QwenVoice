import Foundation
import QwenVoiceCore

enum LanguageTestSupport {
    static func makeRequest(
        mode: GenerationMode,
        text: String,
        languageHint: String? = nil,
        cloneReference: CloneReference? = nil
    ) -> GenerationRequest {
        let payload: GenerationRequest.Payload
        switch mode {
        case .custom:
            payload = .custom(speakerID: "aiden", deliveryStyle: nil)
        case .design:
            payload = .design(voiceDescription: "A clear narrator.", deliveryStyle: nil)
        case .clone:
            payload = .clone(
                reference: cloneReference ?? CloneReference(
                    audioPath: "/tmp/reference.wav",
                    transcript: nil,
                    preparedVoiceID: nil
                )
            )
        }

        return GenerationRequest(
            mode: mode,
            modelID: "pro_custom_speed",
            text: text,
            outputPath: "/tmp/test.wav",
            shouldStream: false,
            languageHint: languageHint,
            payload: payload
        )
    }
}
