# Vocello Unified Health Check Report

**Date:** 2026-05-26  
**Scope:** Full project audit — 167 Swift files under `Sources/`; website excluded  
**Emphasis:** Engine core (MLX, memory, concurrency, streaming, IPC, vendor patches)  
**Orchestration:** 17 Axiom specialized auditors + manual P0 gate verification + engine deep dive

---

## Executive Summary (Engine-Weighted)

The **documented P0 engine gates all pass** — prewarm slot serialization, model-operation lease, host single-generation coordinators, ordered AsyncStream chunk transport, streaming cancellation to vendor producers, decoder `inputContext` chunk invariance, and live-playback session-ID guards are intact. The macOS public release track is **architecturally sound** for engine isolation and bench-validated streaming behavior.

The highest-impact gaps are **performance and IPC correctness under load**, not missing gates:

1. **CRITICAL — Streaming producer blocked on MainActor** (`NativeStreamingSynthesisSession` → `@MainActor eventSink`) serializes MLX token generation behind UI scheduling; fix by decoupling chunk transport from MainActor.
2. **CRITICAL — XPC `perform` lacks cancellation cleanup** (`XPCNativeEngineClient.swift:397-422`) — cancelled macOS generations can leave hung pending requests; extension path already handles this.
3. **CRITICAL — Per-chunk PCM allocation chain** — multiple copies (Float→Int16→Data→struct) per streaming chunk dominate non-MLX time; wire existing `PCM16ScratchBuffer` pool.
4. **CRITICAL — Repetition-penalty Set rebuild every token** in vendor `Qwen3TTS.swift` hot loop — O(n) Swift work × hundreds of tokens.
5. **HIGH — Unbounded macOS `engine.events` AsyncStream** vs iOS `.bufferingNewest(64)` — RSS growth risk on long streaming sessions (memory-auditor).

**iOS TestFlight blockers (non-engine):** Missing Privacy Manifest on all shipping targets; missing `ITSAppUsesNonExemptEncryption`; clone reference recordings stored in `tmp/` (data loss).

**Overall health:** Engine core **stable on invariants, bottlenecked on hot-path performance**; iOS **not App Store ready** on compliance/storage; UI layer **mid-migration** with UX cancel gaps.

---

## P0 Gate Status

| # | Invariant | Verdict |
|---|-----------|---------|
| 1 | Prewarm slot | **PASS** |
| 2 | Model-operation lease | **PASS** |
| 3 | Host single-generation | **PASS** |
| 4 | Ordered chunk transport | **PASS** |
| 5 | Streaming cancellation | **PASS** |
| 6 | Decoder inputContext | **PASS** |
| 7 | Live session ID guard | **PASS** |

Detail: [`scratch/health-check-p0-gates-2026-05-26.md`](health-check-p0-gates-2026-05-26.md)

---

## Top Engine Findings (CRITICAL + HIGH)

### Concurrency / IPC

| Sev | File:Line | Finding | Fix |
|-----|-----------|---------|-----|
| CRITICAL | `XPCNativeEngineClient.swift:397-422` | `perform` missing `withTaskCancellationHandler`; pending requests survive caller cancel | Mirror ExtensionEngineCoordinator cancel-on-termination pattern |
| HIGH | `EngineServiceHost.swift` / `VocelloEngineExtensionHost.swift` | Fire-and-forget `finish(id:)` in generation `defer` | Await coordinator finish before releasing generation task |
| HIGH | `XPCNativeEngineCoordinator` | Timeout handler may touch actor state without `await` | Route timeout through actor-isolated method |
| HIGH | `NativeMemoryPressureMonitor` | `currentLevel` read off dispatch queue | Read on monitor queue or make level atomic/@MainActor |
| HIGH | `MLXTTSEngine.stop()` | Detached cleanup not awaited | Structured cleanup task with await at shutdown |

### Memory / Streaming transport

| Sev | File:Line | Finding | Fix |
|-----|-----------|---------|-----|
| HIGH | `MLXTTSEngine.swift:425-431` | macOS uses unbounded AsyncStream for events | Align with iOS `.bufferingNewest(64)` or strip preview before yield |
| HIGH | `iOS/TTSEngineStore.swift` | Memory guard task not cancelled in `stop()` | Cancel guard in stop/teardown path |
| HIGH | `AudioPlayerViewModel.swift` | `deinit` clears timer but not live AVAudioEngine graph | Teardown live engine in deinit/stop path |

### Performance (MLX hot path)

| Sev | File:Line | Finding | Fix |
|-----|-----------|---------|-----|
| CRITICAL | `NativeStreamingSynthesisSession.swift:1140` | `@MainActor eventSink` blocks detached producer | Background queue / AsyncStream continuation for chunks |
| CRITICAL | `NativeStreamingSynthesisSession.swift:1071-1096` | Per-chunk PCM copy chain | In-place convertLimited; reuse buffer for preview + WAV |
| CRITICAL | `Qwen3TTS.swift:2578` | `Array(Set(tokens))` every token for repetition penalty | Incremental Set maintenance |
| HIGH | `MLXTTSEngine.swift:1374-1390` | PCM16ScratchBuffer pool never wired | Pass shared buffer through factory |
| HIGH | `NativeStreamingSynthesisSession.swift:490-494` | convertLimited returns COW copy | Return borrowed slice from scratch |

### Codable / IPC encode

| Sev | File:Line | Finding | Fix |
|-----|-----------|---------|-----|
| HIGH | `EngineServiceHost.swift:488` | `try?` encode drops streaming chunks silently | do/catch + telemetry on encode failure |
| HIGH | `VocelloEngineExtensionHost.swift:435` | Same silent encode drop | Same fix |
| HIGH | `iOSSupport/Models/TTSContract.swift` | iOS contract load uses fatalError vs macOS graceful degrade | Match macOS error surface |

---

## Findings by Domain (Summary)

### Security & Privacy — NOT READY (iOS ship)

- **CRITICAL:** No `PrivacyInfo.xcprivacy` on any shipping target (Required Reason APIs in use)
- **CRITICAL:** Missing `ITSAppUsesNonExemptEncryption` despite CryptoKit
- **HIGH:** macOS sandbox off (intentional for MLX) — document in privacy nutrition labels
- **HIGH:** ~50 DEBUG print() sites with potential path leakage
- Report: [`health-check-security-2026-05-26.md`](health-check-security-2026-05-26.md)

### Storage — FRAGILE

- **CRITICAL:** iOS clone reference recordings in `tmp/` — silent loss under storage pressure
- **HIGH:** macOS no `isExcludedFromBackup` on multi-GB model folders
- **HIGH:** iOS cache/ regenerable subtrees still backed up
- Report: [`health-check-storage-2026-05-26.md`](health-check-storage-2026-05-26.md)

### Database (GRDB) — FRAGILE

- **HIGH:** macOS v4 index migration missing on iOS — schema drift
- **HIGH:** Duplicated `makeMigrator()` in two files — root cause of drift
- Report: [`health-check-database-2026-05-26.md`](health-check-database-2026-05-26.md)

### UX Flow (iOS) — BROKEN JOURNEYS

- **CRITICAL:** Cancel hidden when switching Studio mode or tab during generation
- **CRITICAL:** `studioGenState` not driven by `hasActiveGeneration` globally
- **HIGH:** Mode rail + setup chips remain enabled during active generation
- Report: [`health-check-ux-flow-2026-05-26.md`](health-check-ux-flow-2026-05-26.md)

### SwiftUI Architecture (iOS) — TANGLED

- **CRITICAL:** Full generation business flow in `IOSGenerationModeViews` (3 modes)
- **HIGH:** Dead `IOSGeneratePrimaryActionDescriptor` pipeline
- Report: [`health-check-swiftui-architecture-2026-05-26.md`](health-check-swiftui-architecture-2026-05-26.md)

### SwiftUI Performance — JANKY (secondary)

- **CRITICAL (compound):** History rows embed `IOSWaveformBars` with GeometryReader per cell
- **HIGH:** Player karaoke rebuilds AttributedString at 30 Hz
- **HIGH:** Voices list uses VStack not LazyVStack
- Report: [`health-check-swiftui-performance-2026-05-26.md`](health-check-swiftui-performance-2026-05-26.md)

### Modernization — Engine-boundary debt

- **Critical:** TTSEngine protocol pins ObservableObject; blocks @Observable migration
- **High:** 12 sites — engine stores, XPC bridges, macOS shell
- Report: [`health-check-modernization-2026-05-26.md`](health-check-modernization-2026-05-26.md)

### Testing — GAPS (policy, not defect)

- Zero XCTest by intentional May 2026 policy
- **HIGH:** Engine-core invariants lack isolated automated tests — rely on bench/signposts
- Report: [`health-check-testing-2026-05-26.md`](health-check-testing-2026-05-26.md)

### Passed / Clean domains

| Auditor | CRITICAL | Notes |
|---------|----------|-------|
| networking-auditor | 0 | HTTPS-only; no reachability anti-patterns |
| energy-auditor | 0 | No idle CRITICAL drain; 4 HIGH lifecycle gaps |
| swiftui-layout-auditor | 0 | Dock clearance documented; minor hardcoded reservation |
| liquid-glass-auditor | 0 | iOS strong Reduce Transparency; macOS glass fallback gap (HIGH not CRITICAL) |

---

## Release / Proof Gaps

| Gap | Status | Source |
|-----|--------|--------|
| M1 8GB floor re-verify on M2 dev host | Pending | release-readiness.md |
| iPhone 15 Pro minimum device proof | Pending | release-readiness.md |
| iOS increased-memory entitlement / TestFlight signing | Pending | release-readiness.md |
| Privacy Manifest + export compliance | **Blocking iOS submit** | security audit |
| MLX 0.30.6 → 0.31.3 vendor refresh | Deferred | foundation-projects-audit.md |

---

## Technical Debt Register

| Item | Priority | Notes |
|------|----------|-------|
| iOS legacy IOS*.swift bodies (~28 files) | P1 | Generation logic not in coordinators |
| Dual theme systems (Theme vs IOSAppTheme) | P2 | Incomplete migration |
| Double IOSModeBackdrop (RootView + shell) | P2 | Wasted compositing |
| Dead IOSGlobalNowPlayingRail | P2 | Orphaned code |
| macOS @StateObject vs iOS @Observable split | P1 | modernization-helper |
| AGENTS.md ModeSegmented.swift reference | P3 | Doc drift only |

---

## Dependency Risk

| Dependency | Pin | Latest observed | Risk |
|------------|-----|-----------------|------|
| MLXSwift | 0.30.6 | 0.31.3 | Controlled refresh needed for vendor rebase |
| mlx-audio-swift | vendored fcbd04d + patches | v0.1.2 base | Highest foundation risk — narrow patches documented |
| GRDB | 7.10.0 | 7.10.0 | Current |
| SwiftHuggingFace | 0.9.0 | current | OK |

---

## Prioritized Roadmap

### P0 — Ship blockers / correctness under load

1. Add `withTaskCancellationHandler` to XPC `perform` (macOS cancel correctness)
2. Decouple streaming `eventSink` from MainActor (throughput + latency)
3. Bound macOS `engine.events` AsyncStream buffer
4. Materialize iOS clone recordings out of `tmp/` immediately
5. Add Privacy Manifest + export compliance keys before iOS submit

### P1 — Pre-iOS public / engine hardening

6. Wire PCM16ScratchBuffer pool; reduce per-chunk copies
7. Fix vendor repetition-penalty Set rebuild in token loop
8. Consolidate GRDB migrations to SharedSupport; port v4 to iOS
9. Global in-flight generation chrome with Cancel on all tabs (UX)
10. Extract iOS generation into coordinator/services (architecture)
11. macOS backup exclusions for models/downloads
12. Replace `try?` on IPC event encode with explicit error handling

### P2 — Cleanup / polish

13. Remove dead primary-action pipeline + orphaned now-playing rail
14. Unify iOS theme tokens; macOS Reduce Transparency glass fallbacks
15. LazyVStack for Voices/voice picker; simplify history row waveforms
16. @Observable migration for TTSEngineStore (engine-first order from modernization audit)
17. Re-bench streaming cells after P0/P1 engine perf fixes

---

## Auditor Summary Table

| Auditor | Trigger | CRIT | HIGH | MED | LOW | Report |
|---------|---------|-----:|-----:|----:|----:|--------|
| memory-auditor | always | 0 | 2 | 7 | 4 | health-check-memory-2026-05-26.md |
| concurrency-auditor | always | 1 | 5 | 8 | 6 | health-check-concurrency-2026-05-26.md |
| swift-performance-analyzer | always | 3 | 6 | 6 | 3 | health-check-swift-performance-2026-05-26.md |
| codable-auditor | always | 0 | 9 | 8 | 3 | health-check-codable-2026-05-26.md |
| security-privacy-scanner | always | 2 | 4 | 6 | 3 | health-check-security-2026-05-26.md |
| modernization-helper | always | 2 | 12 | 11 | 6 | health-check-modernization-2026-05-26.md |
| database-schema-auditor | GRDB | 0 | 2 | 4 | 2 | health-check-database-2026-05-26.md |
| storage-auditor | AppPaths | 1 | 4 | 5 | 2 | health-check-storage-2026-05-26.md |
| networking-auditor | HF/URLSession | 0 | * | * | * | health-check-networking-2026-05-26.md |
| swiftui-performance-analyzer | SwiftUI | 1 | 6 | 7 | 4 | health-check-swiftui-performance-2026-05-26.md |
| swiftui-architecture-auditor | SwiftUI | 3 | 7 | 6 | 3 | health-check-swiftui-architecture-2026-05-26.md |
| swiftui-layout-auditor | SwiftUI | 0 | * | * | * | health-check-swiftui-layout-2026-05-26.md |
| swiftui-nav-auditor | Navigation | 0 | * | * | * | health-check-swiftui-nav-2026-05-26.md |
| ux-flow-auditor | sheets/tabs | 2 | 7 | 5 | 2 | health-check-ux-flow-2026-05-26.md |
| liquid-glass-auditor | glass | 0 | 3 | 9 | 5 | health-check-liquid-glass-2026-05-26.md |
| energy-auditor | timers | 0 | 4 | 5 | 2 | health-check-energy-2026-05-26.md |
| testing-auditor | policy | 0 | 4 | 6 | 5 | health-check-testing-2026-05-26.md |

*See individual scratch files for full severity breakdowns.*

---

## Supplemental Manual Reports

| Report | Purpose |
|--------|---------|
| health-check-phase0-context-2026-05-26.md | Doc vs code cross-check |
| health-check-p0-gates-2026-05-26.md | 7 non-regression gates |
| health-check-engine-deep-dive-2026-05-26.md | Memory parity, vendor, IPC traces, drift |

---

## Validation Recommendation

After implementing P0 engine items (1–3, 6–7), run:

```sh
./scripts/uitest.sh bench-step custom cold medium speed
./scripts/uitest.sh bench-compare
```

Focus on `ms_engine_start_to_autoplay`, `rtf`, and `peak_rss_mb` vs `docs/reference/benchmark-baselines.json`.
