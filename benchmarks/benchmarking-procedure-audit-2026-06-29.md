# Benchmarking procedure audit — 2026-06-29

> **Historical audit (2026-06-29).** References to "compile + fake UI only" (e.g. §6 process
> gaps) reflect the pre-removal CI model. Current CI is compile-only for iOS; the real iOS
> pre-merge gate is `scripts/ios_device.sh gate` on a paired iPhone.

**Scope:** Full benchmarking stack — CLI (`vocello bench`), telemetry harness, summarizer,
platform lanes (macOS CLI/XPC/profile, iOS device bench), fixtures, docs, and CI integration.

**Method:** Code inventory, live bench run, delta vs [`telemetry-harness-review.md`](../docs/reference/telemetry-harness-review.md) (2026-06-15), seven parallel Axiom subagents.

**Deliverable companion:** [`docs/reference/benchmarking-procedure.md`](../docs/reference/benchmarking-procedure.md) (new operator runbook).

**Commit:** `9cc46dd` at audit time

---

## Executive summary

| Area | Verdict |
|------|---------|
| **Procedure maturity** | **Strong foundation** — deterministic CLI driver, rich schema v5, summarizer with chunk timeline + baseline compare |
| **Documentation** | **Was fragmented** — now consolidated in `benchmarking-procedure.md`; schema doc remains authoritative for fields |
| **Automation** | **Gap** — no CI bench gate; release QA step 3 is manual |
| **Measurement validity** | **Caveated** — lazy MLX wall clocks documented; signpost validation recommended |
| **Harness reliability** | **Fixed (2026-06-29 follow-up)** — preview PCM off, event drain per take, strict clone preflight |

**Top 5 gaps:**

1. **No automated engine regression gate in CI/pre-merge** — bench is manual despite release QA requiring it.
2. ~~**CLI bench harness leaks memory**~~ — **Fixed:** `QWENVOICE_STREAMING_PREVIEW_DATA=off` + `generateObservingFirstChunk` per streaming take.
3. **RTF/decode KPI ambiguity** — incompatible time bases; summarizer columns can disagree by 20–50%.
4. **Summarizer omits v5 environment fields** — thermal, GPU working-set ratio, pressure bands collected but not reported.
5. **Ungated failure/native-event JSONL** — production-adjacent writers bypass telemetry gate and retention caps.

**Overall:** Safe to continue using `vocello bench` as the primary backend gate **with documented caveats** on RTF vs decode time bases (P0-1). Treat listening pass and manual HISTORY comparison as mandatory until CI bench lands.

---

## 1. Procedure map

| Driver | Platform | Topology | Primary artifacts | TTFC | UIstall |
|--------|----------|----------|-------------------|------|---------|
| `vocello bench` | macOS CLI | In-process | `engine/generations.jsonl`, `outputs/bench/*.wav` | — | — |
| macOS app + XCUITest | macOS | XPC service | engine + engine-service + app rows, merged | yes | yes |
| `macos_test.sh profile` | macOS | In-process (traced) | `.trace` + diagnostics | partial | — |
| `ios_device.sh bench` | iOS device | In-process | pulled diagnostics + `autorun-done.json` | app row | yes |

Analysis pipeline: `summarize_generation_telemetry.py` → tables / `--ledger-row` → `benchmarks/HISTORY.md`.

---

## 2. Live run evidence

**Command:**

```sh
QWENVOICE_DEBUG=1 ./build/vocello bench \
  --modes custom,design,clone --variants speed \
  --lengths short,medium --warm 1 \
  --label "benchmarking-procedure-audit" --ledger --force
```

| Metric | Result |
|--------|--------|
| **Verdict** | **PASS** — 8 takes in 59s |
| **QC** | 8/8 pass |
| **Tier** | `floor_8gb_mac` (native) |
| **Log** | `build/macos/benchmarking-procedure-audit-bench.log` |
| **Ledger** | Row appended to `benchmarks/HISTORY.md` (`custom/pro_custom_speed/warm/medium` RTF 0.97) |

**Sample headline (custom warm medium):** RTF 0.97 · tok/s 12.11 · physFoot 2525 MB · QC pass.

**Decode pattern (confirms lazy-MLX caveat):** `stepEval` 59% of decode ms; `code2wav` 59 ms total (pipelined); Mimi ~5 ms/frame.

**Not captured:** Instruments trace (`build/macos/profile-*.trace` absent); n=1 per cell (low statistical confidence).

---

## 3. Delta vs 2026-06-15 harness review

| Prior item | Status (2026-06-29) |
|------------|---------------------|
| P0.1 iOS process model doc | **Fixed** |
| P0.2 thermalState in telemetry | **Fixed** — `TelemetrySummary` + record; **not in summarizer** |
| P0.3 gpuWorkingSetUsageRatioPeak | **Fixed** in sampler; **not in summarizer** |
| P0.4 memory limit env doc | **Fixed** |
| R1/R2 sub-ms clock / sequence | **Fixed** — schema v5 `NativeTelemetryClock`, `sequence` on marks |
| P1.3 chunkTimeline in summarizer | **Fixed** — chunk + Mimi breakdown tables |
| P1.3 variance / outliers | **Partial** — `--show-variance`, IQR in code; not default |
| P1.6 `--compare-baseline` | **Fixed** |
| P1.1 GPU eval split | **Open** |
| P1.2 KV-cache footprint | **Fixed 2026-07-01** — `derivedMetrics.kvCacheEstimatedPeakMB` (peak of per-chunk KV diagnostics) |
| J1 crash mid-generation row loss | **Open** |
| Q1 audioQC defect localization | **Fixed** in v5 |
| P6 summarizer stream-only | **Partial** — `iter_jsonl` for engine; still materializes `runs[]` |
| Typed metadata (P2.3) | **Open** — still `[String: String]`; doc drift |

---

## 4. Axiom findings (consolidated)

### P0 — address before long-matrix / release confidence

| ID | Domain | Finding | Status |
|----|--------|---------|--------|
| P0-1 | Performance | RTF (`audioSecondsPerWallSecond`) and decode ms (`qwen_token_loop_total`) use incompatible lazy-MLX time bases | **Fixed** — aligned on `qwen_token_loop_total`; documented §7 `telemetry-and-benchmarking.md` |
| P0-2 | Performance | `vocello bench` always enables telemetry — no `--telemetry off` control run | **Fixed** — `--telemetry off` |
| P0-3 | Performance | `generateTime` / stage marks exclude pipelined decoder drain | **Fixed** — `decoderDrainMS` + stage mark |
| P0-4 | Concurrency | Default streaming bench never drains unbounded `engine.events`; preview PCM retained per chunk | **Fixed** — preview off + event drain |
| P0-5 | Testing | Engine bench absent from CI and `macos_test.sh gate` | **Partial** — opt-in `QWENVOICE_GATE_BENCH=1`; since 2026-07-01 also regression-compares vs committed `benchmarks/baselines/mac-gate-bench.json` |
| P0-6 | Testing | CI macOS smoke skips generation tests (no `QVOICE_REQUIRE_TEST_MODELS`) | **Open** — blocked on macOS 26 CI runners |
| P0-7 | Codable | Failed/superseded runs pollute cell medians (no `finishReason` filter) | **Fixed** — summarizer filter |

### P1 — important

| ID | Domain | Finding | Status |
|----|--------|---------|--------|
| P1-1 | Performance | `--ledger` runs summarizer twice | **Fixed** — `--emit-ledger-row` single pass |
| P1-2 | Performance | Verbose mode double-runs PCM limiter per chunk | **Open** |
| P1-3 | Performance | Preview PCM not disabled in bench | **Fixed** (same as P0-4) |
| P1-4 | Memory | `timeToPeakMS` tracks RSS not physFootprint peak | **Fixed 2026-07-01** — physFoot peak, RSS fallback |
| P1-5 | Memory | Floor-tier 500 ms sampler cadence misses short spikes | **Open** |
| P1-6 | Memory | `IOSMemoryPressureBand` not persisted on engine rows | **Fixed 2026-07-01** — `notes.memoryPressureBandWorst` from sampler extremes |
| P1-7 | Codable | Swift merger strict vs Python lenient — silent row drops | **Fixed 2026-07-01** — decode failures on matching rows logged loudly |
| P1-8 | Security | Ungated `generation-failures.jsonl` on all failures | **Fixed** — `TelemetryGate.resolvedEnabled` |
| P1-9 | Security | Ungated `native-events.jsonl` on macOS XPC | **Fixed** — gated in engine-service + iOS writer |
| P1-10 | Testing | BenchCommand silently skips clone when voice missing | **Fixed** — fail fast |
| P1-11 | Testing | Fixture Speed-only vs default Quality variant mismatch | **Open** |
| P1-12 | Testing | `macos_test.sh profile` ignores bench non-zero exit | **Fixed** — fail unless opt-out |

### P2 — polish / long-term

| ID | Domain | Finding |
|----|--------|---------|
| P2-1 | Performance | Summarizer materializes full `runs[]` — memory at scale |
| P2-2 | Codable | v5 ns fields written but not analyzed in Python |
| P2-3 | Security | Voice brief/delivery in telemetry `notes` when debug on |
| P2-4 | Profiler | No signpost trace in standard audit lane — GPU attribution manual |
| P2-5 | Testing | iOS gate excludes bench; device model install advisory only |

---

## 5. Documentation gaps (before this audit)

| Gap | Remediation |
|-----|-------------|
| No single operator runbook | **Added** `benchmarking-procedure.md` |
| Platform topology (CLI vs XPC vs iOS) scattered | **Documented** §2 of runbook |
| Clone warm-only rule easy to misread | **Documented** §5 runbook |
| Release QA step 3 missing `models ensure` + voice name | **Documented** §4.1; update `macos-release-qa.md` cross-link |
| Harness review stale vs v5 | **Delta table** §3 this report |
| Signpost validation not in standard procedure | **Documented** §4.8 runbook |

**Remaining doc debt:** Summarizer should document which v5 fields it consumes; `telemetry-and-benchmarking.md` typed-metadata claim vs code.

---

## 6. Process gaps

1. **No CI bench** — `.github/workflows/release.yml` explicitly excludes benchmarks; engine regressions merge on compile + fake UI only.
2. **CLI vs XPC divergence** — release QA uses CLI; production macOS uses XPC — TTFC/UIstall/XPC transport not in default bench.
3. **Manual listening pass** — no automation; correct by design but easy to skip under time pressure.
4. **No auto-regression compare gate** — `--compare-baseline` exists but is opt-in; HISTORY is append-only prose.
5. **iOS friction** — device-only, no Mac-side model ensure; gate doesn't run bench.
6. **Prosody/delivery underused** — scripts exist; not in default release net.
7. **n=1 audit runs** — `--warm 1` fast but weak variance signal; release QA specifies `--warm 3`.

---

## 7. Recommended remediation

### Quick wins (docs + scripts, no engine change)

1. Update `macos-release-qa.md` step 3: `models ensure` + `--voice A_warm_elderly_woman`.
2. Wire CI macOS smoke through `scripts/macos_test.sh test` (not bare xcodebuild).
3. `BenchCommand.run`: `setenv("QWENVOICE_STREAMING_PREVIEW_DATA", "off", 1)` + drain `engine.events` per take.
4. Gate cross-link: "If Sources/ changed, run release QA bench (see benchmarking-procedure.md §4.1)."
5. Document `--compare-baseline` in release checklist template.

### Medium (harness + summarizer)

1. Add `--telemetry off` bench mode for control runs.
2. Filter summarizer to successful `finishReason` values only.
3. Export `thermalWorst`, `gpuWsRatioPeak`, `headMinMB` columns in summarizer.
4. Fail `macos_test.sh profile` when bench returns non-zero (opt-out flag).
5. BenchCommand: fail when clone requested but voice missing (align with fixture).
6. Merge ledger into single summarizer invocation.
7. Gate or redact `generation-failures.jsonl` and ungated `native-events.jsonl`.

### Long-term

1. Self-hosted macOS CI job: bounded bench (`custom/speed/medium/warm 1`) + audioQC fail exit code.
2. Optional XPC bench wrapper or documented TTFC gap acceptance criteria.
3. Partial-row flush on crash; thermal/GPU ratio in regression compare thresholds.
4. Shared length-bucket config (Swift + Python) to eliminate drift.

---

## 8. Fix list

Priority order from the audit; implementation status:

| # | Item | Status |
|---|------|--------|
| 1 | P0-4 — event drain + preview-off in `BenchCommand` | **Fixed** |
| 2 | P0-7 — summarizer `finishReason` filter | **Fixed** |
| 3 | P1-8/P1-9 — gate failure/native-event writers | **Fixed** |
| 4 | P1-10 — strict clone fixture in bench preflight | **Fixed** |
| 5 | P0-2 — `--telemetry off` mode | **Fixed** |
| 6 | P0-3 — decoder drain in stage marks / timings | **Fixed** |
| 7 | P0-5 — opt-in gate bench (`QWENVOICE_GATE_BENCH=1`) | **Fixed** |
| 8 | Summarizer v5 env columns (thermal, GPU WS ratio) | **Fixed** |
| 9 | P1-1 — single summarizer pass for `--ledger` | **Fixed** |
| 10 | P1-12 — profile fails on bench non-zero | **Fixed** |

---

## 9. Axiom agents invoked

| Agent | Focus | Key outcome |
|-------|-------|-------------|
| swift-performance-analyzer | Bench + telemetry hot path | BOTTLENECKED — KPI ambiguity, always-on telemetry |
| memory-auditor | Sampler + peaks | NEEDS ATTENTION — peak timing, summarizer gaps |
| concurrency-auditor | Bench streaming path | NOT READY — unbounded events |
| codable-auditor | JSONL schema | HARDENING NEEDED — failed runs in medians |
| security-privacy-scanner | Diagnostics writers | NOT READY — ungated failure logs |
| testing-auditor | Fixtures + CI | GAPS — no bench in gate/CI |
| performance-profiler | Trace + bench log | Lazy MLX caveat confirmed; signposts needed |

---

## 10. References

- New runbook: [`docs/reference/benchmarking-procedure.md`](../docs/reference/benchmarking-procedure.md)
- Prior review: [`docs/reference/telemetry-harness-review.md`](../docs/reference/telemetry-harness-review.md)
- Ledger: [`benchmarks/HISTORY.md`](HISTORY.md)
