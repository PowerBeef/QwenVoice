# Telemetry & benchmarking

How Vocello measures itself. This is the single reference for the per‑generation
telemetry that spans the **frontend (app UI)**, the **middle communication layer
(macOS XPC / iOS ExtensionKit)**, and the **backend core (MLX / Qwen3‑TTS)** — what
is measured, where it lands, how to read it, and how it stays cheap enough to run on
restricted hardware (8 GB Macs, iPhone) without distorting the numbers you optimize
against.

If anything here disagrees with the code, the code wins — fix this file.

> Scope note: this covers runtime telemetry. There is no committed benchmark *script*
> harness, no baselines, and no test bundle (`scripts/check_project_inputs.sh` guards
> those retired surfaces). Benchmarking is **agent/manual‑driven**: drive a generation,
> then read the JSONL this system writes. UI driving uses the `computer-use` MCP — see
> [`ui-driving.md`](ui-driving.md).

---

## 1. Principles

1. **Runtime‑gated, never compiled out.** There is one shippable config; dev and
   release run identical code (see root `CLAUDE.md`). Telemetry is switched on at
   runtime by `TelemetryGate`, not by `#if DEBUG`. When the gate is off, every probe
   is a no‑op and nothing is written.
2. **Correlated by `generationID`.** The app mints a `UUID` per generation and threads
   it down; the engine reuses it. Every layer keys its rows on that one ID so they join.
3. **Cheap on the hot path.** No per‑chunk file I/O, no per‑chunk allocations or
   MainActor hops added by telemetry. Per‑generation work happens at boundaries; the
   memory sampler runs on a background task at a device‑tiered cadence.
4. **Measure, don't perturb.** The fine‑grained backend timings read clocks around work
   that already happens (including the GPU syncs that generation requires); telemetry
   does not add synchronization. See [§9 Observer effect](#9-overhead--observer-effect).

---

## 2. Turning it on

Telemetry persistence is governed by **`TelemetryGate`** (`Sources/QwenVoiceCore/TelemetryGate.swift`),
resolved once per process:

| Source | Effect |
|---|---|
| `QWENVOICE_DEBUG=1` (env) | On in any process that inherits it (e.g. `./scripts/build.sh run`). |
| 7‑tap the version label in Settings (persisted `UserDefaults` flag) | On in the app process; relayed to the engine process over the `initialize` IPC handshake (`telemetryEnabled`). |
| `QWENVOICE_NATIVE_TELEMETRY_MODE=lightweight\|verbose` | Forces sampling/persistence on regardless of the gate. |

The engine runs **out of process** (XPC service on macOS, ExtensionKit on iOS) with a
different bundle id, so the app's `UserDefaults` flag can't reach it via environment —
it is carried on the handshake, where the host calls `TelemetryGate.enableFromHandshake()`.

### Sampling modes (`NativeTelemetryMode`, in `SemanticTypes.swift`)

| Mode | `QWENVOICE_NATIVE_TELEMETRY_MODE` | Memory sampler | Raw per‑sample series |
|---|---|---|---|
| `off` | `off` / `disabled` | — | — |
| `lightweight` (default when gate on) | `lightweight` / `light` | device‑tiered cadence | no |
| `verbose` | `verbose` / `full` / `deep` | device‑tiered cadence | **yes** (sidecar) |

Typical backend‑optimization invocation:

```sh
QWENVOICE_DEBUG=1 QWENVOICE_NATIVE_TELEMETRY_MODE=verbose ./scripts/build.sh run
```

### Related benchmark knobs (also propagated over the handshake)

| Env | Effect |
|---|---|
| `QWENVOICE_SUPPRESS_WARMUP=1` | Skips proactive prewarm/clone‑priming so the first generation records its own **cold** load (`MacGenerationWarmupCoordinator`). App‑process only. |
| `QWENVOICE_FORCE_MEMORY_CLASS=floor_8gb_mac` | Forces the device‑memory tier (`NativeDeviceClassGate`), propagated to the engine over `initialize`. Runs the constrained‑tier code paths so memory **pressure is measurable on any hardware**. See §11 "Memory & pressure pass". Accepts the `NativeDeviceMemoryClass` rawValues + aliases `8gb`/`16gb`. |

---

## 3. Architecture

```
 App process (Vocello)                    Engine process (XPC service / iOS extension)
 ┌───────────────────────────┐  IPC      ┌──────────────────────────────────────────┐
 │ Coordinators              │  ───────► │ NativeEngineRuntime.prepareGeneration      │
 │   mint generationID       │ generate  │   creates per‑generation recorder          │
 │ AudioPlayerViewModel      │           │ MLXModelLoadCoordinator (load/tokenize)    │
 │   submit→firstChunk→       │ ◄──────   │ NativeStreamingSynthesisSession            │
 │   firstAudible→completed   │  chunks   │   decode loop + memory sampler             │
 │ AppGenerationTimeline      │           │   reads MLX timings, per‑chunk substages   │
 │ GenerationTelemetryMerger  │           │ Qwen3TTS (vendored) emits timings/counters │
 └───────────────────────────┘           └──────────────────────────────────────────┘
        │  writes app row                          │  writes engine + engine-service rows
        └──────────────► diagnostics/*/generations.jsonl ◄───────┘
                                  │ merge by generationID
                                  ▼
                         generations-merged.jsonl
```

Core types (all in `Sources/QwenVoiceCore/` unless noted):

| Type | Role |
|---|---|
| `TelemetryGate` | Master on/off, per process; handshake latch. |
| `NativeTelemetryRecorder` | Per‑generation stage timeline (`mark(stage:)`). Created in `prepareGeneration`; shared with the load coordinator and the session. |
| `NativeTelemetrySampler` | Background memory/timing sampler → `TelemetrySummary` + raw `[TelemetrySample]`. |
| `GenerationTelemetryRecord` | One durable row per layer (`engine` / `engine-service` / `app`). |
| `GenerationTelemetryJSONLSink` | Append‑only writer (gated); also the verbose raw‑sample sidecar. |
| `GenerationTelemetryMerger` (`Sources/Services/`, macOS) | Joins per‑layer rows → `generations-merged.jsonl`. |
| `AppGenerationTimeline` (`Sources/SharedSupport/Telemetry/`) | Frontend submit→firstChunk→firstAudible→completed. |

---

## 4. Output files

Under `~/Library/Application Support/QwenVoice[-Debug]/diagnostics/` (the `-Debug`
folder when DebugMode is on, so real data is never polluted):

| File | Layer | Contents |
|---|---|---|
| `engine/generations.jsonl` | backend | The decode breakdown, KPIs, per‑stage MLX memory, per‑chunk timeline, stage marks, memory summary. **The richest source for backend work.** |
| `engine-service/generations.jsonl` | middle | XPC transport: chunks forwarded, gaps, forwarding span. |
| `app/generations.jsonl` | frontend | User‑perceived timings: submit→first chunk→first audible→completed + memory summary. |
| `generations-merged.jsonl` | merged | All layers joined per `generationID` (one row per run). |
| `engine/samples-<generationID>.jsonl` | backend (verbose only) | Raw per‑sample memory/timing series. |
| `*/native-events.jsonl` | engine/middle | Legacy: chunk‑sequence gaps + encode drops only. |

One JSON object per line. Read with `jq` or Python (examples in [§10](#10-running--reading-a-benchmark)).

**Bounded by design.** These are append‑only but **size‑capped + auto‑pruned** (oldest‑first) by
`GenerationTelemetryJSONLSink`, so logs can't blow out disk: each `generations.jsonl` (incl. the merged
file) is front‑trimmed past ~8 MB (`QWENVOICE_DIAGNOSTICS_MAX_MB` scales it), and verbose
`samples-*.jsonl` sidecars are retained newest‑48 / ≤64 MB. No manual clearing needed for logs.

---

## 5. The per‑generation record schema

`GenerationTelemetryRecord` (schema v2). Optional fields are omitted from JSON when nil,
so older v1 rows still decode.

| Field | Type | Notes |
|---|---|---|
| `schemaVersion` | Int | 2. |
| `generationID` | String | Correlation key (UUID). |
| `layer` | String | `engine` / `engine-service` / `app` / `merged`. |
| `mode` | String? | `custom` / `design` / `clone`. |
| `usedStreaming` | Bool? | Streaming vs quality‑first. |
| `finishReason` | String? | `eos` / `maxTokens` / `failed` / `superseded`. |
| `stageMarks` | `[{tMS, stage, metadata}]` | Lifecycle timeline (see §6). |
| `timingsMS` | `[String: Int]` | **Engine layer: the full MLX decode breakdown + counters** (see §6). |
| `counters` | `[String: Int]` | e.g. `chunkCount`; middle layer: `chunksForwarded`, `chunkGaps`. |
| `derivedMetrics` | `[String: Double]?` | Headline KPIs (see §7). |
| `mlxMemoryByStage` | `[String: {activeMB, cacheMB, peakMB}]?` | MLX GPU memory at each stage (see §8). |
| `chunkTimeline` | `[GenerationChunkTelemetry]?` | Per‑chunk decode substages (see §6.3). |
| `summary` | `TelemetrySummary?` | Process memory curve summary (see §8). |
| `notes` | `[String: String]` | Freeform (e.g. error messages). |
| `recordedAt` / `processName` / `processIdentifier` | | Provenance. |

---

## 6. Backend (MLX) timing — the optimization data

### 6.1 Stage timeline (`stageMarks`)

Coarse milestones for one generation, in ms from generation start (the recorder and the
memory sampler **share one start clock**, so marks and samples align). Stages
(`NativeRuntimeStage`): `preparedCacheValidation`, `tokenizerPreparation`,
`upstreamModelLoad`, `prewarm`, `clonePreparation`, `streamStartup`, `firstChunk`,
`streamCompleted` / `streamFailed`, `unload`. Load/prewarm marks appear only on a **cold**
run (warm runs skip that work — that's correct, not missing data). Two additional
string‑keyed marks record memory events on pressure‑bound tiers: `memory_pressure` and
`memory_trim` (see §8).

### 6.2 Decode breakdown (`timingsMS`)

The engine re‑reads the model's diagnostics **after** the decode loop (the MLX hot‑loop
totals are only finalized post‑loop), so `timingsMS` carries the per‑substage wall‑clock
breakdown of where decode time actually went, accumulated across the whole generation.
The MLX layer owns these keys; the set is mode‑dependent — **inspect a real row for the
authoritative list.** Representative keys (prefix `qwen_…`):

| Key (representative) | Meaning |
|---|---|
| `qwen_talker_forward_total` | LLM talker forward pass, summed over tokens. |
| `qwen_code_predictor_total` | Multi‑codebook code‑predictor loop. |
| `qwen_stream_decoder_total` | Streaming audio decoder (codec → waveform). |
| `qwen_stream_step_eval_total` | `eval(...)` flush after each forward step (GPU dispatch). |
| `qwen_stream_step_eos_read_total` | EOS‑flag readback (a GPU sync). |
| `qwen_token_loop_total` | Whole per‑token loop wall time. |
| `qwen_token_loop_unattributed` | Loop time not attributed to a named substage (slack to chase). |
| `qwen_generated_code_count` | Tokens generated (counter). |
| `qwen_stream_decoder_calls` | Streaming chunk decode count. |
| prep / prewarm keys | `*_prefix_tokenize_ms`, `*_prefix_embed_build_ms`, `decoder_bucket_warm`, `*_prewarm_eval_ms`, … |

Use the breakdown to see which substage dominates (talker vs code‑predictor vs decoder)
and how much loop time is `unattributed` (candidate for new sub‑probes).

### 6.3 Per‑chunk timeline (`chunkTimeline`, streaming only)

One entry per emitted audio chunk — the decode substage deltas that produced it, plus its
wall‑clock arrival (ms since start). Mirrors the vendored `ChunkSubstageTimings`:
`talkerForwardMS`, `codePredictorMS`, `audioDecoderMS`, `streamStepEvalMS`,
`streamStepEOSReadMS`, `audioChunkEvalMS`, plus `chunkIndex`, `arrivalMS`. This exposes
**cold‑start vs steady‑state** behavior and localizes stalls to a substage and a chunk.
Captured cheaply (a small struct appended per chunk, only when telemetry is on) and
written once at generation end.

---

## 7. Derived KPIs (`derivedMetrics`)

Computed once at generation end from data already gathered — the headline numbers for
backend throughput:

| Key | Definition | Read as |
|---|---|---|
| `audioSeconds` | Generated audio duration (frames ÷ sample rate). | Output length. |
| `decodeWallSeconds` | Decode wall time (model `.info.generateTime`, else `streamStartup→streamCompleted` span). | Compute cost. |
| `audioSecondsPerWallSecond` | `audioSeconds ÷ decodeWallSeconds`. | **Real‑time factor: >1 = faster than realtime.** Primary throughput KPI. |
| `tokensPerSecond` | Codec tokens ÷ decode wall seconds (from `.info` when present). | Decode throughput; compare across model variants / patches. |
| `generatedTokenCount` | Codec tokens produced. | Work done; normalize other metrics by this. |

Time‑to‑first‑audio (perceived latency) is the **app** row's `submitToFirstChunkMS` /
`submitToFirstAudibleMS`; the engine row's `firstChunk` stage mark is the backend‑only
portion.

---

## 8. Memory probes

- **`mlxMemoryByStage`** — MLX GPU `active`/`cache`/`peak` MB captured at stage boundaries
  (`before_stream`, `first_chunk`, `after_stream`, `after_final_write`,
  `after_generation_trim`, plus prepare/clone/prewarm stages). Shows GPU memory growth
  across the pipeline — key for restricted‑hardware tuning. Captured at boundaries only
  (a GPU snapshot is too costly per chunk).
- **`summary`** (`TelemetrySummary`) — process memory **curve** summary from the background
  sampler: resident start/end/peak, physical footprint peak, compressed peak, headroom
  start/end/min, GPU allocated peak + recommended working set, `timeToPeakMS`, `sampleCount`.
- **Verbose raw series** — `verbose` mode writes every sample (`tMS`, residentMB,
  physFootprintMB, compressedMB, headroomMB, gpuAllocatedMB, threads, decorated `stage`/
  `chunkIndex`) to `engine/samples-<generationID>.jsonl` for full memory‑curve analysis.
  Off by default (higher volume).
- **Kernel memory‑pressure marks** (in `stageMarks`) — on the pressure‑bound tiers
  (`floor8GBMac` / `mid16GBMac` / `iPhonePro`, where `NativeMemoryPressureMonitor` runs):
  - `memory_pressure` — the **raw kernel signal** (`metadata.level` = `softTrim`/`hardTrim`),
    stamped by `NativeEngineRuntime.recordMemoryPressureObserved` the instant the
    `DispatchSource` event arrives. Always recorded — it takes no prewarm slot.
  - `memory_trim` — the **trim action** taken in response (`metadata.level` + `reason`, e.g.
    `macos_memory_pressure_hardTrim`, `post_batch_low_ram`). Written by
    `NativeEngineRuntime.trimMemory`; skipped if the prewarm slot is contended, hence the
    separate always‑on `memory_pressure` mark above.

  A run with a `hardTrim` mid‑generation is shedding model state under pressure — an early
  OOM signal. On a non‑pressure‑bound tier (high‑memory Mac) the monitor never starts, so
  these marks are absent (correct, not missing data). `headroom*` summary fields populate on
  iOS only (`os_proc_available_memory`); on macOS they're nil and `phys_footprint` is the
  OOM‑relevant figure to watch.

---

## 9. Overhead & observer effect

Designed so the numbers you optimize against are trustworthy.

- **Gated to zero when off.** No recorder, no sampler, no writes; per‑chunk capture is
  guarded by `telemetryRecorder != nil`.
- **Device‑tiered sampler cadence** (`NativeTelemetryMode.sampleIntervalMS(for:)`): high‑memory
  Mac 100 ms, 16 GB Mac 250 ms, **8 GB Mac / iPhone 500 ms** — the background sampler never
  competes with generation on constrained devices.
- **Per‑sample cost reduced.** The Metal device is resolved **once per generation** and
  reused (`IOSMemorySnapshot.capture` would otherwise allocate a fresh `MTLCreateSystemDefaultDevice()`
  every tick). A sample is a few `task_info`/mach calls + one cached‑device GPU read.
- **No hot‑path additions.** Writes happen at generation boundaries; the per‑chunk timeline
  is an in‑memory append, persisted once at the end; the engine‑service transport row is
  flushed off the publish loop. The unbounded macOS chunk stream is never blocked.
- **The backend timing reads do not add GPU syncs.** The `eval`/EOS‑read syncs that
  `qwen_stream_step_*` measure are required by generation itself — telemetry times existing
  work. Signposts are near‑zero when Instruments isn't attached.

Rule of thumb: compare like with like. A `verbose` run on an 8 GB Mac adds a 500 ms
sampler + a sidecar write; for the tightest latency numbers use `lightweight` and read
`derivedMetrics` + `timingsMS`.

---

## 10. Running & reading a benchmark

1. Launch with telemetry on: `QWENVOICE_DEBUG=1 ./scripts/build.sh run` (add
   `QWENVOICE_NATIVE_TELEMETRY_MODE=verbose` for the raw series).
2. Drive a generation via the `computer-use` MCP (see [`ui-driving.md`](ui-driving.md)) —
   **cold** (first run after launch / model switch) and **warm** (back‑to‑back) both matter.
3. Read the merged row:

```sh
DIR=~/Library/Application\ Support/QwenVoice-Debug/diagnostics
python3 - <<'PY'
import json, os
d = os.path.expanduser("~/Library/Application Support/QwenVoice-Debug/diagnostics")
row = json.loads(open(d+"/engine/generations.jsonl").read().splitlines()[-1])
print("finish:", row["finishReason"], "| streaming:", row["usedStreaming"])
print("KPIs:", row.get("derivedMetrics"))
print("decode breakdown:", {k: v for k, v in sorted(row.get("timingsMS", {}).items())})
print("chunks:", len(row.get("chunkTimeline") or []))
PY
```

```sh
# Stage timeline (cold runs show upstreamModelLoad / prewarm):
jq -c 'select(.layer=="engine") | .stageMarks[] | {tMS, stage}' "$DIR/engine/generations.jsonl" | tail -20
```

Cold vs warm: force cold by switching the model variant (unloads) or letting idle‑unload
fire; warm = immediate repeat. Compare `derivedMetrics.audioSecondsPerWallSecond` and the
dominant `timingsMS` substage across your before/after.

---

## 11. Reusable benchmark procedure (full matrix)

A repeatable, accurate sweep over **mode × model variant × cold/warm**. There is no committed
script harness or baseline (guard‑banned); the procedure drives the UI and reads the JSONL the
probes write, then aggregates with one read‑only helper. Each engine row self‑identifies its cell
via `mode`, `modelID` (variant‑specific), and `warmState` (`cold`/`warm`).

**Matrix:** 3 modes (Custom Voice / Voice Design / Voice Cloning) × 2 variants (Speed 1.7B 4‑bit /
Quality 1.7B 8‑bit) = 6 cells. Per cell: **1 cold + 3 warm** — **except Voice Cloning, which is
warm‑only by design** (see below): 4 warm samples per Clone cell.

**Voice Cloning is intentionally always warm.** Clone generation requires reference conditioning,
and the engine deliberately primes (loads + conditions) the clone model as part of servicing the
request — a deliberate latency optimization. So a Clone generation never runs against a cold model;
its rows correctly record `warmState=warm` and there is no separate Clone cold cell to measure. Do
not treat the absence of Clone `cold` rows as a bug. (Custom Voice and Voice Design have a genuine
cold path — the model loads inside the generation — so they get a real `cold` sample.)

**Accurate cold (Custom / Design) requires suppressing proactive warmup.** Otherwise prewarm loads
the model before you press Generate and the "cold" run records as `warm`. Launch with:

```sh
QWENVOICE_DEBUG=1 QWENVOICE_SUPPRESS_WARMUP=1 ./scripts/build.sh run
```

`QWENVOICE_SUPPRESS_WARMUP` (1/true/on/yes) skips all proactive warmup + clone priming
(`MacGenerationWarmupCoordinator.isSuppressed`), so the **first generation of a freshly‑loaded
package does — and records — its own cold load**. Leave it unset for normal use.

**Fixed corpus (keep it identical across runs):**
- One fixed script sentence for every mode (RTF + tokens/s are the text‑robust cross‑mode metrics;
  TTFC is the latency metric).
- Custom Voice: the default speaker. Voice Design: one fixed voice description. Voice Cloning: a
  pre‑enrolled saved voice — enroll one once from a Custom Voice output clip (no external audio).

**Driving each cell (computer‑use, see [`ui-driving.md`](ui-driving.md)):**
1. Select the mode (`sidebar_*`) and the variant — `{mode}_speedVariantButton` /
   `{mode}_qualityVariantButton`. Switching variant or mode forces the next load to be cold.
2. Type the fixed script; `cmd+Return`; wait for "Ready" / the inline Player.
3. That first run is the **cold** sample (`warmState=cold`). Repeat ×3 for the **warm** samples.

**Storage‑safe order (disk‑tight machines):** process one cell at a time — download that package
→ run cold + 3 warm → delete the package (`QwenVoice-Debug/models/<pkg>`) → next cell. Peak disk ≈
one package (~2.3–4 GB) instead of all six (~12–18 GB). If the **real** app already has the weights and
you want to avoid the re‑download, **copy** the package into `QwenVoice-Debug/models/` once (don't
symlink — the prepared‑cache overlay lives inside the model dir, so a symlink breaks the rebuild). To
benchmark *without* the debug‑folder isolation, run the real app with telemetry on
(`QWENVOICE_NATIVE_TELEMETRY_MODE=lightweight`, no `QWENVOICE_DEBUG`) — telemetry then lands in the real
`QwenVoice/diagnostics`; prune those rows afterward if you don't want them.

**Aggregate:**

```sh
python3 scripts/summarize_generation_telemetry.py
```

Prints a `mode × model × cold/warm` table (median over warm): RTF, tokens/s, TTFC, decode‑loop ms,
peak GPU / RSS MB, **`physFoot`** (phys_footprint peak — the Jetsam‑relevant OOM figure),
**`headMin`** (min available headroom; iOS‑only, `-` on macOS), and **`trims`** (median
`memory_trim` count for the cell, annotated with the worst level — `soft`/`hard`/`full`; derived
from `stageMarks`, no new record field). A header line shows the **tier** each row ran under (from
`notes.deviceClass`) and flags a forced tier. A second block — **GPU MB by stage** (`load → stream
→ peak → trim`, from `mlxMemoryByStage`) — shows *where* GPU memory grows across the pipeline and how
much the post‑generation trim reclaims. Read‑only; joins `engine/` + `app/` rows by `generationID`.
Pass a diagnostics dir as `$1` to summarize a different run. Compact **summaries may be committed**
under `benchmarks/` (≤256 KB each, **no raw `*.jsonl`** — guard‑enforced); they're reference logs, not
an auto‑compared baseline (those stay retired). Don't commit the raw diagnostics JSONL.

### Memory & pressure pass

RAM usage (physFoot/RSS/peak‑GPU + the per‑stage GPU block) is captured on **every** run. But the
**memory‑pressure** signals (`trims`/`pressure`) only fire on a pressure‑bound tier
(`floor8GBMac`/`mid16GBMac`/`iPhonePro`), and `deviceClass()` is derived from real RAM — so on a
high‑memory dev Mac they read `0`. To measure the constrained‑tier behavior (and pressure) **without
8 GB hardware**, force the tier:

```sh
QWENVOICE_DEBUG=1 QWENVOICE_FORCE_MEMORY_CLASS=floor_8gb_mac QWENVOICE_SUPPRESS_WARMUP=1 ./scripts/build.sh run
```

`QWENVOICE_FORCE_MEMORY_CLASS` (accepts `floor_8gb_mac`/`mid_16gb_mac`/`high_memory_mac`/`iphone_pro`,
or aliases `8gb`/`16gb`) is read in the app process and **propagated to the engine over the
`initialize` IPC handshake** (env doesn't cross to the engine process — same path as `telemetryMode`).
It makes the engine run the floor‑tier code paths: the pressure monitor **starts**, caches are tight,
single‑gen clears + post‑batch hard trims fire, and idle‑unload is aggressive. Every engine row stamps
`notes.deviceClass`, so the summarizer header shows `tier: floor_8gb_mac ⚠ forced` — never mistake a
forced run for native‑tier data.

To exercise **real kernel pressure** (so `memory_pressure` + pressure‑driven `memory_trim` marks
appear), induce it mid‑generation from a Bash shell while a take is running:

```sh
sudo memory_pressure -l warn      # or: -l critical
```

The forced‑tier monitor observes it and the marks land on that generation's timeline. Then
`python3 scripts/summarize_generation_telemetry.py` → confirm non‑zero `trims`/`pressure` and inspect
`physFoot` + the GPU‑by‑stage block.

> **Caveat:** on the forced floor tier, **Quality can be downgraded to Speed** by the OOM fallback in
> `loadModel(id:)`. The row's `modelID` reveals the actual variant served — check it before attributing
> a Quality cell. The forced tier changes real behavior **only while the env is set**; unset it for
> normal use.

**Watch for OOM regressions** when optimizing the backend: a rising `physFoot` peak, GPU‑stage peak,
or any `hardTrim` in `trims` means a run is shedding model state under pressure — the early OOM signal.

**Verify attribution:** for **Custom Voice and Voice Design**, each cold row must show
`warmState":"cold"` (and carry `upstreamModelLoad` in `stageMarks`); warm rows show `"warm"`. If a
Custom/Design "cold" row says `warm`, warmup suppression wasn't in effect — confirm
`QWENVOICE_SUPPRESS_WARMUP=1` reached the app launch. **Voice Cloning rows are always `warm`** — that
is correct (clone is warm‑by‑design, above), not a suppression failure.

### Tracking performance over time

As optimization advances, track the trend with **committed snapshots + on‑demand comparison** — there
is intentionally **no auto‑compared baseline gate** (the old comparison harnesses + baseline
manifests stay retired/guard‑banned; thresholds are a maintainer call).

Two committed artifacts under `benchmarks/` (compact, ≤256 KB, no raw `*.jsonl` — guard‑enforced):

1. **Per‑milestone snapshot** — save the full table before/after a change. `--label` stamps a note;
   the run is auto‑stamped with the date + short git SHA so the numbers tie to a commit:
   ```sh
   python3 scripts/summarize_generation_telemetry.py --label "stepeval fix" > benchmarks/2026-06-02-stepeval.md
   ```
2. **`benchmarks/HISTORY.md` ledger** — one compact row per run for the trend at a glance. The row is
   printed (read‑only); you redirect it to the end of the file:
   ```sh
   python3 scripts/summarize_generation_telemetry.py --ledger-row --label "stepeval fix" >> benchmarks/HISTORY.md
   ```
   Default headline cell is `custom/quality/warm`; pass `--cell mode/model/state` (model = substring)
   to track a different one. Columns: date · sha · cell · RTF · tok/s · TTFC · physFoot · trims · note.

**Compare** by `git diff`‑ing two snapshots (or ask the agent to diff the deltas and flag
regressions). For trustworthy deltas: **same machine, quiet (quit other apps), watch thermals**; keep
cold vs warm separate; compare **medians** of ≥3 warm; record the SHA. For MLX backend work the needle
to watch is the dominant `timingsMS` substage (e.g. `qwen_stream_step_eval_total`) alongside RTF.

### Guarding output quality

Perf is only half the story — a backend change must not introduce **audio** regressions (glitches,
dropouts, garbled words, "sounds worse"). Three layers, increasing in what they catch and what they cost:

1. **Reference-free defect detector — automatic, every run.** The engine runs a per-sample QC pass on
   the final PCM (extends `PCM16StreamLimiter`) and writes an `audioQC` verdict into the engine row:
   `pass` / `warn` / `fail` plus flags — `nonfinite` (NaN/Inf model output), `clipping`, `clicks`
   (chunk-boundary discontinuities — the decoder-drift class), `dropout:Nms` (mid-utterance silence),
   `near_silent` (dead output). Surfaced as the summarizer's **`QC`** column. **Any `fail` blocks
   promoting a backend change.** Thresholds are conservative + tunable (`makeAudioQCReport`).
2. **ASR content accuracy — opt-in.** Launch with `QWENVOICE_TRANSCRIPT_CHECK=1`: after each take the app
   transcribes it on-device (Apple Speech, no model download) and records word error rate vs the input
   text → the summarizer's **`WER%`** column. Catches garbled / wrong / dropped words. Needs the Speech
   permission + an on-device locale model; skips gracefully when unavailable. Adds latency — dev/QC only.
3. **Human/agent listening pass — mandatory before merging a backend change.** No automated check judges
   subtle perceptual quality (timbre, prosody, naturalness). Generate the fixed corpus, play each take
   (drive via computer-use, see [`ui-driving.md`](ui-driving.md)), and listen for hiccups/artifacts/
   quality. Record the verdict in the benchmark snapshot / `HISTORY.md` note. **This is the real quality
   gate — the objective tools are a fast tripwire, not a substitute for ears.**

Workflow: run the corpus → any `QC=fail` or spiking `WER%` is a hard stop (investigate before merging) →
otherwise do the listening pass → record pass/fail. (This deliberately replaces the retired Python
audio-QC harness with an in-engine, harness-free check.)

---

## 12. Extending the telemetry

- **New backend substage timing:** add a `ContinuousClock` accumulator in the Qwen3TTS
  decode loop (`third_party_patches/mlx-audio-swift/.../Qwen3TTS.swift`) and store it into
  the model's preparation‑timings dict — see [`mlx-audio-swift-patching.md`](mlx-audio-swift-patching.md)
  for the patch + validation gates. It will surface automatically in the engine row's
  `timingsMS` (the session re‑reads the model post‑loop). Avoid adding `eval()`/`.item()`
  syncs purely to measure — they distort the very thing you're measuring.
- **New stage mark:** add a `NativeRuntimeStage` case and `recorder.mark(stage:)` at the site
  (or a string‑keyed `recorder.mark(stage: "…")` for one‑off events like `memory_pressure` /
  `memory_trim` — no enum/schema change, the mark flows through `stageMarks` automatically).
- **New derived KPI:** extend `computeDerivedMetrics` in `NativeStreamingSynthesisSession`.
- **New field on the record:** add an optional field to `GenerationTelemetryRecord` (so old
  rows still decode) and bump `currentSchemaVersion`.
- **Naming:** do **not** introduce symbols containing `Probe`/`Benchmark` or the other tokens
  in `scripts/check_project_inputs.sh` — that guard fails the build. Use the `NativeTelemetry…`
  / `GenerationTelemetry…` families.

---

## 12. See also

- [`ui-driving.md`](ui-driving.md) — driving generations + reading timing out‑of‑band; signpost list for Instruments.
- [`mlx-audio-swift-patching.md`](mlx-audio-swift-patching.md) — vendored backend patch procedure + validation gates.
- [`privacy-storage.md`](privacy-storage.md) — where diagnostics live; deletion paths.
- Root `CLAUDE.md` — telemetry summary + engine invariants (unbounded macOS `events`, prewarm reentrancy, per‑tier memory).
