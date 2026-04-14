import Foundation

@MainActor
extension PythonBridge {
    func listVoices() async throws -> [Voice] {
        try UITestFaultInjection.throwIfEnabled(.listVoices)
        if isStubBackendMode {
            return try stubTransport.listVoices()
        }
        let items = try await callArray("list_voices")
        return items.compactMap { item -> Voice? in
            guard let obj = item.objectValue else { return nil }
            return Voice(from: obj)
        }
    }

    func enrollVoice(name: String, audioPath: String, transcript: String?) async throws -> Voice {
        if isStubBackendMode {
            return try stubTransport.enrollVoice(name: name, audioPath: audioPath, transcript: transcript)
        }
        var params: [String: RPCValue] = [
            "name": .string(name),
            "audio_path": .string(audioPath),
        ]
        if let transcript, !transcript.isEmpty {
            params["transcript"] = .string(transcript)
        }
        let response = try await callDict("enroll_voice", params: params)
        let normalizedName = response["name"]?.stringValue ?? SavedVoiceNameSanitizer.normalizedName(name)
        let wavPath = response["wav_path"]?.stringValue ?? ""
        return Voice(
            name: normalizedName,
            wavPath: wavPath,
            hasTranscript: !(transcript?.isEmpty ?? true)
        )
    }

    func deleteVoice(name: String) async throws {
        if isStubBackendMode {
            try stubTransport.deleteVoice(name: name)
            return
        }
        _ = try await callDict("delete_voice", params: ["name": .string(name)])
    }

    func getModelInfo() async throws -> [ModelInfo] {
        if isStubBackendMode {
            return stubTransport.modelInfo()
        }
        let items = try await callArray("get_model_info")
        return try items.map { item in
            try item.decoded(as: ModelInfo.self)
        }
    }

    func getSpeakers() async throws -> [String: [String]] {
        if isStubBackendMode {
            return stubTransport.speakers()
        }
        let response = try await callDict("get_speakers")
        var speakers: [String: [String]] = [:]

        for (group, value) in response {
            guard let array = value.arrayValue else { continue }
            speakers[group] = array.compactMap(\.stringValue)
        }

        return speakers
    }
}
