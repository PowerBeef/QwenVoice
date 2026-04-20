# Frontend-Backend Contract

This document defines the backend surfaces that frontend work is allowed to depend on while the repo is in backend-freeze mode.

## Purpose

Frontend code in this repo must bind to stable app-facing state, not to transport, process-hosting, or runtime-policy implementation details.

That means:

- frontend code can observe shared semantic state owned by `QwenVoiceCore`
- frontend code can call app-layer store actions exposed by the macOS and iPhone shells
- frontend code must not branch on whether the engine is currently hosted through macOS XPC or the iPhone engine extension

## Stable Engine State

The shared engine-facing state surface is:

- `Sources/QwenVoiceCore/TTSEngine.swift`

The primary immutable frontend-safe state type is:

- `TTSEngineFrontendState`

Its stable fields are:

- `isReady`
- `lifecycleState`
- `loadState`
- `clonePreparationState`
- `latestEvent`
- `visibleErrorMessage`

The lifecycle vocabulary frontend code may rely on is:

- `idle`
- `launching`
- `connected`
- `interrupted`
- `recovering`
- `invalidated`
- `failed`

Frontend code may also rely on the shared semantic types already owned by `QwenVoiceCore`:

- `TTSEngineSnapshot`
- `EngineLoadState`
- `ClonePreparationState`
- `GenerationEvent`
- `GenerationResult`
- `PreparedVoice`
- `CloneReference`

## Stable Delivery State

The iPhone model-delivery surface frontend code may rely on is:

- `Sources/iOS/IOSModelDeliveryActor.swift`
- `IOSModelDeliverySnapshot`

The stable delivery phases are:

- `downloading`
- `interrupted`
- `resuming`
- `restarting`
- `verifying`
- `installing`
- `installed`
- `deleting`
- `deleted`
- `failed`

Frontend code may depend on:

- the current model identifier
- the current phase
- byte progress
- user-visible status messaging

Frontend code must not depend on:

- resume-data file layout
- staging-directory names
- URLSession task identifiers
- App Group file internals beyond the documented app-layer actions

## Stable App-Layer Adapters

The maintained app-layer adapters that translate transport/runtime details into frontend-safe state are:

- macOS: `Sources/QwenVoiceNative/TTSEngineStore.swift`
- iPhone: `Sources/iOS/TTSEngineStore.swift`

These stores are the UI-facing boundaries for:

- lifecycle state
- load state
- clone-preparation state
- latest generation event
- visible backend error state
- app-owned memory coordination

Frontend code should prefer store APIs and published state over reaching into host/client/runtime classes directly.

## Intentionally Hidden From Frontend Code

Frontend code must not bind to:

- `NSXPCConnection`
- `QwenVoiceEngineServiceXPCProtocol`
- `QwenVoiceEngineClientEventXPCProtocol`
- `AppExtensionPoint.Monitor`
- `AppExtensionProcess`
- low-level request/reply envelope encoding
- service trust-policy rules
- runtime factory or runtime-host construction

Those remain backend implementation details.

## Current Backend Ownership

The current canonical backend-policy owner is `QwenVoiceCore`.

Active runtime ownership:

- macOS XPC helper: `Sources/QwenVoiceEngineService/EngineServiceHost.swift` now hosts `MLXTTSEngine` from `QwenVoiceCore`
- iPhone extension path: `Sources/QwenVoiceCore/ExtensionEngineHostManager.swift` plus `Sources/iOSEngineExtension/`

Compatibility and test-only retained surface:

- `Sources/QwenVoiceNativeRuntime/`

`QwenVoiceNativeRuntime` may still hold useful compatibility and regression coverage, but it is no longer the active macOS policy owner that frontend work should reason about.

## Backend-Freeze Gate

Frontend work should treat the backend as frozen only when these maintained proofs are green:

```sh
./scripts/check_project_inputs.sh
python3 scripts/harness.py validate
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer native
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
./scripts/release.sh
./scripts/verify_release_bundle.sh build/QwenVoice.app
./scripts/verify_packaged_dmg.sh build/Vocello-macos26.dmg build/release-metadata.txt
```

During the current `macOS-first release track`, `python3 scripts/harness.py test --layer ios` remains maintained but is conditional rather than part of the default required path. Use it for explicit iPhone-impacting backend work and for future iPhone release re-entry.

Maintained CI proof also includes:

- `Backend Freeze Gate`
- `.xcresult` artifact upload for harness and platform build lanes
- unsigned release verification in CI
- signed macOS release proof in its dedicated CI workflow
- deferred iPhone release proof in its dedicated CI workflow

The explicit backend-freeze acceptance checklist lives in:

- `docs/reference/backend-freeze-gate.md`

## Change Discipline

Any backend change that alters one of the stable state surfaces above is a contract change.

When that happens, update:

- `AGENTS.md`
- `docs/README.md`
- `docs/reference/current-state.md`
- `docs/reference/engineering-status.md`
- `docs/reference/backend-freeze-gate.md`
- this document
