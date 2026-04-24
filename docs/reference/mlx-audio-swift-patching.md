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
│   ├── MLXAudioCore/
│   ├── MLXAudioTTS/
│   ├── MLXAudioSTS/
│   ├── MLXAudioSTT/
│   ├── MLXAudioVAD/
│   └── MLXAudioLID/
└── …
```

The vendor tree is referenced from the root `project.yml` as:

```yaml
packages:
  MLXAudio:
    path: third_party_patches/mlx-audio-swift
```

## What We Patch

The vendor copy tracks an upstream snapshot and then carries a small set of local deltas. Today the delta fingerprint is intentionally narrow — we do not mass-refactor upstream code. Broadly the shape is:

- **Qwen3 TTS model families.** Clone-prompt construction, streaming interval wiring, and voice-design emission paths follow the shape Vocello's `QwenVoiceCore` engine expects.
- **Deterministic app link surface.** The root app targets link only the `MLXAudioCore` and `MLXAudioTTS` products. The vendored `Package.swift` may expose additional upstream products and tools so the snapshot stays close to upstream.
- **No repo-owned Python backend.** Nothing in the vendor tree reintroduces a Python bridge. This is a hard rule; see the Apple-platform QA gate.

Vendor metadata lives in `third_party_patches/mlx-audio-swift/UPSTREAM.md`. This directory is copied into the root repository as source, not maintained as a nested git submodule; do not use `git -C third_party_patches/mlx-audio-swift ...` as proof of an independent vendor history.

If you need the concrete source delta for a future rebase, record the upstream commit in `UPSTREAM.md`, compare a fresh upstream checkout against this directory, and keep the local changes narrow.

```bash
git diff --no-index /path/to/upstream/mlx-audio-swift third_party_patches/mlx-audio-swift
```

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
   ./scripts/verify_release_bundle.sh build/Vocello.app
   ./scripts/verify_packaged_dmg.sh build/Vocello-macos26-rebase.dmg build/release-metadata.txt
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

See also:

- [`vendoring-runtime.md`](vendoring-runtime.md) — runtime/packaging boundaries.
- [`current-state.md`](current-state.md) — vendored native backend listed under Architecture.
