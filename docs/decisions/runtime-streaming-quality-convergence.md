# Runtime, streaming, and quality convergence

- **Status:** Accepted; Phase 4 overall promotion passed (Phases 0–6 closed 2026-07-20). Phases 7–14 remain open.
- **Date:** 2026-07-20
- **Owners:** Backend/MLX, macOS, iOS, and Release/QA
- **Machine contract:** [`config/runtime-refactor-contract.json`](../../config/runtime-refactor-contract.json)

## Glossary

| Term | Meaning |
| --- | --- |
| Qwen dual-track streaming | Official Qwen3-TTS hybrid path for low first-packet latency (CUDA-class demos; not Vocello’s API) |
| Vocello product streaming / preview | Early codec-frame chunks plus the frontend preview router that makes generation feel immediate |
| Lossless final channel | Actor-owned classified session drain through `GenerationOutputAdapter` to atomic WAV + Fast QC |

### Secret-sauce invariants

Keep early first/later codec frames, the preview-vs-lossless split, request-local sampling v2, tiered
`Memory.cacheLimit` with soft relief (no hard production `memoryLimit`), XPC engine isolation on
macOS, and the 1.7B Speed/Quality matrix. Do not chase A100 first-packet figures, reopen 0.6B, or
add Core ML / custom Metal during convergence. Latency/memory cells are named in
`config/characterization-fixtures.json` (`secretSauceCells`); roadmap cross-check:
[`docs/reference/qwen3-apple-silicon-roadmap-review.md`](../reference/qwen3-apple-silicon-roadmap-review.md).

## Context

The owned Qwen3 runtime is production-capable, memory-qualified, and covered by clean canonical
macOS and physical-iPhone evidence at the pre-convergence source identities. Its remaining risk
comes from authority split across product, runtime, and compatibility layers rather than from a
missing replacement backend. At the start of this program, XPC admission occurred after some side
effects, pressure state crossed isolation unsafely, final-audio events used mixed
`bufferingNewest` streams, sampling and memory used process globals, and model termination was
separated from final output publication only by convention.

The implementation blueprint reviewed on 2026-07-17 was grounded against the owned package and
product sources. Its convergence direction is accepted with these corrections:

- The existing inner Qwen generation gate remains defense-in-depth during migration.
- A runtime operation is not complete at model end. Product WAV finalization, Fast QC, atomic
  publication, public terminal, and an opaque finalization acknowledgment remain inside the same
  admission lease.
- Lossless audio requires a suspending, size-aware producer channel. Changing an `AsyncStream`
  buffer policy is insufficient.
- Request-local MLX random state is a separately versioned migration because fixed-seed output may
  change.
- Clone artifacts already use schema 3, and the current first/later stream schedule already exists.
- Disk component deduplication and in-memory decoder reuse are independent decisions.
- Existing three-pass ASR consensus remains the promotion authority; a one-pass diagnostic cannot
  replace it.
- Timing and memory thresholds remain candidate budgets until repeated clean controls establish
  measurement noise.

## Decision

Vocello will converge incrementally on one public actor-owned Qwen3 runtime. The actor owns loaded
model identity, prepared components, clone tensors, request-local random state, generation, trim,
and unload. Product code retains private text, output destinations, persistence, frontend delivery,
and quality publication. MLX arrays and mutable conditioning tensors never cross the runtime
boundary.

Generation uses reserve, bind, and open admission. A reservation creates no model task until the
mandatory product output adapter owns the single audio drain. The operation lease remains active
through model terminal and product finalization. Duplicate identical finalization acknowledgment is
idempotent; stale, conflicting, or cross-generation acknowledgment cannot release a later lease.

Core audio delivery becomes ordered, bounded by frames or audio duration, single-consumer, and
lossless. Prepared state is replay-latest, progress is monotonic and coalesced, diagnostics are
bounded and PCM-free, and terminal completion is independent. Critical memory relief closes
admission before cancellation and reopens it only after product cleanup and trim or unload.

Immutable plans use three privacy boundaries:

1. `ProductGenerationPlan` owns original/spoken text, local destination, output, and review policy.
2. `CoreGenerationPlan` owns only model-facing input and explicit runtime policy.
3. `GenerationEvidenceIdentity` contains only privacy-safe counts, versions, and digests.

Dependency-specific digests ensure an output-policy change cannot invalidate model preparation or
conditioning. The initial plan types are shadow-only and cannot run a second model generation.

## Delivery and rollback

Correctness prerequisites landed before actor/session cutover. Plans remain in comparison-only
shadow mode, while Custom, Design, and Clone now share the actor/classified-session/product-adapter
source path. The named `VocelloQwen3LegacyCompatibility` SPI remains only for prepared-model
load/prewarm and validated schema-3 conditioning adoption; it is not product generation authority.
Sampling, telemetry, preview calibration, component storage, long-form, and unified quality remain
separately promotable changes.

No permanent feature flag or dual backend is introduced. Each small pull request must leave `main`
releasable and is independently revertible. Protected remote history is the rollback surface; no
local Git bundle or migration tag is required.

## Promotion requirements

Runtime behavior changes require deterministic macOS/Core/XPC tests and iOS device-SDK compilation.
Mode cutover or shared generation changes additionally require explicit model-dependent focused and
full macOS/physical-iPhone evidence. Ordinary commits and merges remain deterministic-only.

Promotion must prove ordered complete final audio, one model and product terminal, readable atomic
WAV output, unchanged mandatory QC and language outcomes, qualified memory evidence, and no hard
trim or full unload. Performance budgets are derived from compatible clean repeated controls rather
than assumed from a single benchmark record.

## Non-goals

- Replacing the macOS XPC or iPhone in-process topology.
- Adding a second backend, permanent dual session, Simulator, or alternate UI driver.
- Upgrading MLX dependencies during convergence.
- Parallel model candidates, hidden retries, or hidden sampling/memory globals.
- Buffering full long-form audio or weakening autonomous three-pass language proof.
- Promoting decoder-object reuse or a speaker evaluator without isolated evidence and resource
qualification on the 8 GB support floor.

## Implementation checkpoint

The machine-readable contract distinguishes implemented shipping behavior from foundations that
must not yet be treated as product authority. At this checkpoint:

- XPC reserve-before-side-effects, synchronized pressure snapshots, and continuous critical-relief
  admission are implemented on the current product path.
- Sampling algorithm v2 and Qwen generation-memory behavior are request-local and shipping. Every
  request has an effective seed, independent talker/subtalker policy, explicit cache cadence and KV
  window; the process-global MLX RNG is not mutated. MLX allocator limits remain process-wide
  because that is the allocator API boundary, not request policy.
- Immutable product/core/evidence plans run in comparison-only shadow mode and never start a second
  model generation. Raw text, conditioning, and destination plans are non-encodable; only the safe
  evidence identity is serializable. The shipping runtime captures its resolved prompt, model,
  sampling, chunk, memory, output, and quality values independently before comparing every field.
- The engine actor, frame-bounded suspending channel, classified session, and stale-safe
  finalization acknowledgment now serve Custom, Design, and Clone product generation through
  QwenVoiceCore's `GenerationOutputAdapter`. Each lazy audio
  chunk is evaluated and copied to `[Float]` before an awaited channel send, so channel pressure
  suspends the actual Qwen token/decode loop without transferring `MLXArray` across isolation.
  Deterministic coverage includes delayed drains, receiver and producer cancellation, consumer
  failure, maximum-length ordering, bounded high-water evidence, and terminal/finalization lease
  ordering. `VocelloQwen3Engine` is the shipping generation-mutation authority; the old combined
  event session is package-internal. QwenVoiceCore imports `VocelloQwen3LegacyCompatibility` only
  for the remaining load/prewarm and conditioning bridge, so the actor is not yet described as the
  sole MLX mutator. The actor correctness closure remains complete:
  explicit reserved/generating/aborting ownership makes duplicate aborts join one finalization and
  rejects open after abort ownership begins; typed cache-trim/full-unload relief transfers the
  generation lease directly into critical relief and reopens admission only after that relief
  completes. Rejected atomic relief claims clear their ownership before session reconciliation, so
  ordinary finalization cannot strand the generation lease in either acknowledgment ordering.
  Epoch-bound Clone handles retain one prompt by default, use bounded LRU eviction when
  configured larger, support explicit fail-closed release, survive noncritical cache trim, and are
  invalidated by model reload, critical trim, or full unload. The source wiring, deterministic
  verification, and focused macOS Custom/Design/Clone acceptance have passed. Physical-iPhone runs
  `ios-xcui-benchmark-20260719-133203-d413fac1` (Custom 2/2),
  `ios-xcui-benchmark-20260719-134041-9653f7cf` (Design 2/2), and
  `ios-xcui-benchmark-20260719-134646-d90db984` (Clone 1/1) also passed with complete telemetry,
  Fast QC, readable output, and no crash delta. They are exploratory `passedWithWarnings` evidence
  because the worktree was dirty and soft trims were observed. Those focused runs closed Phase 4
  platform acceptance; clean Phase 0 controls, canonical 29-take matrices, Phase 5 packaging, and
  Phase 6 v9 sidecar authority later closed overall promotion on 2026-07-20
  (`overallPromotion: passed` in the machine contract).
- Production catalog schema v2 and the shared-component store are integrated into macOS, CLI, and
  iOS delivery. Exact verified content is published atomically, surfaced through ordinary hard
  links, and read alongside legacy schema-v1 installations. Delivery-plan resolution now
  authenticates and automatically migrates or repairs each existing installed artifact locally;
  live all-artifact proof remains pending, and runtime component-object reuse is still a separate
  experiment. Spoken-text/long-form schema-v4 planning and the two-pass bounded PCM16
  assembler are isolated foundations; neither is wired to the product coordinator. Manifest-v3
  non-streaming execution remains authoritative.
- The low-dependency prosody analyzer is now two-pass and bounded-memory, while the typed unified
  quality registry remains a foundation. Existing persisted-WAV Fast QC and specialized language,
  delivery, and prosody gates still own shipping decisions.
- Telemetry JSONL remains schema v8 with a nested transition projection. Publication-ready
  transitions with exact MLX chunk instants publish complete `*.streaming-telemetry-v9.json`
  sidecars; those sidecars are the history authority for streaming detail. Benchmark history
  schema v2 remains authoritative until Phase 13. Non-blocking layer gaps (`notApplicable`,
  aggregate-only transport list, missing player render callback) may remain listed.

Overall Phase 4 promotion is closed. The broader convergence program remains open for Phases
7–13 and for Phase 14 mechanical retirement of the named Legacy SPI, adapter filename, combined
characterization session, and Clone priming stream APIs.

## Amendment 2026-07-22 — characterization-gate resequencing (maintainer endorsed)

The R1 characterization gate (backend refactor review) proved the engine innocent of the
post-cutover canonical macOS RTF decline: interleaved CLI A/B benches across the cutover
(`9a8da874` vs `610125b7` vs HEAD) are flat at 1.02–1.17 while the app/XPC topology measures
0.69–0.81 on identical engine code — the engine is submission-starved in the delivery pipeline
(zero lossless-channel producer suspensions, normal thread priorities, ~83% of its command-buffer
timeline submission-side idle in a Metal System Trace). Because the Phase 0 promotion controls
were CLI-context short-cell runs, the topology-bound regression could not be seen by the gate
that passed. Three changes, recorded machine-readably in `amendment20260722` of
`config/runtime-refactor-contract.json`:

1. **Phase 7 is rescoped** from raw chunk/preview RTF experiments to the delivery-pipeline
   pacing fix (coalesce per-frame actor hops, move v9 per-chunk publication off the generation
   path, evaluate larger macOS chunk schedules), preserving first-preview latency and
   trim/unload safety.
2. **Promotion characterization matrices must include at least one UI/app-XPC-context cell**
   (`characterization.promotedMatrixRequiresUIContextCell`).
3. **Phase 14 mechanical retirement is pulled forward** to immediately after the phase 7–9
   block, before phases 10–13, so quality/long-form phases build against one topology.

## Amendment 2026-07-23 — observer-effect correction (supersedes the 07-22 diagnosis)

The phase 7 characterization program (`benchmarks/OPTIMIZATION.md` §J) found the dominant cause
of the canonical macOS UI decline outside the product entirely: XCUITest's default automatic
screen recording (`testmanagerd` → `VTEncoderXPCService`/`replayd`) video-encoded the display
through every UI take. With `preferredScreenCaptureFormat: screenshots` on both UI schemes
(`project.yml`), the one-cell custom/long lane moved from warm RTF 0.70–0.78 to **1.196** with
clean QC. Engine code remains exonerated (flat interleaved CLI A/B across the cutover), and true
Mac capability at the product's `-O` optimization measured **1.81** in an interactive CLI process
(all historical CLI benches were `-Onone` dev builds). Machine-readable record:
`amendment20260723`. Consequences:

1. **Phase 7's objective becomes the honest UI/XPC-context gap** (≈1.2 → ≈1.8) with recording
   disabled, instrumented by the new per-generation `processTaskRole`/`processMainThreadQOS`/
   `processNice` telemetry notes.
2. **Pre-2026-07-23 UI-generation records carry the recording overhead** in every cell and are
   not baselines for post-change comparisons (their comparison keys already differ).
3. **Three diagnostic engine-loop experiments were reverted** (generation-task priority pin,
   per-token `publishProgress` coalescing, dedicated `userInteractive` actor executor) after two
   intermittent Fast-QC hard failures appeared with them in-tree; 12/12 takes passed QC after
   the revert. Re-introducing any of them requires a fixed-seed QC soak.
4. The UI-context promotion-cell requirement and the phase 14 pull-forward from the 07-22
   amendment stand unchanged.
