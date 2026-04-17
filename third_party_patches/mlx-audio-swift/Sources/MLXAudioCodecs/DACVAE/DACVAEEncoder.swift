//
//  DACVAEEncoder.swift
//  MLXAudioCodecs
//
// Created by Prince Canuma on 04/01/2026.
//

import Foundation
import MLX
import MLXNN

// MARK: - Encoder Block

/// Encoder block with residual units and downsampling.
public class DACVAEEncoderBlock: Module {
    @ModuleInfo(key: "res1") var res1: DACVAEResidualUnit
    @ModuleInfo(key: "res2") var res2: DACVAEResidualUnit
    @ModuleInfo(key: "res3") var res3: DACVAEResidualUnit
    @ModuleInfo(key: "snake") var snakeAct: DACVAESnake1d
    @ModuleInfo(key: "conv") var conv: DACVAEWNConv1d

    public init(dim: Int = 16, stride: Int = 1) {
        self._res1.wrappedValue = DACVAEResidualUnit(dim: dim / 2, dilation: 1)
        self._res2.wrappedValue = DACVAEResidualUnit(dim: dim / 2, dilation: 3)
        self._res3.wrappedValue = DACVAEResidualUnit(dim: dim / 2, dilation: 9)
        self._snakeAct.wrappedValue = DACVAESnake1d(channels: dim / 2)
        self._conv.wrappedValue = DACVAEWNConv1d(
            inChannels: dim / 2,
            outChannels: dim,
            kernelSize: 2 * stride,
            stride: stride,
            padding: Int(ceil(Float(stride) / 2.0))
        )
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = res1(x)
        h = res2(h)
        h = res3(h)
        h = snakeAct(h)
        h = conv(h)
        return h
    }
}

// MARK: - Encoder

/// DACVAE Encoder.
public class DACVAEEncoder: Module {
    @ModuleInfo(key: "conv_in") var convIn: DACVAEWNConv1d
    @ModuleInfo(key: "blocks") var blocks: [DACVAEEncoderBlock]
    @ModuleInfo(key: "snake_out") var snakeOut: DACVAESnake1d
    @ModuleInfo(key: "conv_out") var convOut: DACVAEWNConv1d

    public let encDim: Int

    public init(
        dModel: Int = 64,
        strides: [Int] = [2, 4, 8, 8],
        dLatent: Int = 64
    ) {
        self._convIn.wrappedValue = DACVAEWNConv1d(
            inChannels: 1,
            outChannels: dModel,
            kernelSize: 7,
            padding: 3
        )

        var currentDim = dModel
        var encoderBlocks: [DACVAEEncoderBlock] = []
        for stride in strides {
            currentDim *= 2
            encoderBlocks.append(DACVAEEncoderBlock(dim: currentDim, stride: stride))
        }
        self._blocks.wrappedValue = encoderBlocks

        self.encDim = currentDim
        self._snakeOut.wrappedValue = DACVAESnake1d(channels: currentDim)
        self._convOut.wrappedValue = DACVAEWNConv1d(
            inChannels: currentDim,
            outChannels: dLatent,
            kernelSize: 3,
            padding: 1
        )
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = convIn(x)
        for block in blocks {
            h = block(h)
        }
        h = snakeOut(h)
        h = convOut(h)
        return h
    }
}
