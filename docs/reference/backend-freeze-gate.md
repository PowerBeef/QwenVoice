# Backend Freeze Gate

This document defines the measurable gate that must stay green before frontend work is treated as unblocked.

## Purpose

Frontend work in this repo should start from a backend that is stable, shared across macOS and iPhone, and proven by maintained source, build, and release checks.

The backend-freeze gate exists so frontend work does not quietly bind to:

- transport-specific behavior
- process-hosting details
- stale runtime ownership assumptions
- unproven delivery or memory recovery paths
- release claims that are only true on one platform

During the current `macOS-first release track`, this gate remains the shared-core regression gate, not the full two-platform public ship gate.

## Gate Owner

The canonical backend/runtime policy owner is `QwenVoiceCore`.

The maintained process shells are:

- macOS: `Sources/QwenVoiceEngineService/EngineServiceHost.swift`
- iPhone: `Sources/QwenVoiceCore/ExtensionEngineHostManager.swift` plus `Sources/iOSEngineExtension/`

Retained compatibility surface:

- `Sources/QwenVoiceNativeRuntime/`

`QwenVoiceNativeRuntime` may remain useful for regression coverage, but it is not the app-facing policy owner that frontend work should reason about.

## Frontend-Safe Contract

Frontend work is allowed to depend on:

- `TTSEngineFrontendState`
- `TTSEngineSnapshot`
- `EngineLoadState`
- `ClonePreparationState`
- `GenerationEvent`
- `IOSModelDeliverySnapshot`

Frontend work is not allowed to depend on:

- `NSXPCConnection`
- `QwenVoiceEngineServiceXPCProtocol`
- `AppExtensionPoint.Monitor`
- `AppExtensionProcess`
- transport request and reply envelope details
- trust-policy string construction
- runtime-host construction details

See:

- `docs/reference/frontend-backend-contract.md`

## Required Proof

The backend-freeze gate is green only when all maintained proofs below are green for the current change.

### Local Source And Runtime Proof

```sh
./scripts/check_project_inputs.sh
python3 scripts/harness.py validate
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer native
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
```

`python3 scripts/harness.py test --layer ios` remains maintained, but it is conditional during the current release track. Run it when:

- working directly in `Sources/iOS/`
- working directly in `Sources/iOSSupport/`
- working directly in `Sources/iOSEngineExtension/`
- touching iPhone model-delivery, memory policy, or extension-host behavior
- preparing to re-open the iPhone release track

### Local Unsigned Release Proof

```sh
./scripts/release.sh
./scripts/verify_release_bundle.sh build/QwenVoice.app
./scripts/verify_packaged_dmg.sh build/Vocello-macos26.dmg build/release-metadata.txt
```

### Maintained CI Proof

- `Backend Freeze Gate`
- `Vocello macOS Release`

The maintained CI evidence includes:

- uploaded `.xcresult` bundles for harness and platform build lanes
- unsigned macOS release verification artifacts
- dedicated signed macOS notarization proof
- generic iPhone compile proof to protect shared-core integration

Deferred but still maintained CI proof:

- `Vocello iOS TestFlight`
- dedicated iPhone archive/export/upload-prep proof

## Acceptance Checklist

Treat frontend work as unblocked only when these statements are true:

- `QwenVoiceCore` is the sole semantic and runtime-policy owner for active macOS and iPhone behavior.
- macOS and iPhone publish the same lifecycle vocabulary: `idle`, `launching`, `connected`, `interrupted`, `recovering`, `invalidated`, `failed`.
- app-facing engine state is consumed through `TTSEngineFrontendState`, not transport-specific state.
- app-facing delivery state is consumed through `IOSModelDeliverySnapshot`, not URLSession or staging internals.
- capability and entitlement drift is caught by maintained tests against `config/apple-platform-capability-matrix.json`.
- process-isolation behavior is covered by maintained transport and host-manager tests.
- delivery restore, verification, and rollback behavior is covered by maintained iPhone recovery tests.
- memory admission and trim policy is covered by maintained iPhone foundation tests.
- the maintained local and CI proof lanes above are green for the current change.

## Current Explicit Non-Blockers

These items remain important, but they do not block the frontend-safe backend gate by themselves:

- official `iPhone 15 Pro` minimum-device evidence is still pending while owned-device proof continues on `iPhone 17 Pro`
- `Sources/QwenVoiceNativeRuntime/` still exists as a retained compatibility and regression surface
- iPhone release/TestFlight proof is deferred from the current macOS-first public release milestone
- upstream MLX and package warning noise may still appear in `.xcresult` bundles as long as the gate remains green and repo-owned targets stay warning-clean where expected

## Current Explicit Follow-Ons

When one of these changes, treat it as a backend contract review:

- engine lifecycle meaning
- engine load-state meaning
- clone-preparation meaning
- generation progress or event semantics
- user-visible backend error semantics
- model-delivery phase meaning
- capability or entitlement declarations

Update these docs together when the gate changes:

- `CLAUDE.md`
- `docs/README.md`
- `docs/reference/current-state.md`
- `docs/reference/engineering-status.md`
- `docs/reference/frontend-backend-contract.md`
- this file
