# Vocello Qwen3 audio runtime provenance

This directory is Vocello-owned product source derived from
[`Blaizzy/mlx-audio-swift`](https://github.com/Blaizzy/mlx-audio-swift). It is copied into the
repository, not tracked as a submodule and not maintained as a rebasing fork.

Machine-readable provenance, package facts, and semantic deltas are authoritative:

- [`VENDOR_MANIFEST.json`](VENDOR_MANIFEST.json)
- [`UPSTREAM_BASELINE.json`](UPSTREAM_BASELINE.json)
- [`PATCHES.json`](PATCHES.json)

## Import and review points

- Imported release: `v0.1.2`
- Imported commit: `fcbd04daa1bfebe881932f630af2ba6ce9af3274`
- Last reviewed upstream head: `d302a5c6080d2bb97bae38c7418f82abb76013b6` on 2026-07-14
- Official Qwen model family: [`QwenLM/Qwen3-TTS`](https://github.com/QwenLM/Qwen3-TTS)

The import was specialized to Qwen3-TTS. Vocello retains `MLXAudioCore`, the Mimi subset of
`MLXAudioCodecs`, `MLXAudioTTS`, and product-owned Qwen3 tests. STT, STS, VAD, LID, G2P, UI/tools,
non-Qwen TTS models, and non-Mimi codec families are outside the production package surface.

## Current integration boundary

`QwenVoiceCore` owns model coordination, generation semantics, memory policy, telemetry sessions,
and the application-facing engine. The vendored package owns the lower-level Qwen3 model,
tokenizer, sampler, streaming, codec, and clone-artifact implementation.

`QwenVoiceBackendCore` does **not** re-export MLX or MLXAudio. It contains provenance, shared
generation defaults and policy vocabulary, finish reasons, and a minimal app-owned backend
abstraction.

The macOS app reaches the engine through an XPC service. The iPhone engine runs in-process. There
is no iPhone extension engine and no repository-owned Python inference runtime.

## Production posture

Production generation uses bounded chunked streaming for Custom Voice, Voice Design, and Voice
Clone. The pipeline asynchronously materializes non-final chunks, synchronizes consumers, and
uses a final barrier before reporting completion or publishing the final WAV. Full-result helpers
remain useful for explicit offline/diagnostic paths; they are not the universal production default.

Sampling follows the checkpoint’s official talker defaults. The Code Predictor/subtalker inherits
the effective talker temperature, top-k, and top-p unless a controlled diagnostic override is set.
See [`PERFORMANCE.md`](PERFORMANCE.md) for the active, diagnostic, dormant, and rejected mechanisms.

## Selective upstream intake

Future updates are selective ports, not rebases:

1. Record the upstream head reviewed in `VENDOR_MANIFEST.json`.
2. Compare it with the pinned baseline and current semantic ledger.
3. Port only behavior that preserves Vocello’s model, artifact, streaming, cancellation, memory,
   output, and telemetry contracts.
4. Update the affected `PATCHES.json` entries with upstream disposition and removal criteria.
5. Run `python3 scripts/vendor_runtime_contract.py validate` and the deterministic backend gates.

Never replace the directory wholesale, infer parity from matching filenames, or treat a newer
upstream implementation as equivalent without the relevant deterministic and benchmark evidence.
