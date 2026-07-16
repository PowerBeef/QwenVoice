# Vocello Qwen3 runtime performance architecture

This document explains the causal performance and memory design of the owned Qwen3 runtime. It
does not turn every experiment into a shipped optimization: `RUNTIME_CAPABILITIES.json` is
authoritative for current behavior and evidence freshness. `PATCHES.json` is the active semantic
delta ledger, while `UPSTREAM_BASELINE.json` remains the immutable imported-byte inventory.
Benchmark records remain diagnostic after a runtime-impacting source change until a clean record
matches the current capability sources.

## Loading and prepared state

Model resolution includes repository revision in cache identity. Prepared loading validates the
checkpoint once, records the required capability profile, and reuses trusted tokenizer or
speech-tokenizer components only when model identity and capability match. Platform-bounded LRUs
hold prepared components; clone-capable profiles include learned encoders while ordinary synthesis
may load the decoder-only tokenizer surface. Weight materialization is batched to bound transient
unified-memory peaks.

Cold-load evidence must include the model-loading lifecycle boundaries. A warm generation is not
evidence that the loader or prepared-state trust path is correct.

## Clone conditioning

The speaker encoder does not consume the generic Whisper-style mel helper. Clone conditioning uses
the official Qwen frontend contract: reflect padding, a periodic Hann window, magnitude STFT,
Slaney mel scale and normalization, and natural-log features. Extracted embeddings are materialized,
validated as finite `float32 [1, D]`, and bound to the decoded encoder/talker dimension before they
enter either transcript-backed or x-vector-only generation. They are cast to the talker compute
dtype only at prefix construction.

The prompt identity includes the model repository, pinned revision, artifact version, installed
integrity-manifest digest, runtime topology, and speaker-feature algorithm version. Changed weights,
frontend code, or runtime profile therefore cannot hit an older in-memory entry or persisted clone
artifact. This is especially important for x-vector-only mode because no reference acoustic codes
can compensate for a malformed speaker embedding.

## Sampling and the hot loop

The talker uses the official effective generation parameters. The subtalker/Code Predictor
inherits temperature, top-k, and top-p by default; diagnostic overrides are independent and must
never be described as production defaults. Temperature is applied before probability filtering,
EOS remains eligible, repetition state is maintained incrementally, and reusable sampler/mask
scratch avoids rebuilding equivalent arrays in each token step.

Lazy MLX timings around graph construction are not kernel attribution. Performance conclusions
must use the tracked benchmark registry or an Instruments profile with the runtime signposts.

## Production streaming

The producer retains only pending codes needed for the next decode. A mode/profile-specific first
chunk establishes initial playback; later chunks may be larger to amortize decoder work. The Mimi
decoder maintains causal state across partitions. Non-final audio may be `asyncEval`-materialized
while token generation continues, but the consumer synchronizes before use and the final chunk has
an explicit barrier before terminal completion and atomic WAV publication.

Cancellation terminates the producer, resets reusable state, and produces exactly one terminal
result. The generation gate permits one owner, transfers FIFO, and handles cancellation after
ownership transfer without releasing another task’s permit.

The public facade event channel has a fixed nonterminal capacity plus one reserved terminal slot.
Offering an event never suspends on consumer progress: an undrained full buffer rejects the next
nonterminal event, terminates the session as a runtime failure, preserves the order of events that
were already accepted, and still publishes the terminal event. Cancellation intentionally discards
queued nonterminal work and replaces it with the cancellation terminal. Consequently,
`waitForTermination()` never depends on a caller draining `events`, and neither overflow nor
cancellation can silently lose the terminal result.

## Memory and caches

Pending token retention, platform-sized prepared caches, bounded MLX cache policy, reusable PCM
scratch, and per-tier cleanup keep resident growth controlled. Sliding/quantized KV experiments,
legacy speed profiles, and alternate eval strategies must be read through their ledger state; a
knob in source is not proof that it is active or beneficial.

Memory-qualified benchmarks use telemetry schema v8 and evidence manifest v2. Process memory
stays attributed to the process that measured it; macOS app/XPC totals use uptime-aligned samples.

## Mimi decoder correctness

The speech-tokenizer decoder uses input-side overlap-and-discard, exact block-count fallback,
explicit reset isolation, and timing/no-timing parity. Fixed and randomized partition tests must
produce the same waveform. The generic `streamingDecode(..., chunkTokens: 100)` helper represents
about eight seconds of 12.5 Hz codec frames; production Qwen streaming derives much smaller
first/later chunk sizes from the requested interval and mode profile.

## Evidence states

- **production**: executed in the shipping runtime.
- **diagnostic**: available only for measurement or fault isolation.
- **internal**: package assurance or support behavior not exposed as a product capability.
- **retired**: historical behavior that is no longer current.

The historical delta ledger has a broader state vocabulary for upstream comparison. Those labels do
not override the current capability contract.

Current measured results live in `benchmarks/HISTORY.md`. Historical optimization narratives may
explain why a path was rejected, but they are never current performance evidence by themselves.
