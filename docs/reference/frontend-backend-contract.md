# Frontend-Backend Contract

This document defines the backend surfaces that frontend work is allowed to depend on while the repo is in its macOS-first build-gate mode.

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
- `GenerationChunkDeliveryIdentity`
- `GenerationResult`
- `PreparedVoice`
- `CloneReference`

Streaming chunk events carry a UUID `generationID`. Frontend playback/session logic should prefer that identity over the numeric `requestID`; the numeric value remains useful for logs, signposts, and session-directory naming but can restart with the runtime.

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

## Stable Model Selection State

The macOS model-management surface may expose variant-specific model identifiers such as:

- `pro_custom_speed`
- `pro_custom_quality`
- `pro_design_speed`
- `pro_design_quality`
- `pro_clone_speed`
- `pro_clone_quality`

Frontend code may rely on:

- macOS showing Speed and Quality rows for each generation mode
- separate `Recommended` and `Active` states in the model catalog
- active macOS variant selection being stored per generation mode through app preference state
- generation flows resolving the active model through the app model layer rather than changing request wire shapes
- legacy base IDs resolving to the hardware-recommended variant for compatibility
- iPhone exposing Speed-only model delivery

Frontend code must not require changes to `qwenvoice_contract.json`, XPC envelopes, saved-voice schema, database schema, or `GenerationRequest` wire shapes to support macOS variant selection.

## Stable App-Layer Adapters

The maintained app-layer adapters that translate transport/runtime details into frontend-safe state are:

- macOS: `Sources/QwenVoiceNative/TTSEngineStore.swift`
- iPhone: `Sources/iOS/TTSEngineStore.swift`

These stores are the UI-facing boundaries for:

- lifecycle state
- load state
- clone-preparation state
- active generation state (`hasActiveGeneration`)
- generation cancellation (`cancelActiveGeneration`)
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

- macOS XPC helper: `Sources/QwenVoiceEngineService/EngineServiceHost.swift` hosts `MLXTTSEngine` from `QwenVoiceCore`
- iPhone extension path: `Sources/QwenVoiceCore/ExtensionEngineHostManager.swift` plus `Sources/iOSEngineExtension/`

The legacy `Sources/QwenVoiceNativeRuntime/` compatibility surface was retired in May 2026; the active macOS helper path is `QwenVoiceCore` end-to-end.

## Backend-Freeze Gate

Frontend work should treat the backend as frozen only when these maintained proofs are green:

```sh
./scripts/check_project_inputs.sh
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
./scripts/release.sh
./scripts/verify_release_bundle.sh build/Release/Vocello.app
./scripts/verify_packaged_dmg.sh build/Release/Vocello-macos26.dmg build/Release/release-metadata.txt
```

Then exercise the affected user-facing paths locally. Use Debug (`./scripts/build.sh run`) for persistent macOS development smoke and `build/Release/Vocello.app` after `./scripts/release.sh` for fresh repo-local release behavior; iPhone is compile-safe only. There is no CI smoke, benchmark, or XCTest proof layer, and no automated UI-driving or bench harness; manual local app acceptance is the behavioral regression check.

The explicit build-gate acceptance checklist lives in:

- `docs/reference/backend-freeze-gate.md`

## Change Discipline

Any backend change that alters one of the stable state surfaces above is a contract change.

When that happens, update:

- `docs/README.md`
- `docs/reference/current-state.md`
- `docs/reference/engineering-status.md`
- `docs/reference/backend-freeze-gate.md`
- this document
