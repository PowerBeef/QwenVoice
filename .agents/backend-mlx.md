# Backend / MLX Engineer

> Agent role for `QwenVoiceBackendCore`, `QwenVoiceCore`, the vendored `mlx-audio-swift`
> stack, and everything related to model loading, prompt construction, synthesis,
> memory policy, and audio QC.

## Boundaries

**Owns:**
- `Sources/QwenVoiceBackendCore/`
- `Sources/QwenVoiceCore/` (engine core, generation semantics, model registry, downloader, telemetry)
- `third_party_patches/mlx-audio-swift/`
- `Sources/Resources/qwenvoice_contract.json`

**Does NOT own:**
- macOS SwiftUI / XPC client wiring (`.agents/macos-engineer.md`)
- iOS app UI / on-device coordination (`.agents/ios-engineer.md`)
- Build scripts, CI, signing, release packaging (`.agents/release-qa-engineer.md`)

**Consults:**
- `docs/ARCHITECTURE.md` §4 (engine core), §11 (model management), §12 (telemetry)
- `docs/reference/{mlx-guide,qwen3-tts-guide,mimi-codec-guide,metal-guide,swift-performance-guide,ios-engine-optimization,telemetry-and-benchmarking}.md`
- Root `AGENTS.md` (Hard rules) + [`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) (engine invariants)

## Required pre-read

Before changing anything in this layer, read:
1. `docs/ARCHITECTURE.md` §4 (the `TTSEngine` abstraction, factory, pipeline, memory, streaming, prewarm, clone cache, cancellation, QC).
2. The relevant subsystem guide under `docs/reference/` (e.g. `mlx-guide.md` for `MLXArray`/`Memory`/`GPU`, `qwen3-tts-guide.md` for prompt construction, `mimi-codec-guide.md` for codec work).
3. `Sources/Resources/qwenvoice_contract.json` if you are touching model IDs, speakers, variants, or HF revisions.

## Tools and skills (Codex)

- **Shell scripts are authoritative** for build/test:
  - `scripts/build_foundation_targets.sh macos|ios` for compile-safety.
  - `scripts/build.sh cli` to build `vocello`.
  - `QWENVOICE_DEBUG=1 ./build/vocello bench …` for perf/quality gates.
- Use `$swift-mlx` and `$swift-mlx-lm` for MLX/MLX LM implementation guidance. Use the relevant
  Axiom Swift, concurrency, and performance skills for language, isolation, and profiling
  decisions. Read each selected skill before use.
- Skills guide implementation and diagnosis; shell builds, tests, benchmarks, and their artifacts
  remain authoritative. Where no skill applies, inspect vendored source and authoritative Apple,
  package, or Hugging Face documentation.
- Browser inspection may support website work, but never replaces benchmarks, compile checks, or
  physical-device iOS gates.
- XCUITest is the sole autonomous app UI driver. Smoke and benchmark UI lanes are explicit
  frontend acceptance only and never a prerequisite for a commit, push, pull request, ordinary
  merge, ordinary CI, or release package. Frontend observations do not prove backend completion;
  typed app/XPC/backend rows must still join by `generationID`.

## Build / test commands

```sh
# Compile-safety for the core frameworks
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
scripts/macos_test.sh test   # Core, XPC transport, and owned Qwen3 runtime contracts

# Build the CLI and run a quick generate
./scripts/build.sh cli
QWENVOICE_DEBUG=1 ./build/vocello custom --variant speed --text "Hello world."

# Perf gate (mandatory listening pass for release-affecting changes)
QWENVOICE_DEBUG=1 ./build/vocello bench --modes clone --variants speed \
  --lengths short,medium,long --warm 3 --voice <prepared-voice> \
  --label "backend-qa" --ledger
```

## Invariants (do not regress)

- **Prewarm reentrancy gate.** `acquirePrewarmSlot()` / `releasePrewarmSlot()` must stay paired.
  Never pair a throwing `try? await acquirePrewarmSlot()` with an unconditional
  `defer { releasePrewarmSlot() }` — on a throw the slot isn't held and the defer releases
  someone else's slot.
- **Streaming buffer policy.** macOS uses `.unbounded`; iOS uses `.bufferingNewest(64)`.
  Do not change this without a memory-tight review.
- **Cancellation ownership.** iOS cancel is cooperative only. `MLXTTSEngine.generate`'s catch
  must not rethrow `CancellationError` early (it would skip the `loadState` reset and strand
  the engine in `.running`).
- **Per-tier memory.** `NativeMemoryPolicyResolver` sets policy per device class. There is
  **no hard `Memory.memoryLimit` in production** and **no Quality→Speed OOM fallback**.
- **Decoder drift.** The vendored `Qwen3TTSSpeechTokenizer` uses input-side overlap-and-discard.
  Do not "fix" drift by changing the output side.
- **SPM pins move in lockstep.** `mlx-swift` and `mlx-swift-lm` are bumped together, never
  alone, and only after a benchmark-gated review on a throwaway branch.
- **MLX is the only backend.** Do not pivot to Core ML or another runtime.

## Common mistakes

- Editing `QwenVoice.xcodeproj/project.pbxproj` directly. Always edit `project.yml` and run
  `./scripts/regenerate_project.sh`.
- Adding a generic `#if DEBUG` behavior fork. There is no Debug configuration or `DEBUG` symbol;
  use runtime `DebugMode.isEnabled` or a narrowly named condition owned by a test target.
- Touching the iOS Simulator. Backend work is validated through macOS builds, foundation-target
  builds, and on-device iOS lanes — never the simulator.
- Changing the contract JSON without updating the iOS catalog check
  (`scripts/check_ios_catalog.sh`) if model eligibility changes.
