# Engineering Status

QwenVoice is the merged Apple-platform codebase that currently ships publicly as `QwenVoice v1.2.3` on macOS and will ship its next macOS release under the forward `Vocello` brand. The repo carries a shared engine core, a macOS XPC-isolated runtime path, and an iPhone engine-extension path without reintroducing a secondary Python backend or standalone CLI surface.

The current milestone is operating on a `macOS-first release track`: macOS is the only public release target for the next ship, while iPhone remains a maintained compile-safe and deferred release surface.

## Rescue Checkpoint

As of `main` commit `90e1f33` (`Stabilize macOS generation mode switching`), the repo is back on a clean salvage baseline:

- local `main` and `origin/main` are aligned at the same commit
- `./scripts/check_project_inputs.sh`, `python3 scripts/harness.py validate`, and `git diff --check` are green
- `python3 scripts/harness.py test --layer swift` is green
- `./scripts/build_foundation_targets.sh macos` and `./scripts/build_foundation_targets.sh ios` are green

The next recovery work should keep this baseline stable: native SwiftUI only, no broad visual redesign, no speculative model work from screen mount, and no overlapping heavy build/test commands on the 8 GB local development machine.

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
- Restored repo workflows for project inputs, the Apple-platform QA gate, macOS release packaging/notarization, and iPhone TestFlight packaging
- Rebuilt `scripts/harness.py` as the repo-owned QA orchestrator for validation, contract/source/native/iOS/UI test layers, diagnostics, and opt-in benchmarks
- Maintained release scripts for signed/notarized macOS DMGs and iPhone archive/export flows
- Deterministic local foundation paths now separate package resolution, build, archive, and export work into explicit roots with `.xcresult` evidence
- `Apple Platform QA Gate` now treats `.xcresult` bundles as first-class artifacts for maintained harness, build, and archive/release lanes instead of depending on raw `xcodebuild` log tails alone
- An explicit public-homepage posture that keeps GitHub landing-page messaging aligned with the currently shipped `QwenVoice v1.2.3` build, with `Vocello` framed as the forward rebrand that lands with the next macOS release

## Current Caveats

- The iPhone target is Vocello-branded, but the macOS target graph still keeps several internal `QwenVoice` names and bundle paths for continuity.
- The supported macOS minimum-hardware path is the 4-bit `Speed` lane on `Mac mini M1, 8 GB RAM`; `Quality` remains opt-in and must stay admission-guarded.
- The repo compiles the iPhone app and engine extension, but official minimum-device proof still depends on real `iPhone 15 Pro` validation under load.
- Owned-device iPhone validation currently centers on `iPhone 17 Pro`; that does not replace the separate `iPhone 15 Pro` proof obligation.
- The restored iPhone TestFlight workflow still depends on real Apple signing materials, provisioning, and App Store Connect credentials when run outside local source-only validation.
- The iPhone release/TestFlight path remains maintained, but it is intentionally deferred from signoff for the current macOS-first public release milestone.
- The macOS and iPhone release verifiers now rely on the checked-in capability and entitlement matrix, but floor-device proof and live signed distribution proof are still separate evidence obligations.
- The iPhone App Group remains intentionally narrow and file-based, but it is still a real cross-process dependency because model, output, voice, and cache state must be shared between the host app and the engine extension.
- The legacy `QwenVoiceNativeRuntime` module is still present for compatibility coverage, so the codebase has not finished its cleanup pass even though the active macOS helper path now runs through `QwenVoiceCore`.
- A plain signed `xcodebuild -scheme QwenVoice build` on shared local DerivedData can still be polluted by stale build output; the maintained deterministic compile-proof path is the isolated `./scripts/build_foundation_targets.sh` flow.
- Hosted UI smoke can still soft-skip macOS Accessibility/TCC or foreground-window issues; controlled release signoff must use `QWENVOICE_E2E_STRICT=1`.
- Manual local app launches and Computer Use remain useful after the harness/build gates, especially for visual polish and real model-load checks.
- The public README is intentionally conservative during the refactor period, so public GitHub messaging is narrower than the internal repo architecture docs by design.
- Preview, debug, and manual-verification helper surfaces still need a keep/refactor/delete pass so the cleanup tracker can close with explicit ownership.

## Source Of Truth

When documentation and code drift, trust:

1. `Sources/`
2. `project.yml`
3. `scripts/` plus `.github/workflows/`
4. `docs/reference/current-state.md`, `docs/reference/engineering-status.md`, and `docs/reference/release-readiness.md`
5. other prose docs
