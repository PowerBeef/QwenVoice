# Runtime, streaming, and quality convergence

- **Status:** Accepted as a staged convergence program
- **Date:** 2026-07-17
- **Owners:** Backend/MLX, macOS, iOS, and Release/QA
- **Machine contract:** [`config/runtime-refactor-contract.json`](../../config/runtime-refactor-contract.json)

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

Correctness prerequisites land before actor/session cutover. Plans and actor state first operate in
shadow or compatibility mode. Custom, Design, and Clone then cut over independently, each with
deterministic proof and focused platform acceptance. Sampling, telemetry, preview calibration,
component storage, long-form, and unified quality remain separately promotable changes.
Compatibility mode uses the named `VocelloQwen3LegacyCompatibility` SPI for the unchanged shipping
bridge; it is outside the normal public facade mutation boundary and is not a second product backend.

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
- The engine actor, frame-bounded suspending channel, classified session, stale-safe finalization
  acknowledgment, atomic WAV output sink, and typed quality registry are compiled foundations.
  The engine drives a direct caller-isolated Custom, Design, or Clone producer. Each lazy audio
  chunk is evaluated and copied to `[Float]` before an awaited channel send, so channel pressure
  suspends the actual Qwen token/decode loop without transferring `MLXArray` across isolation.
  Deterministic coverage includes delayed drains, receiver and producer cancellation, consumer
  failure, maximum-length ordering, bounded high-water evidence, and terminal/finalization lease
  ordering. Phase 2's normal public mutation boundary is complete as a non-shipping foundation:
  `VocelloQwen3Engine` owns mutation, loaded-model/stream/clone/load/cache adapters are quarantined
  under `VocelloQwen3LegacyCompatibility`, and the old combined event session is package-internal.
  QwenVoiceCore imports that SPI only for the unchanged shipping bridge. This is API-boundary
  completion, not mode cutover or actor promotion. The actor correctness closure is also complete:
  explicit reserved/generating/aborting ownership makes duplicate aborts join one finalization and
  rejects open after abort ownership begins; typed cache-trim/full-unload relief transfers the
  generation lease directly into critical relief and reopens admission only after that relief
  completes. Rejected atomic relief claims clear their ownership before session reconciliation, so
  ordinary finalization cannot strand the generation lease in either acknowledgment ordering.
  Epoch-bound Clone handles retain one prompt by default, use bounded LRU eviction when
  configured larger, support explicit fail-closed release, survive noncritical cache trim, and are
  invalidated by model reload, critical trim, or full unload. Custom, Design, and Clone still
  require product wiring and focused macOS and physical-iPhone acceptance before the compatibility
  product session can be retired.
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
- Telemetry v8 and benchmark history v2 remain authoritative. New v8 rows embed a partial v9
  transition projection with safe shadow-plan/policy digests and explicit unavailability reasons,
  but complete v9 actor/session/output-adapter capture, merging, validation, and publication remain
  pending until those product paths stabilize.

This explicit split prevents a compiled foundation from being mistaken for completed convergence.
The full program remains open until the superseded compatibility authorities are removed and clean
canonical platform evidence passes for the converged runtime.
