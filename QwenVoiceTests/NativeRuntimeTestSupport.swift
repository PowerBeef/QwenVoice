@preconcurrency import AVFoundation
import Foundation
import XCTest

enum NativeRuntimeTestSupport {
    struct ModelEntry {
        let id: String
        let name: String
        let folder: String
        let mode: String
        let requiredRelativePaths: [String]

        init(
            id: String,
            name: String,
            folder: String,
            mode: String,
            requiredRelativePaths: [String] = [
                "config.json",
                "speech_tokenizer/model.safetensors",
            ]
        ) {
            self.id = id
            self.name = name
            self.folder = folder
            self.mode = mode
            self.requiredRelativePaths = requiredRelativePaths
        }
    }

    static func makeTemporaryRoot(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func writeManifest(
        at root: URL,
        models: [ModelEntry]
    ) throws -> URL {
        let manifestURL = root.appendingPathComponent("qwenvoice_contract.json")
        let payload: [String: Any] = [
            "defaultSpeaker": "vivian",
            "speakers": [
                "English": ["vivian"]
            ],
            "models": models.map { model in
                [
                    "id": model.id,
                    "name": model.name,
                    "tier": "pro",
                    "mode": model.mode,
                    "folder": model.folder,
                    "huggingFaceRepo": "example/\(model.folder)",
                    "outputSubfolder": model.name.replacingOccurrences(of: " ", with: ""),
                    "requiredRelativePaths": model.requiredRelativePaths,
                ]
            }
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL)
        return manifestURL
    }

    static func installModel(
        _ model: ModelEntry,
        into modelsDirectory: URL,
        existingRelativePaths: [String]? = nil
    ) throws -> URL {
        let installDirectory = modelsDirectory.appendingPathComponent(model.folder, isDirectory: true)
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)

        let relativePaths = existingRelativePaths ?? model.requiredRelativePaths
        for relativePath in relativePaths {
            let fileURL = installDirectory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(relativePath.utf8).write(to: fileURL)
        }
        return installDirectory
    }

    static func bundledModelEntry(id: String) throws -> ModelEntry {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Resources/qwenvoice_contract.json")
        let data = try Data(contentsOf: manifestURL)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = payload["models"] as? [[String: Any]],
              let model = models.first(where: { ($0["id"] as? String) == id }),
              let name = model["name"] as? String,
              let folder = model["folder"] as? String,
              let mode = model["mode"] as? String,
              let requiredRelativePaths = model["requiredRelativePaths"] as? [String] else {
            throw NSError(
                domain: "NativeRuntimeTestSupport",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing bundled model entry for \(id)."]
            )
        }

        return ModelEntry(
            id: id,
            name: name,
            folder: folder,
            mode: mode,
            requiredRelativePaths: requiredRelativePaths
        )
    }

    static func installedModelsRoot() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["QWENVOICE_APP_SUPPORT_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("models", isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QwenVoice/models", isDirectory: true)
    }

    static func installedModelDirectory(for model: ModelEntry) -> URL {
        installedModelsRoot().appendingPathComponent(model.folder, isDirectory: true)
    }

    static func mirrorInstalledModel(
        _ model: ModelEntry,
        into modelsDirectory: URL
    ) throws -> URL {
        let sourceURL = installedModelDirectory(for: model)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw NSError(
                domain: "NativeRuntimeTestSupport",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Installed model is missing at \(sourceURL.path)."]
            )
        }

        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let targetURL = modelsDirectory.appendingPathComponent(model.folder, isDirectory: true)
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.createSymbolicLink(at: targetURL, withDestinationURL: sourceURL)
        return targetURL
    }

    static func writeTestWAV(
        to url: URL,
        sampleRate: Double = 24_000,
        channels: AVAudioChannelCount = 1,
        frameCount: Int = 480
    ) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: false
            )
        )
        let frameCapacity = AVAudioFrameCount(frameCount)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)
        )
        buffer.frameLength = frameCapacity

        for channel in 0..<Int(channels) {
            let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
            for frame in 0..<frameCount {
                let baseSample = Float(frame % 32) / 32.0
                samples[frame] = channel == 0 ? baseSample : -baseSample
            }
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    static func writeCanonicalPCM16WAV(
        to url: URL,
        sampleRate: Double = 24_000,
        channels: AVAudioChannelCount = 1,
        frameCount: Int = 480
    ) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: false
            )
        )
        let frameCapacity = AVAudioFrameCount(frameCount)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)
        )
        buffer.frameLength = frameCapacity

        for channel in 0..<Int(channels) {
            let samples = try XCTUnwrap(buffer.int16ChannelData?[channel])
            for frame in 0..<frameCount {
                let magnitude = Int16((frame % 32) * 512)
                samples[frame] = channel == 0 ? magnitude : -magnitude
            }
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        try file.write(from: buffer)
    }
}
