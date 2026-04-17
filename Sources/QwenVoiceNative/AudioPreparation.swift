@preconcurrency import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

enum AudioPreparationError: LocalizedError, Equatable {
    case missingInputFile(String)
    case unsupportedInput(String)
    case missingOutputDirectory
    case failedToCreateOutputDirectory(String)
    case failedToReadAudio(String)
    case failedToCreateOutput(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingInputFile(let path):
            return "Audio file not found: \(path)"
        case .unsupportedInput(let message):
            return message
        case .missingOutputDirectory:
            return "Audio preparation needs an output directory when the source is not already canonical."
        case .failedToCreateOutputDirectory(let path):
            return "Couldn't create audio output directory at \(path)."
        case .failedToReadAudio(let path):
            return "Couldn't read audio file at \(path)."
        case .failedToCreateOutput(let path):
            return "Couldn't create normalized audio output at \(path)."
        case .conversionFailed(let message):
            return message
        }
    }
}

struct AudioPreparationRequest: Hashable, Codable, Sendable {
    let inputPath: String
    let outputPath: String?

    init(inputPath: String, outputPath: String? = nil) {
        self.inputPath = inputPath
        self.outputPath = outputPath
    }
}

extension AudioPreparationRequest {
    init(inputURL: URL, outputURL: URL? = nil) {
        self.init(inputPath: inputURL.path, outputPath: outputURL?.path)
    }

    var inputURL: URL {
        URL(fileURLWithPath: inputPath)
    }

    var outputURL: URL? {
        guard let outputPath else { return nil }
        return URL(fileURLWithPath: outputPath)
    }
}

struct AudioNormalizationResult: Hashable, Codable, Sendable {
    let sourcePath: String
    let normalizedPath: String
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int64
    let durationSeconds: Double
    let byteSize: Int64
    let wasAlreadyCanonical: Bool
    let fingerprint: String

    var sourceURL: URL {
        URL(fileURLWithPath: sourcePath)
    }

    var normalizedURL: URL {
        URL(fileURLWithPath: normalizedPath)
    }
}

protocol AudioPreparationService: Sendable {
    func normalizeAudio(_ request: AudioPreparationRequest) async throws -> AudioNormalizationResult
}

struct NativeAudioPreparationService: AudioPreparationService, Hashable, Sendable {
    static let canonicalSampleRate: Double = 24_000
    static let canonicalChannelCount: AVAudioChannelCount = 1
    static let canonicalBitDepth = 16

    private static let normalizationQueue = DispatchQueue(
        label: "com.qwenvoice.native.audio-preparation",
        qos: .utility
    )

    let preparedAudioDirectory: URL?

    init(preparedAudioDirectory: URL? = nil) {
        self.preparedAudioDirectory = preparedAudioDirectory
    }

    func normalizeAudio(_ request: AudioPreparationRequest) async throws -> AudioNormalizationResult {
        try await withCheckedThrowingContinuation { continuation in
            Self.normalizationQueue.async {
                do {
                    continuation.resume(returning: try normalizeAudioSynchronously(request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func isCanonicalWAV(at sourceURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return false
        }

        do {
            return isCanonical(file: try AVAudioFile(forReading: sourceURL), sourceURL: sourceURL)
        } catch {
            return false
        }
    }

    static func canReuseExistingNormalizedOutput(at outputURL: URL, fingerprint: String) -> Bool {
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            return false
        }
        let normalizedStem = outputURL.deletingPathExtension().lastPathComponent
        guard normalizedStem.contains(fingerprint) else {
            return false
        }
        return isCanonicalWAV(at: outputURL)
    }

    private func normalizeAudioSynchronously(_ request: AudioPreparationRequest) throws -> AudioNormalizationResult {
        let fileManager = FileManager.default
        let sourceURL = request.inputURL
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw AudioPreparationError.missingInputFile(sourceURL.path)
        }

        let fingerprint = Self.fileFingerprint(for: sourceURL)
        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: sourceURL)
        } catch {
            throw AudioPreparationError.failedToReadAudio(sourceURL.path)
        }
        guard inputFile.length > 0 else {
            throw AudioPreparationError.unsupportedInput(
                "The selected audio file does not contain readable audio frames."
            )
        }

        let alreadyCanonical = Self.isCanonical(file: inputFile, sourceURL: sourceURL)
        let outputURL = try normalizedOutputURL(
            sourceURL: sourceURL,
            outputURL: request.outputURL,
            fingerprint: fingerprint,
            sourceAlreadyCanonical: alreadyCanonical
        )

        if alreadyCanonical && outputURL == sourceURL {
            return try Self.makeResult(
                sourceURL: sourceURL,
                normalizedURL: sourceURL,
                fingerprint: fingerprint,
                wasAlreadyCanonical: true
            )
        }

        if outputURL != sourceURL,
           Self.canReuseExistingNormalizedOutput(at: outputURL, fingerprint: fingerprint) {
            return try Self.makeResult(
                sourceURL: sourceURL,
                normalizedURL: outputURL,
                fingerprint: fingerprint,
                wasAlreadyCanonical: false
            )
        }

        let parentDirectory = outputURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        } catch {
            throw AudioPreparationError.failedToCreateOutputDirectory(parentDirectory.path)
        }

        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }

        let writtenFrameCount = try Self.convertAudio(inputURL: sourceURL, outputURL: outputURL)
        return try Self.makeCanonicalResult(
            sourceURL: sourceURL,
            normalizedURL: outputURL,
            fingerprint: fingerprint,
            wasAlreadyCanonical: false,
            frameCount: writtenFrameCount
        )
    }

    private func normalizedOutputURL(
        sourceURL: URL,
        outputURL: URL?,
        fingerprint: String,
        sourceAlreadyCanonical: Bool
    ) throws -> URL {
        if let outputURL {
            return outputURL
        }
        if sourceAlreadyCanonical {
            return sourceURL
        }
        guard let preparedAudioDirectory else {
            throw AudioPreparationError.missingOutputDirectory
        }
        let stem = Self.sanitizedStem(for: sourceURL)
        return preparedAudioDirectory.appendingPathComponent("\(stem)_\(fingerprint).wav")
    }

    private static func convertAudio(inputURL: URL, outputURL: URL) throws -> Int64 {
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: canonicalSampleRate,
            AVNumberOfChannelsKey: canonicalChannelCount,
            AVLinearPCMBitDepthKey: canonicalBitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let asset = AVURLAsset(url: inputURL)
        let track = try firstAudioTrack(from: asset)
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw AudioPreparationError.unsupportedInput("The selected audio track could not be decoded natively.")
        }
        reader.add(readerOutput)

        guard reader.startReading() else {
            throw AudioPreparationError.conversionFailed(
                reader.error?.localizedDescription ?? "Native audio decoding could not start."
            )
        }

        let writer: AVAudioFile
        do {
            writer = try AVAudioFile(
                forWriting: outputURL,
                settings: outputSettings,
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )
        } catch {
            throw AudioPreparationError.failedToCreateOutput(outputURL.path)
        }

        var totalWrittenFrames: Int64 = 0
        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frameCount > 0 else { continue }

            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: writer.processingFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ) else {
                throw AudioPreparationError.conversionFailed("Couldn't allocate the decoded audio buffer.")
            }
            outputBuffer.frameLength = AVAudioFrameCount(frameCount)

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                throw AudioPreparationError.conversionFailed("Decoded audio data was unavailable.")
            }

            let dataLength = CMBlockBufferGetDataLength(blockBuffer)
            guard let channelData = outputBuffer.int16ChannelData else {
                throw AudioPreparationError.conversionFailed("Decoded audio data could not be mapped into PCM channels.")
            }

            let status = CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: dataLength,
                destination: UnsafeMutableRawPointer(channelData[0])
            )
            guard status == noErr else {
                throw AudioPreparationError.conversionFailed("Decoded audio bytes could not be copied into the canonical buffer.")
            }

            do {
                try writer.write(from: outputBuffer)
            } catch {
                throw AudioPreparationError.conversionFailed("Audio write failed: \(error.localizedDescription)")
            }

            totalWrittenFrames += Int64(frameCount)
        }

        switch reader.status {
        case .completed, .reading:
            break
        case .failed:
            throw AudioPreparationError.conversionFailed(reader.error?.localizedDescription ?? "Native audio decoding failed.")
        case .cancelled:
            throw AudioPreparationError.conversionFailed("Native audio decoding was cancelled before completion.")
        case .unknown:
            throw AudioPreparationError.conversionFailed("Native audio decoding ended in an unknown state.")
        @unknown default:
            throw AudioPreparationError.conversionFailed("Native audio decoding ended in an unsupported state.")
        }

        guard totalWrittenFrames > 0 else {
            throw AudioPreparationError.unsupportedInput(
                "The selected audio file does not contain readable audio frames."
            )
        }

        return totalWrittenFrames
    }

    private static func firstAudioTrack(from asset: AVURLAsset) throws -> AVAssetTrack {
        final class TrackLoadBox: @unchecked Sendable {
            var result: Result<AVAssetTrack, Error>?
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = TrackLoadBox()
        Task.detached {
            do {
                let resolvedTrack = try await asset.loadTracks(withMediaType: .audio).first
                guard let resolvedTrack else {
                    box.result = .failure(
                        AudioPreparationError.unsupportedInput(
                            "No readable audio track was found in the selected file."
                        )
                    )
                    semaphore.signal()
                    return
                }
                box.result = .success(resolvedTrack)
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        guard let result = box.result else {
            throw AudioPreparationError.unsupportedInput(
                "No readable audio track was found in the selected file."
            )
        }
        return try result.get()
    }

    private static func makeResult(
        sourceURL: URL,
        normalizedURL: URL,
        fingerprint: String,
        wasAlreadyCanonical: Bool
    ) throws -> AudioNormalizationResult {
        let normalizedFile: AVAudioFile
        do {
            normalizedFile = try AVAudioFile(forReading: normalizedURL)
        } catch {
            throw AudioPreparationError.failedToReadAudio(normalizedURL.path)
        }

        let frameCount = Int64(normalizedFile.length)
        let sampleRate = normalizedFile.fileFormat.sampleRate
        let channels = Int(normalizedFile.fileFormat.channelCount)
        let durationSeconds = sampleRate > 0 ? Double(frameCount) / sampleRate : 0
        let byteSize = Int64((try? normalizedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

        return AudioNormalizationResult(
            sourcePath: sourceURL.path,
            normalizedPath: normalizedURL.path,
            sampleRate: sampleRate,
            channelCount: channels,
            frameCount: frameCount,
            durationSeconds: durationSeconds,
            byteSize: byteSize,
            wasAlreadyCanonical: wasAlreadyCanonical,
            fingerprint: fingerprint
        )
    }

    private static func makeCanonicalResult(
        sourceURL: URL,
        normalizedURL: URL,
        fingerprint: String,
        wasAlreadyCanonical: Bool,
        frameCount: Int64
    ) throws -> AudioNormalizationResult {
        let byteSize = Int64((try? normalizedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let durationSeconds = canonicalSampleRate > 0 ? Double(frameCount) / canonicalSampleRate : 0
        return AudioNormalizationResult(
            sourcePath: sourceURL.path,
            normalizedPath: normalizedURL.path,
            sampleRate: canonicalSampleRate,
            channelCount: Int(canonicalChannelCount),
            frameCount: frameCount,
            durationSeconds: durationSeconds,
            byteSize: byteSize,
            wasAlreadyCanonical: wasAlreadyCanonical,
            fingerprint: fingerprint
        )
    }

    private static func isCanonical(file: AVAudioFile, sourceURL: URL) -> Bool {
        let settings = file.fileFormat.settings
        let bitDepth = settings[AVLinearPCMBitDepthKey] as? Int
        let formatID = settings[AVFormatIDKey] as? UInt32
        let isFloat = settings[AVLinearPCMIsFloatKey] as? Bool

        return sourceURL.pathExtension.lowercased() == "wav"
            && file.fileFormat.sampleRate == canonicalSampleRate
            && file.fileFormat.channelCount == canonicalChannelCount
            && formatID == kAudioFormatLinearPCM
            && bitDepth == canonicalBitDepth
            && isFloat == false
    }

    private static func fileFingerprint(for url: URL) -> String {
        let resolvedPath = url.resolvingSymlinksInPath().path
        let attributes = (try? FileManager.default.attributesOfItem(atPath: resolvedPath)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let data = Data("\(resolvedPath)|\(size)|\(mtime)".utf8)
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizedStem(for url: URL) -> String {
        let raw = url.deletingPathExtension().lastPathComponent
        let sanitized = raw
            .replacingOccurrences(of: #"[^\w\s-]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        return sanitized.isEmpty ? "reference" : sanitized
    }
}
