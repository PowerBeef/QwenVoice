//
//  EncodecConfig.swift
//  MLXAudioCodecs
//
//  Ported from mlx-audio Python implementation
//

import Foundation

/// Configuration for the Encodec model.
public struct EncodecConfig: Codable {
    public var modelType: String
    public var audioChannels: Int
    public var numFilters: Int
    public var kernelSize: Int
    public var numResidualLayers: Int
    public var dilationGrowthRate: Int
    public var codebookSize: Int
    public var codebookDim: Int
    public var hiddenSize: Int
    public var numLstmLayers: Int
    public var residualKernelSize: Int
    public var useCausalConv: Bool
    public var normalize: Bool
    public var padMode: String
    public var normType: String
    public var lastKernelSize: Int
    public var trimRightRatio: Float
    public var compress: Int
    public var upsamplingRatios: [Int]
    public var targetBandwidths: [Float]
    public var samplingRate: Int
    public var chunkLengthS: Float?
    public var overlap: Float?
    public var useConvShortcut: Bool

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case audioChannels = "audio_channels"
        case numFilters = "num_filters"
        case kernelSize = "kernel_size"
        case numResidualLayers = "num_residual_layers"
        case dilationGrowthRate = "dilation_growth_rate"
        case codebookSize = "codebook_size"
        case codebookDim = "codebook_dim"
        case hiddenSize = "hidden_size"
        case numLstmLayers = "num_lstm_layers"
        case residualKernelSize = "residual_kernel_size"
        case useCausalConv = "use_causal_conv"
        case normalize
        case padMode = "pad_mode"
        case normType = "norm_type"
        case lastKernelSize = "last_kernel_size"
        case trimRightRatio = "trim_right_ratio"
        case compress
        case upsamplingRatios = "upsampling_ratios"
        case targetBandwidths = "target_bandwidths"
        case samplingRate = "sampling_rate"
        case chunkLengthS = "chunk_length_s"
        case overlap
        case useConvShortcut = "use_conv_shortcut"
    }

    public init(
        modelType: String = "encodec",
        audioChannels: Int = 1,
        numFilters: Int = 32,
        kernelSize: Int = 7,
        numResidualLayers: Int = 1,
        dilationGrowthRate: Int = 2,
        codebookSize: Int = 1024,
        codebookDim: Int = 128,
        hiddenSize: Int = 128,
        numLstmLayers: Int = 2,
        residualKernelSize: Int = 3,
        useCausalConv: Bool = true,
        normalize: Bool = false,
        padMode: String = "reflect",
        normType: String = "weight_norm",
        lastKernelSize: Int = 7,
        trimRightRatio: Float = 1.0,
        compress: Int = 2,
        upsamplingRatios: [Int] = [8, 5, 4, 2],
        targetBandwidths: [Float] = [1.5, 3.0, 6.0, 12.0, 24.0],
        samplingRate: Int = 24000,
        chunkLengthS: Float? = nil,
        overlap: Float? = nil,
        useConvShortcut: Bool = true
    ) {
        self.modelType = modelType
        self.audioChannels = audioChannels
        self.numFilters = numFilters
        self.kernelSize = kernelSize
        self.numResidualLayers = numResidualLayers
        self.dilationGrowthRate = dilationGrowthRate
        self.codebookSize = codebookSize
        self.codebookDim = codebookDim
        self.hiddenSize = hiddenSize
        self.numLstmLayers = numLstmLayers
        self.residualKernelSize = residualKernelSize
        self.useCausalConv = useCausalConv
        self.normalize = normalize
        self.padMode = padMode
        self.normType = normType
        self.lastKernelSize = lastKernelSize
        self.trimRightRatio = trimRightRatio
        self.compress = compress
        self.upsamplingRatios = upsamplingRatios
        self.targetBandwidths = targetBandwidths
        self.samplingRate = samplingRate
        self.chunkLengthS = chunkLengthS
        self.overlap = overlap
        self.useConvShortcut = useConvShortcut
    }

    public init(from jsonDecoder: Swift.Decoder) throws {
        let container = try jsonDecoder.container(keyedBy: CodingKeys.self)
        modelType = try container.decodeIfPresent(String.self, forKey: .modelType) ?? "encodec"
        audioChannels = try container.decodeIfPresent(Int.self, forKey: .audioChannels) ?? 1
        numFilters = try container.decodeIfPresent(Int.self, forKey: .numFilters) ?? 32
        kernelSize = try container.decodeIfPresent(Int.self, forKey: .kernelSize) ?? 7
        numResidualLayers = try container.decodeIfPresent(Int.self, forKey: .numResidualLayers) ?? 1
        dilationGrowthRate = try container.decodeIfPresent(Int.self, forKey: .dilationGrowthRate) ?? 2
        codebookSize = try container.decodeIfPresent(Int.self, forKey: .codebookSize) ?? 1024
        codebookDim = try container.decodeIfPresent(Int.self, forKey: .codebookDim) ?? 128
        hiddenSize = try container.decodeIfPresent(Int.self, forKey: .hiddenSize) ?? 128
        numLstmLayers = try container.decodeIfPresent(Int.self, forKey: .numLstmLayers) ?? 2
        residualKernelSize = try container.decodeIfPresent(Int.self, forKey: .residualKernelSize) ?? 3
        useCausalConv = try container.decodeIfPresent(Bool.self, forKey: .useCausalConv) ?? true
        normalize = try container.decodeIfPresent(Bool.self, forKey: .normalize) ?? false
        padMode = try container.decodeIfPresent(String.self, forKey: .padMode) ?? "reflect"
        normType = try container.decodeIfPresent(String.self, forKey: .normType) ?? "weight_norm"
        lastKernelSize = try container.decodeIfPresent(Int.self, forKey: .lastKernelSize) ?? 7
        trimRightRatio = try container.decodeIfPresent(Float.self, forKey: .trimRightRatio) ?? 1.0
        compress = try container.decodeIfPresent(Int.self, forKey: .compress) ?? 2
        upsamplingRatios = try container.decodeIfPresent([Int].self, forKey: .upsamplingRatios) ?? [8, 5, 4, 2]
        targetBandwidths = try container.decodeIfPresent([Float].self, forKey: .targetBandwidths) ?? [1.5, 3.0, 6.0, 12.0, 24.0]
        samplingRate = try container.decodeIfPresent(Int.self, forKey: .samplingRate) ?? 24000
        chunkLengthS = try container.decodeIfPresent(Float.self, forKey: .chunkLengthS)
        overlap = try container.decodeIfPresent(Float.self, forKey: .overlap)
        useConvShortcut = try container.decodeIfPresent(Bool.self, forKey: .useConvShortcut) ?? true
    }
}
