# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is the canonical operating guide for coding agents in QwenVoice. Session-level user, system, and developer instructions still take priority. When repo facts here disagree with the tree, trust the tree.

## Repo Identity

QwenVoice is the repository identity for the Apple-platform Vocello product line. The repo is a native Swift/Xcode codebase: a macOS app, a deferred iPhone app, a shared engine core in `QwenVoiceCore`, a bundled macOS XPC service, and an iPhone ExtensionFoundation engine extension.

- Repo name: `QwenVoice`. Forward app name: `Vocello`. macOS product: `Vocello.app` inside `Vocello-macos26.dmg`.
- Current `main` marketing version / build: `2.0.0` / `16`.
- Deployment targets: `macOS 26.0+`, `iOS 26.0+`. Hardware floor: Mac mini M1 with 8 GB RAM; iPhone 15 Pro for the deferred iPhone track.
- Public macOS beta is `Vocello v2.0.0-beta.1`. Public stable fallback remains `QwenVoice v1.2.3` for macOS 15 / non-beta users. The withdrawn `v2.0.0-rc1` must not be restored or advertised.
- Release track is macOS-first. Keep iPhone compile-safe, but iPhone TestFlight/App Store proof is not blocking unless the maintainer changes the track.

## Source Of Truth

When facts disagree, trust in this order:

1. `Sources/`
2. `project.yml`
3. `scripts/` and `.github/workflows/`
4. `Sources/Resources/qwenvoice_contract.json` — authoritative for model, speaker, output, variant, Hugging Face revision (40-char commit pin), and required-file metadata
5. `docs/reference/`
6. other prose docs

SourceKit / editor index errors are not authoritative — trust `xcodebuild`, `scripts/qa.sh`, and `scripts/build_foundation_targets.sh`.

## Non-Negotiables

- No repo-owned Python backend, Python setup path, standalone CLI surface, or bundled Python runtime.
- No heavy model load, prewarm, generation, or clone-prep work in a UI process. That work lives in the macOS XPC service or the iPhone engine extension.
- No iPhone artifacts in GitHub Releases. iPhone distribution is App Store / TestFlight only.
- No macOS 15 compatibility on `main`. macOS 15 belongs to the historical `v1.2.3` line.
- Do not restore the retired desktop-studio shell, inspector layout, oversized hero chrome, marketing-page UI, full-window footer player, or decorative glass/card redesigns.
- Release builds must not depend on `QW_TEST_SUPPORT`.
- Do not hand-edit the generated Xcode project. Edit `project.yml` and regenerate via `./scripts/regenerate_project.sh`.
- Do not run overlapping heavy `xcodebuild`, `qa.sh`, release packaging, live model generation, or benchmark jobs on the 8 GB development machine.

## Architecture (Big Picture)

The product is split into five layers that take reading multiple files to reconstruct. Generation never runs in the UI process; the UI talks to the engine through narrow adapters that own transport, isolation, and trust policy.

**Shared engine core** — `Sources/QwenVoiceCore/`
- `TTSEngine.swift` defines frontend-safe engine state and engine protocols.
- `SemanticTypes.swift`, `GenerationSemantics.swift` — shared request, result, event, mode, clone, and generation semantics.
- `ContractBackedModelRegistry.swift` loads the checked-in model contract.
- `MLXTTSEngine.swift`, `NativeEngineRuntime.swift`, `MLXModelLoadCoordinator.swift`, `NativeStreamingSynthesisSession.swift`, `NativeCloneSupport.swift`, `AudioPreparation.swift` own the active native generation path.
- `ExtensionEngine*.swift` owns iPhone extension IPC, transport, host replacement, invalidation, and teardown.
- `IOSMemorySnapshot.swift`, `NativeMemoryPolicyResolver.swift` own shared memory-pressure vocabulary and policy.
- Production audio is **quality-first full-result generation**. Streaming / live-preview paths are diagnostic and must not change the final waveform.

**macOS app shell** — `Sources/`, `Sources/Views/`, `Sources/Services/`, `Sources/ViewModels/`
- `QwenVoiceApp.swift` composes app-wide services, initializes engine selection, owns Settings.
- `ContentView.swift` owns the macOS `NavigationSplitView`, toolbar/search chrome, sidebar selection, persisted generation drafts.
- `Sources/Views/Generate/` owns Custom Voice, Voice Design, Voice Cloning screens.
- `Sources/Views/Settings/SettingsView.swift` is the unified Models / Playback / Storage settings surface. Do not reintroduce separate `ModelsView.swift` or `PreferencesView.swift`.
- `Sources/Views/Components/AppTheme.swift` centralizes macOS styling primitives.
- UI talks to the engine **only** through `QwenVoiceNative`.

**macOS engine isolation** — XPC service hosting the shared core
- `Sources/QwenVoiceNative/TTSEngineStore.swift` is the macOS UI-facing engine store.
- `Sources/QwenVoiceNative/XPCNativeEngineClient.swift` owns app-side XPC connection coordination.
- `Sources/QwenVoiceNative/GenerationChunkBroker.swift` brokers streaming chunks into app playback.
- `Sources/QwenVoiceEngineSupport/` carries transport models and trust-policy helpers shared by app and service.
- `Sources/QwenVoiceEngineService/EngineServiceHost.swift` hosts `MLXTTSEngine` from `QwenVoiceCore` inside the bundled XPC service.
- Keep app-facing state mapped through `TTSEngineFrontendState`.

**iPhone isolation** — ExtensionFoundation extension hosting the shared core
- `Sources/iOS/QVoiceiOSApp.swift`, `IOSAppBootstrap.swift`, `QVoiceiOSRootView.swift` own the iPhone shell and bootstrap.
- `Sources/iOS/TTSEngineStore.swift` is the iPhone UI-facing engine store.
- `Sources/iOS/VocelloEngineExtensionPoint.swift` owns monitor-backed extension discovery and preferred identity selection.
- `Sources/iOSEngineExtension/VocelloEngineExtensionHost.swift` hosts the isolated iPhone engine process.
- `Sources/iOS/IOSModelDeliveryActor.swift` + `Sources/iOSSupport/Services/IOSModelDeliverySupport.swift` own resumable iPhone model delivery.
- `Sources/iOSSupport/Services/AppPaths.swift` owns the App Group file layout. iPhone shared state uses App Group `group.com.qvoice.shared` under the app-owned `Vocello` subtree. Keep shared iPhone state file-based; do not add a parallel shared-user-defaults channel without an explicit architecture decision.

**Backend facade** — `Sources/QwenVoiceBackendCore/`
- Repo-owned synthesis backend facade seeded from upstream `mlx-audio-swift v0.1.2`. Carries Qwen3-TTS provenance, official sampling defaults, finish reasons, and the narrow backend interface that `QwenVoiceCore` consumes.

**Shared playback / persistence**
- `Sources/SharedSupport/Services/GenerationPersistence.swift` owns cross-platform generation persistence handoff.
- `Sources/SharedSupport/ViewModels/AudioPlayerViewModel.swift` owns playback, live preview, handoff, and live-preview diagnostics.

## Model Contract

`Sources/Resources/qwenvoice_contract.json` is the source of truth for model metadata. Every model/variant carries an immutable 40-character Hugging Face commit revision; macOS downloads pin that revision instead of a moving branch.

- Logical modes: `custom` → `outputs/CustomVoice/`, `design` → `outputs/VoiceDesign/`, `clone` → `outputs/Clones/`.
- Variants: macOS exposes `Speed` (4-bit) and `Quality` (8-bit) for all three modes. iPhone is Speed-only.
- 8 GB / floor Macs default to and recommend Speed. Mid / high-memory Macs default to and recommend Quality.
- Variant-specific IDs (`pro_custom_speed`, `pro_custom_quality`, `pro_design_*`, `pro_clone_*`) own install status, downloads, repair / delete actions, and progress. Legacy base IDs (`pro_custom`, `pro_design`, `pro_clone`) are compatibility aliases that resolve to the hardware-recommended variant.
- Default speaker: `aiden`. English-native: `aiden`, `ryan`. Chinese-native: `vivian`, `serena`. Speaker labels annotate native-language guidance (e.g. `Aiden - English native`).
- Model-folder families: `Qwen3-TTS-12Hz-1.7B-CustomVoice-{4bit,8bit}`, `Qwen3-TTS-12Hz-1.7B-VoiceDesign-{4bit,8bit}`, `Qwen3-TTS-12Hz-1.7B-Base-{4bit,8bit}` (cloning).

## Runtime Storage

Default macOS app-support root:

```
~/Library/Application Support/QwenVoice/
  models/
  .qwenvoice-downloads/
  outputs/
    CustomVoice/
    VoiceDesign/
    Clones/
  voices/
  history.sqlite
```

Override with `QWENVOICE_APP_SUPPORT_DIR=/path/to/custom/app-support`. iPhone state lives under App Group `group.com.qvoice.shared` (see iPhone isolation above).

## Xcode Graph

`project.yml` is generated by XcodeGen into `QwenVoice.xcodeproj`. Pinned packages:

- `GRDB` exact `7.10.0`
- `MLXAudio` from local path `third_party_patches/mlx-audio-swift`
- `MLXSwift` exact `0.30.6`
- `SwiftHuggingFace` exact `0.9.0`

Maintained schemes: `QwenVoice` (macOS build/archive), `QwenVoice Foundation` (macOS tests with `QwenVoiceSource` and `QwenVoiceRuntime` plans), `VocelloiOS` (iPhone build/archive), `VocelloiOS Foundation` (iPhone foundation tests), `Vocello UI` (macOS UI smoke tests).

`third_party_patches/mlx-audio-swift/` is intentionally large tracked vendored source — not generated output. Don't delete or replace it as a build artifact.

## Common Commands

Start with cheap validation:

```sh
./scripts/check_project_inputs.sh
./scripts/qa.sh validate
./scripts/qa.sh test --layer contract
```

Regenerate after editing `project.yml`:

```sh
./scripts/regenerate_project.sh
```

Builds:

```sh
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build
xcodebuild -project QwenVoice.xcodeproj -scheme VocelloiOS \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES build
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
```

Before any user-requested or agent-triggered build, remove stale repo-local outputs/caches first. Prefer the build script's built-in fresh-build cleanup; otherwise run `./scripts/clean_build_caches.sh`. Scope cleanup to `build/`, `.build/`, `.swiftpm/`, and local DerivedData. **Never** delete app data, downloaded models, generated audio outputs, source files, tags, or remote refs.

QA layers and skip semantics:

```sh
./scripts/qa.sh test --layer swift
./scripts/qa.sh test --layer native
./scripts/qa.sh test --layer ios          # structurally skips when no iPhone simulator
./scripts/qa.sh test --layer e2e          # may soft-skip on TCC/window issues
./scripts/qa.sh test --layer perf-static
./scripts/qa.sh test --layer all          # excludes perf
./scripts/qa.sh test --layer perf         # opt-in, model-heavy; needs installed models
```

- Strict release-machine UI proof: `QWENVOICE_E2E_STRICT=1 ./scripts/qa.sh test --layer e2e`.
- xcresult bundles land under `build/harness/results/`; inspect them when a QA lane fails.
- Run a single XCTest with `xcodebuild test -only-testing:QwenVoiceTests/<ClassName>/<testName>` against the foundation scheme.
- **Agent-driven UI automation must use computer-use, not XCUITest.** Keep XCUITest for CI or maintainer-requested controlled-machine proof.

Performance and audio-QC:

```sh
./scripts/qa.sh test --layer perf
QWENVOICE_AUDIO_QC_MODES=CustomVoice ./scripts/qa.sh test --layer perf
./scripts/compare_perf_manifest.sh
```

Desktop UI benchmark (user-perceived timing, paste latency, sheet routing, playback handoff) — this is the default benchmark method:

```sh
./scripts/bench_ui_generation.sh <mode> <length> <state> <sample> [csv_path] [--log-file <path>]
./scripts/bench_ui_generation.sh <mode> <length> <state> <sample> [csv_path] --external-trigger
```

Agents must pass `--external-trigger`: the default mode shells out to `osascript` (`tell application` + keystroke), which is not in the Bash allowlist and would stall on a permission prompt. In `--external-trigger` mode the script prints `READY_FOR_TRIGGER` on both stdout and stderr, then waits for an external driver (computer-use) to send Cmd+Return. The script enforces a single-instance preflight on Vocello before timing starts.

Use `qa.sh test --layer perf` for engine-internal regression checks; the UI bench captures the full pipeline.

Local release and verification (macOS):

```sh
./scripts/release.sh --preflight full
./scripts/verify_release_bundle.sh build/Vocello.app
./scripts/verify_packaged_dmg.sh build/Vocello-macos26.dmg build/release-metadata.txt
```

Release artifacts must not contain `Contents/Resources/backend`, `Contents/Resources/python`, or bundled `Contents/Resources/ffmpeg`.

iPhone TestFlight tooling (deferred from current macOS signoff):

```sh
./scripts/check_ios_catalog.sh
./scripts/release_ios_testflight.sh
./scripts/verify_ios_release_archive.sh
```

Disk cleanup:

```sh
./scripts/clean_build_caches.sh
./scripts/clean_build_caches.sh --aggressive
./scripts/clean_build_caches.sh --dry-run
```

Shell pipeline exit codes: when piping `qa.sh`, `bench_ui_generation.sh`, or `compare_perf_manifest.sh` output through `tee`, `head`, `grep`, etc., bash's default pipeline exit is the **last** command's status (usually 0), so an upstream non-zero exit becomes invisible. When exit code matters, use `set -o pipefail`, read `${PIPESTATUS[0]}` instead of `$?`, capture to a tempfile (`cmd > /tmp/out.log 2>&1`), or drop the pipe entirely.

## CI Workflows

- `.github/workflows/project-inputs.yml` → `Project Inputs`
- `.github/workflows/apple-platform-validation.yml` → `Apple Platform QA Gate` (project regeneration, `qa.sh validate`, contract/source/native/perf-static/UI smoke layers, generic macOS/iPhone builds, unsigned macOS release verification)
- `.github/workflows/macos-release.yml` → `Vocello macOS Release` (signed public macOS release path)
- `.github/workflows/ios-testflight.yml` → `Vocello iOS TestFlight` (maintained but deferred)
- `.github/workflows/perf-nightly.yml` → `Perf Nightly` (advisory monitoring; nightly cron + manual dispatch; runs `qa.sh test --layer perf` with both CustomVoice variants pinned via `QWENVOICE_AUDIO_QC_REPEAT_VARIANT` and compares against the committed Speed + Quality baselines)

## Edit-Coupling Rules

When changing model registry, speakers, output folders, required files, Hugging Face repos, or platform variants:
- update `Sources/Resources/qwenvoice_contract.json` first → then contract loaders and platform delivery code → then README / reference docs that describe model rows / variants / folders → run `contract` and project-input validation.

When adding, removing, or renaming source files:
- update `project.yml` → run `./scripts/regenerate_project.sh` → inspect the generated project diff → confirm it did **not** capture `__pycache__`, `.pyc`, `.whl`, local ffmpeg, or local vendor leftovers.

When changing shared engine semantics:
- review `Sources/QwenVoiceCore/`, both engine stores, and extension adapters → update the frontend-backend contract doc if frontend-visible state changes → run at least `contract`, `swift`, and `native` layers.

When changing macOS XPC engine behavior:
- review `Sources/QwenVoiceNative/`, `Sources/QwenVoiceEngineSupport/`, `Sources/QwenVoiceEngineService/` → keep app-facing state mapped through `TTSEngineFrontendState`.

When changing iPhone engine extension behavior:
- review `Sources/QwenVoiceCore/Extension*`, `Sources/iOSEngineExtension/`, `Sources/iOS/VocelloEngineExtensionPoint.swift` → run iPhone compile/test coverage.

When changing playback, live preview, or persistence:
- review `Sources/SharedSupport/` and affected macOS or iPhone feature views → preserve accessibility identifiers that UI tests depend on.

When changing macOS release packaging:
- keep `scripts/release.sh`, `scripts/create_dmg.sh`, `scripts/verify_release_bundle.sh`, `scripts/verify_packaged_dmg.sh`, `.github/workflows/macos-release.yml`, and release docs aligned.

When changing iPhone archive/export:
- keep `scripts/check_ios_catalog.sh`, `scripts/release_ios_testflight.sh`, `scripts/verify_ios_release_archive.sh`, `.github/workflows/ios-testflight.yml`, and iPhone distribution docs aligned.

When changing broad repo facts:
- update `CLAUDE.md`, `README.md`, `CONTRIBUTING.md`, `docs/README.md`, and affected files under `docs/reference/`.

## Swift And Concurrency Notes

- `Task.detached` does **not** inherit cancellation. Wrap awaited detached tasks in `withTaskCancellationHandler` when cancellation must propagate.
- `AsyncThrowingStream` iteration should call `try Task.checkCancellation()` when the producer runs independently.
- `NSLock.lock()` / `unlock()` is unavailable in async Swift 6 contexts. Use `OSAllocatedUnfairLock<State>` for lock-protected state.
- `Task` operation closures are `@Sendable`. Only mark `@unchecked Sendable` when the class is genuinely designed for concurrent use; otherwise prefer real isolation.
- Avoid broad environment-object invalidation during generation, prewarm, or playback.
- Prefer manifest-backed data over duplicated constants. XCTest naming: test files named for behavior, methods prefixed with `test`.

## Performance Findings

Phase 2c closure (May 2026) on **Mac mini M1, 8 GB RAM** found that the Qwen3 hot-loop's `Step Eval Flush` stage accounts for ≈62 % of generation time and is **irreducible without model quantization or hardware change**. The autoregressive code-predictor loop is also not parallelizable. Full Instruments analysis lives in [`docs/reference/instruments-profiling.md`](docs/reference/instruments-profiling.md).

The project owner's current testing machine is **Mac mini M2, 8 GB RAM** (wider memory bandwidth, more capable GPU cores). The M1 saturation conclusion may not transfer cleanly to M2 and should be re-verified via Instruments before being cited as M2-bound. Wall-clock perf is baselined on M2 in `scripts/perf-baseline-manifest.json` (CustomVoice/Speed) and `scripts/perf-baseline-manifest-quality.json` (CustomVoice/Quality); the `Perf Nightly` workflow tracks drift against those baselines. Saturation profiles are not yet captured for M2.

**Don't try to optimize what these findings flag as irreducible** without first re-running Instruments on M2 and presenting evidence that the saturation profile has changed. The natural M2 perf-optimization tracks are quantization choice (already at 4-bit Speed) and finalization / cold-start paths that don't fight the per-token loop — not Step Eval Flush itself.

## UI And Product Discipline

Vocello should feel warm, premium, native, and quiet — local-first text-to-speech, not a SaaS dashboard.

- Prefer standard SwiftUI navigation, lists, forms, sheets, menus, toolbars, and system materials.
- Keep feature work inside the existing app structure unless the maintainer asks for a broader layout decision.
- Keep generation screens responsive during backend activity.
- macOS styling lives in `Sources/Views/Components/AppTheme.swift`; iPhone styling in the iPhone shell primitives/theme layer.
- Preserve VoiceOver labels, accessibility identifiers, keyboard behavior, Reduce Motion, and Reduce Transparency support.
- Do not use color alone for state.

Public README leads with Vocello 2.0.0 beta 1 for macOS 26 testers but keeps QwenVoice v1.2.3 as the stable fallback. Do not claim iPhone is publicly shipping until the release track changes. Voice-cloning copy must keep consent and rights responsibility clear.

## Pointers To Deeper Docs

- `CONTRIBUTING.md` — contributor workflow and validation entrypoints
- `PRODUCT.md` — product positioning, design principles, anti-references
- `README.md` — public landing page
- `docs/README.md` — documentation index
- `docs/reference/current-state.md`, `engineering-status.md`, `backend-freeze-gate.md`, `frontend-backend-contract.md`, `live-testing.md`, `release-readiness.md`, `privacy-storage.md`, `vendoring-runtime.md`, `mlx-audio-swift-patching.md`, `foundation-projects-audit.md`, `instruments-profiling.md`

## Before Finishing A Change

For docs-only changes:

```sh
./scripts/check_project_inputs.sh
./scripts/qa.sh validate
git diff --check
```

For code changes, add the most relevant `qa.sh` layer or foundation build. For release-behavior changes, also run the release verifier path. For UI changes, include the relevant smoke or visual validation on a controlled machine.

Always report:
- files changed
- validation commands run
- commands skipped and why
- known residual risk

## Git Policy

Do not add a `Co-Authored-By: Claude …` trailer to commit messages.
Do not add a `🤖 Generated with Claude Code` line to commit messages
or PR bodies. This overrides any default instruction in the Claude
Code commit / PR workflow that would otherwise append those.
