//
//  EncodecQuantization.swift
//  MLXAudioCodecs
//
//  Ported from mlx-audio Python implementation
//

import Foundation
import MLX
import MLXNN

// MARK: - Euclidean Codebook

/// Codebook with Euclidean distance.
public class EncodecEuclideanCodebook: Module {
    @ModuleInfo(key: "embed") var embed: MLXArray

    public init(config: EncodecConfig) {
        self._embed.wrappedValue = MLXArray.zeros([config.codebookSize, config.codebookDim])
    }

    public func quantize(_ hiddenStates: MLXArray) -> MLXArray {
        let embedT = embed.T
        let scaledStates = hiddenStates.square().sum(axis: 1, keepDims: true)
        let dist = -(
            scaledStates
            - 2 * MLX.matmul(hiddenStates, embedT)
            + embedT.square().sum(axis: 0, keepDims: true)
        )
        let embedInd = MLX.argMax(dist, axis: -1)
        return embedInd
    }

    public func encode(_ hiddenStates: MLXArray) -> MLXArray {
        let shape = hiddenStates.shape
        let flattened = hiddenStates.reshaped([-1, shape.last!])
        let embedInd = quantize(flattened)
        return embedInd.reshaped(Array(shape.dropLast()))
    }

    public func decode(_ embedInd: MLXArray) -> MLXArray {
        return embed[embedInd]
    }
}

// MARK: - Vector Quantization

/// Vector quantization implementation using Euclidean distance.
public class EncodecVectorQuantization: Module {
    @ModuleInfo(key: "codebook") var codebook: EncodecEuclideanCodebook

    public init(config: EncodecConfig) {
        self._codebook.wrappedValue = EncodecEuclideanCodebook(config: config)
    }

    public func encode(_ hiddenStates: MLXArray) -> MLXArray {
        return codebook.encode(hiddenStates)
    }

    public func decode(_ embedInd: MLXArray) -> MLXArray {
        return codebook.decode(embedInd)
    }
}

// MARK: - Residual Vector Quantizer

/// Residual Vector Quantizer.
public class EncodecResidualVectorQuantizer: Module {
    public let codebookSize: Int
    public let frameRate: Int
    public let numQuantizers: Int

    @ModuleInfo(key: "layers") var layers: [EncodecVectorQuantization]

    public init(config: EncodecConfig) {
        self.codebookSize = config.codebookSize

        let hopLength = config.upsamplingRatios.reduce(1, *)
        self.frameRate = Int(ceil(Float(config.samplingRate) / Float(hopLength)))

        let maxBandwidth = config.targetBandwidths.max() ?? 24.0
        self.numQuantizers = Int(1000 * maxBandwidth / Float(frameRate * 10))

        self._layers.wrappedValue = (0..<numQuantizers).map { _ in
            EncodecVectorQuantization(config: config)
        }
    }

    /// Return num_quantizers based on specified target bandwidth.
    public func getNumQuantizersForBandwidth(_ bandwidth: Float?) -> Int {
        let bwPerQ = log2(Float(codebookSize)) * Float(frameRate)
        var nQuantizers = numQuantizers
        if let bw = bandwidth, bw > 0.0 {
            nQuantizers = max(1, Int(floor(bw * 1000 / bwPerQ)))
        }
        return nQuantizers
    }

    /// Encode embeddings to discrete codes.
    public func encode(_ embeddings: MLXArray, bandwidth: Float? = nil) -> MLXArray {
        let nQuantizers = getNumQuantizersForBandwidth(bandwidth)
        var residual = embeddings
        var allIndices: [MLXArray] = []

        for i in 0..<nQuantizers {
            let layer = layers[i]
            let indices = layer.encode(residual)
            let quantized = layer.decode(indices)
            residual = residual - quantized
            allIndices.append(indices)
        }

        return MLX.stacked(allIndices, axis: 1)
    }

    /// Decode codes to quantized representation.
    public func decode(_ codes: MLXArray) -> MLXArray {
        var quantizedOut: MLXArray? = nil

        for i in 0..<codes.shape[1] {
            let indices = codes[0..., i, 0...]
            let layer = layers[i]
            let quantized = layer.decode(indices)

            if quantizedOut == nil {
                quantizedOut = quantized
            } else {
                quantizedOut = quantizedOut! + quantized
            }
        }

        return quantizedOut!
    }
}
