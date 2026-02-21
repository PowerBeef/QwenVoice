import Foundation
import AVFoundation
import Accelerate

/// Extracts waveform sample data from audio files using AVAudioFile and vDSP.
enum WaveformService {

    /// Extract downsampled amplitude data for waveform visualization.
    /// Returns an array of normalized Float values in [0, 1].
    static func extractSamples(from url: URL, targetCount: Int = 120) -> [Float] {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return [] }

        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: audioFile.fileFormat.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return [] }

        do {
            try audioFile.read(into: buffer)
        } catch {
            return []
        }

        guard let channelData = buffer.floatChannelData?[0] else { return [] }
        let totalSamples = Int(buffer.frameLength)

        guard totalSamples > 0 else { return [] }

        let samplesPerBin = max(1, totalSamples / targetCount)
        let binCount = min(targetCount, totalSamples)

        var result = [Float](repeating: 0, count: binCount)

        for i in 0..<binCount {
            let start = i * samplesPerBin
            let count = min(samplesPerBin, totalSamples - start)
            guard count > 0 else { continue }

            // Use vDSP to compute RMS of each bin
            var rms: Float = 0
            vDSP_rmsqv(channelData.advanced(by: start), 1, &rms, vDSP_Length(count))
            result[i] = rms
        }

        // Normalize to [0, 1]
        var maxVal: Float = 0
        vDSP_maxv(result, 1, &maxVal, vDSP_Length(binCount))

        if maxVal > 0 {
            var scale = 1.0 / maxVal
            vDSP_vsmul(result, 1, &scale, &result, 1, vDSP_Length(binCount))
        }

        return result
    }
}
