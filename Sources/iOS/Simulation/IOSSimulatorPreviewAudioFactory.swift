import Foundation
import QwenVoiceCore

enum IOSSimulatorPreviewAudioFactory {
    static let durationSeconds: Double = 6.4

    static func makeResult(mode: GenerationMode, text: String, outputSubfolder: String) throws -> GenerationResult {
        let outputPath = makeOutputPath(subfolder: outputSubfolder, text: text)
        return try makeResult(mode: mode, text: text, outputPath: outputPath)
    }

    static func makeResult(mode: GenerationMode, text: String, outputPath: String) throws -> GenerationResult {
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writePreviewWAV(
            to: outputURL,
            mode: mode,
            text: text,
            durationSeconds: durationSeconds
        )
        return GenerationResult(
            audioPath: outputURL.path,
            durationSeconds: durationSeconds,
            streamSessionDirectory: nil,
            usedStreaming: false,
            finishReason: .eos
        )
    }

    private static func writePreviewWAV(
        to outputURL: URL,
        mode: GenerationMode,
        text: String,
        durationSeconds: Double
    ) throws {
        let sampleRate: UInt32 = 24_000
        let bitsPerSample: UInt16 = 16
        let numChannels: UInt16 = 1
        let bytesPerSample = bitsPerSample / 8
        let numSamples = Int((Double(sampleRate) * durationSeconds).rounded())
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bytesPerSample)
        let blockAlign = numChannels * bytesPerSample
        let dataSize = UInt32(numSamples) * UInt32(blockAlign)
        let fileSizeMinus8 = 36 + dataSize

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        data.appendLE(UInt32(fileSizeMinus8))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(numChannels)
        data.appendLE(sampleRate)
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(bitsPerSample)
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        data.appendLE(dataSize)

        let baseFrequency = Self.baseFrequency(for: mode, text: text)
        let sampleRateDouble = Double(sampleRate)
        let twoPi = Double.pi * 2
        for sampleIndex in 0..<numSamples {
            let t = Double(sampleIndex) / sampleRateDouble
            let fadeIn = min(1, t / 0.08)
            let fadeOut = min(1, max(0, (durationSeconds - t) / 0.18))
            let envelope = fadeIn * fadeOut
            let phrasePulse = 0.62 + 0.38 * sin(twoPi * 1.35 * t)
            let carrier = sin(twoPi * baseFrequency * t)
                + 0.28 * sin(twoPi * baseFrequency * 1.5 * t)
                + 0.12 * sin(twoPi * baseFrequency * 2.02 * t)
            let normalized = max(-1, min(1, carrier * phrasePulse * envelope * 0.34))
            data.appendLE(Int16(normalized * Double(Int16.max)))
        }

        try data.write(to: outputURL, options: [.atomic])
    }

    private static func baseFrequency(for mode: GenerationMode, text: String) -> Double {
        let offset = Double(abs(IOSStableVisualHash.int(text)) % 9)
        switch mode {
        case .custom:
            return 196 + offset
        case .design:
            return 246 + offset
        case .clone:
            return 220 + offset
        }
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Int16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
