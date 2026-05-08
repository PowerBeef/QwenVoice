# mlx-audio-swift Vendor Metadata

This directory is a vendored snapshot of:

```text
https://github.com/Blaizzy/mlx-audio-swift
```

It is copied into the root repository as source, not tracked as a nested git submodule. The root `project.yml` now routes production use through the QwenVoice-owned `QwenVoiceBackendCore` target, which re-exports only the MLX, `MLXAudioCore`, and `MLXAudioTTS` surfaces needed by Vocello. The vendored package manifest may expose additional upstream products and tools so the snapshot stays close to upstream.

## Local Delta Rationale

QwenVoice/Vocello keeps this snapshot in-tree so the native Apple-platform runtime can depend on a deterministic MLXAudio surface for Qwen3 TTS, custom voice, voice design, clone prompt handling, local model-directory loading, and final WAV integration.

The May 2026 backend reset uses upstream `mlx-audio-swift` `v0.1.2` as the provenance seed and then applies only QwenVoice-required patches. Quality-first full-result generation is the production default; streaming probes remain available for diagnostics and future preview work, but must not affect the final waveform.

## Rebase Checklist

- Record the upstream commit or release used for the new snapshot.
- Preserve Qwen3 TTS, custom voice, voice design, clone prompt, quality-first full-result generation, and diagnostic streaming behavior expected by `Sources/QwenVoiceCore/`.
- Regenerate the Xcode project when package products or transitive dependency pins change.
- Run the Swift, contract, native, macOS foundation, and iPhone foundation gates listed in `docs/reference/mlx-audio-swift-patching.md`.
- Verify packaging still excludes `Contents/Resources/backend`, `Contents/Resources/python`, and `Contents/Resources/ffmpeg`.

## Current Upstream Revision

- Upstream repository: `https://github.com/Blaizzy/mlx-audio-swift`
- Upstream release tag: `v0.1.2`
- Upstream commit: `fcbd04daa1bfebe881932f630af2ba6ce9af3274`
- QwenVoice integration target: `Sources/QwenVoiceBackendCore/`

Retained QwenVoice deltas:

- Prepared local model-directory loading through `QwenVoiceCore`.
- Contract-backed model variants and pinned Hugging Face revisions.
- XPC and iPhone extension process isolation.
- Cancellation and unload coordination owned by the app engine boundary.
- Qwen3-TTS quality-first full-result generation using official sampling defaults and full-text nonstreaming conditioning for Custom Voice and Voice Design.
- Final WAV/output integration and benchmark/diagnostic metadata.

Intentionally omitted from the owned production path:

- Repo-owned Python backend or Python runtime.
- Standalone CLI surface.
- RC1 short text-length token clamps and Custom Voice `0.7 / 0.9` sampling override.
- Production dependence on async streaming chunk decode or live-preview chunk handoff.
