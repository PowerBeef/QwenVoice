# Foundation Projects Audit

Audit date: 2026-04-28

This report documents the upstream projects that meaningfully shaped the current QwenVoice/Vocello codebase, whether they are still used, whether the pinned version appears current, and whether the repo carries local customization.

The audit is grounded in:

- `project.yml`
- `QwenVoice.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `Sources/Resources/qwenvoice_contract.json`
- `third_party_patches/mlx-audio-swift/Package.swift`
- `third_party_patches/mlx-audio-swift/UPSTREAM.md`
- `docs/reference/mlx-audio-swift-patching.md`
- live `git ls-remote` checks against upstream repositories
- live Hugging Face model API checks for the `mlx-community/Qwen3-TTS-*` model repos

## Executive Summary

The current app is still built on the same core foundation stack: Qwen3-TTS model families, a vendored `mlx-audio-swift` runtime layer, MLX Swift, Hugging Face Swift libraries, and GRDB for local persistence.

The healthiest dependencies are `GRDB.swift`, `swift-huggingface`, `swift-jinja`, and several Apple transitive packages, whose pinned versions match the latest release tags observed during this audit. The highest-risk foundation is the vendored `third_party_patches/mlx-audio-swift` tree: it is intentionally customized and central to generation, but its exact upstream source SHA is not recorded. The main runtime stack is also behind current upstream MLX tags, so updates should be treated as a controlled backend/vendor refresh with benchmark and audio-QC proof, not a routine package bump.

## Core Foundations

| Foundation | Current source | Still used? | Currentness | Customized locally? | Recommendation |
| --- | --- | --- | --- | --- | --- |
| Qwen3-TTS / mlx-community models | `Sources/Resources/qwenvoice_contract.json` | Yes, all three modes | Model repos are live, but not pinned to immutable revisions | No local model files are tracked; app contract customizes mode/variant mapping | Add optional immutable revision pins in a future stability pass |
| `mlx-audio-swift` | `third_party_patches/mlx-audio-swift/` | Yes, central runtime foundation | Unknown exact snapshot; upstream SHA is not recorded | Yes, intentionally vendored and adapted | Record upstream SHA before further backend work |
| MLX Swift | `project.yml`, Package.resolved | Yes, native tensor/runtime dependency | Pinned `0.30.6`; latest observed tag `0.31.3` | No | Defer update to vendor refresh benchmark |
| MLX Swift LM | Vendored package dependency | Yes, via MLXAudio TTS internals | Pinned `2.30.6`; latest observed tag `3.31.3` | No | Defer update to vendor refresh benchmark |
| Hugging Face Swift tooling | `project.yml`, vendored package manifest | Yes, direct package plus vendored imports | `swift-huggingface` current; `swift-transformers` behind | No package patches; app has its own downloader | Keep `swift-huggingface`; review Transformers only with MLXAudio refresh |
| GRDB.swift | `project.yml`, Package.resolved | Yes, history and saved-generation SQLite | Pinned `7.10.0`; latest observed tag `v7.10.0` | No | Keep unchanged |

### Qwen3-TTS And Model Repositories

Qwen3-TTS remains the model foundation for the current product. The root README credits `Qwen3-TTS`, and `Sources/Resources/qwenvoice_contract.json` maps the three product modes to Qwen3-TTS model families:

| Product mode | macOS Quality variant repo | macOS/iPhone Speed variant repo | Contract artifact version |
| --- | --- | --- | --- |
| Custom Voice | `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit` | `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit` | `2026.04.05.2` |
| Voice Design | `mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit` | `mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit` | `2026.04.05.2` |
| Voice Cloning | `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit` | `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit` | `2026.04.05.2` |

macOS treats both variant repos as first-class downloadable rows, with the active default and recommendation derived from hardware class. iPhone remains Speed-only. The live Hugging Face checks recorded during this 2026-04-28 audit found the referenced model repos and repository SHAs below; they were not refreshed for the model-selection documentation update.

| Model repo | Last modified | Current SHA |
| --- | --- | --- |
| `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit` | 2026-01-26 | `41d3337e8b7f2843a75841595fc14e4b9a7a4b96` |
| `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit` | 2026-01-25 | `f35faf19b0cc2160865af64ecf0f22f83d335135` |
| `mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit` | 2026-01-25 | `f90d617701d9f7f4ca499291e0b57f2b3c2fd2ee` |
| `mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit` | 2026-01-25 | `5c390979e4b93af5f2932f90742ca99c7dd04687` |
| `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit` | 2026-01-25 | `e7dd0585652209fa0d7783659aad4e8a324de11c` |
| `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit` | 2026-01-25 | `37e955a1deb861c088ae5f3a67043185f3d1a60c` |

The app does not currently pin those remote SHAs in the contract. The `artifactVersion` field is a repo contract/delivery marker, not an immutable Hugging Face revision lock. That is acceptable for development, but release hardening would benefit from a revision field so the model catalog can prove exactly which remote artifacts it expects.

### Vendored `mlx-audio-swift`

`third_party_patches/mlx-audio-swift/` is still the most important inherited code foundation in the repo. `project.yml` links it as a local Swift package:

```yaml
packages:
  MLXAudio:
    path: third_party_patches/mlx-audio-swift
```

The root app and engine targets link only `MLXAudioCore` and `MLXAudioTTS`, while the vendored package still exposes broader upstream products such as STT, VAD, LID, STS, and tools. Local inspection found about 310 files in the vendor tree.

The vendor docs state that this copy is intentionally customized for:

- Qwen3 TTS model families
- clone-prompt construction
- streaming interval wiring
- custom voice and voice design streaming
- deterministic app link surfaces
- avoiding any repo-owned Python backend path

`UPSTREAM.md` explicitly says the current upstream source revision has not been recorded. A live upstream check found `Blaizzy/mlx-audio-swift` at `dfb938211eb4132966bd703e626c0307a0b4bb44` with latest tag `v0.1.2`, but this repo cannot prove which upstream commit the vendored snapshot came from. Treat the vendored tree as maintained local source until that provenance is recorded.

### MLX Swift And MLX Swift LM

MLX Swift is a direct package in `project.yml` and is imported by `QwenVoiceCore`, retained native runtime files, and iPhone bootstrap code. MLX Swift LM is pulled by the vendored `mlx-audio-swift` package and used through MLXAudio TTS internals.

| Package | Pinned version | Pinned revision | Latest observed tag | Status |
| --- | --- | --- | --- | --- |
| `mlx-swift` | `0.30.6` | `6ba4827fb82c97d012eec9ab4b2de21f85c3b33d` | `0.31.3` | Behind |
| `mlx-swift-lm` | `2.30.6` | `7e19e09027923d89ac47dd087d9627f610e5a91a` | `3.31.3` | Behind |

These should not be bumped casually. They sit under generation quality, runtime memory behavior, first-audio timing, and the patched MLXAudio surface. Any update should be handled as a vendor/runtime refresh with Swift tests, macOS and iOS foundation builds, autonomous audio QC, and cold/warm timing comparisons.

### Hugging Face Swift Tooling

The repo has two Hugging Face surfaces:

- `swift-huggingface` is declared directly in `project.yml` and imported by the vendored MLXAudio package.
- `swift-transformers` is a vendored MLXAudio dependency, used by tokenizer/model internals rather than directly imported by app source.

The app itself uses `Sources/Services/HuggingFaceDownloader.swift` for repository downloads, so model delivery does not depend on Hugging Face Swift API calls in app-layer source.

| Package | Pinned version | Latest observed tag | Direct app imports? | Status |
| --- | --- | --- | --- | --- |
| `swift-huggingface` | `0.9.0` | `0.9.0` | No direct Swift imports in `Sources/`; used by vendored package | Current |
| `swift-transformers` | `1.1.9` | `1.3.0` | No direct Swift imports in `Sources/`; used by vendored package | Behind |
| `swift-jinja` | `2.3.5` | `2.3.5` | Transitive through Transformers | Current |

The practical recommendation is to keep `swift-huggingface` as-is and evaluate `swift-transformers` only as part of an MLXAudio/MLX refresh.

### GRDB.swift

GRDB remains the SQLite foundation for local generation history and saved output metadata. It is directly imported by macOS and iPhone persistence surfaces:

- `Sources/Services/DatabaseService.swift`
- `Sources/Models/Generation.swift`
- `Sources/iOSSupport/Services/DatabaseService.swift`
- `Sources/iOSSupport/Models/Generation.swift`

`project.yml` pins `GRDB.swift` to `7.10.0`, and the resolved revision is `36e30a6f1ef10e4194f6af0cff90888526f0c115`. A live upstream check found latest tag `v7.10.0`, so this dependency appears current. There is no local GRDB customization.

## Compact Transitive Package Appendix

These packages are resolved through the Swift package graph. They are not product foundations in the same sense as Qwen3-TTS or MLXAudio, but they affect build determinism and should remain visible in dependency audits.

| Package | Pinned | Latest observed tag | Currentness |
| --- | --- | --- | --- |
| `eventsource` | `1.4.1` | `1.4.1` | Current |
| `swift-asn1` | `1.7.0` | `1.7.0` | Current |
| `swift-atomics` | `1.3.0` | `1.3.0` | Current |
| `swift-collections` | `1.4.1` | `1.4.1` | Current |
| `swift-crypto` | `4.4.0` | `4.5.0` | Behind |
| `swift-nio` | `2.98.0` | `2.99.0` | Behind |
| `swift-numerics` | `1.1.1` | `1.1.1` | Current |
| `swift-system` | `1.6.4` | `1.6.4` | Current |
| `yyjson` | `0.12.0` | `0.12.0` | Current |

The behind transitive packages are not urgent by themselves. Updating them should follow the owning package that brings them in, usually the Hugging Face or MLXAudio graph.

## Customization Summary

| Area | Local customization level | Notes |
| --- | --- | --- |
| Product app code | High | QwenVoice/Vocello owns the macOS/iPhone shells, XPC/extension boundaries, playback, persistence, and generation coordinators. |
| Model catalog | Medium | Contract maps upstream model repos into product modes, variants, required files, and output folders. |
| `mlx-audio-swift` | High | Vendored and patched source boundary for Qwen3 TTS behavior and streaming. |
| MLX / MLX LM / Hugging Face packages | Low | Consumed as pinned Swift packages; no local patches outside the vendored MLXAudio manifest. |
| GRDB | Low | Consumed as a normal pinned Swift package. |

## Actionable Recommendations

1. Record the exact upstream `mlx-audio-swift` commit SHA and snapshot date before any further backend or vendor work. This is the largest provenance gap.
2. Add optional immutable Hugging Face revision pins to the model contract in a future release-hardening pass, while keeping the existing repo IDs and artifact versions.
3. Defer MLX Swift, MLX Swift LM, and Swift Transformers upgrades until a dedicated vendor refresh can run source tests, macOS/iOS foundation builds, autonomous audio QC, and cold/warm generation timing.
4. Keep `GRDB.swift` and `swift-huggingface` unchanged for now because their pinned versions match the latest observed release tags.
5. Keep `third_party_patches/mlx-audio-swift/` narrow and readable; do not mass-format or fold unrelated upstream products into app targets.
