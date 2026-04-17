//
//  SNACConfig.swift
//  MLXAudio
//
//  Created by Ben Harraway on 14/05/2025.
//
import Foundation
// MARK: - SNAC Configuration

public struct SNACConfig: Codable {
    public let samplingRate: Int
    public let encoderDim: Int
    public let encoderRates: [Int]
    public let latentDim: Int?
    public let decoderDim: Int
    public let decoderRates: [Int]
    public let attnWindowSize: Int?
    public let codebookSize: Int
    public let codebookDim: Int
    public let vqStrides: [Int]
    public let noise: Bool
    public let depthwise: Bool

    enum CodingKeys: String, CodingKey {
        case samplingRate = "sampling_rate"
        case encoderDim = "encoder_dim"
        case encoderRates = "encoder_rates"
        case latentDim = "latent_dim"
        case decoderDim = "decoder_dim"
        case decoderRates = "decoder_rates"
        case attnWindowSize = "attn_window_size"
        case codebookSize = "codebook_size"
        case codebookDim = "codebook_dim"
        case vqStrides = "vq_strides"
        case noise
        case depthwise
    }
}