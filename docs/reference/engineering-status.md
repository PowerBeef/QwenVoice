# Engineering Status

QwenVoice is the merged Apple-platform codebase whose current public macOS product ships under the `Vocello 2.0.0` brand. `QwenVoice v1.2.3` remains the legacy macOS 15 fallback. The repo carries a shared engine core, a macOS XPC-isolated runtime path, and an iPhone engine-extension path without reintroducing a secondary Python backend or standalone CLI surface.

The current milestone is operating on a `macOS-first release track`: macOS is the current public release target, while iPhone remains a maintained compile-safe, real-device-tested, and deferred public release surface.

## Rescue Checkpoint

As of `main` commit `63a5e02` (`Guard macOS UI observation boundaries`), the repo is back on a green rescue baseline:

- local `main` and `origin/main` are aligned at the same commit
- GitHub `Project Inputs` passed for `63a5e02` in run `24973916220`
- GitHub `Apple Platform QA Gate` (later renamed `Apple Platform Build Gate`) passed for `63a5e02` in run `24973916195`. That historical run included contract/Swift/native/hosted UI smoke layers, macOS + iPhone builds, and unsigned macOS release-artifact verification. The broad gate was retired in May 2026; the only current workflow is `.github/workflows/release.yml`, scoped to macOS release packaging plus iOS compile-safety.
- local pre-push proof for `63a5e02` historically passed `./scripts/check_project_inputs.sh`, the retired automation surface, and `./scripts/build_foundation_targets.sh macos`
- prior local full release proof passed from `c6beacd` with `./scripts/release.sh`, `./scripts/verify_release_bundle.sh build/Release/Vocello.app`, and `./scripts/verify_packaged_dmg.sh build/Release/Vocello-macos26.dmg build/Release/release-metadata.txt`; the hosted QA gate re-proved the unsigned release-artifact lane for `63a5e02`
- controlled local macOS acceptance on April 26, 2026 launched the local Release app, switched Custom Voice / Voice Design / Voice Cloning, typed a Custom Voice script, generated a 2-second preview, played it through the sidebar player, and persisted the output under that release app's app-support outputs folder

The next recovery work should keep this baseline stable: native SwiftUI only, no broad visual redesign, no speculative model work from screen mount, and no overlapping heavy build/packaging commands on the 8 GB local development machine. Manual app acceptance and targeted agent-driven smoke runs confirm the app can complete primary generation paths locally; the automated XCTest/CI surfaces were retired in May 2026.

## Current Strengths

- One shared Apple-platform codebase with explicit separation between UI orchestration and isolated engine execution
- `QwenVoiceCore` now owns the repo’s shared engine semantics for requests, results, events, load state, clone state, lifecycle state, and capability negotiation
- Shared manifest-driven contract for model, speaker, and platform-variant metadata
- Shared app-layer playback and generation-persistence ownership now lives in `Sources/SharedSupport/` instead of drifting across separate platform copies
- Process isolation preserved on both platforms during generation and prewarm work
- Shared host lifecycle/capability primitives now live in `QwenVoiceCore`, with both macOS XPC and iPhone extension paths negotiating through the same lifecycle vocabulary
- The active macOS XPC helper now hosts `MLXTTSEngine` from `QwenVoiceCore`, so the repo no longer relies on a separate live macOS-native policy stack for load, prewarm, generation, and clone behavior
- The iPhone host/runtime contract now runs through a monitor-backed extension manager that selects a preferred identity, replaces stale transports, and invalidates on teardown instead of leaving that lifecycle implicit in the UI shell
- Explicit low-RAM policy surfaces for the iPhone path, including guarded and critical memory bands
- The shared frontend-safe engine state surface now exists as `TTSEngineFrontendState`, with matching macOS and iPhone store adapters
- Maintained release scripts for signed/notarized macOS DMGs (`scripts/release.sh`); iPhone is compile-safe only — on-device deploy/proof and TestFlight tooling were removed and that work is deferred pending the increased-memory entitlement
- A single scoped GitHub workflow for macOS release packaging plus iOS compile-safety; behavioral validation is manual local app acceptance
- Deterministic local foundation paths now separate package resolution, build, archive, and export work into explicit roots with `.xcresult` evidence
- The maintained local build and archive/release lanes treat `.xcresult` bundles as first-class artifacts instead of depending on raw `xcodebuild` log tails alone (a discipline carried forward from the retired `Apple Platform QA Gate` / `Apple Platform Build Gate` workflow)
- An explicit public-homepage posture that keeps GitHub landing-page messaging aligned with `Vocello 2.0.0` as the current macOS 26+ release and `QwenVoice v1.2.3` as the legacy macOS 15 fallback
- Manual local app acceptance is the behavioral validation path; there is no automated UI-driving or benchmark harness (the macOS bench harness and committed timing baselines were removed in the testing-harness cleanup)
- A runtime-side prewarm gate in `NativeEngineRuntime` (`acquirePrewarmSlot` / `releasePrewarmSlot`) that serializes `prewarmVoiceDesign` / `prewarmCustomVoice` / `prewarmVoiceClone` across actor suspension points — closes the actor-reentrancy race that previously let two threads enter MLX's KV cache slice updates concurrently and trip an upstream assertion (crash report May 15, 2026).
- A broader generation-ownership hardening layer now serializes model-mutating work through `MLXTTSEngine`, exposes `hasActiveGeneration` through the macOS/iPhone app stores, rejects concurrent host generations, carries UUID-backed streaming identity, and cancels vendored Qwen stream producers when consumers stop.

## Current Caveats

- The iPhone target is Vocello-branded, but the macOS target graph still keeps several internal `QwenVoice` names and bundle paths for continuity.
- The supported macOS minimum-hardware path is the 4-bit `Speed` lane on `Mac mini M1, 8 GB RAM`; `Quality` is selectable per generation mode when installed, but floor hardware defaults to Speed and Quality is not guaranteed there.
- The repo compiles the iPhone app and engine extension, but official minimum-device proof still depends on real `iPhone 15 Pro` validation under load.
- On-device MLX on iPhone requires Apple's increased-memory entitlement for the app and engine extension; until approval, generation is expected to block at model admission. See [`ios-shipping.md`](ios-shipping.md).
- Owned-device iPhone validation currently centers on `iPhone 17 Pro`; that does not replace the separate `iPhone 15 Pro` proof obligation.
- The restored iPhone TestFlight workflow still depends on real Apple signing materials, provisioning, and App Store Connect credentials when run outside local source-only validation.
- The iPhone release/TestFlight path remains maintained, but it is intentionally deferred from signoff for the current macOS-first public release milestone.
- The macOS and iPhone release verifiers now rely on the checked-in capability and entitlement matrix, but floor-device proof and live signed distribution proof are still separate evidence obligations.
- The iPhone App Group remains intentionally narrow and file-based, but it is still a real cross-process dependency because model, output, voice, and cache state must be shared between the host app and the engine extension.
- The legacy `QwenVoiceNativeRuntime` module has been retired (Session 6, May 2026). The active macOS helper path is `QwenVoiceCore` end-to-end. Regression coverage was historically in `QwenVoiceTests/`; with the test surface and the agent-driven UI/bench harness both retired, regressions are now caught by manual app acceptance plus the build/compile-safety gates.
- A plain signed `xcodebuild -scheme QwenVoice build` on shared local DerivedData can still be polluted by stale build output; the maintained deterministic compile-proof path is the isolated `./scripts/build_foundation_targets.sh` flow.
- Manual local app launches are the only behavioral verification path after the build gates, especially for visual polish, real model-load checks, and visible UI validation.
- The public README is intentionally conservative during the refactor period, so public GitHub messaging is narrower than the internal repo architecture docs by design.
- Preview, debug, and manual-verification helper surfaces still need a keep/refactor/delete pass so the cleanup tracker can close with explicit ownership.

## Source Of Truth

When documentation and code drift, trust:

1. `Sources/`
2. `project.yml`
3. `scripts/` and `.github/workflows/release.yml` for maintained local and scoped CI automation
4. `docs/reference/current-state.md`, `docs/reference/engineering-status.md`, and `docs/reference/release-readiness.md`
5. other prose docs
