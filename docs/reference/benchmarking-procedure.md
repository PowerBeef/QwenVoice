# Benchmarking procedure — operator runbook

Step-by-step guide for running Vocello performance and quality benchmarks on **macOS**
(CLI and app/XPC) and **iOS** (on-device autorun). This document covers **when** to bench,
**how** to drive each platform path, **what** artifacts to expect, and **how** to read results.

For telemetry schema, record fields, and MLX timing semantics, see
[`telemetry-and-benchmarking.md`](telemetry-and-benchmarking.md). For CLI flags, see
[`cli.md`](cli.md) §bench.

If anything here disagrees with the code, the code wins — fix this file.

---

## 1. Purpose and principles

### When to run a benchmark

Run a benchmark when you change anything that can affect **decode throughput**, **memory
peaks**, **first-chunk latency**, or **audio quality**:

- MLX / vendored Qwen3-TTS or Mimi codec
- Memory policy, streaming interval, idle-unload, XPC lifecycle
- Model load path, prewarm, clone conditioning
- Before merging engine-adjacent work or cutting a macOS/iOS release

### What “good” means

A benchmark pass requires **all** of the following:

| Gate | Criterion |
|------|-----------|
| **audioQC** | No `fail` in any cell (`pass` or `warn` only). Any `fail` blocks promotion. |
| **RTF** | `derivedMetrics.audioSecondsPerWallSecond` within noise of the latest [`benchmarks/HISTORY.md`](../../benchmarks/HISTORY.md) row for the headline cell (same tier, same variant). |
| **Memory** | No rising `physFoot` peak or non-zero `hardTrim` in `trims` on floor-tier runs. |
| **Listening pass** | Mandatory human ear check for engine changes — automated QC is a tripwire, not a substitute. |

**RTF > 1** means faster than realtime (more audio seconds produced per wall second).

### Design constraints

1. **Primary backend driver is headless** — `vocello bench` drives the matrix in-process with exact
   cold/warm control. **`scripts/macos_test.sh bench-ui`** is the supplementary XPC integration net (§4.10).
2. **Telemetry is runtime-gated** — identical code in Release; off unless debug env/toggle/handshake.
3. **No CI auto-gate today** — benchmarks are local/release-lane only (see §9).
4. **Lazy MLX caveat** — decode breakdown columns measure Swift wall-clock around lazy graph
   ops, not per-stage GPU compute. Use Instruments signposts for GPU attribution (§6.3).

---

## 2. Platform topology

Three hosts write telemetry; only some layers exist per path:

```text
                    CLI (vocello bench)     macOS app + XPC        iOS app (in-process)
                    ───────────────────     ───────────────        ────────────────────
Engine row          yes                     yes                    yes
Engine-service row  no                      yes (XPC transport)    no
App row             no                      yes (UI timings)       yes (UI timings)
Merged row          no (CLI)                yes (macOS merger)     partial
TTFC column         — (no app process)      yes (submit→chunk)     yes
UIstall column      —                       yes                    yes
```

| Path | Driver | Engine topology | Best for |
|------|--------|-----------------|----------|
| **CLI** | `./build/vocello bench` | In-process `MLXTTSEngine` | Deterministic RTF/decode/memory matrix; release QA step 3 |
| **macOS UI** | App + `QwenVoiceEngineService` XPC | Out-of-process engine | End-to-end TTFC, UI stall, XPC transport; UI smoke tests |
| **macOS XPC UI bench** | `scripts/macos_test.sh bench-ui` | Out-of-process engine | Full release matrix through real app + XPC; merged 3-layer telemetry |
| **macOS profile** | `scripts/macos_test.sh profile` | In-process via CLI inside trace | Instruments / os_signpost validation |
| **iOS device** | `scripts/ios_device.sh bench` | In-process | iPhone tier, Jetsam, on-device RTF (headless autorun, single take) |
| **iOS UI bench** | `scripts/ios_device.sh bench-ui` | In-process | Full release matrix through the real Studio UI on the iPhone (XCUITest); gate `scripts/check_ios_ui_bench.py` |

**Important:** CLI bench numbers are **not** identical to macOS XPC UI numbers. Compare like with
like (CLI vs CLI, UI vs UI). Use CLI for backend optimization; use UI/XPC for integration regressions.

---

## 3. Preflight checklist

Run before any benchmark session:

### Build and CLI

```sh
./scripts/build.sh cli          # produces build/vocello
./scripts/check_project_inputs.sh
```

### Models and clone fixture (macOS)

```sh
scripts/macos_test.sh models ensure
```

This installs (or symlinks into debug context):

- `pro_custom_speed`, `pro_design_speed`, `pro_clone_speed` (~6.9 GB one-time if none installed)
- Clone voice `A_warm_elderly_woman` (reference clip + enrollment via `vocello`)

Set `QVOICE_REQUIRE_TEST_MODELS=1` is automatic on script paths; bare `xcodebuild` may skip tests.

### Environment hygiene

| Check | Action |
|-------|--------|
| Quiet machine | Quit heavy apps; watch thermals (see §6.4). |
| Single Vocello session | `pkill -x Vocello; pkill -x QwenVoiceEngineService` before UI benches. |
| Debug data dir | `QWENVOICE_DEBUG=1` → `~/Library/Application Support/QwenVoice-Debug/` |
| Floor-tier simulation | `QWENVOICE_FORCE_MEMORY_CLASS=floor_8gb_mac` (propagates to engine via handshake) |
| Suppress proactive warm | `QWENVOICE_SUPPRESS_WARMUP=1` for accurate Custom/Design **cold** rows in UI runs |

### iOS device

- Paired physical iPhone (never Simulator for real engine)
- Speed models verified: `scripts/ios_device.sh models check --strict` (headless inventory)
- `scripts/ios_device.sh preflight` before bench/gate; optional `--strict-models`
- Agent + MCP playbook: [`ios-device-testing.md` § Agent + MCP workflow](ios-device-testing.md#agent--mcp-workflow)

---

## 4. Standard workflows

### 4.1 Release QA engine net (macOS)

From [`macos-release-qa.md`](macos-release-qa.md) step 3 — run when `Sources/` engine code changed:

```sh
scripts/macos_test.sh models ensure

QWENVOICE_DEBUG=1 ./build/vocello bench \
  --modes custom,design,clone \
  --variants speed \
  --lengths short,medium,long \
  --warm 3 \
  --voice A_warm_elderly_woman \
  --label "release-QA" \
  --ledger
```

Gate: all cells `QC=pass` (or documented `warn` with listening pass); RTF within noise of
`HISTORY.md`; **listening pass by ear**.

### 4.2 Quick multi-mode smoke (Speed, short matrix)

```sh
QWENVOICE_DEBUG=1 ./build/vocello bench \
  --modes custom,design,clone \
  --variants speed \
  --lengths short,medium \
  --warm 1 \
  --label "my-change" \
  --ledger \
  --force
```

`--force` clears diagnostics before run (default without `--keep`).

### 4.3 Full 6-cell matrix (Speed + Quality)

Default CLI includes both variants; fixture installs **Speed only**:

```sh
# Option A: Speed only (matches models ensure)
QWENVOICE_DEBUG=1 ./build/vocello bench \
  --variants speed --lengths short,medium,long --warm 3 --label "speed-matrix"

# Option B: include Quality — ensure Quality weights installed first (~12–18 GB peak disk)
QWENVOICE_DEBUG=1 ./build/vocello bench \
  --variants speed,quality --lengths short,medium,long --warm 3 --label "full-matrix"
```

**Clone is warm-only by design** — no cold clone cell; rows always show `warmState=warm`.

### 4.4 Floor-tier forced run

Exercise constrained-tier code paths on any Mac:

```sh
QWENVOICE_DEBUG=1 \
  QWENVOICE_FORCE_MEMORY_CLASS=floor_8gb_mac \
  QWENVOICE_SUPPRESS_WARMUP=1 \
  ./build/vocello bench \
  --modes custom --variants speed --lengths medium --warm 3 \
  --label "floor-tier" --ledger
```

Summarizer header shows `tier: floor_8gb_mac ⚠ forced`.

### 4.5 Memory-pressure exercise

While a generation is running on forced floor tier:

```sh
sudo memory_pressure -S -l warn    # or: -S -l critical
```

Then summarize and confirm non-zero `trims` / `memory_pressure` stage marks.

### 4.6 Delivery / prosody cells

```sh
QWENVOICE_DEBUG=1 ./build/vocello bench \
  --modes custom,design \
  --variants speed \
  --lengths medium \
  --warm 1 \
  --delivery happy,calm,whisper \
  --prosody-profile path/to/profile.json \
  --label "delivery-audit"
```

Adds instruct-bearing warm takes; summarizer prints a delivery block with prosody deltas.

### 4.7 iOS on-device bench

```sh
scripts/ios_device.sh bench custom:speed: \
  --label "ios-device-bench"
```

Optional restriction simulation:

```sh
scripts/ios_device.sh bench --sim-device iphone15pro custom:speed:
```

Pulls diagnostics from device; runs summarizer; exits non-zero if autorun status ≠ ok.

### 4.7b iOS UI benchmark (Studio matrix — XCUITest, unattended)

Same matrix semantics as macOS `bench-ui` (29 takes default). Step-by-step:
[`testing-runbook.md` §3b](testing-runbook.md#3b-ui-driven-benchmark-lanes--step-by-step-any-agent-can-run-these).

```sh
scripts/ios_device.sh device-state
scripts/ios_device.sh models check --strict
scripts/ios_device.sh bench-ui --warm 1 --lengths medium --modes custom --label ios-bench-smoke
scripts/ios_device.sh bench-ui --label ios-bench-full
```

Requires phone **unlocked once** for XCUITest automation handshake. Do **not** touch the phone or mirroir-tap during the run.

Optional trace during matrix (single in-process attach):

```sh
scripts/ios_device.sh bench-ui --profile --profile-template "Time Profiler" --label ios-profile
```

Artifacts: `build/ios/bench-ui-<timestamp>/` (log, gate.log, optional `vocello.trace`).
Post-run gate: `python3 scripts/check_ios_ui_bench.py build/ios-diagnostics --run-id …`.

### 4.7c iOS UI benchmark (deprecated agent lanes — historical)

> **Retired 2026-07.** Full matrix = XCUITest `bench-ui` only (§4.7b). Agent smokes use
> mirroir + `measure-*`. Historical `bench-ui-mirroir` procedure:
> [`computer-use-mcp-pilot-log.md`](computer-use-mcp-pilot-log.md) §Archived agent bench.

| iOS UI bench lane | Driver | When |
| --- | --- | --- |
| **`bench-ui`** | XCUITest | **Only** supported full matrix lane |
| **`bench-ui-mirroir --agent-drive`** | mirroir native | **Deprecated** — retired 2026-07 |
| **`bench-ui-mcp --agent-drive`** | mobile-mcp WDA | Deferred (signing) |
| **`bench-ui-vision --agent-drive`** | Peekaboo coords | Deprecated |

**iOS engine RTF without UI friction:** use headless §4.7 (`ios_device.sh bench`), not UI bench lanes.

| Phase | Tool |
|-------|------|
| Trace capture | `bench-ui --profile` / `profile` lane |
| Trace analysis | `axiom_xcprof_analyze` / `performance-profiler` |
| Test failure | `axiom_get_agent` → `test-runner` on `build/ios/Logs/Test/*.xcresult` |
| Crash post-mortem | `axiom_xcsym_crash` on `build/ios-diagnostics/**/crashes/` |

Full MCP routing: [`ios-device-testing.md` § Agent + MCP workflow](ios-device-testing.md#agent--mcp-workflow).

### 4.8 macOS Instruments profile (signpost validation)

```sh
QVOICE_MAC_PROFILE_TEMPLATE=os_signpost \
QVOICE_MAC_PROFILE_DURATION=120 \
scripts/macos_test.sh profile custom:speed:
```

Produces `build/macos/profile-<timestamp>.trace`. **In-process only** — not the production XPC path.
The lane **fails** when `vocello bench` exits non-zero unless you pass `--allow-bench-fail` or set
`QVOICE_MAC_PROFILE_ALLOW_BENCH_FAIL=1` (useful when you only need the trace artifact).
For XPC: attach `xctrace` to `QwenVoiceEngineService` while generating via UI.

### 4.9 UI-driven generation (macOS XPC)

Real generation through the macOS frontend is driven only by the repository Codex Computer Use
skill. Deterministic completion comes from the session harness and typed XPC/backend probes:

```sh
scripts/macos_test.sh models ensure
scripts/macos_agent_ui.sh impact
# Invoke $vocello-macos-ui-qa quick or full.
scripts/macos_test.sh ui-report --suite full
```

This validates semantic frontend behavior plus the matching History/WAV/XPC/backend state. It is
not the primary RTF matrix driver.

### 4.10 macOS XPC UI benchmark (supplementary integration net)

**Primary backend regression remains `vocello bench` (§4.1).** The supplementary UI matrix is
driven by `$vocello-macos-ui-qa benchmark` through the real app + XPC service. The shell harness
owns the take definitions, timestamps, typed telemetry validation, and aggregation.

Telemetry rows stamp `notes.benchRunID`, `benchTakeIndex`, `benchCell`, and `benchWarmState` when
`QVOICE_MAC_BENCH_RUN_ID` is set. Completion requires `verify-generation`, `verify-history`, and
`verify-probes`; there are no hidden UI-test flush markers. Gate with the run ID:

```sh
python3 scripts/check_macos_xpc_bench.py ~/Library/Application\ Support/QwenVoice-Debug/diagnostics \
  --run-id mac-ui-benchmark-YYYYMMDD-HHMMSS
```

**One-time machine setup:** grant Codex Computer Use Accessibility and Screen Recording, build
`build/Vocello.app`, and install models. TCC enrollment stays attended.

```sh
scripts/macos_agent_ui.sh doctor --suite benchmark --json
```

See [`macos-testing.md`](macos-testing.md) § Prerequisites.

**Full matrix:**

```text
$vocello-macos-ui-qa benchmark
```

The skill obtains the canonical matrix from `scripts/macos_agent_ui.sh benchmark-manifest` and
wraps every UI-driven generation with ordered `benchmark-take --phase begin|complete` calls.
Cold Custom and Design cells are exact-path relaunches; a cell cannot complete without its
matching deterministic History/WAV assertion.

Then validate the report and matrix:

```sh
scripts/macos_test.sh bench-ui --report <run-id-or-directory>
```

Artifacts live under `build/macos/agent-ui/<run-id>/`; the tracked attestation contains only
fingerprints, verdicts, issue counts, evidence digest, and cleanup result.

The benchmark attestation is independent: it never satisfies a required full semantic report.
Likewise, full never satisfies benchmark. For telemetry/backend changes, run the seeded overhead
parity lane before attesting the UI matrix:

```sh
scripts/macos_test.sh telemetry-overhead
```

This uses `vocello bench --seed` with one warm-up and five measured warm takes per telemetry mode,
requires identical PCM, and gates median RTF/TTFC at 5% (lightweight) and 10% (verbose) versus off.

Post-run gate:

```sh
python3 scripts/check_macos_xpc_bench.py ~/Library/Application\ Support/QwenVoice-Debug/diagnostics \
  --run-id <run-id>
```

| Phase | Tool |
|-------|------|
| Trace capture | `xctrace record --attach QwenVoiceEngineService` during a benchmark scenario |
| Trace analysis | Instruments/xctrace plus the relevant installed macOS performance skill |
| Logs / warm-admission | `scripts/macos_test.sh logs` and unified-log inspection |
| Crash post-mortem | `scripts/macos_test.sh crashes`, dSYMs, and standard symbolication |

Cold takes: app relaunch + `QWENVOICE_SUPPRESS_WARMUP=1` + `QWENVOICE_BENCH_FORCE_COLD=1`
(debug-only unload before generate). Warm takes stay in-session.

---

## 5. Matrix semantics

### Fixed corpus

Defined in `BenchMatrixSpec` (`Sources/QwenVoiceCore/BenchMatrixSpec.swift`; shared with
`BenchCommand` and XPC UI bench) — do not change without updating baselines:

| Bucket | Chars (approx) | Text role |
|--------|----------------|-----------|
| short | < 70 | One sentence |
| medium | 70–220 | Two sentences |
| long | > 220 | Extended narration |

`lenBucket()` in Swift and Python must agree (bench fails on corpus drift).

### Mode payloads

| Mode | Payload |
|------|---------|
| Custom Voice | Default speaker + optional delivery |
| Voice Design | Fixed brief: *"A warm, calm middle-aged male narrator with a clear, measured pace."* |
| Voice Cloning | Saved voice `A_warm_elderly_woman` (or `--voice`) |

### Cold vs warm

| Mode | Cold sample | Warm samples |
|------|-------------|--------------|
| Custom | 1× (after `unloadModel`) | `--warm` × each length |
| Design | 1× | `--warm` × each length |
| Clone | **none** (warm-by-design) | `--warm` × each length |

CLI forces cold via explicit unload before cold take. UI cold uses app relaunch +
`QWENVOICE_SUPPRESS_WARMUP=1` + `QWENVOICE_BENCH_FORCE_COLD=1` (see §4.10).

### Streaming default

`vocello bench` streams by default (`--no-stream` for legacy quality-first accumulation).
Streaming populates `chunkTimeline`; non-streaming leaves it empty.

---

## 6. Reading results

### 6.1 Summarizer invocation

```sh
python3 scripts/summarize_generation_telemetry.py [DIAGNOSTICS_DIR] [--label NOTE]
```

Default dir: `~/Library/Application Support/QwenVoice-Debug/diagnostics`

Useful flags:

| Flag | Purpose |
|------|---------|
| `--show-variance` | IQR / outlier hints per cell |
| `--merged` | Cross-layer first-chunk table from `generations-merged.jsonl` |
| `--save-baseline PATH` | Write the current per-cell summary as a **JSON** baseline |
| `--compare-baseline PATH` | Regression compare vs a **JSON** baseline from `--save-baseline` (exit 2 on >5% regression; RTF **drop**, tok/s drop, TTFC/physFoot rise, QC worsening). Markdown snapshots cannot be fed to this flag — diff those with `git diff`. |
| `--ledger-row` | One HISTORY.md row (pipe to `>> benchmarks/HISTORY.md`) |
| `--cell mode/model/state[/len]` | Headline cell for ledger (default `custom/quality/warm`) |

### 6.2 Headline table columns

| Column | Source | Notes |
|--------|--------|-------|
| RTF | `derivedMetrics.audioSecondsPerWallSecond` | Primary throughput KPI |
| tok/s | Codec tokens / decode wall | Compare across variants |
| TTFC ms | App row `submitToFirstChunkMS` | `-` for CLI (no app process) |
| peakGPU / physFoot | Sampler peaks | physFoot = Jetsam-relevant on iOS |
| trims | `memory_trim` stage marks | Floor/mid/iPhone tiers |
| UIstall | App row stall counters | `-` for CLI |
| QC | `audioQC.verdict` + flags | `fail` = hard stop |

### 6.3 Decode breakdown (lazy MLX)

**RTF vs decode ms:** Both now prefer `qwen_token_loop_total` for wall time when present. See
[`telemetry-and-benchmarking.md`](telemetry-and-benchmarking.md) §7 (RTF vs decode ms).

Columns: `talker · sampCB0 · codePred · code2wav · stepEval · other`

- **stepEval** ≈ fused per-frame `eval()` (Talker + CodePredictor + sampling) — best compute proxy in JSONL
- **talker / codePred** ≈ graph **build** time, not GPU kernels
- **code2wav ≈ 0** — decoder is `asyncEval`'d and overlaps the token loop

Validate with Instruments signposts: **Step Eval Flush**, **Code Predictor Loop**, **Talker Forward**, **Audio Decoder**.

### 6.4 Chunk timeline block

When streaming, summarizer prints per-cell medians: chunk count, first-chunk ms, inter-chunk ms,
substage ms. Use for cold-start vs steady-state analysis.

### 6.5 Thermal and environment

Summarizer prints **thermal** (worst state in cell), **gpuWS** (`gpuWorkingSetUsageRatioPeak`),
and **headMin** (`headroomMinMB`) when the sampler collected them. Re-run if thermal throttling
suspected; inspect raw JSONL for full `thermalState` start/end/worst.

---

## 7. Tracking performance over time

### HISTORY.md ledger

```sh
python3 scripts/summarize_generation_telemetry.py --ledger-row --label "what changed" \
  >> benchmarks/HISTORY.md
```

Or use `vocello bench --ledger` — one summarizer invocation (`--emit-ledger-row` internally)
that prints the table and appends one row to `benchmarks/HISTORY.md`.

### Milestone snapshots

```sh
python3 scripts/summarize_generation_telemetry.py --label "stepeval fix" \
  > benchmarks/2026-06-29-stepeval.md
```

Compare with `git diff`. No auto-fail gate — maintainer judgment.

### Baseline comparison (JSON, machine-gated)

```sh
# Seed / reseed a baseline (after an intentional, reviewed perf change):
python3 scripts/summarize_generation_telemetry.py <diag-dir> \
  --save-baseline benchmarks/baselines/mac-gate-bench.json

# Compare (exit 2 on regression — usable in scripts/gates):
python3 scripts/summarize_generation_telemetry.py <diag-dir> \
  --compare-baseline benchmarks/baselines/mac-gate-bench.json
```

The committed **`benchmarks/baselines/mac-gate-bench.json`** (custom/speed/medium,
cold+warm) is what `QWENVOICE_GATE_BENCH=1 scripts/macos_test.sh gate` compares against —
the gate isolates its own run's rows by `recordedAt` before comparing. Markdown snapshots
(`benchmarks/baseline-*.md`) remain the human-readable full-matrix references; diff them
with `git diff`, not `--compare-baseline`.

### Like-for-like comparison rules (ledger discipline)

Never compare numbers across topologies — each is a different measurement, not a
regression signal:

| Lane | Build | Topology | Headline custom/speed/medium warm |
|------|-------|----------|-----------------------------------|
| `build.sh` CLI bench | `-Onone` | in-process | RTF ≈ 1.0 |
| local release / `-O` CLI | optimized | in-process | RTF ≈ 1.7 |
| macOS `bench-ui` | Release app | app + XPC service | RTF ≈ 1.7 |
| iOS `ios_device.sh bench` | `-Onone` device | in-process on iPhone | RTF ≈ 1.6–1.9 |
| iOS `ios_device.sh bench-ui` | `-Onone` device | in-process, real Studio UI | same engine numbers as `bench` (same build flags); adds UI-path coverage |

Compare a row only against a baseline from the **same lane** (HISTORY.md rows carry the
label; keep the lane in the label text).

---

## 8. Quality gates

### Layer 1 — audioQC (automatic, every run)

Engine runs reference-free PCM analysis: `nonfinite`, `clipping`, `clicks`, `dropout`, `near_silent`.
Punctuation-aware pause budget avoids false positives on natural delivery.

### Layer 2 — Prosody scripts (optional)

`scripts/prosody_quality_gate.py`, `scripts/delivery_adherence.py` on bench WAVs when using `--delivery`.

### Layer 2.5 — Language hint contract (Phase 2)

Headless matrix (`scripts/ios_device.sh lang-bench` or `scripts/macos_test.sh lang-bench`)
stamps `notes.languageHint` (resolved Qwen3 token, not raw UI picker). Gate with
`scripts/check_language_hints.py` against `config/language-bench-matrix.json`.
Offline fixture self-test: `python3 scripts/test_check_language_hints.py`.

### Layer 2.6 — Output language + WER (Phase 3, iOS autorun)

When `QVOICE_IOS_VERIFY_OUTPUT=1`, the app transcribes each bench WAV in-process (Speech)
and stamps `outputVerification` on `autorun-done.json`. Gate with
`scripts/check_language_output.py`. Requires Speech Recognition permission on the phone once.
Skip with `QVOICE_LANG_BENCH_SKIP_OUTPUT=1`. See [`language-bench.md`](language-bench.md).

### Layer 3 — Listening pass (mandatory pre-merge for engine)

Play takes; judge timbre, prosody, artifacts. Record verdict in snapshot note or HISTORY.md.

---

## 9. Artifact map

### On disk (gitignored)

| Path | Contents |
|------|----------|
| `~/Library/Application Support/QwenVoice-Debug/diagnostics/engine/generations.jsonl` | Richest backend rows |
| `.../engine-service/generations.jsonl` | XPC transport (macOS app path) |
| `.../app/generations.jsonl` | UI timings |
| `.../generations-merged.jsonl` | Joined layers (macOS) |
| `.../engine/samples-<UUID>.jsonl` | Verbose per-sample series |
| `QwenVoice-Debug/outputs/bench/*.wav` | Bench WAV outputs |

Auto-pruned: `generations.jsonl` ~8 MB cap; verbose sidecars newest-48 / 64 MB.

### Committed (bounded)

| Path | Rule |
|------|------|
| `benchmarks/HISTORY.md` | Compact ledger rows |
| `benchmarks/baseline-*.md` | Full summarizer snapshots ≤ 256 KB each |
| `benchmarks/*-audit-*.md` | Audit reports |

**Never commit raw `*.jsonl`** under `benchmarks/` (guard-enforced).

### CI / automation

- `.github/workflows/ci.yml` — `ios-compile-check` (compile-only; no XCUITest, no bench)
- `.github/workflows/release.yml` — packaging; **no bench**
- Pre-merge: `scripts/macos_test.sh gate` — UI smoke + models; **no bench**

Engine regression net remains **manual local** until a self-hosted macOS bench job exists.

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Custom/Design "cold" shows `warm` | Proactive warmup ran | `QWENVOICE_SUPPRESS_WARMUP=1` for UI; CLI unloads explicitly |
| Clone missing from matrix | No enrolled voice | `scripts/macos_test.sh models ensure` |
| `preflightModels` fails Quality | Speed-only fixture | Install Quality weights or use `--variants speed` |
| Summarizer empty | Wrong diagnostics dir / gate off | Confirm `QWENVOICE_DEBUG=1`; check `engine/generations.jsonl` |
| RTF vs decode ms disagree | Different time bases + lazy MLX | Read §6.3; use signpost trace |
| All QC warn:dropout on long | Often natural pauses | Listening pass; check punctuation-aware budget |
| iOS bench timeout | Model missing / autorun stuck | `scripts/ios_device.sh console`; install Speed model |
| Clone cold row appears | Summarizer labels first clone take | Clone is warm-by-design; ignore cold label if present |

---

## 11. Related documents

| Doc | Role |
|-----|------|
| [`telemetry-and-benchmarking.md`](telemetry-and-benchmarking.md) | Schema, knobs, telemetry architecture |
| [`cli.md`](cli.md) | Full `vocello bench` flag reference |
| [`macos-release-qa.md`](macos-release-qa.md) | Release gate sequence |
| [`macos-testing.md`](macos-testing.md) | UI test / profile / gate lanes |
| [`ios-device-testing.md`](ios-device-testing.md) | iOS bench, gate, device lanes |
| [`telemetry-harness-review.md`](telemetry-harness-review.md) | 2026-06-15 harness technical review |
| [`benchmarks/OPTIMIZATION.md`](../../benchmarks/OPTIMIZATION.md) | Optimization program status |
| [`benchmarks/HISTORY.md`](../../benchmarks/HISTORY.md) | Performance ledger |
| [`benchmarks/benchmarking-procedure-audit-2026-06-29.md`](../../benchmarks/benchmarking-procedure-audit-2026-06-29.md) | 2026-06-29 procedure audit |
