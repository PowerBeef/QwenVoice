# Vocello Qwen3 audio runtime

This directory is Vocello's owned, specialized runtime derived from
[`mlx-audio-swift`](https://github.com/Blaizzy/mlx-audio-swift). It is not the upstream multi-model SDK.
The import was narrowed to the Qwen3-TTS runtime and the codec primitives that runtime needs; deleted
upstream model families remain recoverable from Git history or the recorded upstream baseline.

## Checked-in products

- **`MLXAudioCore`** — generation protocols and shared audio utilities.
- **`MLXAudioCodecs`** — the Mimi codec subset used by the Qwen3 speech tokenizer.
- **`MLXAudioTTS`** — Qwen3-TTS only.
- **`Qwen3RuntimeTests`** — deterministic coverage for the runtime behavior Vocello owns.

There are no checked-in STT, speech-to-speech, VAD/diarization, UI, or non-Qwen TTS targets. Do not use
the upstream README's model catalogue as evidence that a model is supported by this fork.

## Supported model contract

The owned model family is **Qwen3-TTS 12 Hz**. Vocello currently selects the 1.7B Base, CustomVoice,
and VoiceDesign families in 4-bit and 8-bit variants. The authoritative repository IDs, pinned
Hugging Face revisions, artifact versions, required files, tokenizer profile, and platform eligibility
live in:

- [`Sources/Resources/qwenvoice_contract.json`](../../Sources/Resources/qwenvoice_contract.json)

The local implementation and family-level API notes live in:

- [`Sources/MLXAudioTTS/Models/Qwen3TTS/`](Sources/MLXAudioTTS/Models/Qwen3TTS/)

Do not add a model to this README as a declaration of support. Update the contract, loader validation,
tests, and benchmark evidence together when the product adopts a new artifact.

## Integration and ownership

Vocello consumes this package as a local dependency from the generated Xcode project.
`QwenVoiceCore` coordinates the product engine while this package owns Qwen3 model loading,
sampling, streaming, Mimi decoding, and clone artifacts. `QwenVoiceBackendCore` contains shared
provenance/policy vocabulary; it does not re-export this package.

Keep MLX dependency versions synchronized with `project.yml`; see the repository backend role
playbook for the required upgrade gates.

```swift
.package(path: "third_party_patches/mlx-audio-swift")
```

The package requires Swift 6.1, macOS 14 or newer, or iOS 17 or newer. Vocello's application deployment
targets are stricter and remain authoritative for the shipped products.

## Verification

From the repository root, use the authoritative deterministic lane:

```sh
scripts/macos_test.sh test
```

That lane runs the owned `Qwen3RuntimeTests` target in addition to Vocello's Core and XPC integration
coverage. Model-dependent benchmark and frontend lanes remain explicit QA and are not prerequisites for
committing or publishing ordinary development work.

## Provenance and license

The import baseline, last upstream review, file inventory, and semantic deltas are recorded in
[`VENDOR_MANIFEST.json`](VENDOR_MANIFEST.json), [`UPSTREAM_BASELINE.json`](UPSTREAM_BASELINE.json),
and [`PATCHES.json`](PATCHES.json). Active performance design is in
[`PERFORMANCE.md`](PERFORMANCE.md). Upstream attribution remains with the original project and its
contributors. This runtime remains under the MIT license; see [`LICENSE`](LICENSE).
