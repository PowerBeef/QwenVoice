# Apple Platform QA Gate

This document defines the source, integration, build, and unsigned-release gate that must stay green before release-hardening work is treated as reviewable.

## Purpose

The gate keeps the native Apple-platform codebase aligned with the current `macOS-first release track` using project-input validation, repo-owned harness layers, deterministic builds, and release-verification checks.

It protects against:

- stale project generation
- accidental reintroduction of removed Python, CLI, vendored-test, screenshot, or benchmark-UI surfaces
- source/runtime regression drift that should be caught before packaging
- macOS or iPhone compile drift
- release artifact drift around `Vocello.app` and `Vocello-macos26.dmg`
- packaged-resource drift around prohibited `backend`, `python`, and `ffmpeg` resources

## Gate Owner

The canonical runtime policy owner remains `QwenVoiceCore`.

The maintained process shells are:

- macOS: `Sources/QwenVoiceEngineService/EngineServiceHost.swift`
- iPhone: `Sources/QwenVoiceCore/ExtensionEngineHostManager.swift` plus `Sources/iOSEngineExtension/`

Retained compatibility surface:

- `Sources/QwenVoiceNativeRuntime/`

`QwenVoiceNativeRuntime` remains compatibility code, but it is not the app-facing policy owner that frontend work should reason about.

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

The gate is green only when the maintained checks below are green for the current change.

### Local Harness And Build Proof

```sh
./scripts/check_project_inputs.sh
python3 scripts/harness.py validate
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer native
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
```

The `ios` harness layer remains available but requires an installed iPhone simulator. A structured simulator-missing skip does not replace the generic iPhone compile proof from `build_foundation_targets.sh ios`.

Strict release-machine UI proof:

```sh
QWENVOICE_E2E_STRICT=1 python3 scripts/harness.py test --layer e2e
```

### Local Unsigned Release Proof

```sh
./scripts/release.sh
./scripts/verify_release_bundle.sh build/Vocello.app
./scripts/verify_packaged_dmg.sh build/Vocello-macos26.dmg build/release-metadata.txt
```

### Maintained CI Proof

- `Project Inputs`
- `Apple Platform QA Gate`
- `Vocello macOS Release`

The maintained CI evidence includes:

- uploaded `.xcresult` bundles for harness layers, platform builds, and release packaging
- hosted macOS UI smoke that may soft-skip only known TCC/window-activation environment failures
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
- capability, bundle identity, entitlement, and packaged-resource drift are caught by `scripts/check_project_inputs.sh` and `python3 scripts/harness.py validate`.
- contract, macOS source, and native-runtime harness layers pass.
- macOS and iPhone compile through the maintained foundation build script.
- the maintained local and CI proof lanes above are green for the current change.

## Current Explicit Non-Blockers

These items remain important, but they do not block the current macOS-first QA gate by themselves:

- official `iPhone 15 Pro` minimum-device evidence is still pending while owned-device proof continues on newer local hardware
- `Sources/QwenVoiceNativeRuntime/` still exists as a retained compatibility surface
- iPhone release/TestFlight proof is deferred from the current macOS-first public release milestone
- upstream MLX and package warning noise may still appear in `.xcresult` bundles as long as repo-owned targets compile
- hosted CI e2e can soft-skip first-time TCC/window activation failures; controlled-machine strict e2e remains required for release signoff

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

- `AGENTS.md`
- `docs/README.md`
- `docs/reference/current-state.md`
- `docs/reference/engineering-status.md`
- `docs/reference/frontend-backend-contract.md`
- this file
