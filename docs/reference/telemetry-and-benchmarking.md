# Telemetry & benchmarking

How Vocello measures itself. This is the single reference for the per‑generation
telemetry that spans the **frontend (app UI)**, the **middle communication layer
(macOS XPC service / iOS in‑process engine)**, and the **backend core (MLX / Qwen3‑TTS)** — what
is measured, where it lands, how to read it, and how it stays cheap enough to run on
restricted hardware (8 GB Macs, iPhone) without distorting the numbers you optimize
against.

If anything here disagrees with the code, the code wins — fix this file.

> Scope note: this covers the runtime telemetry that is the **default** benchmarking path —
> drive a generation, then read the JSONL this system writes + aggregate with
> `summarize_generation_telemetry.py`. Benchmarking + output‑quality checks are **first‑class**:
> committed benchmark/QC scripts, baselines, and summaries are permitted (bounded by the
> `benchmarks/` cap). macOS frontend acceptance is driven only by the repository
> `$vocello-macos-ui-qa` Computer Use skill; deterministic history/WAV/XPC/backend probes make its
> structured attestation gate-bearing. iOS UI tests and real-engine generation remain
> **on-device only** via `scripts/ios_device.sh`; mirroir is exploratory and GitHub CI
> (`.github/workflows/ci.yml`) is **compile-only** for iOS (`build-for-testing`, no XCUITest).
> See [`testing-runbook.md`](testing-runbook.md) and [`ios-device-testing.md`](ios-device-testing.md).

---

## 1. Principles

1. **Runtime‑gated, never compiled out.** There is one shippable config; dev and
   release run identical code (see root `AGENTS.md`). Telemetry is switched on at
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
| `QWENVOICE_NATIVE_TELEMETRY_MODE=lightweight\|verbose` (aliases: `light`, `full`, `deep`) | Forces sampling/persistence on regardless of the gate. |

The engine runs **out of process on macOS** (XPC service) and **in process on iOS**
(the ExtensionKit extension was removed; see `AGENTS.md` / commit `aed617c`). The
different bundle id means the app's `UserDefaults` flag still can't reach the macOS
engine via environment — it is carried on the handshake, where the host calls
`TelemetryGate.applyHandshakeMode(_:)`.

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
| `QWENVOICE_MAC_WARM_GATE=off\|records\|enforce` | macOS warm‑admission gate (`MacWarmupAdmissionPolicy`): defers **proactive** warms while the app‑process kernel pressure level is soft/hardTrim on floor/mid tiers. Default `enforce` (validated 2026‑06‑09); `records` logs verdicts without blocking; user generations are never gated. Events land in `diagnostics/app/native-events.jsonl`. |
| `QWENVOICE_ENGINE_RETIRE_DWELL_SECONDS=<n>` | Dev override for the XPC service retirement idle dwell (default 300 s) so retirement‑to‑reclaim can be exercised without the full wait. App‑process only. |
| `QWENVOICE_FAKE_MIC_WAV=<clip.wav>` | Virtual microphone for mic‑less machines — the record flow simulates capture from this clip (see [`macos-permissions.md`](macos-permissions.md)). |
| `QVOICE_TALKER_KV_QUANT=8\|4` | **Dev-only** opt‑in talker KV‑cache quantization (QuantizedKVCache, group 64). Measured (P4, §H): clone/long −271 MB physFoot but **−8.6% RTF** — not shipped on any tier; insurance knob only. Never combined with `QVOICE_TALKER_KV_WINDOW`. |
| `QVOICE_IOS_MLX_CACHE_LIMIT_MB=<n>` | **Dev-only** override of the MLX `Memory.cacheLimit` for the iPhone tier. Useful for sweeps; production uses the tier default. |
| `QVOICE_IOS_MLX_MEMORY_LIMIT_MB=<n>` | **Dev-only / do not ship** override of MLX `Memory.memoryLimit`. Production avoids a hard `memoryLimit`; see `mlx-guide.md` §5.2. |
| `QVOICE_IOS_SIM_DEVICE=iphone15pro` / `QVOICE_IOS_SIMULATED_PROCESS_LIMIT_MB=<n>` | **iPhone restriction simulation (memory dimension only)**: clamps the effective per‑process limit inside `IOSMemorySnapshot.capture()` so bands/admission/clone‑gate behave like the smaller device (`iphone15pro` → 5,000 MB, the conservative bottom of the 8 GB‑iPhone entitled band). Rows self‑stamp `notes.simulatedDevice`/`notes.simulatedProcessLimitMB`. GPU compute + thermals are NOT simulated — the real‑8GB‑device proof stays open (see ios‑engine-optimization.md §9). Convenience: `scripts/ios_device.sh bench --sim-device iphone15pro …`. |

---

## 3. Architecture

```
 App process (Vocello)                    Engine process (macOS XPC service / iOS in‑process engine)
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
| `*/native-events.jsonl` | engine/middle/app | Chunk‑sequence gaps + encode drops; the **app** file also carries `mac_warm_admission_observed` / `mac_warm_blocked` (warm‑admission gate) and `engine_service_retired` (XPC retirement) events. **Written only when telemetry is enabled** (`TelemetryGate.resolvedEnabled` / app-process intended mode). |
| `<documents>/generation-failures.jsonl` | debug | Append-only failure log when telemetry is on (see `GenerationFailureDiagnosticLogger`). |

One JSON object per line. Read with `jq` or Python (examples in [§10](#10-running--reading-a-benchmark)).

**Bounded by design.** These are append‑only but **size‑capped + auto‑pruned** (oldest‑first) by
`GenerationTelemetryJSONLSink`, so logs can't blow out disk: each `generations.jsonl` (incl. the merged
file) is front‑trimmed past ~8 MB (`QWENVOICE_DIAGNOSTICS_MAX_MB` scales it), and verbose
`samples-*.jsonl` sidecars are retained newest‑48 / ≤64 MB. No manual clearing needed for logs.

---

## 5. The per‑generation record schema

`GenerationTelemetryRecord` (schema v6). Optional fields are omitted from JSON when nil and
v1–v5 rows remain decodable.

| Field | Type | Notes |
|---|---|---|
| `schemaVersion` | Int | 6 (v2 derived/memory/chunk; v3 model/warm state; v4 audioQC; v5 high-resolution clock/stage metadata; v6 typed frontend/transport/backend/output payloads). |
| `clockSource` | String? | `mach_absolute_time` when nanosecond timestamps are present. |
| `generationID` | String | Correlation key (UUID). |
| `layer` | String | `engine` / `engine-service` / `app` / `merged`. (The retired iOS `engine-extension` layer no longer emits — iOS runs in-process.) |
| `mode` | String? | `custom` / `design` / `clone`. |
| `modelID` | String? | Resolved model variant id (e.g. `pro_custom_quality`). |
| `warmState` | String? | `cold` / `warm` — the benchmark cell. |
| `usedStreaming` | Bool? | Streaming vs quality‑first. |
| `finishReason` | String? | `eos` / `maxTokens` / `failed` / `superseded`. |
| `stageMarks` | `[{tMS, tNS?, sequence?, stage, metadata}]` | Lifecycle timeline with optional nanosecond timestamps and monotonic sequence numbers (see §6). |
| `frontendMetrics` | `FrontendGenerationMetrics?` | Typed submit/first-chunk/audible/completed and main-thread-stall metrics. |
| `transportMetrics` | `EngineTransportMetrics?` | Typed terminal/cancellation/lifecycle, opaque session identity, first/last sequence, forwarded/gap/duplicate/reordered counters and duration. |
| `backendMetrics` | `BackendGenerationMetrics?` | Typed lifecycle stages, warm/streaming state, finish reason, timing/counter enums, and final-chunk barrier. |
| `outputMetrics` | `GenerationOutputMetrics?` | Duration, readable-WAV verdict, atomic-publication verdict, and audio QC. |
| `timingsMS` / `counters` | compatibility maps | Generated compatibility output for existing summarizers and old rows; new validators consume typed v6 payloads. |
| `derivedMetrics` | `[String: Double]?` | Headline KPIs (see §7). Includes `kvCacheEstimatedPeakMB` (2026‑07‑01, audit P1‑2) — the peak of the per‑chunk KV‑cache footprint estimates, surfaced at row level so regression tooling doesn't walk the chunk timeline. |
| `mlxMemoryByStage` | `[String: {activeMB, cacheMB, peakMB}]?` | MLX GPU memory at each stage (see §8). |
| `chunkTimeline` | `[GenerationChunkTelemetry]?` | Per‑chunk decode substages, with `arrivalNS` (v5) and optional `mimiDecoderBreakdownMS` (v5) (see §6.3). |
| `audioQC` | `AudioQCReport?` | Reference‑free quality verdict + flags, plus defect sample offsets and optional per‑chunk QC (`chunkQC`) in verbose mode (see "Guarding output quality"). |
| `summary` | `TelemetrySummary?` | Process memory curve summary (see §8). `timeToPeakMS` tracks the **physFootprint** peak (the Jetsam‑relevant figure; falls back to RSS only when phys_footprint is unavailable — audit P1‑4, 2026‑07‑01). |
| `notes` | `[String: String]` | Bounded compatibility metadata such as `deviceClass`, `promptChars`, and memory pressure. Raw script, transcript, voice description, file path, and failure message are forbidden; failures use length + SHA-256 digest. |
| `recordedAt` / `processName` / `processIdentifier` | | Provenance. |

---

## 6. Backend (MLX) timing — the optimization data

### 6.0 os_signpost interval mirrors (`timingsMS`)

In addition to the MLX decode counters, v5 records the client/server boundary
intervals captured by `NativeTelemetrySignpostInterval` so a JSONL row can be read
back into Instruments‑style spans without the trace file:

| Key | Meaning |
|---|---|
| `clientWaitMS` | Time from user submit to the engine accepting the request. |
| `requestMS` | Engine total request wall time. |
| `serverGenerationMS` | Core model generation (token loop + decode). |
| `outputStreamingMS` | From first output byte to stream complete. |
| `totalMS` | End‑to‑end request span. |

These are optional and only emitted when the corresponding signpost interval was logged.

### 6.1 Stage timeline (`stageMarks`)

Coarse milestones for one generation, in ms from generation start (the recorder and the
memory sampler **share one high‑resolution `NativeTelemetryClock`**, so marks and samples
align on both ms and ns timelines). Each mark carries `tMS`, optional `tNS`
(nanoseconds since start), and a monotonic `sequence` number. `metadata` values are
typed (`string`/`int`/`double`/`bool`) in v5, while remaining JSON‑serializable.
Stages (`NativeRuntimeStage`): `preparedCacheValidation`, `tokenizerPreparation`,
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
wall‑clock arrival. Mirrors the vendored `ChunkSubstageTimings`:
`talkerForwardMS`, `codePredictorMS`, `audioDecoderMS`, `streamStepEvalMS`,
`streamStepEOSReadMS`, `audioChunkEvalMS`, plus `chunkIndex`, `arrivalMS`, and in v5
`arrivalNS` (nanosecond resolution from `NativeTelemetryClock`). In v5 verbose mode,
`mimiDecoderBreakdownMS` further splits the chunk decode into `quantizer`, `transformer`,
`upsample`, `seanet`, and `output` (coarse stage clocks around the Mimi decoder). This
exposes **cold‑start vs steady‑state** behavior and localizes stalls to a substage and a
chunk. Captured cheaply (a small struct appended per chunk, only when telemetry is on) and
written once at generation end.

---

## 7. Derived KPIs (`derivedMetrics`)

Computed once at generation end from data already gathered — the headline numbers for
backend throughput:

| Key | Definition | Read as |
|---|---|---|
| `audioSeconds` | Generated audio duration (frames ÷ sample rate). | Output length. |
| `decodeWallSeconds` | Decode wall time (`qwen_token_loop_total` when present, else model `.info.generateTime`, else `streamStartup→streamGenerationEnded` span). Excludes WAV finalize I/O. | Compute cost — **same time base as the summarizer `decode ms` column.** |
| `audioSecondsPerWallSecond` | `audioSeconds ÷ decodeWallSeconds`. | **Real‑time factor: >1 = faster than realtime.** Primary throughput KPI. |
| `tokensPerSecond` | Codec tokens ÷ decode wall seconds (from `.info` when present). | Decode throughput; compare across model variants / patches. |
| `generatedTokenCount` | Codec tokens produced. | Work done; normalize other metrics by this. |

Time‑to‑first‑audio (perceived latency) is the **app** row's `submitToFirstChunkMS` /
`submitToFirstAudibleMS`; the engine row's `firstChunk` stage mark is the backend‑only
portion.

### RTF vs `decode ms` (read together, don't diff naively)

The summarizer prints **RTF** from `derivedMetrics.audioSecondsPerWallSecond` and **decode
ms** from `timingsMS.qwen_token_loop_total`. As of the P0‑1 alignment, both prefer the same
token‑loop wall clock when `qwen_token_loop_total` is present.

Caveats that still apply:

- **Lazy MLX** — substage columns (`talkerForward`, `codePredictor`, `streamStepEval`, Mimi
  decoder) measure Swift wall time around lazy graph ops; they sum to less than
  `qwen_token_loop_total` when work is pipelined across iterations.
- **`.info.generateTime`** — emitted mid‑stream before the trailing decoder flush; retained
  only as a fallback. When it differs from the token loop, `qwen_stream_decoder_drain_ms`
  captures the gap.
- **Stage marks** — `streamGenerationEnded` closes before WAV finalize; do not compare
  `streamStartup→streamCompleted` to decode ms (finalize I/O inflates the old span).

Use **RTF** for release throughput gates; use **decode breakdown + chunk timeline** for
where time goes; use **Instruments signposts** (see [`benchmarking-procedure.md`](benchmarking-procedure.md)
§4.8) for GPU attribution.

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
2. Drive a generation from the UI or via the `vocello` CLI — **cold** (first run after launch /
   model switch) and **warm** (back‑to‑back) both matter.
3. Read the merged row (engine-only for CLI; use `--merged` for macOS XPC UI bench):

```sh
python3 scripts/summarize_generation_telemetry.py "$DIR" --merged --show-variance
```

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

> **Operator runbook:** Step-by-step workflows, platform topology (CLI vs macOS XPC vs iOS device),
> preflight, artifact map, and troubleshooting live in
> [`benchmarking-procedure.md`](benchmarking-procedure.md). This section retains the matrix
> semantics and manual UI procedure; the runbook is the preferred entry point for agents and release QA.

> **Primary driver — the `vocello` CLI (headless, deterministic).**
> `./scripts/build.sh cli bench --lengths short,medium,long --warm 3` drives this entire matrix
> in‑process (cold/warm controlled exactly via load/unload — no UI waits, focus races, or engine‑busy
> rejections) and runs the aggregator automatically. It **replaced computer‑use UI‑driving** as the
> benchmark/test driver. Engine telemetry rows (RTF / decode / memory / `audioQC` / `promptChars`) are
> identical to the app path; the CLI bypasses XPC, so the app/XPC frontend row is absent and the
> summarizer's end‑to‑end **TTFC shows `-`** (engine‑only boundary — what backend optimization targets).
> `vocello bench` and `vocello generate` now stream by default. To measure first‑chunk latency, just
> use `vocello generate` or `vocello bench --ttfc` (an engine‑side warm probe per cell → a table +
> `diagnostics/bench-ttfc.json`); both report engine TTFC,
> not the app's through‑XPC buffered TTFA.
>
> One‑command flags fold in the manual workflow below: `--label "<note>"` stamps the summary,
> `--ledger` appends a row to `benchmarks/HISTORY.md`, `--force-class 8gb|16gb|high|iphone` forces a
> constrained tier on any Mac (the `QWENVOICE_FORCE_MEMORY_CLASS` knob), and `--telemetry verbose`
> writes the raw per‑sample sidecars. Full CLI reference: [`cli.md`](cli.md). The computer‑use UI
> procedure below is retained for manual/visual runs only.

A repeatable, accurate sweep over **mode × model variant × cold/warm**. The `vocello` CLI above is the
default driver; the **manual UI procedure below** drives the app by hand and reads the JSONL the probes
write, then aggregates with the read‑only helper (it's retained for visual/interactive runs — committed
benchmark scripts + baselines are permitted if you want to automate it further). Each engine row
self‑identifies its cell
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

**Driving each cell (frontend):**
1. Select the mode (`sidebar_*`) and the variant — `{mode}_speedVariantButton` /
   `{mode}_qualityVariantButton`. Switching variant or mode forces the next load to be cold.
2. Type the fixed script; `cmd+Return`; wait for "Ready" / the inline Player.
3. That first run is the **cold** sample (`warmState=cold`). Repeat ×3 for the **warm** samples.
   macOS: `$vocello-macos-ui-qa benchmark` drives the exact app and the shell harness joins typed
   app/XPC/backend rows before accepting the take. iOS: `VocelloiOSUITests` drives real generation on a paired iPhone via
   `scripts/ios_device.sh` (see [`testing-runbook.md`](testing-runbook.md)).

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

The summarizer is streaming (it walks JSONL once with `iter_jsonl`, maintains a lightweight
app index, and aggregates with `CellAccumulator`) so it handles large verbose logs without
loading them into memory. Prints a `mode × model × cold/warm` table (median over warm): RTF, tokens/s, TTFC, decode‑loop ms,
peak GPU / RSS MB, **`physFoot`** (phys_footprint peak — the Jetsam‑relevant OOM figure),
**`headMin`** (min available headroom; iOS‑only, `-` on macOS), and **`trims`** (median
`memory_trim` count for the cell, annotated with the worst level — `soft`/`hard`/`full`; derived
from `stageMarks`, no new record field). A header line shows the **tier** each row ran under (from
`notes.deviceClass`) and flags a forced tier. A second block — **GPU MB by stage** (`load → stream
→ peak → trim`, from `mlxMemoryByStage`) — shows *where* GPU memory grows across the pipeline and how
much the post‑generation trim reclaims. A third block — **Decode breakdown** (`talker · sampCB0 ·
codePred · code2wav · stepEval · other`, from the `timingsMS` sub‑keys; named + other ≈ decode ms) —
splits the decode loop. ⚠ These are Swift‑side wall‑clock timers around **lazy** MLX ops, not per‑stage
GPU compute: `talker`/`codePred` measure graph‑*build* time, the single per‑frame `eval()` makes
`stepEval` the *fused* compute of Talker+CodePredictor+sampling, and `code2wav`≈0 because the decoder is
`asyncEval`'d (Phase 2c) and overlaps the token loop (pipelined, not free). To attribute compute per
stage, capture the os_signpost intervals under Instruments `xctrace`. Read‑only; joins `engine/` +
`app/` rows by `generationID`.
Pass a diagnostics dir as `$1` to summarize a different run. Compact **summaries (and baselines) may be
committed** under `benchmarks/` (≤256 KB each, **no raw `*.jsonl`** — guard‑enforced); don't commit the
raw diagnostics JSONL. Comparison stays manual/agent‑driven (`git diff`) — there's no auto‑compared
baseline *gate*, but committing a baseline file for reference is fine.

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
or aliases `8gb`/`16gb`/`high`/`iphone`) is read in the app process and **propagated to the engine over the
`initialize` IPC handshake** (env doesn't cross to the engine process — same path as `telemetryMode`).
It makes the engine run the floor‑tier code paths: the pressure monitor **starts**, caches are tight,
single‑gen clears + post‑batch hard trims fire, and idle‑unload is aggressive. Every engine row stamps
`notes.deviceClass`, so the summarizer header shows `tier: floor_8gb_mac ⚠ forced` — never mistake a
forced run for native‑tier data.

To exercise kernel pressure (so `memory_pressure` + pressure‑driven `memory_trim` marks appear),
fire a **simulated pressure notification** mid‑generation from a shell while a take is running:

```sh
sudo memory_pressure -S -l warn      # or: -S -l critical
```

`-S` sends a one‑shot notification to every subscribed process and auto‑resets ~1 s later (it needs
sudo — without it the trigger sysctl fails with "Operation not permitted"). **Plain `-l warn` does
NOT work for this**: it allocates real memory and raises the kernel level, but dispatch‑source
monitors never receive a notification, so nothing lands in telemetry (verified 2026‑06‑09).
The monitor observes the simulated event and the marks land on that generation's timeline. Then
`python3 scripts/summarize_generation_telemetry.py` → confirm non‑zero `trims`/`pressure` and inspect
`physFoot` + the GPU‑by‑stage block.

> **Caveat:** on the forced floor tier, a Quality load that cannot fit will surface as an error rather
> than silently falling back to Speed. The row's `modelID` reveals the actual variant served — check it
> before attributing a Quality cell. The forced tier changes real behavior **only while the env is set**;
> unset it for normal use.

**Watch for OOM regressions** when optimizing the backend: a rising `physFoot` peak, GPU‑stage peak,
or any `hardTrim` in `trims` means a run is shedding model state under pressure — the early OOM signal.

**Verify attribution:** for **Custom Voice and Voice Design**, each cold row must show
`warmState":"cold"` (and carry `upstreamModelLoad` in `stageMarks`); warm rows show `"warm"`. If a
Custom/Design "cold" row says `warm`, warmup suppression wasn't in effect — confirm
`QWENVOICE_SUPPRESS_WARMUP=1` reached the app launch. **Voice Cloning rows are always `warm`** — that
is correct (clone is warm‑by‑design, above), not a suppression failure.

### Tracking performance over time

As optimization advances, track the trend with **committed snapshots + on‑demand comparison**. There's
intentionally **no auto‑compared baseline *gate*** (no build fails on a regression — thresholds are a
maintainer call), but committed baselines, comparison scripts, and snapshots are all permitted under
`benchmarks/` if you want to automate the comparison.

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
   to track a different one. Columns: date · sha · cell · RTF · tok/s · TTFC · physFoot · trims · QC ·
   note · uiMaxStall ms (trailing, added 2026‑06 — max main‑thread stall during the generation; `—`
   for CLI bench rows, which have no UI process).

**Compare** by `git diff`‑ing two snapshots (or ask the agent to diff the deltas and flag
regressions). For trustworthy deltas: **same machine, quiet (quit other apps), watch thermals**; keep
cold vs warm separate; compare **medians** of ≥3 warm; record the SHA. For MLX backend work the needle
to watch is the dominant `timingsMS` substage (e.g. `qwen_stream_step_eval_total`) alongside RTF.

### Guarding output quality

Perf is only half the story — a backend change must not introduce **audio** regressions (glitches,
dropouts, garbled words, "sounds worse"). Two layers, increasing in what they catch and what they cost:

1. **Reference-free defect detector — automatic, every run.** The engine runs a per-sample QC pass on
   the final PCM (extends `PCM16StreamLimiter`) and writes an `audioQC` verdict into the engine row:
   `pass` / `warn` / `fail` plus flags — `nonfinite` (NaN/Inf model output), `clipping`, `clicks`
   (chunk-boundary discontinuities — the decoder-drift class), `dropout` (interior silence),
   `near_silent` (dead output). Surfaced as the summarizer's **`QC`** column. **Any `fail` blocks
   promoting a backend change.** Thresholds are conservative + tunable (`makeAudioQCReport`).
   **Dropout is punctuation-aware** (calibrated 2026-05-31): the model emits a prosodic pause at each
   sentence/clause boundary, so on long, slow content interior silences legitimately reach ~800 ms — a
   fixed ≥400 ms fail line cried wolf on natural delivery (every long-content silence mapped to a
   punctuation mark). Instead the detector counts *long pauses* (≥350 ms) against the text's **pause
   budget** (interior punctuation boundaries, from `request.text`) and flags only an **excess** beyond it
   (`dropout:excessN(long/budget)` — ≥2 = fail, 1 = warn) or a single **egregious** gap no natural pause
   reaches (≥1200 ms = fail `dropout:Nms`; ≥900 ms = warn). A genuine mid-phrase gap that merely *replaces*
   a punctuation pause (same count, ~same length) is positionally indistinguishable from a comma pause by
   amplitude alone — that residual is **ear-only**, so the listening pass below stays its gate.
   In v5 `audioQC` also reports **defect sample offsets** for debugging: `firstNonFiniteSample`,
   `firstClipSample`, and `longestSilenceStartMS`. In verbose mode the streaming path captures
   `chunkQC: [AudioQCChunkReport]` so defects can be tied to an individual output chunk.
2. **Automated prosody gate — every run, no external model.** `scripts/prosody_quality_gate.py`
   analyzes each take for monotone, rushed, flat, and pause-issue signatures; `scripts/delivery_adherence.py`
   measures paired neutral-vs-instructed deltas for delivery cells. These are deterministic, reference-free,
   and run on the bench WAVs directly. With `vocello bench --delivery`, the summarizer also surfaces
   `prosEff` / `dF0Std` / `dRateCV` / `dPauseR` / `dRough` in the delivery table.
   A JSON **prosody profile** (`scripts/prosody_profile.py`) supplies thresholds and delivery-effect
   weights; calibrate one from a labeled corpus with `scripts/prosody_calibration.py`, then pass it to
   `vocello bench --delivery --prosody-profile path/to/profile.json`. The built-in profile is used when
   none is supplied.
3. **Listening pass — mandatory before merging a backend change.** No automated check judges subtle
   perceptual quality (timbre, prosody, naturalness). Play each take and listen for hiccups/artifacts;
   record the verdict in the snapshot / `HISTORY.md` note. The objective `audioQC` + prosody gates are
   fast tripwires, not substitutes for ears.

Workflow: run the corpus → any `QC=fail` is a hard stop (investigate before merging) → inspect prosody
gate output → do the manual listening pass → record pass/fail. (The in-engine `audioQC` is the harness-free
default; committed quality-check scripts/baselines under `benchmarks/` are also permitted.)

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
  In v5 prefer typed metadata (`recorder.mark(stage:, metadata:)`) over string formatting for
  numeric metadata.
- **New derived KPI:** extend `computeDerivedMetrics` in `NativeStreamingSynthesisSession`.
- **New signpost interval:** wrap the span with `NativeTelemetrySignpostInterval.begin/end`
  and merge the resulting key into `timingsMS`.
- **New field on the record:** add an optional field to `GenerationTelemetryRecord` (so old
  rows still decode) and bump `currentSchemaVersion`.
- **Naming:** do **not** introduce symbols containing `Probe`/`Benchmark` or the other tokens
  in `scripts/check_project_inputs.sh` — that guard fails the build. Use the `NativeTelemetry…`
  / `GenerationTelemetry…` families.

---

## 13. See also

- [`mlx-audio-swift-patching.md`](mlx-audio-swift-patching.md) — vendored backend patch procedure + validation gates.
- [`privacy-storage.md`](privacy-storage.md) — where diagnostics live; deletion paths.
- [`.agents/backend-mlx.md`](../../.agents/backend-mlx.md) — telemetry summary + engine invariants (unbounded macOS `events`, prewarm reentrancy, per‑tier memory).
