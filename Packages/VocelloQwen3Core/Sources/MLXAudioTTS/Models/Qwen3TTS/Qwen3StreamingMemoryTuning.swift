import Foundation
import os

/// Process-wide streaming memory knobs set by the host app before generation.
public enum Qwen3StreamingMemoryTuning: Sendable {
    private struct State: Sendable {
        var clearCacheOnStreamChunkEmit = true
        var tokenMemoryClearCadenceOverride: Int?
        // Sliding-window talker KV cache: nil = disabled (unbounded KVCacheSimple,
        // the default/quality-transparent path). Non-nil = the number of GENERATED
        // audio-codec tokens to retain beyond the conditioning prefix (which is
        // always kept). The talker creates a RotatingKVCache(maxSize: prefixLen +
        // window, keep: prefixLen) when this is set. Used to cap peak RAM on long
        // generations for the iOS / low-end-Mac tiers.
        var talkerKVGeneratedWindow: Int?
    }

    private static let lock = OSAllocatedUnfairLock(initialState: State())

    public static var clearCacheOnStreamChunkEmit: Bool {
        lock.withLock { $0.clearCacheOnStreamChunkEmit }
    }

    public static var tokenMemoryClearCadenceOverride: Int? {
        lock.withLock { $0.tokenMemoryClearCadenceOverride }
    }

    /// Generated-audio-token window for the sliding-window talker KV cache, or nil
    /// when disabled (the default — unbounded cache, no behavior change).
    public static var talkerKVGeneratedWindow: Int? {
        lock.withLock { $0.talkerKVGeneratedWindow }
    }

    public static func apply(clearOnStreamChunk: Bool, tokenCadence: Int) {
        lock.withLock {
            $0.clearCacheOnStreamChunkEmit = clearOnStreamChunk
            $0.tokenMemoryClearCadenceOverride = tokenCadence
        }
    }

    /// Set (or clear, with nil) the sliding-window talker KV cache's generated-token
    /// window. The host sets this per-tier/per-request before generation.
    public static func applyTalkerKVWindow(_ window: Int?) {
        lock.withLock {
            $0.talkerKVGeneratedWindow = window
        }
    }

    /// Opt-in talker KV-cache quantization (P4 A/B; dev knob, default off):
    /// `QVOICE_TALKER_KV_QUANT=8|4` → QuantizedKVCache(groupSize: 64, bits: n).
    /// Quality-sensitive (clone fidelity) — ships per-tier only after fixed-seed
    /// exact-WAV QC plus the applicable ASR/prosody gates. Never combined with the rotating-window cache (its
    /// toQuantized is unimplemented upstream); the window knob wins if both
    /// are set.
    public static let talkerKVQuantBits: Int? = {
        guard let raw = VocelloQwen3ImplementationDebugGate.value(
            for: "QVOICE_TALKER_KV_QUANT"
        ),
              let bits = Int(raw), bits == 4 || bits == 8 else { return nil }
        return bits
    }()
}
