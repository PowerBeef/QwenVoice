//
//  DACVAEConfig.swift
//  MLXAudioCodecs
//
// Created by Prince Canuma on 04/01/2026.
//

import Foundation

/// Configuration for the DACVAE audio codec.
public struct DACVAEConfig: Codable {
    public var encoderDim: Int
    public var encoderRates: [Int]
    public var latentDim: Int
    public var decoderDim: Int
    public var decoderRates: [Int]
    public var nCodebooks: Int
    public var codebookSize: Int
    public var codebookDim: Int
    public var quantizerDropout: Bool
    public var sampleRate: Int
    public var mean: Float
    public var std: Float

    /// Computed hop length based on encoder rates
    public var hopLength: Int {
        return encoderRates.reduce(1, *)
    }

    enum CodingKeys: String, CodingKey {
        case encoderDim = "encoder_dim"
        case encoderRates = "encoder_rates"
        case latentDim = "latent_dim"
        case decoderDim = "decoder_dim"
        case decoderRates = "decoder_rates"
        case nCodebooks = "n_codebooks"
        case codebookSize = "codebook_size"
        case codebookDim = "codebook_dim"
        case quantizerDropout = "quantizer_dropout"
        case sampleRate = "sample_rate"
        case mean
        case std
    }

    public init(
        encoderDim: Int = 64,
        encoderRates: [Int] = [2, 8, 10, 12],
        latentDim: Int = 1024,
        decoderDim: Int = 1536,
        decoderRates: [Int] = [12, 10, 8, 2],
        nCodebooks: Int = 16,
        codebookSize: Int = 1024,
        codebookDim: Int = 128,
        quantizerDropout: Bool = false,
        sampleRate: Int = 48000,
        mean: Float = 0.0,
        std: Float = 1.0
    ) {
        self.encoderDim = encoderDim
        self.encoderRates = encoderRates
        self.latentDim = latentDim
        self.decoderDim = decoderDim
        self.decoderRates = decoderRates
        self.nCodebooks = nCodebooks
        self.codebookSize = codebookSize
        self.codebookDim = codebookDim
        self.quantizerDropout = quantizerDropout
        self.sampleRate = sampleRate
        self.mean = mean
        self.std = std
    }

    public init(from jsonDecoder: Swift.Decoder) throws {
        let container = try jsonDecoder.container(keyedBy: CodingKeys.self)
        encoderDim = try container.decodeIfPresent(Int.self, forKey: .encoderDim) ?? 64
        encoderRates = try container.decodeIfPresent([Int].self, forKey: .encoderRates) ?? [2, 8, 10, 12]
        latentDim = try container.decodeIfPresent(Int.self, forKey: .latentDim) ?? 1024
        decoderDim = try container.decodeIfPresent(Int.self, forKey: .decoderDim) ?? 1536
        decoderRates = try container.decodeIfPresent([Int].self, forKey: .decoderRates) ?? [12, 10, 8, 2]
        nCodebooks = try container.decodeIfPresent(Int.self, forKey: .nCodebooks) ?? 16
        codebookSize = try container.decodeIfPresent(Int.self, forKey: .codebookSize) ?? 1024
        codebookDim = try container.decodeIfPresent(Int.self, forKey: .codebookDim) ?? 128
        quantizerDropout = try container.decodeIfPresent(Bool.self, forKey: .quantizerDropout) ?? false
        sampleRate = try container.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 48000
        mean = try container.decodeIfPresent(Float.self, forKey: .mean) ?? 0.0
        std = try container.decodeIfPresent(Float.self, forKey: .std) ?? 1.0
    }
}
