# Test Quality Audit — QwenVoice (2026-05-26)

## Summary

Vocello has **zero** Swift test targets (`*Tests.swift`, XCTest, Swift Testing) by **intentional policy** (retired May 2026; enforced by `scripts/check_project_inputs.sh` and documented in `docs/reference/testing-overview.md`). Behavioral validation is **local-only**: `scripts/uitest.sh` smoke/bench runbooks, manual acceptance, static `check_*.sh` scripts, and CI compile/packaging only (`.github/workflows/release.yml`).

**Test Health (repo policy lens):** **GAPS** — E2E smoke/bench covers macOS generation paths well for regression timing and WAV/DB proof, but **engine-core invariants** (prewarm serialization, concurrent-generation rejection, GRDB migrations, iOS extension/memory admission) have **no isolated automated tests**. These are **informational policy findings**, not requests to reintroduce XCTest unless maintainers explicitly decide otherwise.

| Severity | Count | Nature |
|----------|------:|--------|
| CRITICAL | 0 | No XCTest anti-patterns; no policy violation |
| HIGH | 4 | Engine-core / persistence gaps without unit isolation |
| MEDIUM | 6 | Shallow negative-path / platform coverage |
| LOW | 5 | Non-engine surfaces, vendor examples |
| Phase 2 (anti-patterns in test code) | 0 | No test files exist |
| Phase 4 (compound) | 3 | Listed under compound section |

**Quick wins (within current policy):** (1) Run all three smoke runbooks after any `QwenVoiceCore` / `mlx-audio-swift` edit; (2) run `bench-compare` on affected mode when touching streaming or prewarm; (3) add a one-line `uitest.sh db` migration sanity check to smoke-history when adding GRDB migrations.

---

## Coverage Shape Map

- **Production Swift:** ~167 files under `Sources/` across targets `QwenVoice`, `QwenVoiceCore` (29), `QwenVoiceBackendCore` (1), `QwenVoiceNative` (4), `QwenVoiceEngineService` (2), `QwenVoiceEngineSupport` (3), `VocelloEngineExtension` (2), `iOSSupport` (18), plus macOS/iOS app UI.
- **Automated tests:** **0** unit/UI/spec files; **0** `@testable import`; **0** `import XCTest` / `import Testing` / `XCUIApplication` in repo Swift.
- **Substitute validation:** `scripts/uitest.sh` (smoke-check, verify-generation, bench-step/summarize/compare), `docs/reference/smoke-*.md` (6), `docs/reference/bench-*.md` (3), `docs/reference/benchmark-baselines.json` (24 cells), `scripts/check_project_inputs.sh`, `scripts/check_qwen3_backend_only.sh`, `scripts/check_backend_resource_contract.sh`, `scripts/check_ios_catalog.sh`, `scripts/ios_device.sh` (iPhone hardware).
- **CI:** macOS DMG packaging + iOS compile-safety only; **no** smoke/bench on CI.
- **Auth / IAP / Keychain:** not present in `Sources/` (N/A).
- **Networking:** Hugging Face download path (`HuggingFaceDownloader.swift`) — real Hub in manual/smoke flows, no mocked contract tests.
- **Persistence:** GRDB `DatabaseService` + migrations v1–v4 (macOS); iOS mirror in `iOSSupport` — smoke asserts post-generate row, not migration correctness.
- **Engine core:** exercised **indirectly** via full-stack bench (ms, RTF, RSS) and smoke (WAV + DB); critical gates documented in AGENTS.md (prewarm slot, generation ownership, stale live completion) rely on signposts + manual/bench triage, not unit tests.

---

## Test Health Score

| Metric | Value |
|--------|-------|
| Module coverage | 0/8 production modules have dedicated test targets (0%) |
| Critical path coverage | auth N/A, payments N/A, persistence smoke-only, networking manual/HF-live |
| Error path coverage | Many `MLXTTSEngineError` / `*Error` enums; **0** automated per-case assertions |
| Test reliability | 0 `sleep()` in tests; 0 shared mutable test state |
| Test speed | N/A (no test target) |
| Test framework | 0 XCTest, 0 Swift Testing |
| **Health (traditional)** | **UNDERTESTED** |
| **Health (repo policy)** | **GAPS** — scripted E2E adequate for ship track if bench/smoke run on engine changes |

---

## Findings (severity · file:line · description · fix)

### HIGH — Engine core: no isolated tests for concurrency gates

| | |
|---|---|
| **Severity** | HIGH (informational — validation gap, not policy defect) |
| **File:line** | `Sources/QwenVoiceCore/NativeEngineRuntime.swift:870-915` (`acquirePrewarmSlot` / `releasePrewarmSlot`) |
| **Description** | Prewarm serialization across actor suspension is documented as CRITICAL (May 2026 KV-cache race). No unit/integration test reproduces concurrent `prefetchInteractiveReadiness` + `prepareGeneration`; only crash forensics + engineering docs. |
| **Fix** | **Policy-aligned:** After any change to prewarm paths, run bench for affected mode (cold + warm) and inspect signposts (`Native Prewarm Cache Hit`, crash logs). **If unit tests ever return:** add a Swift Testing suite that launches two concurrent prewarm callers and asserts single-flight (mock runtime). |

### HIGH — Engine core: model-operation gate untested in isolation

| | |
|---|---|
| **Severity** | HIGH (informational) |
| **File:line** | `Sources/QwenVoiceCore/MLXTTSEngine.swift:220-225` (`beginUserModelOperation`) |
| **Description** | Concurrent generation rejection and batch/load/unload serialization are production-critical; coverage is E2E only (UI disables via `hasActiveGeneration`, XPC host rejects). No automated test asserts `MLXTTSEngineError.generationFailed` on double-start. |
| **Fix** | Run all three smokes when touching generation gating; optionally extend `uitest.sh` with a scripted double-`super+Return` attempt and expect disabled UI / error toast (no XCTest required). |

### HIGH — Persistence: GRDB migrations without fixture tests

| | |
|---|---|
| **Severity** | HIGH (informational) |
| **File:line** | `Sources/Services/DatabaseService.swift:41-99` (migrations v1–v4, especially v3 table rebuild) |
| **Description** | Destructive migration `v3_drop_sortOrder` copies rows across tables; no automated test loads a pre-migration SQLite fixture and verifies row counts/paths. Smoke only checks a new row after generate. |
| **Fix** | On migration edits: manual test with copied `history.sqlite` from Debug App Support; add optional `uitest.sh db` queries to smoke-history runbook. Long-term: GRDB in-memory migrator test in a **new** test target only if policy changes. |

### HIGH — iOS engine extension / memory admission

| | |
|---|---|
| **Severity** | HIGH (informational) |
| **File:line** | `Sources/QwenVoiceCore/ExtensionEngineCoordinator.swift` (transport/timeouts); `Sources/iOS/TTSEngineStore.swift` (memory policy refresh) |
| **Description** | ExtensionKit IPC, aggregate memory bands, and Debug-only admission env vars are not covered by macOS bench/smoke. Simulator uses stub engine (`IOSSimulatorTTSEngine.swift`). |
| **Fix** | Follow `docs/reference/ios-device-screen-mirror-testing.md` + `scripts/ios_device.sh` for hardware changes; document run id + `pull` artifacts in PR notes. |

### MEDIUM — Streaming / live playback invariants

| | |
|---|---|
| **Severity** | MEDIUM (informational) |
| **File:line** | `Sources/SharedSupport/ViewModels/AudioPlayerViewModel.swift:1019-1020` (`Stale Completion Dropped`) |
| **Description** | Session-ID guard for AVAudioEngine buffer completions is bench-validated via `ms_engine_start_to_autoplay` on back-to-back cells, not a deterministic unit test. |
| **Fix** | When editing live playback: run clone/custom bench cold→warm pairs per AGENTS.md Phase 4 recipe; grep signposts in `uitest.sh logs`. |

### MEDIUM — floor8GB Quality→Speed OOM fallback

| | |
|---|---|
| **Severity** | MEDIUM (informational) |
| **File:line** | `Sources/QwenVoiceCore/MLXTTSEngine.swift` (`loadModel` OOM retry — see AGENTS.md) |
| **Description** | Hardware-specific fallback path is not in committed bench matrix (M2 baselines). M1 8 GB proof called out as not re-verified in `release-readiness.md`. |
| **Fix** | Manual bench on floor hardware before claiming Quality availability on 8 GB Macs; extend baselines only after intentional perf signoff. |

### MEDIUM — Error enum / negative paths

| | |
|---|---|
| **Severity** | MEDIUM (informational) |
| **File:line** | `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift` (multiple `MLXTTSEngineError` throws); `ExtensionEngineTransportError`, `AudioPreparationError` |
| **Description** | Production defines many failure variants; no table-driven tests. Smoke happy-path only. |
| **Fix** | For API/error changes: manual fault injection (missing model, cancel mid-generation) + document expected UI copy; consider Swift Testing only if policy reopens. |

### MEDIUM — Hugging Face downloader

| | |
|---|---|
| **Severity** | MEDIUM (informational) |
| **File:line** | `Sources/Services/HuggingFaceDownloader.swift:281` (`Task.sleep` retry backoff) |
| **Description** | Real Hub dependency; no mock server tests. Offline/flaky network failures are manual. |
| **Fix** | smoke-settings for model Ready state; retry logic changes need manual download interrupt test. |

### MEDIUM — Static checks vs behavioral tests

| | |
|---|---|
| **Severity** | MEDIUM (informational) |
| **File:line** | `scripts/check_qwen3_backend_only.sh:1-40`; `scripts/check_backend_resource_contract.sh` |
| **Description** | Shell validators cover contract/vendor shape, not runtime MLX correctness. Complement bench, not replace. |
| **Fix** | Keep running `check_project_inputs.sh` + foundation builds on engine edits per `testing-overview.md` decision table. |

### MEDIUM — CI does not run smoke/bench

| | |
|---|---|
| **Severity** | MEDIUM (informational) |
| **File:line** | `.github/workflows/release.yml:4-5` |
| **Description** | Documented carve-out: no behavioral CI. Regressions depend on maintainer/agent local runs. |
| **Fix** | Pre-release: explicit checklist in PR (smoke trio + bench-compare for engine); optional future `workflow_dispatch` bench job — policy decision only. |

### LOW — iOS Simulator stub timing

| | |
|---|---|
| **Severity** | LOW |
| **File:line** | `Sources/iOS/IOSSimulatorTTSEngine.swift:144,179` |
| **Description** | `Task.sleep` simulates download/generation; not a test anti-pattern but can mask real timing bugs if relied on for perf claims. |
| **Fix** | Do not use Simulator stub for perf signoff; use device script. |

### LOW — Website / marketing app

| | |
|---|---|
| **Severity** | LOW |
| **File:line** | `website/` (no `test`/`describe` in TS) |
| **Description** | Vite/React site has no automated tests; out of macOS bench scope. |
| **Fix** | `npm --prefix website run build` on copy/CSS changes; optional Vitest only if team wants web CI. |

### LOW — Vendor example sleeps

| | |
|---|---|
| **Severity** | LOW |
| **File:line** | `third_party_patches/mlx-audio-swift/Examples/SimpleChat/...:336` |
| **Description** | Example code uses `Task.sleep`; not part of Vocello ship surface. |
| **Fix** | None required for Vocello release track. |

### LOW — Prohibited test surface enforcement

| | |
|---|---|
| **Severity** | LOW (positive control) |
| **File:line** | `scripts/check_project_inputs.sh:35-71` |
| **Description** | `QwenVoiceTests`, `VocelloUITests`, `tests/perf`, etc. are prohibited — correctly absent. |
| **Fix** | Run `./scripts/check_project_inputs.sh` before merge; do not re-add test targets without maintainer decision. |

### LOW — Retired historical QA docs

| | |
|---|---|
| **Severity** | LOW |
| **File:line** | `docs/reference/engineering-status.md:13-18,51` |
| **Description** | Docs accurately state XCTest retirement and smoke/bench replacement. |
| **Fix** | Keep `testing-overview.md` decision table in sync when adding new validation layers. |

---

## Phase 2: Anti-Pattern Detection

**Result: 0 issues.** No `*Tests.swift`, `*Test.swift`, or `*Spec.swift` files. Grep for `XCTestCase`, `XCTAssert*`, `func test`, `static var` in test classes, and test-target `sleep()` all returned empty. Production `Task.sleep` usages are debounce/timeout/retry logic, not test flakiness.

---

## Phase 3: Completeness (policy-aware)

| Question | Answer |
|----------|--------|
| Critical paths tested? | Generation E2E yes (smoke/bench); auth/IAP N/A; persistence partial; iOS engine hardware manual |
| Async test patterns? | N/A — no async tests |
| Error paths tested? | Mostly no — happy-path smokes |
| Public API contract tests? | `check_*` shell + `qwenvoice_contract.json` static only |
| Network mocks? | No — HF is live in operational flows |
| Edge cases in tests? | Bench matrix covers cold/warm × variant × bucket; not cancellation/OOM/migration |
| Error enums asserted? | No automated matrix |

---

## Phase 4: Compound Findings

1. **No unit tests + actor prewarm gate + MLX KV cache** → regressions surface as engine crashes or bench drift; mitigated by documented gate and bench signposts (**HIGH**, informational).
2. **No migration tests + v3 destructive GRDB migration** → schema edits risk silent data loss on upgrade (**HIGH**, informational).
3. **Smoke passes + no per-error assertions** → false confidence on new `MLXTTSEngineError` branches (**MEDIUM**, informational).

**Cross-auditor:** Untested `@MainActor` UI/store code compounds with concurrency-auditor concerns; untested GRDB migrations compound with data-auditor concerns. Neither implies XCTest must return under current policy.

---

## Quick Wins

1. **Fastest risk reduction:** Engine-touching PR → three smokes + one `bench-compare` on touched mode (per `docs/reference/testing-overview.md`).
2. **Biggest coverage gap closure (no XCTest):** Document required `ios_device.sh` run for iOS engine/memory PRs.
3. **Easiest guard:** Run `./scripts/check_project_inputs.sh` to prevent accidental test-target reintroduction.

---

## Recommendations

### Immediate (maintainers / agents)

1. Treat **QwenVoiceCore** / **mlx-audio-swift** edits as **bench-mandatory**; smoke-mandatory for audio path and IPC.
2. Never ship GRDB migration changes without a **manual upgrade test** from a real Debug `history.sqlite`.
3. Do **not** reintroduce XCTest targets unless explicit maintainer decision — `check_project_inputs.sh` will fail.

### Short-term (within local-only policy)

1. Optional smoke enhancement: double-generate / cancel step in `uitest.sh` for gating verification.
2. Re-verify **M1 8 GB** Quality→Speed fallback outside M2 baselines before marketing floor-hardware claims.
3. PR template line: "Smoke: custom/design/clone; Bench: \<mode\>; iOS device: yes/no".

### Long-term (only if policy changes)

1. Swift Testing package targeting **QwenVoiceCore** only: migrator fixtures, `beginUserModelOperation` rejection, prewarm single-flight with injected mock runtime.
2. Optional CI `workflow_dispatch` bench job on self-hosted Mac (heavy; not current scope).

---

## Related

- `docs/reference/testing-overview.md` — decision table
- `docs/reference/engineering-status.md` — validation posture
- `AGENTS.md` — Testing policy, prewarm gate, bench reading rules
- Subagent: test-failure-analyzer (if flaky harness behavior appears in `build/Debug/uitest/`)
