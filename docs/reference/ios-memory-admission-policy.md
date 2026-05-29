# iOS memory admission policy (Release vs Debug)

Source of truth for iPhone memory guardrails. Implementation: `TTSEngineStore` in `Sources/iOS/TTSEngineStore.swift`, thresholds in `IOSMemoryBudgetPolicy` (`Sources/QwenVoiceCore/IOSMemorySnapshot.swift`).

**Hub:** [`ios-shipping.md`](ios-shipping.md)

## Current behavior (May 2026 — jetsam investigation)

| Guard | Default | Notes |
|---|---|---|
| **Model admission block** (`model_admission_blocked`) | **Off** | `guardModelAdmission` only samples context and records `model_admission_observed`; load/generation proceed |
| **In-flight critical cancel + full unload** | **Off** | `shouldEnforceCriticalMemoryContext` returns false except `debug_force_critical_once` in Debug |
| Proactive warm/prefetch gate | On (band-based) | Unchanged |
| Engine/kernel trim via `NativeMemoryPressureMonitor` | On | Unchanged in extension |

**Rationale:** On iPhone 17 Pro without Apple's increased-memory entitlement, admission blocking prevented observing whether the extension Jetsam's or MLX fails first. Admission is disabled until entitled proof defines a safe re-enable threshold.

**Risk:** Load/generation may Jetsam the engine extension or fail with MLX OOM instead of a recoverable in-app error. Use owned hardware only until policy is restored.

## Diagnostics

- `model_admission_observed` — memory context sampled before load/generation (no block).
- `model_admission_blocked` — **not emitted** while admission blocking is disabled.
- `likelyEntitlementBlocked` in pull JSONL may still be true when extension headroom is low; it is informational only.

## Maintainer env vars (unchanged)

| Variable | Purpose |
|---|---|
| `QVOICE_IOS_ALLOW_AGGREGATE_GUARDED_ADMISSION` | Reserved; no effect while admission block is disabled |
| `QVOICE_IOS_ENABLE_PROACTIVE_PREFETCH` | Debug: enable proactive warm on device |
| `QVOICE_IOS_MEMORY_GUARD_FORCE_CRITICAL_ONCE` | Debug: one-shot critical cancel probe |
| `QVOICE_IOS_MEMORY_GUARD_FORCE_BAND` | Debug: synthetic guarded band |
| `QWENVOICE_STREAMING_PREVIEW_DATA` | Inline PCM on device when `on` |

Removed: `QVOICE_IOS_SKIP_MODEL_ADMISSION_GUARD` and the `--skip-admission-guard` device flag (admission skip is now the default).

## Restoring admission blocking (future)

When re-enabling, restore checks in `guardModelAdmission` for:

1. Per-process critical band (`allowsModelAdmission`).
2. Aggregate critical.
3. Aggregate guarded in Release unless `QVOICE_IOS_ALLOW_AGGREGATE_GUARDED_ADMISSION=1`.

And restore `shouldEnforceCriticalMemoryContext` to use `engineExecutionBand == .critical`. User-visible copy lives in `IOSMemoryBudgetPolicy.modelAdmissionBlockMessage`.

## Product / support

Until admission is re-enabled, users may see extension restarts, hung generation, or MLX errors instead of “needs more memory” copy. After Apple increased-memory approval, re-enable admission and validate on iPhone 17 Pro then iPhone 15 Pro before TestFlight.
