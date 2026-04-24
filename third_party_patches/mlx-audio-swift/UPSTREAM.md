# mlx-audio-swift Vendor Metadata

This directory is a vendored snapshot of:

```text
https://github.com/Blaizzy/mlx-audio-swift
```

It is copied into the root repository as source, not tracked as a nested git submodule. The root `project.yml` links only the `MLXAudioCore` and `MLXAudioTTS` products, though the vendored package manifest may expose additional upstream products and tools.

## Local Delta Rationale

QwenVoice/Vocello keeps this snapshot in-tree so the native Apple-platform runtime can depend on a deterministic MLXAudio surface for Qwen3 TTS, custom voice, voice design, clone prompt handling, and streaming behavior.

## Rebase Checklist

- Record the upstream commit or release used for the new snapshot.
- Preserve Qwen3 TTS, custom voice, voice design, clone prompt, and streaming behavior expected by `Sources/QwenVoiceCore/`.
- Regenerate the Xcode project when package products or transitive dependency pins change.
- Run the Swift, contract, native, macOS foundation, and iPhone foundation gates listed in `docs/reference/mlx-audio-swift-patching.md`.
- Verify packaging still excludes `Contents/Resources/backend`, `Contents/Resources/python`, and `Contents/Resources/ffmpeg`.

## Current Upstream Revision

The current upstream source revision has not been recorded in a nested git history. The next vendor refresh should replace this section with the exact upstream commit SHA and snapshot date.
