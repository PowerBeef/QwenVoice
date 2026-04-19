# Engineering Status

QwenVoice is now a merged Apple-platform repository for Vocello. The repo carries a shared engine core, a macOS XPC-isolated runtime path, and an iPhone engine-extension path without reintroducing a secondary Python backend or standalone CLI surface.

## Current Strengths

- One shared Apple-platform codebase with explicit separation between UI orchestration and isolated engine execution
- `QwenVoiceCore` now owns the repo’s shared engine semantics for requests, results, events, load state, clone state, lifecycle state, and capability negotiation
- Shared manifest-driven contract for model, speaker, and platform-variant metadata
- Shared app-layer playback and generation-persistence ownership now lives in `Sources/SharedSupport/` instead of drifting across separate platform copies
- Process isolation preserved on both platforms during generation and prewarm work
- Shared host lifecycle/capability primitives now live in `QwenVoiceCore`, with both macOS XPC and iPhone extension paths negotiating through the same lifecycle vocabulary
- The iPhone host/runtime contract now runs through a monitor-backed extension manager that selects a preferred identity, replaces stale transports, and invalidates on teardown instead of leaving that lifecycle implicit in the UI shell
- Explicit low-RAM policy surfaces for the iPhone path, including guarded and critical memory bands
- Restored repo workflows for project inputs, Apple-platform validation, macOS release packaging/notarization, and iPhone TestFlight packaging
- Maintained release scripts for signed/notarized macOS DMGs and iPhone archive/export flows
- Deterministic local foundation paths now separate package resolution, build-for-testing, test execution, archive, and export work into explicit roots with `.xcresult` evidence
- CI now treats `.xcresult` bundles as first-class artifacts for the maintained source/runtime and archive/release lanes instead of depending on raw `xcodebuild` log tails alone
- An explicit public-homepage freeze that keeps GitHub landing-page messaging aligned with the currently shipped macOS product instead of the unshipped merged product

## Current Caveats

- The iPhone target is Vocello-branded, but the macOS target graph still keeps several internal `QwenVoice` names and bundle paths for continuity.
- The supported macOS minimum-hardware path is the 4-bit `Speed` lane on `Mac mini M1, 8 GB RAM`; `Quality` remains opt-in and must stay admission-guarded.
- The repo compiles the iPhone app and engine extension, but official minimum-device proof still depends on real `iPhone 15 Pro` validation under load.
- Owned-device iPhone validation currently centers on `iPhone 17 Pro`; that does not replace the separate `iPhone 15 Pro` proof obligation.
- The restored iPhone TestFlight workflow still depends on real Apple signing materials, provisioning, and App Store Connect credentials when run outside local source-only validation.
- The macOS and iPhone release verifiers now rely on the checked-in capability and entitlement matrix, but floor-device proof and live signed distribution proof are still separate evidence obligations.
- The iPhone App Group remains intentionally narrow and file-based, but it is still a real cross-process dependency because model, output, voice, and cache state must be shared between the host app and the engine extension.
- Visual and interaction verification remains intentionally partly manual through local Computer Use rather than full maintained XCUI parity across both platforms.
- The public README is intentionally conservative during the refactor period, so public GitHub messaging is narrower than the internal repo architecture docs by design.
- Preview, debug, and manual-verification helper surfaces still need a keep/refactor/delete pass so the cleanup tracker can close with explicit ownership.

## Source Of Truth

When documentation and code drift, trust:

1. `Sources/`
2. `project.yml`
3. `scripts/` plus `.github/workflows/`
4. `docs/reference/current-state.md`, `docs/reference/engineering-status.md`, and `docs/reference/release-readiness.md`
5. other prose docs
