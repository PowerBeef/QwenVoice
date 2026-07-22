# Benchmarking procedure — operator runbook

Step-by-step guide for running Vocello performance and quality benchmarks on **macOS**
(CLI and app/XPC) and **iOS** (physical-device UI and headless diagnostics). This document covers **when** to bench,
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

- MLX / owned Qwen3-TTS core runtime or Mimi codec
- Memory policy, streaming interval, idle-unload, XPC lifecycle
- Model load path, prewarm, clone conditioning
- Before explicitly promoting engine-adjacent work or cutting a macOS/iOS release

Benchmarks that require models or a device are not prerequisites for a
commit, push, pull request, ordinary merge, ordinary CI run, or release package. They remain useful
promotion and release-QA evidence when explicitly requested.

### What “good” means

A benchmark pass requires **all** of the following:

| Gate | Criterion |
|------|-----------|
| **audioQC** | Publication accepts `pass` or `warn`; promotion requires `pass` in every required cell. Any `fail` blocks both. |
| **RTF** | `derivedMetrics.audioSecondsPerWallSecond` reviewed against the nearest compatible clean record in generated [`benchmarks/HISTORY.md`](../../benchmarks/HISTORY.md). |
| **Memory** | No rising `physFoot` peak or non-zero `hardTrim` in `trims` on floor-tier runs. |
| **Automated output proof** | Fixed-seed cohort, exact WAV identity, and applicable locale-locked ASR/prosody gates pass. Human listening is optional annotation and is never inferred. |

**RTF > 1** means faster than realtime (more audio seconds produced per wall second).

### Design constraints

1. **Primary backend driver is headless** — `vocello bench` drives the matrix in-process with exact
   cold/warm control. The scripted UI benchmark lanes were retired 2026-07-22; interactive UI QA
   ([`interactive-ui-qa.md`](interactive-ui-qa.md)) is the advisory frontend acceptance method and
   is not a benchmark publisher.
2. **Telemetry is runtime-gated** — identical code in Release; off unless debug env/toggle/handshake.
3. **No CI execution gate** — model-dependent benchmarks are local and explicitly requested. CI validates the compact registry and reproducible index but does not run models, devices, or Instruments.
4. **Lazy MLX caveat** — decode breakdown columns measure Swift wall-clock around lazy graph
   ops, not per-stage GPU compute. Use Instruments signposts for GPU attribution (§6.3).
5. **PASS-only publication** — a successful repository benchmark publishes one allowlisted JSON
   record and regenerates `HISTORY.md`. Failed or incomplete runs leave tracked history unchanged;
   raw telemetry, audio, screenshots, traces, and result bundles remain untracked.

---

## 2. Platform topology

Three hosts write telemetry; only some layers exist per path:

```text
                    CLI (vocello bench)     macOS app + XPC        iOS app (in-process)
                    ───────────────────     ───────────────        ────────────────────
Engine row          yes                     yes                    yes
Engine-service row  no                      yes (XPC transport)    no
App row             no                      yes (UI timings)       yes (UI timings)
Required join        engine                  app + service + engine app + engine
TTFC column         — (no app process)      yes (submit→chunk)     yes
UI heartbeat        —                       yes                    yes
```

| Path | Driver | Engine topology | Best for |
|------|--------|-----------------|----------|
| **CLI** | `./build/vocello bench` | In-process `MLXTTSEngine` | Deterministic RTF/decode/memory matrix; release QA step 3 |
| **macOS UI** | App + `QwenVoiceEngineService` XPC | Out-of-process engine | Submit-to-first-chunk, playback scheduling, delayed-heartbeat, and XPC transport evidence; interactive UI QA observations |
| **macOS profile** | `scripts/macos_test.sh profile --kind cpu|memory` | In-process via CLI inside exact-PID trace | CPU/signpost or allocation/VM validation |
| **iOS device** | `scripts/ios_device.sh bench` | In-process | iPhone tier, Jetsam, on-device RTF (headless diagnostics, single take) |

The scripted macOS/iOS UI benchmark lanes (full 29-take UI matrices with merged telemetry) were
retired 2026-07-22 with the XCUITest stack; their committed `ui-generation` records remain
immutable history.

**Important:** CLI bench numbers are **not** identical to macOS XPC UI numbers. Compare like with
like (CLI vs CLI, UI vs UI). Use CLI for backend optimization; use UI/XPC for integration regressions.

### Canonical hardware profiles

Native history is anchored to [`benchmarks/hardware-profiles.json`](../../benchmarks/hardware-profiles.json):

| Platform | Profile | Hardware |
|---|---|---|
| macOS | `mac-mini-m2-8gb` | Mac mini `Mac14,3`, Apple M2, 8 GB |
| iOS | `iphone-17-pro` | iPhone 17 Pro `iPhone18,1` |

Records also capture current OS build, thermal/low-power state, sanitized transport, toolchain,
executables, input/model fingerprints, and source state. A dirty success is `exploratory`, not a
canonical trend point. Profiles and forced-memory-class diagnostics are not compared with normal
timing records.

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
- Clone voice `A_warm_elderly_woman`, enrolled from a 10–20 second, transcript-backed Voice
  Design reference with a distinctive mature feminine alto. `models ensure` replaces the retired
  Custom/Aiden-derived short fixture when it detects that stale transcript.

Set `QVOICE_REQUIRE_TEST_MODELS=1` is automatic on script paths; bare `xcodebuild` may skip tests.

### Environment hygiene

| Check | Action |
|-------|--------|
| Quiet machine | Quit heavy apps; watch thermals (see §6.4). |
| Single Vocello session | Quit any separately installed Vocello first so telemetry and evidence come from one known Release product. |
| Debug data dir | `QWENVOICE_DEBUG=1` → `~/Library/Application Support/QwenVoice-Debug/` |
| Floor-tier simulation | `QWENVOICE_FORCE_MEMORY_CLASS=floor_8gb_mac` (propagates to engine via handshake) |
| Suppress proactive warm | `QWENVOICE_SUPPRESS_WARMUP=1` for accurate Custom/Design **cold** rows in UI runs |

### iOS device

- Paired physical iPhone (never Simulator for real engine)
- Speed models visibly verified ready in Settings (interactive UI QA observation when explicitly requested)
- `scripts/ios_device.sh preflight` before bench/gate
- Physical-device playbook: [`ios-device-testing.md`](ios-device-testing.md)

---

## 4. Standard workflows

All `--label` values are opaque privacy-safe identifiers matching
`[A-Za-z0-9][A-Za-z0-9._-]{0,95}`. Use a short slug such as `release-QA`; never put a prompt,
voice description, username, path, or free-form note in a label.

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
  --label "release-QA"
```

Gate: all required cells `QC=pass`; RTF within noise of `HISTORY.md`; fixed-seed identity and every
applicable automated language/prosody gate pass. A `warn` may remain in history but is not an
engine-promotion pass.

### 4.2 Quick multi-mode smoke (Speed, short matrix)

```sh
QWENVOICE_DEBUG=1 ./build/vocello bench \
  --modes custom,design,clone \
  --variants speed \
  --lengths short,medium \
  --warm 1 \
  --label "my-change" \
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
  --label "floor-tier"
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

Adds instruct-bearing warm takes. The prosody analyzer reads the current run's immutable
`bench-results.json` allowlist before the final summary, so older WAVs left by `--keep` cannot enter
the delivery comparison; the summarizer then prints that current prosody block.

### 4.7 iOS on-device bench

```sh
scripts/ios_device.sh bench custom:speed: \
  --label "ios-device-bench"
```

Optional physical-device memory-profile diagnostic:

```sh
scripts/ios_device.sh bench --memory-profile iphone15pro custom:speed:
```

Pulls diagnostics from the device, runs the summarizer, and exits non-zero unless
`device-diagnostics-done.json` reports success.

### 4.7b iOS UI benchmark (retired 2026-07-22)

The scripted iOS UI benchmark lane ran the same 29-take matrix semantics as the retired macOS UI
benchmark, through XCUITest on the paired physical iPhone with run-scoped engine/app telemetry and
an atomic `benchmark-evidence.json`. It was retired with the XCUITest stack; its committed
`ui-generation` records remain immutable history. On-device engine benchmarking continues headless
via `scripts/ios_device.sh bench` (§4.7), and frontend acceptance is the advisory interactive UI QA
checklist ([`interactive-ui-qa.md`](interactive-ui-qa.md)) over iPhone Mirroring.

For the retired iPhone UI matrix, the `long` cell was the production 150-character boundary case;
the extended >220-character corpus below remains the macOS/CLI definition, and nothing overrides
iOS's on-device input limit.

The Instruments profile is a separate headless lane:

```sh
scripts/ios_device.sh profile
scripts/ios_device.sh profile --kind memory
```

It builds and installs the diagnostic app, launches one headless generation suspended, attaches
CPU Profiler plus `os_signpost` to that exact PID, resumes it, waits for the success sentinel, pulls
its run-scoped diagnostics, and publishes an independent `instrument-profile` record. The memory
kind additionally records Allocations and VM Tracker in the same trace. Run it whenever
profiling evidence is useful; its trace, generation, and history record stand alone and are never
folded into another lane's evidence manifest.

Retained-memory qualification is a separate one-process nine-take lane:

```sh
scripts/ios_device.sh memory --voice-id <exact-prepared-saved-voice-id> --label retained-check
```

It runs three medium Speed takes each in fixed Custom→Design→Clone order without relaunching the
app. `retained-memory-v1` compares first-to-last retained-take footprint growth within each mode against a 5%
of physical-RAM limit; cross-mode model residency is diagnostic. The terminal sentinel is atomic and
a PASS publishes `memory-qualification`, not `instrument-profile`.

Clone-conditioning semantics have a separate local acceptance command:

```sh
scripts/ios_device.sh clone-conditioning --label focused-clone-proof
```

It proves transcript-backed and genuine x-vector-only conditioning with the exact canonical
reference in one physical-iPhone process. It is intentionally not a timing matrix and never creates
a benchmark-history record; the compact validation and its raw telemetry/WAV evidence remain under
the untracked iOS artifact tree.

### 4.7c iOS benchmark ownership

Engine RTF evidence is owned by the headless §4.7 `ios_device.sh bench` lane. There is no scripted
UI benchmark lane; frontend behavior is reviewed through the advisory interactive UI QA checklist.

| Phase | Tool |
|-------|------|
| Independent trace capture | `scripts/ios_device.sh profile --kind cpu|memory` (separate headless generation/profile lane) |
| Trace analysis | Instruments / `xcrun xctrace`; optional `xcprof` on `PATH` |
| UI failure | Interactive-QA screenshots and per-item verdicts |
| Crash post-mortem | Xcode Organizer; optional `xcsym` on `PATH` |

Use `$axiom-tools` for workflow selection. Physical-device setup is documented in
[`ios-device-testing.md`](ios-device-testing.md).

The iOS profile command resolves Instruments' UDID independently from CoreDevice's device ID and
stops before launching Vocello if the phone is listed under `Devices Offline`. Reconnect and unlock
the phone until `xcrun xctrace list devices` places it under `Devices`; CoreDevice reachability alone
is not sufficient evidence that Instruments can attach.

### 4.8 macOS Instruments profile (signpost validation)

```sh
QVOICE_MAC_PROFILE_DURATION=120 \
scripts/macos_test.sh profile custom:speed:

scripts/macos_test.sh profile --kind memory custom:speed:

# Only when the raw document must be reopened in Instruments:
scripts/macos_test.sh profile --kind memory --keep-trace custom:speed:
```

The macOS memory profile records one cold long take. This captures model-load plus sustained
allocation/VM peaks. The lane uses Apple's Allocations template for its Allocations and VM Tracker
tracks because that template disables automatic VM snapshots; adding standalone VM Tracker to a
Blank trace enables stop-the-world snapshots that create real holes in the target's 500 ms sampler.
Publication verifies the captured template setting and retains the strict 95% floor. The memory
profile's default 180-second safety cap is only a maximum; exact-target exit ends the recording
early. The separate `scripts/macos_test.sh memory` lane owns repeated retained growth.

Produces `build/artifacts/macos/profiles/<run-id>/<run-id>.trace` containing CPU Profiler samples and
`os_signpost` rows in one capture; the memory kind adds Allocations and VM Tracker. **In-process
only** — not the production XPC
path. The lane is PASS-only: a tracer failure, benchmark failure, invalid trace, or failed publication
returns nonzero without creating history. It retains only the newest raw failure per platform and
profile kind; older failures are compacted to small diagnostic summaries.
Explicitly pinned failures are never compacted. An unpinned compacted failure retains the required
retention marker and summary plus at most 8 MiB of allowlisted auxiliary diagnostics; individual
logs are capped at 1 MiB. Inspect and acknowledge a current failed capture by exact run ID:

```sh
python3 scripts/build_output_policy.py status
scripts/clean_build_caches.sh --compact-profile-failure <run-id> --dry-run
scripts/clean_build_caches.sh --compact-profile-failure <run-id>
```

The profiler launches or attaches to the exact target PID, requires a successful tracer exit, and
validates the trace through `xctrace export --toc`; there is no blind startup sleep. For XPC, attach
to the exact `QwenVoiceEngineService` PID while generating via UI. Traces remain untracked. On
success the registry retains the digest, settings, extracted summary, original ephemeral path, and
retention policy, then the runner removes the raw trace. Pass `--keep-trace` to retain it
explicitly. The tracer stage requires at least 5 GiB free for CPU profiles and 15 GiB for memory
profiles. The prerequisite macOS CLI build has an 8 GiB floor, so the complete CPU-profile command
effectively requires 8 GiB; memory remains 15 GiB because Allocations can emit tens of megabytes
per second.

The separate retained-memory lane is:

```sh
scripts/macos_test.sh memory --label retained-check
```

It runs Custom and Design as one cold plus three `retained#0...2` takes and Clone as three
`retained#0...2` takes, all Speed/medium in one CLI process. Each retained take keeps its actual
engine warm-state attribution. The same `retained-memory-v1` within-mode 5%-of-RAM policy applies;
an accepted run publishes `memory-qualification` and carries no trace.

### 4.9 UI-driven generation (macOS XPC)

Real generation through the macOS frontend is exercised by interactive UI QA (agent-driven
computer use). For explicit frontend acceptance, run `scripts/macos_test.sh models ensure` if the
visible Settings readiness check fails, then run the interactive UI QA checklist
([`interactive-ui-qa.md`](interactive-ui-qa.md)) against `./scripts/build.sh run`. Completion is
observed through the visible player and History state; it is advisory and is not an RTF matrix
driver.

### 4.10 macOS XPC UI benchmark (retired 2026-07-22)

**Primary backend regression remains `vocello bench` (§4.1).** The supplementary UI matrix was
driven by XCUITest through the real app + XPC service, stamping `notes.benchRunID`,
`benchTakeIndex`, `benchCell`, and `benchWarmState` via `QVOICE_MAC_BENCH_RUN_ID`, and running
exactly 29 takes with runner-owned crash-delta and evidence-manifest gating. That lane and its
validator were retired with the XCUITest stack; the committed `ui-generation` records remain
immutable history. XPC-topology performance evidence now comes from the deterministic
`scripts/macos_test.sh gate` bench option and headless telemetry lanes, while interactive UI QA
covers advisory frontend behavior.

The seeded telemetry-overhead result remains independent.
For telemetry/backend changes, run the model-dependent overhead parity lane directly when its
fixture is available; it does not consume or require UI evidence:

```sh
scripts/macos_test.sh telemetry-overhead
```

This counterbalances `off`, `lightweight`, and `verbose` through three deterministic order
rotations. Every rotation performs one warm-up and two measured takes per mode, yielding six
machine-readable measured takes per mode. It requires identical PCM, records thermal/load context,
and gates median RTF/TTFC at 5% (lightweight) and 10% (verbose) versus off. It never repairs or
downloads models; missing fixtures stop the run. Its verdict stays under `build/artifacts/macos/`
and is not
published to schema-v2 history: adding the in-process memory sampler to the `off` lane would change
the observer whose overhead is being measured. This fail-closed exception preserves the experiment
without admitting memory-incomplete records.

| Phase | Tool |
|-------|------|
| Trace capture | `xctrace record --attach <exact-service-pid>` during a benchmark scenario |
| Trace analysis | Instruments/xctrace plus the relevant installed macOS performance skill |
| Logs / warm-admission | `scripts/macos_test.sh logs` and unified-log inspection |
| Crash post-mortem | `scripts/macos_test.sh crashes`, dSYMs, and standard symbolication |

Cold takes: app relaunch + `QWENVOICE_DEBUG=1` + `QWENVOICE_SUPPRESS_WARMUP=1` +
`QWENVOICE_BENCH_FORCE_COLD=1` (master-gated unload before generate). Warm takes stay in-session.

---

## 5. Matrix semantics

### Fixed corpus

Defined in `BenchMatrixSpec` (`Sources/QwenVoiceCore/BenchMatrixSpec.swift`; shared with
`BenchCommand`, and formerly with the retired XPC UI bench) — do not change without updating baselines:

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
`QWENVOICE_DEBUG=1` + `QWENVOICE_SUPPRESS_WARMUP=1` + `QWENVOICE_BENCH_FORCE_COLD=1`
(see §4.10).

### Streaming default

`vocello bench` streams by default (`--no-stream` for legacy quality-first accumulation).
Streaming populates `chunkTimeline`; non-streaming leaves it empty.

---

## 6. Reading results

### 6.1 Summarizer invocation

```sh
python3 scripts/summarize_generation_telemetry.py <DIAGNOSTICS_DIR> \
  --run-id <run-id> --evidence-manifest <artifact-dir>/benchmark-evidence.json \
  --label release-QA
```

For an authoritative benchmark, both selectors are mandatory: the run ID rejects unrelated rows,
and the evidence manifest supplies the exact ordered generation IDs/cells. Never summarize an
entire historical diagnostics directory as if it were one run. Ad-hoc diagnostics may still use
the default directory (`~/Library/Application Support/QwenVoice-Debug/diagnostics`) without being
eligible for registry publication.

Useful flags:

| Flag | Purpose |
|------|---------|
| `--show-variance` | IQR / outlier hints per cell |
| `--merged` | Cross-layer first-chunk table from `generations-merged.jsonl` |
| `--save-baseline PATH` | Write the current per-cell summary as a **JSON** baseline |
| `--compare-baseline BASELINE.json` | Regression compare vs a **JSON** baseline from `--save-baseline` (exit 2 on >5% regression; RTF **drop**, tok/s drop, TTFC/physFoot rise, QC worsening). Markdown snapshots cannot be fed to this flag — diff those with `git diff`. |
| `--run-id ID` | Reject rows from other benchmark runs. |
| `--evidence-manifest PATH` | Select the manifest's exact ordered generations and cells. |

### 6.2 Headline table columns

| Column | Source | Notes |
|--------|--------|-------|
| RTF | `derivedMetrics.audioSecondsPerWallSecond` | Primary throughput KPI |
| tok/s | Codec tokens / decode wall | Compare across variants |
| TTFC ms | App row `submitToFirstChunkMS` | `-` for CLI (no app process) |
| peakGPU / physFoot | Sampler peaks | physFoot = Jetsam-relevant on iOS |
| trims | `memory_trim` stage marks | Floor/mid/iPhone tiers |
| UIdelay | App row delayed-heartbeat count/max plus coverage | Sampling signal; `-` for CLI, not an exhaustive stall count |
| QC | `audioQC.verdict` + flags | `fail` = hard stop |

### 6.2a Memory qualification contract

New publishable generation benchmarks require telemetry schema v8 and benchmark-evidence manifest
v2. For every selected generation, the exact `engine/samples-<generationID>.jsonl` sidecar must
begin with one `start`, end with one `stop`, retain monotonic elapsed and absolute-uptime clocks,
and contain the required preparation/model-load/session/first-output/final-WAV/terminal boundaries.
iOS additionally requires finite headroom samples. macOS UI/XPC runs require a matching app sidecar;
their total resident/footprint/compressed/GPU values use samples paired by absolute uptime within one
500 ms cadence. Headless macOS CLI/profile runs remain owning-engine-process evidence. Never add
independent process maxima.

Sidecar and summary counts must agree, capture failures must be zero, and periodic sampler coverage
must be at least 95%. Coverage from 95% to below 100%, guarded pressure, or `softTrim` produces
`passedWithWarnings`. Coverage below 95%, critical pressure, an app memory warning/exit,
`hardTrim`, or `fullUnload` fails publication and leaves tracked history unchanged. Manifest v2
binds `memoryContractVersion`, the selected sidecar count/digest, each take's memory status/digest,
and bounded start/end/delta/peak, headroom/utilization, sampler, pressure, trim, warning, and exit
metrics. Raw samples remain untracked.

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

### PASS-only registry

Every in-repository benchmark-like lane publishes only after its own success contract passes. The
runner writes an atomic untracked `benchmark-evidence.json`, then calls:

```sh
python3 scripts/benchmark_history.py record --artifact-dir <run-artifact-dir>
python3 scripts/benchmark_history.py validate --all
python3 scripts/benchmark_history.py rebuild-index --check
```

Publication creates `benchmarks/runs/<kind>/<run-id>.json` and regenerates
`benchmarks/HISTORY.md`; it never stages, commits, or pushes. Re-recording byte-identical evidence
is idempotent. A conflicting run ID, duplicate evidence digest, privacy violation, oversized
record, failed QC, failed finish, crash delta, missing layer, wrong take order, or unreadable WAV
fails publication and leaves tracked history unchanged. If publication fails after the expensive
run passed, retain the local artifact directory and rerun the printed `record --artifact-dir`
command after repairing the exporter.

An accepted QC warning produces `passedWithWarnings` and remains visible in run/cell warning
counts and worst-QC fields. A QC failure is never downgraded or published.

Schema-v2 tracked benchmark kinds are `ui-generation`, `engine-generation`, `language`,
`instrument-profile`, `memory-qualification`, and `prosody-calibration`. Schema-v1
`telemetry-overhead` records remain readable historical evidence, but new overhead runs are local
observer-effect diagnostics and do not publish. Delivery/prosody cells from
`vocello bench --delivery` remain inside their parent engine-generation record. Smoke, unit tests,
crash inspection, preflight, and standalone analysis tools do not publish benchmark records.

| Kind | Publisher | Minimum publishable success |
|---|---|---|
| `ui-generation` | Retired UI benchmark runner (2026-07-22); existing records are immutable history | Historically: XCTest, exact selected matrix/order, complete required telemetry layers, memory qualification, readable atomic WAVs, QC, and crash delta |
| `engine-generation` | `vocello bench`, iOS headless bench, optional gate bench | Exact selected rows, memory qualification, successful finishes, readable/QC-accepted output, and command PASS |
| `language` | macOS/iOS `lang-bench` | Requested hint/output gates; hint-only is explicitly `partial` |
| `instrument-profile` | macOS/iOS profile commands | Memory-qualified target generation PASS, exact PID, tracer success, valid trace TOC, non-empty exported performance rows, and run/generation/take/cell-correlated signposts |
| `memory-qualification` | macOS/iOS `memory` commands | Fixed policy topology, v8 sidecar qualification, output/QC success, and within-mode retained-footprint growth ≤5% of physical RAM |
| `prosody-calibration` | `prosody_calibration.py` | Required corpus coverage with no analysis failure |

`HISTORY.md` is a generated index grouped by kind, platform, hardware, and comparable
configuration. It computes a delta against the nearest earlier compatible clean record; a delta is
information, not an automatic failure. [`benchmarks/LEGACY_HISTORY.md`](../../benchmarks/LEGACY_HISTORY.md)
preserves the former manual ledger as incomplete historical evidence.

### Listening annotation

Automated success and optional perceptual review are independent. Add the latter without rewriting
the run:

```sh
python3 scripts/benchmark_history.py annotate --run-id <run-id> \
  --listening pass --note "reviewed representative takes"
```

Use `fail` or `not-performed` when appropriate. Listening never changes the automated verdict and
is not required for promotion; it records subjective observations that deterministic gates do not
claim to measure.

### Baseline comparison (JSON, machine-gated)

```sh
# Seed / reseed a baseline (after an intentional, reviewed perf change):
python3 scripts/summarize_generation_telemetry.py <diag-dir> \
  --run-id <run-id> --evidence-manifest <run-artifact-dir>/benchmark-evidence.json \
  --save-baseline benchmarks/baselines/mac-gate-bench.json

# Compare (exit 2 on regression — usable in scripts/gates):
python3 scripts/summarize_generation_telemetry.py <diag-dir> \
  --run-id <run-id> --evidence-manifest <run-artifact-dir>/benchmark-evidence.json \
  --compare-baseline benchmarks/baselines/mac-gate-bench.json
```

The committed **`benchmarks/baselines/mac-gate-bench.json`** (custom/speed/medium,
cold+warm) is what `QWENVOICE_GATE_BENCH=1 scripts/macos_test.sh gate` compares against —
the gate uses an isolated runtime directory, rejects rows outside its collision-resistant run ID,
and freezes the exact ordered generation selection in `benchmark-evidence.json` before comparing.
Markdown snapshots (`benchmarks/baseline-*.md`) remain the human-readable full-matrix references;
diff them with `git diff`, not `--compare-baseline`.

### Like-for-like comparison rules

Never compare numbers across topologies — each is a different measurement, not a
regression signal:

| Lane | Build | Topology | Headline custom/speed/medium warm |
|------|-------|----------|-----------------------------------|
| `build.sh` CLI bench | `-Onone` | in-process | RTF ≈ 1.0 |
| local release / `-O` CLI | optimized | in-process | RTF ≈ 1.7 |
| macOS UI benchmark (retired lane; historical records) | Release app | app + XPC service | RTF ≈ 1.7 |
| iOS `ios_device.sh bench` | `-Onone` device | in-process on iPhone | RTF ≈ 1.6–1.9 |
| iOS UI benchmark (retired lane; historical records) | `-O` Release app | in-process, real Studio UI | optimized frontend/device result; do not compare with the `-Onone` headless lane |

Compare a record only against one with the same generated comparison key. That key includes lane,
platform/hardware, matrix (including CLI streaming/seed and overhead rotation settings),
model/runtime, toolchain, and relevant input identities. Dirty,
instrumented, partial, and forced-profile runs are excluded from canonical trends.

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

### Layer 2.6 — Output language + WER/CER (Phase 3, iOS device diagnostics)

When `QVOICE_IOS_DEVICE_DIAGNOSTICS_VERIFY_OUTPUT=1`, the app transcribes each exact fixed-seed WAV
three times in-process with one locale-locked on-device Speech recognizer and stamps the consensus
evidence on `device-diagnostics-done.json`. `scripts/check_language_output.py` independently
recomputes edit metrics from the corpus: WER is primary for word-delimited languages and CER for
Chinese/Japanese, both with a 0.15 ceiling. Requires Speech Recognition permission on the phone
once. Skip with `QVOICE_LANG_BENCH_SKIP_OUTPUT=1`. See [`language-bench.md`](language-bench.md).

### Layer 3 — Optional listening annotation

When desired, play takes and record a subjective timbre/prosody observation with
`scripts/benchmark_history.py annotate`; never edit `HISTORY.md` directly. This annotation is not
an automated gate and does not authorize overriding a deterministic failure or warning.

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
| `<run-artifact-dir>/benchmark-evidence.json` | Atomic run-scoped validator selection and verdict used for publication |
| `build/**/*.xcresult`, screenshots | UI evidence retained locally under bounded lane retention |
| `build/**/profiles/` | Compact local profile summaries; raw `*.trace` is success-ephemeral unless `--keep-trace` was explicit |

Auto-pruned: `generations.jsonl` ~8 MB cap; verbose sidecars newest-48 / 64 MB.

### Committed (bounded)

| Path | Rule |
|------|------|
| `benchmarks/runs/<kind>/<run-id>.json` | One canonical allowlisted record per successful run, ≤ 256 KB; only `annotate` may update listening review |
| `benchmarks/HISTORY.md` | Generated registry index; never edit by hand |
| `benchmarks/LEGACY_HISTORY.md` | Preserved incomplete manual history; never promoted to complete registry evidence |
| `benchmarks/hardware-profiles.json`, `schema-v1.json`, `schema-v2.json` | Canonical hardware identities plus compatibility/current record contracts |
| `benchmarks/baseline-*`, `OPTIMIZATION.md` | Existing reference snapshots and historical optimization narrative |

The exporter uses a strict allowlist and rejects serials/UDIDs/ECIDs, host/device/user names,
absolute paths, prompts/transcripts/voice descriptions, raw errors, emails, URLs, and secret-like
labels. **Never commit raw JSONL, WAVs, screenshots, result bundles, or traces** under `benchmarks/`.

### CI / automation

- `.github/workflows/ci.yml` — `ios-compile-check` (compile-only; no attended UI, no bench)
- `.github/workflows/release.yml` — deterministic signing and packaging; interactive UI QA remains explicit/local
- `scripts/check_project_inputs.sh` — validates all compact records and checks that `HISTORY.md` is reproducible
- Explicit frontend acceptance: run the interactive UI QA checklist ([`interactive-ui-qa.md`](interactive-ui-qa.md))
- Deterministic macOS platform gate: `scripts/macos_test.sh gate` (does not consume UI observations)

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
| All QC warn:dropout on long | Often natural pauses | Run the fixed-seed exact-WAV cohort; inspect the punctuation-aware budget, ASR consensus, and prosody evidence |
| iOS bench timeout | Model missing / device diagnostics did not complete | `scripts/ios_device.sh console`; install Speed model |
| Clone cold row appears | Corrupt matrix ordering, generation map, or frozen evidence | **Hard failure:** inspect `bench-results.json` or the UI generation map plus `benchmark-evidence.json`, repair the producer/selection mismatch, and rerun. Never relabel or ignore a Clone cold row. |

---

## 11. Related documents

| Doc | Role |
|-----|------|
| [`telemetry-and-benchmarking.md`](telemetry-and-benchmarking.md) | Schema, knobs, telemetry architecture |
| [`cli.md`](cli.md) | Full `vocello bench` flag reference |
| [`macos-release-qa.md`](macos-release-qa.md) | Release gate sequence |
| [`macos-testing.md`](macos-testing.md) | UI test / profile / gate lanes |
| [`ios-device-testing.md`](ios-device-testing.md) | iOS bench, gate, device lanes |
| [`benchmarks/OPTIMIZATION.md`](../../benchmarks/OPTIMIZATION.md) | Optimization program status |
| [`benchmarks/HISTORY.md`](../../benchmarks/HISTORY.md) | Generated benchmark registry index |
