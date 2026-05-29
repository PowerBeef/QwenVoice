# iOS smooth MLX feasibility (memory and Jetsam)

Maintained summary of whether Vocello can run Qwen3-TTS on iPhone with acceptable stability and perceived smoothness.

**Hub (reading order and checklists):** [`ios-shipping.md`](ios-shipping.md)

## Executive verdict

| Question | Answer |
|---|---|
| Can this project run Qwen3-TTS on iPhone at all? | **Yes in principle** — same `MLXTTSEngine` in an ExtensionKit process with iOS admission, trim, and streaming policy. |
| Smooth for typical users today? | **No** — without Apple's increased-memory entitlement, extension headroom is low; admission blocking is temporarily disabled (May 2026) so Jetsam/MLX behavior can be observed on device. |
| Smooth after entitlement + device proof? | **Plausible** for **iPhone 15 Pro+** with **Speed 4-bit** packages only — not yet proven on official minimum hardware. |
| Simulator sufficient? | **No** for MLX/memory — UI and stub engine only. |

**Bottom line:** Design and code support a bounded iOS product; **shipping smooth on-device generation** requires entitlement approval plus entitled proof on iPhone 17 Pro (dev) and **iPhone 15 Pro** (minimum).

## Architecture (Jetsam-oriented)

- **UI process:** `Sources/iOS/`, `TTSEngineStore` — admission, diagnostics, playback.
- **MLX process:** `Sources/iOSEngineExtension/` — `VocelloEngineExtensionHost` + `MLXTTSEngine`.

Jetsam is per-process. Isolating MLX protects the UI; the **extension limit** is the current bottleneck.

### iPhonePro tier (`NativeMemoryPolicyResolver`)

| Knob | Value | Role |
|---|---|---|
| MLX cache limit | 128 MB | Caps retained cache |
| `clearCacheAfterGeneration` | true | Post-run cache drop |
| Idle unload | 30 s | Unload when idle |
| Clone cache | 1 | Limits reference RAM |
| Streaming interval floor | 0.6 s | Throttles chunk pressure |
| Custom prewarm | skip (extension) | Defers peak to first user gen |

### Admission (`IOSMemoryBudgetPolicy` + `TTSEngineStore`)

- Per-process headroom: healthy ≥ 768 MB, guarded 384–768 MB, critical &lt; 384 MB.
- Aggregate footprint: guarded ≥ ~4.5 GB, critical ≥ ~5.2 GB (app + extension).
- **Admission block disabled (May 2026):** `guardModelAdmission` records `model_admission_observed` only; see [`ios-memory-admission-policy.md`](ios-memory-admission-policy.md).
- Kernel pressure → `NativeMemoryPressureMonitor` → soft/hard trim; critical during generation → cancel + unload.

### iOS vs macOS RAM tradeoffs

- No eager load after model install; first foreground generation pays load.
- Streaming-first; physical device omits inline PCM preview unless `QWENVOICE_STREAMING_PREVIEW_DATA=on`.
- Extension events **bounded** (`.bufferingNewest(64)`); macOS stays **`.unbounded`** for chunk delivery.
- `Qwen3TTSMemoryCaches.clearAll()` on iOS hard-trim/unload/failure.
- Model ID switch: unload + clear before next load peak.

## Memory budget

iOS catalog (`qwenvoice_ios_model_catalog.json`): three **Speed 4-bit** packages (~2.15–2.33 GB each), ~1.53 GB `model.safetensors` + ~0.64 GB speech tokenizer per mode. No Quality 8-bit or 0.6B on iOS in the current catalog.

Peak RAM (order of magnitude): weights + activations/KV + capped MLX cache + app footprint counted in aggregate admission.

## Jetsam risk matrix

| Scenario | Without entitlement | Mitigation | Residual |
|---|---|---|---|
| Load 1.7B 4-bit in extension | High block/fail | Admission block | Feature unavailable |
| Multitasking + guarded aggregate | High block in Release | Block guarded admission | User frees RAM |
| Mid-gen memory warning | Medium | Trim / cancel | Aborted generation |
| Quality 8-bit on iOS | N/A | Not shipped | — |

Philosophy: **block with clear errors** rather than Jetsam kill.

## What “smooth” means for TestFlight

| Dimension | Expectation |
|---|---|
| Stable (no Jetsam in normal use) | High once thresholds match hardware |
| Cold first generation | Medium — load + compile; multi-second delay expected |
| Warm repeat | Medium–High — 30 s idle unload hurts |
| Time to first audio | Medium — streaming-first; device playback policy |
| macOS Quality parity | Low — Speed-only on iOS |
| Multi-mode fast switch | Low–Medium — unload on model ID change |

Not parity with 16 GB Mac Quality bench cells.

## Critical path

1. Apple **increased-memory** approval for app + extension (tracker).
2. Regenerate profiles; `verify-entitlements --enable-increased-memory-limit`.
3. Device proof matrix on **iPhone 17 Pro** then **iPhone 15 Pro**.
4. TestFlight after signing path includes entitlement.

### Optional engineering (only if entitled 1.7B still fails)

The deferred 0.6B evaluation is gated behind entitled 1.7B proof. Do not switch macOS event buffering to match iOS bounded stream.

## Validation (deferred)

The on-device validation scripts (`ios_device.sh`, `ios_device_proof_matrix.sh`) were removed in the testing-harness cleanup. iOS verification is currently `./scripts/build_foundation_targets.sh ios` (compile-safety only); on-device baseline/entitled proof must be re-established when iPhone work resumes.

Axiom: `memory-auditor` + `axiom:axiom-performance` on policy changes (see `CLAUDE.md` § Performance + memory adaptation).
