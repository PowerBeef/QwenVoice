# Patching `third_party_patches/mlx-audio-swift/`

This repo vendors a patched copy of [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) under `third_party_patches/mlx-audio-swift/`. The vendored tree is the source boundary for the native MLX TTS backend used by both Vocello on macOS and the in-development iPhone engine extension.

This doc exists so contributors can update, rebase, or audit the vendor delta without guessing.

## Why It's Vendored

The upstream package is moving quickly and Vocello depends on a specific combination of model surfaces (Qwen3 TTS families, clone-prompt plumbing, custom-voice + voice-design streaming) that is stable in the vendored snapshot but not always in upstream `main`. Keeping a vendored copy lets us:

- Pin the exact MLX + MLXAudio+Qwen3 combination we ship.
- Apply small patches that have not yet landed upstream.
- Build against a single deterministic checkout in CI without resolving multiple `Package.resolved` branches.

## Layout

```
third_party_patches/mlx-audio-swift/
├── Package.swift
├── Sources/
│   ├── MLXAudioCore/      # audio I/O + DSP + model-load utilities (Qwen3-live subset)
│   ├── MLXAudioCodecs/    # Mimi transformer/conv/quantization/seanet primitives only
│   └── MLXAudioTTS/       # Qwen3-TTS (the only model family)
└── …
```

The snapshot was **specialized to Qwen3-TTS on 2026-06-09** — the upstream multi-model
targets (STT/STS/VAD/LID/G2P/UI/Tools) and non-Mimi codec families were deleted
(restorable from upstream `fcbd04d`; see `UPSTREAM.md`).

The vendor tree is referenced from the root `project.yml` as:

```yaml
packages:
  MLXAudio:
    path: third_party_patches/mlx-audio-swift
```

## What We Patch

The vendor copy tracks upstream `mlx-audio-swift` `v0.1.2` commit `fcbd04daa1bfebe881932f630af2ba6ce9af3274`, then carries local deltas that are intentionally narrow. The owned production integration point is `Sources/QwenVoiceBackendCore/`; the vendor tree remains the lower-level MLXAudio implementation boundary.

- **Qwen3 TTS model families.** Clone-prompt construction, custom voice, voice design, tokenizer, codec, and model-loading surfaces follow the shape Vocello's `QwenVoiceCore` engine expects.
- **Reusable Qwen3 clone prompts.** `Qwen3TTSVoiceClonePrompt` persists `manifest.json`, `ref_codes.safetensors`, and `speaker_embedding.safetensors` for Saved Voices and transient `.qvoice_clone_prompts` entries. Manifest metadata includes schema version, model id, language, source-audio fingerprint, transcript presence/hash, x-vector mode, runtime-profile signature, and creation time so stale or mismatched artifacts are rebuilt instead of silently reused.
- **Chunked and full-result generation.** `Qwen3TTSModel` exposes both full-result and chunked Custom Voice, Voice Design, and Voice Cloning generation methods. macOS batch can remain quality-first/full-result, while iOS uses Vocello's internal chunked final-file pipeline for memory safety. Do not describe that app pipeline as Qwen's public Python true end-to-end streaming API.
- **Truncation is a failure.** The vendor layer reports `eos`, `maxTokens`, `cancelled`, or `failed` completion. `QwenVoiceCore` treats `maxTokens` as a quality failure instead of accepting a truncated waveform.
- **Deterministic app link surface.** The root app routes through `QwenVoiceBackendCore`. The vendored `Package.swift` exposes only the three Qwen3-live products (`MLXAudioCore`, `MLXAudioCodecs`, `MLXAudioTTS`); the snapshot is intentionally specialized and no longer tracks the upstream multi-model surface — an upstream sync is a selective re-port, not a rebase.
- **No repo-owned Python backend.** Nothing in the vendor tree reintroduces a Python bridge. This is a hard rule; see the Apple-platform QA gate.
- **Legacy streaming probes.** Per-chunk sub-stage timings, Instruments signposts, and async chunk eval probes are retained only for diagnostics and future preview experiments. They are not the production quality path and must not be used to change final waveform semantics without a fresh quality signoff.

Vendor metadata lives in `third_party_patches/mlx-audio-swift/UPSTREAM.md`. This directory is copied into the root repository as source, not maintained as a nested git submodule; do not use `git -C third_party_patches/mlx-audio-swift ...` as proof of an independent vendor history.

If you need the concrete source delta for a future rebase, record the upstream commit in `UPSTREAM.md`, compare a fresh upstream checkout against this directory, and keep the local changes narrow.

```bash
git diff --no-index /path/to/upstream/mlx-audio-swift third_party_patches/mlx-audio-swift
```

## Local Patch Policy

Targeted edits inside `third_party_patches/mlx-audio-swift/` are allowed again. Treat this tree as maintained repo-owned source, not read-only imported code, when the fix belongs in the lower-level MLXAudio/Qwen3 runtime rather than the app-facing `QwenVoiceCore` layer.

Allowed local patches include backend correctness, memory-pressure behavior, cancellation, streaming mechanics, model loading, diagnostics, and performance fixes. Keep them intentionally narrow, preserve upstream style, and avoid unrelated cleanup.

Keep local patches isolated from upstream refresh work:

- Do not use the vendored directory as a nested git repository or submodule.
- Do not casually replace the tree with a fresh upstream snapshot.
- Do not mass-format the vendor tree.
- Do not rename package products such as `MLXAudioCore` or `MLXAudioTTS`.
- Keep a full upstream rebase/snapshot in its own branch and commit series.

Before landing a local vendor patch:

- Confirm why the change belongs in `mlx-audio-swift` instead of `QwenVoiceCore`.
- Document behavior, memory, cancellation, streaming, or performance impact in the commit message or relevant reference doc.
- Preserve app-facing request/result contracts unless a separate plan explicitly changes them.
- Update `UPSTREAM.md` only for provenance, upstream revision, or rebase/snapshot metadata; small local patches do not need an `UPSTREAM.md` entry.
- Run `./scripts/check_project_inputs.sh`; add macOS/iOS foundation builds when source behavior changes.

## Rebase Procedure

When you want to advance the vendored copy to a newer upstream revision:

1. **Branch off `main`** in the root repo so the vendor bump is isolated.
2. **Sync the vendor tree.** Either cherry-pick upstream commits onto the vendored history, or drop a full snapshot and re-apply local patches. Preserve the patch commits as discrete revisions so future audits can read the delta.
3. **Update pins.** `project.yml` references the vendor by path — no version bump there. But `Package.resolved` may need regenerating if transitive dependencies (`mlx-swift`, `swift-huggingface`, `GRDB`, `swift-transformers`, etc.) moved. Regenerate via `./scripts/regenerate_project.sh` and confirm diffs.
4. **Run the validation gates:**
   ```bash
   ./scripts/check_project_inputs.sh
   ./scripts/build_foundation_targets.sh macos
   ./scripts/build_foundation_targets.sh ios
   ```
5. **Eyeball the release bundle.** An unsigned packaging run is cheap and catches bundle-shape regressions:
   ```bash
   ./scripts/release.sh --output-name Vocello-macos26-rebase
   ./scripts/verify_release_bundle.sh build/Release/Vocello.app
   ./scripts/verify_packaged_dmg.sh build/Release/Vocello-macos26-rebase.dmg build/Release/release-metadata.txt
   ```

## Build Checklist After A Rebase

- [ ] macOS generic compile green (`build_foundation_targets.sh macos`).
- [ ] iPhone generic compile green (`build_foundation_targets.sh ios`).
- [ ] Unsigned DMG packaging + `verify_release_bundle` + `verify_packaged_dmg` green.
- [ ] No `Contents/Resources/backend`, `Contents/Resources/python`, or bundled `Contents/Resources/ffmpeg` leaks into the packaged artifact.

## Things Not To Do

- **Do not reintroduce a Python runtime path.** The repo's build-gate rule forbids it. If an upstream change adds Python bootstrap scripts, exclude or stub them in the vendor layer.
- **Do not rename vendor products** (`MLXAudioCore`, `MLXAudioTTS`). The root `project.yml` and every import in `Sources/QwenVoiceCore/` would need a coordinated change.
- **Do not mass-reformat the vendor tree.** Preserve upstream code style so future upstream diffs stay readable.

See also [`../../AGENTS.md`](../../AGENTS.md) — Architecture (vendored backend), SPM dependencies, and Conventions.
