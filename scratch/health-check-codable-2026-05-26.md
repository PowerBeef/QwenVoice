# Codable Audit — QwenVoice `Sources/` (2026-05-26)

## Summary

**Health: HARDENING NEEDED**

Focused scan of IPC envelopes (`ExtensionEngineIPC`, `EngineServiceIPC`), contract JSON (`qwenvoice_contract.json`), generation-event serialization, `try?` decode/encode sites, and `JSONSerialization` usage.

**What's in good shape**
- Shared wire codec (`QwenVoiceWireCodec`) with static encoder/decoder reuse; no `Date` fields on the IPC wire surface.
- Request/reply envelopes validate `schemaVersion` and reply encoding failures return a matched-id failure envelope (macOS + iOS extension hosts).
- Contract decode is strict (`try` + post-decode validation) on macOS; JSON keys align with camelCase Swift properties (no snake_case drift).
- Event decode on clients logs errors and forces disconnect rather than swallowing bad payloads.

**Top risks**
- **2 HIGH:** `try?` on generation-event encode drops streaming chunks with only a generic log line.
- **1 HIGH:** iOS contract load uses `fatalError` instead of macOS-style graceful degradation.
- **6 HIGH:** Closed `String` enums on IPC/wire types (`GenerationFinishReason`, `GenerationMode`, etc.) will crash decode when a new raw value appears.
- **4 MEDIUM:** `try?` on prepared-cache / install-metadata persistence hides corruption and forces cache rebuilds or re-downloads silently.
- **3 MEDIUM:** `JSONSerialization` remains for dynamic HF config/API shapes — acceptable, but brittle vs typed Codable.

| Severity | Count |
|----------|------:|
| CRITICAL | 0 |
| HIGH | 9 |
| MEDIUM | 8 |
| LOW | 3 |

---

## Serialization Architecture Map

- **~40 Codable conformances** across `Sources/`; **8 manual** `init(from:)` / `encode(to:)` implementations (IPC envelopes, `PreparedVoice`, `GenerationResult`, `Qwen3TTSModelSize`, iOS install state).
- **Wire boundary:** macOS XPC (`EngineServiceIPC`) and iOS ExtensionKit (`ExtensionEngineIPC`) share `QwenVoiceWireCodec` — default JSON strategies, no dates.
- **Contract boundary:** bundled `qwenvoice_contract.json` → `ContractBackedModelRegistry` / `TTSContract` via ad-hoc `JSONDecoder()` instances.
- **Generation events:** `GenerationEvent` + nested structs synthesized Codable; wrapped in `EngineEventEnvelope` / `ExtensionEngineEventEnvelope` with schema version + legacy fallback.
- **Round-trip pairs:** encoder/decoder both use `QwenVoiceWireCodec` static instances — no cross-file strategy drift on IPC.

---

## Issues

### HIGH — `try?` swallows generation-event encode failures (streaming data loss)

| File:Line | Description | Fix |
|-----------|-------------|-----|
| `Sources/QwenVoiceEngineService/EngineServiceHost.swift:488` | `publish(_:toSessionID:)` uses `try? EngineServiceCodec.encode(event)`. A non-encodable chunk (e.g. bad `Double`, oversized payload) is dropped; client never receives the chunk. Only generic OSLog — no `EncodingError` context. | Replace with `do/catch`; log `error` with request/generation IDs. Consider publishing a `.failed` snapshot or incrementing a dropped-event counter surfaced to telemetry. Mirror reply-path `encodeFailureFallback` pattern for at least one terminal error event. |
| `Sources/iOSEngineExtension/VocelloEngineExtensionHost.swift:435` | Same `try? ExtensionEngineCodec.encode(event)` pattern on the iOS extension event sink (Debug event sink only, but same silent drop when enabled). | Same as above. |

### HIGH — iOS contract decode crashes the process

| File:Line | Description | Fix |
|-----------|-------------|-----|
| `Sources/iOSSupport/Models/TTSContract.swift:59` | `ContractBackedModelRegistry(manifestURL:)` failure → `fatalError("Failed to load qwenvoice_contract.json: …")`. Any schema typo or bundled-resource regression crashes at static init. | Match macOS `TTSContract.swift`: catch, return empty manifest + `ContractLoadError`, surface in Settings/onboarding instead of `fatalError`. |
| `Sources/iOSSupport/Models/TTSContract.swift:72` | Missing bundled contract → `fatalError("Could not locate bundled qwenvoice_contract.json")`. | Return a typed load error; gate app features on `loadError != nil`. |

### HIGH — Closed String enums on IPC/wire paths (future-case crash)

These enums participate in XPC/extension payloads. Adding a new case on one side (or in persisted JSON) causes `dataCorrupted` decode failure → client disconnect.

| File:Line | Enum | Fix |
|-----------|------|-----|
| `Sources/QwenVoiceCore/SemanticTypes.swift:934` | `GenerationFinishReason` | Add `case unknown(String)` or custom `init(from:)` default branch; encode unknowns as raw string. |
| `Sources/QwenVoiceCore/SemanticTypes.swift:3` | `GenerationMode` | Same — used in `GenerationRequest` over IPC. |
| `Sources/QwenVoiceCore/SemanticTypes.swift:1344` | `GenerationEvent.Kind` | Same — top-level event discriminator. |
| `Sources/QwenVoiceCore/EngineHostPrimitives.swift:3` | `RemoteErrorCode` | Same — failure replies over IPC. |
| `Sources/QwenVoiceCore/EngineHostPrimitives.swift:111` | `EngineLifecycleState` | Same — lifecycle snapshots. |
| `Sources/QwenVoiceCore/SemanticTypes.swift:934` | `GenerationFinishReason` in `GenerationResult` | Optional field mitigates missing key, but unknown raw value still crashes. |

### HIGH — `try?` on prepared-cache marker decode (silent cache invalidation)

| File:Line | Description | Fix |
|-----------|-------------|-----|
| `Sources/QwenVoiceCore/MLXModelLoadCoordinator.swift:905` | `readPreparedCacheMarker` returns `nil` on any decode failure via `try? JSONDecoder().decode(PreparedCacheMarker.self, …)`. Corrupt marker treated as cache miss — full re-prepare with no visibility. | Use `do/catch`; log `DecodingError` + marker path; optionally quarantine corrupt marker file. |
| `Sources/QwenVoiceCore/MLXModelLoadCoordinator.swift:969` | Same for `QwenPreparedCheckpointTrust` trust marker. | Same. |

### MEDIUM — Contract / persistence `try?` decode

| File:Line | Description | Fix |
|-----------|-------------|-----|
| `Sources/QwenVoiceCore/ModelAssets.swift:279` | Integrity manifest decode via `try?` → `.unavailable(reason: "manifest unreadable")` with no underlying error logged. | Log decode error; distinguish corrupt vs missing schema. |
| `Sources/ViewModels/ModelManagerViewModel.swift:899` | `readInstallMetadata` uses `try?` decode — corrupt metadata treated as absent; may trigger unnecessary re-download. | Log failure; delete or rename corrupt sidecar after logging. |
| `Sources/iOS/IOSModelDeliveryActor.swift:927` | `loadPersistedState` uses `try?` decode — interrupted iOS model install state lost silently. | Log + surface `.failed` delivery phase; preserve corrupt file for diagnostics. |
| `Sources/iOS/IOSModelDeliveryActor.swift:859` | `decodeTaskDescription` uses `try?` on URLSession task metadata. | Log; fall back to explicit retry rather than silent nil. |

### MEDIUM — IPC envelope legacy fallback can mask corruption

| File:Line | Description | Fix |
|-----------|-------------|-----|
| `Sources/QwenVoiceCore/ExtensionEngineIPC.swift:157-166` | `ExtensionEngineEventEnvelope.init(from:)` re-decodes via `LegacyExtensionEngineEventEnvelope` when modern keyed decode throws **and** `schemaVersion` key is absent. A truncated/corrupt payload without `schemaVersion` may take the legacy path or throw ambiguous errors. | Gate legacy fallback on an explicit version check or magic key set; log when legacy path is taken. |
| `Sources/QwenVoiceEngineSupport/EngineServiceIPC.swift:169-178` | Same pattern on `EngineEventEnvelope`. | Same. |

### MEDIUM — Strict wire schema rejects forward-compatible clients

| File:Line | Description | Fix |
|-----------|-------------|-----|
| `Sources/QwenVoiceCore/EngineHostPrimitives.swift:163-171` | `QwenVoiceWireSchema.validate` rejects any `version != 1`. Rolling upgrade with mixed app/extension versions fails hard. | Document as intentional; or accept `version <= currentVersion` and ignore unknown fields until bump. |

### MEDIUM — `JSONSerialization` on dynamic external/config JSON

| File:Line | Description | Fix |
|-----------|-------------|-----|
| `Sources/QwenVoiceCore/MLXModelLoadCoordinator.swift:646-677` | Mutates HF `config.json` via `[String: Any]` + `JSONSerialization` to normalize speaker maps before cache fingerprinting. No compile-time schema. | Acceptable for vendor config; add unit fixture tests for normalization. Long-term: partial Codable struct for `talker_config` only. |
| `Sources/QwenVoiceCore/MLXModelLoadCoordinator.swift:1091` | `preparedModelType(from:)` uses `try? JSONSerialization` — returns `nil` silently on parse failure. | Log parse failures at debug/warning level. |
| `Sources/QwenVoiceCore/Qwen3TTSRuntimeProfile.swift:397-404` | `readJSONObject` uses `JSONSerialization` + cast for model metadata. Throws on failure (good), but untyped downstream. | Typed nested Codable for fields actually consumed. |
| `Sources/Services/HuggingFaceDownloader.swift:368` | HF repo listing API parsed via `[[String: Any]]` cast chain. | Define `RepoFileResponse: Decodable` matching HF API; keeps LFS oid/size typing. |

### MEDIUM — Silent contract field drop (structural risk)

| File:Line | Description | Fix |
|-----------|-------------|-----|
| `Sources/QwenVoiceCore/ContractBackedModelRegistry.swift:59` | `ContractManifest` decodes bundled contract; Codable ignores unknown keys. New contract fields (e.g. future paywall/eligibility flags) would be silently dropped until Swift structs are updated. | Add contract `schemaVersion` to JSON + decode guard; or CI check that contract keys ⊆ struct keys. |
| `Sources/Models/TTSContract.swift:129` | macOS path re-derives UI models from registry — same silent-drop risk transitively. | Same schema-version gate. |

### MEDIUM — Ad-hoc `JSONDecoder()` per call (drift risk)

| File:Line | Description | Fix |
|-----------|-------------|-----|
| `Sources/QwenVoiceCore/ContractBackedModelRegistry.swift:59` | Fresh decoder per registry init. | Shared static decoder (like `QwenVoiceWireCodec`) if strategies are added later. |
| `Sources/iOS/IOSModelDeliveryActor.swift:475,483` | Per-fetch catalog decoders. | Shared instance on actor or configuration object. |

### LOW — Encode error logging lacks structured detail

| File:Line | Description | Fix |
|-----------|-------------|-----|
| `Sources/QwenVoiceEngineService/EngineServiceHost.swift:489` | Log message does not include `String(describing: error)` / encoding path. | Include `error` and event case name in log + signpost. |
| `Sources/iOSEngineExtension/VocelloEngineExtensionHost.swift:436` | Same. | Same. |

### LOW — `try?` on non-critical persistence (acceptable with logging gap)

| File:Line | Description | Fix |
|-----------|-------------|-----|
| `Sources/Services/BatchGenerationRunner.swift:1067` | Long-form manifest encode via `try?` — batch artifact optional. | Log on failure; batch output still usable without manifest. |
| `Sources/iOS/IOSSimulatorFakeInstallRegistry.swift:100` | Simulator-only fake install registry decode via `try?`. | OK for dev stub; add `#if DEBUG` log. |

---

## Positive Patterns (no action required)

| Area | File | Notes |
|------|------|-------|
| Reply encode failure handling | `EngineServiceHost.swift:92-112`, `VocelloEngineExtensionHost.swift:84-100` | Preserves request ID; avoids hung continuations. |
| Event decode failure handling | `XPCNativeEngineClient.swift:312-318`, `ExtensionEngineCoordinator.swift:128-134` | Logs + disconnect — not silent. |
| Contract validation | `ContractBackedModelRegistry.swift:207-335`, `TTSContract.swift:248-289` | Post-decode semantic validation beyond Codable. |
| Backward-compat fields | `PreparedVoice.swift:596-599`, `GenerationResult.swift:988-991`, `IOSPersistedModelInstallState.swift:89-91` | Documented `decodeIfPresent` defaults. |
| CamelCase contract alignment | `qwenvoice_contract.json` + `ModelDescriptor` | No snake_case mapping gap. |

---

## Recommendations

### Immediate
1. Replace `try?` on event `publish` encode paths with `do/catch` + structured logging (streaming chunk loss).
2. Remove iOS `fatalError` contract paths; align with macOS graceful load failure.

### Short-term
3. Add unknown-case handling to wire enums (`GenerationFinishReason`, `GenerationMode`, `RemoteErrorCode`, `EngineLifecycleState`, `GenerationEvent.Kind`).
4. Replace `try?` on cache markers and install metadata with logged `do/catch`.
5. Add contract schema version to `qwenvoice_contract.json` and reject/ warn on mismatch.

### Long-term
6. Migrate HF API + config.json hot paths from `JSONSerialization` to partial Codable structs.
7. Centralize non-IPC decoders beside `QwenVoiceWireCodec` to prevent future strategy drift.

---

## Serialization Health Score

| Metric | Value |
|--------|-------|
| Codable coverage | ~40 types, 8 manual implementations |
| Strategy consistency | IPC: 100% shared static codec; contract/catalog: ad-hoc decoders, no dates |
| Silent-failure risk | 12 `try?` decode/encode sites in scoped paths |
| CodingKeys coverage | Contract + install metadata explicit; IPC uses camelCase synthesis |
| Enum future-proofing | ~0% of wire enums have unknown-case handling |
| Cross-file alignment | IPC encoder/decoder aligned via `QwenVoiceWireCodec` |
| Legacy serialization | 4 `JSONSerialization` call sites (2 justified dynamic config) |
| **Health** | **HARDENING NEEDED** |
