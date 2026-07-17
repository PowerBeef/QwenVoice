# Vocello development checkpoint

> Current maintainer checkpoint. Confirm this summary against the checkout before acting; source,
> `project.yml`, and repository scripts remain authoritative.

## Runtime convergence status — reviewed 2026-07-17

This audit covers the in-progress convergence checkpoint branch based on
`5bafd639f890e39307aef717939badf667b7da72`. “Foundation” means deterministic code and tests exist;
it does not mean the product uses that path. `config/runtime-refactor-contract.json` is the
machine-readable status record.

| Plan phase | Current state |
| --- | --- |
| 0 — Characterization | Partial. The ADR, contract, and model-free fixtures exist; exact shipping-path mode/token/PCM and manifest-v3 long-form fixtures plus the required clean 3-control, 10-warm, and 3-cold measurements are pending. |
| 1 — Correctness prerequisites | Shipping. XPC reserves before side effects, pressure snapshots are synchronized, and critical relief holds admission continuously through cancellation, terminal cleanup, and relief. |
| 2 — Plans and actor | Complete non-shipping foundation. Immutable plans run in shipping shadow comparison; load, prewarm, direct generation, cache relief, and unload are actor-isolated foundations. Reserved/generating/aborting ownership makes concurrent aborts join one finalization, while typed cache-trim/full-unload relief transfers the generation lease without reopening critical admission. Actor-owned Clone prompts use a one-handle default LRU, explicit fail-closed release, benign-trim preservation, and critical-trim/full-unload invalidation. The loaded-model shipping bridge is quarantined behind the named `VocelloQwen3LegacyCompatibility` SPI and the old combined event session is package-internal; none of this changes shipping authority. |
| 3 — Classified sessions | Complete non-shipping foundation. Custom, Design, and Clone have a direct caller-isolated Qwen producer that materializes `[Float]` before an awaited, frame-bounded channel send. Producer/receiver cancellation, delayed drains, maximum-length ordering, consumer failure, typed terminal outcomes, and stale-safe finalization are covered deterministically. Mutable speech tokenizer/decoder state is model-local; the only global prepared-component cache contains the immutable text tokenizer. |
| 4 — Product adapter and mode cutover | Not cut over. The adapter, atomic WAV sink, and Fast-QC finalization foundation exist, but Custom, Design, and Clone still need product wiring and focused macOS/iPhone acceptance. |
| 5 — Request-local sampling | Shipping. Algorithm v2 is request-local; it still requires fixed-seed live promotion evidence and shipping long-form/candidate sub-seed integration. |
| 6 — Telemetry v9 | Transitional. Schema/types/tests and a partial v9 projection inside v8 exist; the complete writer, merger, validator, publisher, and shipping actor/session observations do not. |
| 7 — Chunk and preview experiments | Not started beyond prerequisites. Shipping v9 evidence, controlled A/B runs, audio-graph preparation experiments, and identity-bound calibration are pending. |
| 8 — Shared component storage | Production-integrated with deterministic coverage. Live validation across all six macOS artifacts and all three iPhone Speed artifacts is pending. |
| 9 — Runtime component reuse | Not started. Decoder/immutable-weight reuse remains an optional isolated A/B after disk-component proof. |
| 10 — Spoken-text planning | Model-free foundation only; it is not shadowed against or used by shipping generation. |
| 11 — Long-form v4 | Planner and bounded assembler foundations only. Sequential streaming, resume/replacement, segment QA, History integration, and product cutover are pending; manifest-v3 non-streaming remains shipping. |
| 12 — Bounded analysis and unified quality | Partial. Bounded prosody algorithm v2 is shipping; persisted-WAV consolidation and the typed registry/scheduler are not integrated. |
| 13 — Benchmark/history v3 | Not started; schema v2 remains authoritative until shipping plan/session/quality identities stabilize. |
| 14 — Organization and retirement | Deferred final phase. Shipping compatibility authorities, the named legacy SPI and its direct loaded-model APIs, the internal combined event session, the old segmenter/writer, and large source files remain until the cutovers pass. |

Latest deterministic proof for this checkpoint passed 243 Core tests, 15 XPC integration tests,
and 98 owned-runtime tests. The arm64 macOS build completed at `2026-07-17T18:27:29Z`; the generic
physical-device SDK app and policy-test compile completed at `2026-07-17T18:30:01Z`. Runtime,
documentation, vendor, build-output, and benchmark-history contracts pass. No model generation,
XCUITest, benchmark, or physical-iPhone promotion run has been performed for this convergence
worktree.

## Current implementation

- Native app UI acceptance uses one shared XCUITest stack: `macos smoke|benchmark` on the native
  Mac host and `ios smoke|benchmark` on a paired physical iPhone.
- UI execution is explicit frontend QA. It is not required to commit, push, open or merge a pull
  request, run ordinary CI, package a release, or create an iOS archive.
- The ordinary iOS compile lane now typechecks both the app and a standalone app-host-free policy
  XCTest bundle for the generic physical-device SDK. It covers catalog/ledger, memory policy,
  cancellation, storage-path gating, and diagnostic redaction without a phone. Xcode 26 rejects
  tool-hosted app-free XCTest execution on physical-device destinations, so this target remains
  compile-only and device runtime proof stays in the headless diagnostics and XCUITest lanes.
- The physical-iPhone smoke contract now covers two distinct cancellation paths. It first cancels
  one active stream through the genuine visible Cancel control, then relaunches with the registered
  one-shot critical-memory diagnostic, requires typed `memory_pressure` cancellation to complete
  before `fullUnload`, and proves the same engine surface can complete a subsequent generation.
  Pulled run-scoped diagnostics own the pressure-event ordering verdict; unknown toggle values fail
  closed and are never tapped. Physical-iPhone run
  `ios-xcui-smoke-20260716-172350-2c6828e1` passed the expanded contract: the visible user
  cancellation and typed critical-memory cancellation both terminated without entering History,
  `fullUnload` followed the pressure cancellation, and the same engine completed and persisted the
  recovery generation.
- Generation ownership is now explicit across all hosts. Both platform streams are bounded
  (`bufferingNewest(256)` on macOS, `bufferingNewest(96)` on iOS) and every yield outcome is
  measured. `ActiveGenerationCoordinator` admits one active task, carries typed user,
  memory-pressure, superseded, or shutdown cancellation, and awaits the cancelled terminal barrier
  before trim, unload, ownership release, or persistence.
- The runtime/streaming convergence program is active under
  `config/runtime-refactor-contract.json` and
  `docs/decisions/runtime-streaming-quality-convergence.md`. Its correctness prerequisites are in
  the current product path: macOS XPC reserves before creating generation side effects, pressure
  snapshots are synchronized, and critical relief closes admission continuously from cancellation
  through terminal cleanup and trim. Immutable product/core/evidence plans also run in independent
  shadow comparison, but shadow mode never starts a second model generation.
- Sampling algorithm v2 and Qwen generation-memory policy are shipping request-owned contracts.
  Every request records an effective seed and uses a fresh `MLXRandom.RandomState`; independently
  configurable talker/subtalker sampling and per-request cache cadence/window policy no longer rely
  on mutable generation globals. Existing canonical schema-v2 benchmarks predate this runtime
  change and remain valid historical evidence only; fresh promotion evidence is required after the
  convergence cutovers stabilize.
- `VocelloQwen3Engine`, classified session channels, the product output adapter, telemetry-v9
  schema and transition types, schema-v4 spoken/long-form planning, the bounded two-pass joined-WAV
  assembler, and the unified quality registry are implemented as deterministic foundations, not
  shipping authorities. The actor foundation now drives a direct caller-isolated Qwen producer for
  Custom, Design, and Clone. Lazy MLX audio is evaluated and copied to `[Float]` before the producer
  awaits the size-aware channel, so a delayed mandatory drain backpressures the actual token/decode
  loop without moving an `MLXArray` across a task or actor boundary. Receiver cancellation and
  consumer failure wake blocked producers; terminal state cannot release the operation lease until
  product finalization is acknowledged. Mutable speech tokenizer/decoder state is owned by each
  loaded model; the shared prepared-component registry caches only the immutable text tokenizer.
  The normal public mutation boundary is now `VocelloQwen3Engine`. The unchanged shipping bridge
  reaches loaded-model, stream, clone-artifact, load, and cache adapters only through the named
  `VocelloQwen3LegacyCompatibility` SPI, while the old combined event session is package-internal.
  This completes the Phase 2 API boundary as a non-shipping foundation; it does not promote the
  actor or change product authority.
  The actor's remaining correctness gaps are also closed: `reserved`, `generating`, and `aborting`
  lifecycle ownership prevents an abort-owned reservation from reopening generation and makes
  duplicate aborts join the same finalization. Typed cache-trim or full-unload relief carries the
  generation lease directly through critical relief and reopens admission only after the
  revalidated relief operation completes. A rejected atomic relief claim clears only its matching
  ownership before crossing the session barrier again; ordinary finalization therefore releases
  the generation lease in both possible acknowledgment orderings instead of stranding it.
  Clone conditioning remains tensor-opaque behind epoch-bound handles. The actor retains one handle
  by default, supports an explicit bounded capacity with LRU eviction, and makes repeated release
  fail closed. A reservation keeps the prompt it already captured; noncritical cache trim preserves
  otherwise valid handles, while model reload, critical trim, and full unload invalidate them.
  New shipping schema-v8
  rows do embed a partial v9 transition projection with safe plan/policy digests and explicit
  reasons for actor-session, output-adapter, exact-range, and first-render fields that are not yet
  observable.
  Custom, Design, and Clone still use
  `NativeEngineRuntime` plus `NativeStreamingSynthesisSession`; telemetry v8/evidence v2, manifest
  v3, persisted Fast QC, and the existing specialized gates remain operational truth. Mode cutover,
  the sequential streaming long-form coordinator/cutover, v9 writer/merger/publication, and history
  v3 are pending.
- Clone conditioning is typed as transcript-backed or genuine audio-only x-vector. Both apps own
  the visible `voiceCloning_consentAcknowledgment` in Settings, persist the choice locally, and
  keep Clone Generate disabled until consent is acknowledged. Smoke and benchmark enable it through
  that real Settings control for later testing; there is no hidden test-state override. The two
  conditioning modes retain distinct cache and artifact identities.
- History persistence now fails closed with typed privacy-safe errors. An unavailable database is
  never presented as an empty library and destructive actions remain disabled; iOS exposes a Retry
  control, while macOS retries on reload or re-entry.
- Headless iOS generation, language, profiling, crash, and memory diagnostics use
  `IOSDeviceDiagnosticsRunner` through `scripts/ios_device.sh`. This is a non-UI diagnostic lane,
  not a second app driver.
- The iOS diagnostic Clone path requires the exact prepared voice ID. The canonical fixture is a
  transcript-backed Voice Design reference; a Custom Voice output is not an acceptable substitute.
- A compile-gated `scripts/ios_device.sh clone-conditioning` acceptance lane now runs exactly two
  clone takes in one physical-iPhone app/engine process: the canonical transcript-backed saved
  voice followed by an exact sidecar-free audio copy using genuine x-vector-only conditioning. It
  validates distinct prompt identities, typed runtime flags, output/ASR, telemetry-v8 memory, app
  correlation, crash delta, and scratch cleanup, then writes local evidence only. Local run
  `ios-clone-conditioning-20260716-162518-ea8e8989` passed both conditioning modes with strict
  output/ASR, memory, correlation, crash, and cleanup checks. It intentionally published no
  benchmark-history record.
- No preview/browser-mirror route, invisible accessibility state marker, alternate UI driver,
  coordinate bridge, or hidden UI bootstrap belongs in the shippable app.
- Model delivery uses one shared integrity/atomic-install implementation. iPhone now owns one
  bundle-aware app-lifetime background session plus an atomic schema-v2 request ledger, exact task
  adoption, cancellation barriers, durable delegate staging, and bounded privacy-safe diagnostics.
  macOS and CLI retain foreground delivery with terminal session teardown. Cancel discards staging;
  Retry reuses verified files. The isolated `scripts/ui_test.sh ios model-download` lifecycle proof
  is explicit QA and never joins smoke, benchmark, CI, packaging, or release gates. The 2026-07-14
  isolated Custom Speed proofs passed on both canonical platforms: macOS verified and removed its
  temporary 2.31 GB install, while the physical-iPhone test preserved monotonic progress across
  backgrounding, termination, and relaunch, installed with exact wire bytes and no retry, then
  deleted the isolated model through visible Settings. No connection or chunking default changed.
  Post-policy run `ios-xcui-model-download-20260716-163359-61377762` refreshed the physical-iPhone
  proof: expected and wire bytes both equaled 2,312,057,897, with zero retries or duplicates, one
  accepted provider redirect, HTTP/3 plus HTTP/1.1, nominal thermal state, final integrity, visible
  isolated cleanup, and all canonical model states preserved.
- iOS model cancellation now treats its ledger writes as authorization barriers. The coordinator
  durably records cancel intent and the deleted tombstone before task/staging destruction or a
  deleted UI state; a storage failure preserves recoverable state and cannot become a queued request
  after relaunch.
- The generated cross-platform production model catalog schema v2 is complete for all six
  Speed/Quality artifacts, with exact pinned revisions, sizes, per-file SHA-256 identities, and the
  shared `speech_tokenizer` content/compatibility identity. macOS, CLI, and iOS now resolve the
  same delivery plan; verified component blobs can omit exact bytes from a later download and new
  installs publish ordinary hard-linked model files atomically. Schema-v1 documents remain
  read-compatible. Resolving a schema-v2 delivery plan now authenticates all catalog files in an
  existing installation and automatically migrates or repairs its shared-component presentation;
  failed authentication contributes no reusable bytes and falls back to ordinary network repair.
  Live validation across all supported artifacts is still pending; earlier isolated delivery
  evidence predates shared-component activation. The isolated
  macOS/CLI Custom Speed proof at source `9a8da874…` transferred exactly 2,312,057,897 expected and
  wire bytes with zero control or duplicate bytes, zero retries, nominal thermal state, and final
  integrity. Its bounded foreground delegate ingress preserved terminal staging and metrics before
  completion, then the isolated 2.31 GB payload was removed.
- Benchmark evidence now uses collision-resistant run IDs, atomic run-scoped manifests, and a
  privacy-safe PASS-only registry. `benchmarks/HISTORY.md` is generated from canonical JSON records;
  raw telemetry, audio, screenshots, traces, and `.xcresult` bundles remain untracked.
- The canonical comparison hardware is the Mac mini `Mac14,3` (Apple M2, 8 GB) and iPhone 17 Pro
  `iPhone18,1`. Filtered runs are focused, dirty runs exploratory, and Instruments runs
  instrumented; those classes are not silently mixed into canonical timing trends.
- Generation telemetry schema v8 plus benchmark-evidence manifest v2 make RAM/pressure evidence a
  publication contract rather than optional summary data. Exact run-scoped sample sidecars carry
  start/periodic/boundary/stop samples and absolute uptime; summary counts must match, capture
  failures must be zero, and sampler coverage must be at least 95%. Critical pressure, app memory
  warnings/exits, `hardTrim`, and `fullUnload` fail publication; guarded pressure, `softTrim`, and
  95–<100% coverage are explicit warnings. macOS totals pair app and engine samples by uptime rather
  than adding independent maxima.
- CPU and memory Instruments lanes use exact-PID attachment. `profile --kind memory` records CPU
  Profiler, Allocations, VM Tracker, and `os_signpost` together; publication requires target-PID
  rows from every exportable memory schema and labels a configured but non-exportable track
  explicitly instead of claiming row verification. The separate `memory` lane runs the versioned retained-memory sequence and
  publishes `memory-qualification` only when within-mode retained-take growth stays within policy. The iOS
  `memory-field-report` command reads already-pulled,
  privacy-reduced delayed MetricKit summaries only; absence is `notYetDelivered`, not failure.
- Raw Instruments documents are diagnostic, not durable benchmark history. Successful profiles
  publish their validated digest/settings/extracted summary and then discard the raw trace unless
  `--keep-trace` was explicit. Routine cleanup also bounds failed profiles, superseded XCUITest
  results, and scratch DerivedData while preserving the current app, canonical caches, dSYMs, and
  external models. Benchmark results without a valid registry record remain available for
  idempotent publication repair; compile-safety scratch builds use only
  `build/scratch/derived-data/` and self-remove on exit.
- Generated output is classified by `config/build-output-policy.json`: two persistent platform
  Xcode caches, one shared package checkout, ephemeral scratch builds, bounded evidence/current
  symbols, and release-only `build/dist/` outputs. Public `build/Vocello.app` and `build/vocello`
  paths are symlinks to canonical macOS products; local macOS products are arm64-only.
- The Qwen3/Mimi implementation is now an explicitly owned monorepo core package at
  `Packages/VocelloQwen3Core`. Product targets depend on the `VocelloQwen3Core` facade, whose typed
  model-bundle, capability, sampling, memory, request, terminal, cancellation, and diagnostic
  contracts isolate application code from implementation modules. Its normal public mutation
  boundary is `VocelloQwen3Engine`; the current shipping bridge imports
  `VocelloQwen3LegacyCompatibility` for temporary loaded-model access. The legacy `MLXAudio`
  package, products, targets, modules, and public APIs remain available behind the facade for
  implementation compatibility; synthesis behavior and persistent identities did not change.
  Immutable lineage, compatibility, ownership, and runtime-capability contracts replace
  patch-stack governance. The named SPI, large-file decomposition, and compatibility-surface
  retirement are deferred Phase 14 work after shipping authority converges.
- The package-internal combined session's bounded event channel never suspends a producer on an
  absent consumer.
  Overflow fails explicitly with a reserved terminal slot, cancellation replaces obsolete queued
  events with its terminal, and `waitForTermination()` is independent of event-stream drainage.
- Runtime trust boundaries are machine-readable. `config/runtime-debug-knobs.json` makes every
  production-affecting environment override inert without the `QWENVOICE_DEBUG` master gate;
  `config/concurrency-safety.json` inventories and justifies every owned unchecked/unsafe
  concurrency declaration. Release/QA orchestration, evidence impact, project health, supply-chain,
  and release-candidate evidence are likewise governed by tracked contracts.
- Release-candidate evidence is now schema v2 and fail-closed. It begins from a clean full-tree
  source identity, accepts required checks only when the managed release runner executes them in
  one invocation, enforces a six-hour creation-time freshness window, and carries the exact ledger
  and step manifests inside a hashed `release-verification.json` bundle for offline asset review.
  Each managed release step is also bound to its contract-defined command template and declared
  outputs. The iOS candidate cannot reach archive/export until the same ledger has run the
  deterministic macOS gate and generic iOS device-SDK compile. It cannot proceed from export to
  evidence until a non-device schema-v2
  verifier has proved archive/IPA bundle version, build, identifier, arm64 UUID plus
  signature-normalized code continuity, root privacy-manifest identity, entitlements,
  locally trusted profile-authorized certificates, and configured team/App ID prefix consistency. App Store
  provisioning, Apple Distribution signing, and `get-task-allow` absence apply to the exported IPA;
  the archive may use either valid Apple development or distribution signing.
- The telemetry-overhead observer-effect diagnostic keeps its verdict under
  `build/artifacts/macos/` and does
  not publish schema-v2 history. Its `off` lane deliberately constructs no sampler, so requiring
  in-process memory evidence there would change the experiment rather than qualify it.
- A clean canonical macOS schema-v2 baseline exists, and a clean canonical iPhone schema-v2
  baseline exists, for the pre-convergence owned Qwen3 implementation. Mac mini M2 8 GB run
  `macos-xcui-benchmark-20260716-181853-b4c2e299` at source `9a8da874…` and iPhone 17 Pro run
  `ios-xcui-benchmark-20260716-184106-48e3a3a6` at source `bcb5265a…` each completed the exact
  29-take matrix with telemetry schema v8, complete layer correlation, qualified memory evidence,
  clean crash deltas, and the allowed `memory.pressure.soft_trim` warning. Earlier canonical
  records remain valid for their recorded source identities but do not promote the request-local
  sampling/memory or shared-component changes in this worktree; dirty records remain exploratory
  and are excluded from canonical trends.
- The physical-iPhone language lane predeclares a one-based, fixed-seed run plan; retains only the
  exact selected WAV and telemetry evidence; requires three-pass locale-locked on-device Speech
  consensus; and offers a retry-free 15-take diagnostic cohort that never publishes history. Its
  version-2 corpus uses at least 15 normalized words per alphabetic script and 24 normalized
  characters per CJK script, pins Design to the known language, and records language-appropriate
  Custom speakers where the Qwen contract supplies one. Custom pinned/Auto pairs test hint
  equivalence, while the three Speech passes test recognizer reproducibility; neither is counted as
  independent audio evidence.

## Publishing boundary

Routine verification is deterministic:

```sh
./scripts/check_project_inputs.sh
scripts/macos_test.sh test
./scripts/build.sh build
./scripts/build_foundation_targets.sh ios
```

Stop there for ordinary development publishing. A model download, paired phone, or UI result is
required only for the explicit quality task that needs it. Audio promotion quality is decided by
deterministic QC, fixed-seed evidence, ASR/prosody gates, and telemetry; listening is optional
annotation rather than a prerequisite.

## Explicit frontend acceptance

```sh
scripts/ui_test.sh macos smoke
scripts/ui_test.sh macos benchmark

scripts/ios_device.sh preflight
scripts/ui_test.sh ios smoke
scripts/ui_test.sh ios benchmark
```

Generation UI tests visibly require Custom, Design, and Clone Speed to be ready, Generate to be
enabled, and the prepared Clone voice to exist before the first take. Use `models ensure` only as an
explicit macOS fixture repair/bootstrap step.

## Open release work

- macOS 2.1.0 is released.
- Future macOS releases now start from a protected version tag or explicit existing tag. The
  workflow verifies source/version identity, signs and notarizes, emits SPDX/CycloneDX inventories,
  checksums, release evidence, and provenance, then verifies downloaded draft assets before the
  final publication step. Immutable Action pins, Dependabot, dependency review, scheduled CodeQL,
  and deterministic website checks are repository contracts; GitHub administrative settings still
  require maintainer authorization and API verification.
- The optional CI `archive-ios` lane is implemented with process-bound deterministic readiness,
  signed-artifact verification, and release evidence. Public iOS distribution still requires
  maintainer-owned distribution credentials, the App Store Connect record and metadata, screenshots,
  and submission.
- The 2026-07-16 Speech-asset verification resolved the requested locales to installed `de_DE`,
  `es_ES` (for `es_419`), `ja_JP`, and `zh_CN` DictationTranscriber modules; fresh
  `SFSpeechRecognizer` instances also passed Vocello's legacy on-device gate. This is prerequisite
  evidence, not a language-generation verdict. The clean seven-cell EN/FR quick language record is
  tracked. The first post-asset
  full attempt passed the 19/19 hint gate but failed the output gate; it correctly published no
  history. That run exposed an out-of-range language-score producer bug plus genuine accuracy
  failures under the original short corpus. The strict validator, version-2 corpus/matrix, and
  CJK-aware punctuation pause budget subsequently passed a retry-free six-cell DE/ZH/JA diagnostic
  cohort with 6/6 hint/QC and 6/6 output checks. That bounded local diagnostic intentionally
  published no history. The first clean corpus-v2 full attempt then passed all 19 hint/QC checks
  but stopped at 13/18 output cells, correctly publishing no history; its failures were isolated to
  French Custom and the three German paths. Revised natural French and German scripts passed four
  retry-free exact-canonical-seed cohorts with strict QC and all 6/6 output checks. The subsequent
  full run `ios-lang-bench-20260714-153252-d2a3eea5` was intentionally interrupted while take 7
  was launching after six takes had completed. It produced no final hint/output gates and no
  history record, so it remains non-authoritative local evidence and must not be resumed or
  published. Fresh run `ios-lang-bench-20260716-164248-1ecf8361` then completed the immutable full
  plan with 19/19 hint/QC rows, 18/18 output-gated rows, zero diagnostic failures, and three-pass
  locale-locked on-device ASR. Its status is `passedWithWarnings` for the accepted Spanish Custom
  written-output/dropout warning and soft memory trims. It is tracked as `exploratory` because the
  owned-runtime worktree was dirty; it proves the exact recorded fingerprint but is excluded from
  clean comparison trends.
- Clean canonical macOS and iPhone schema-v2 UI baselines exist for their recorded pre-convergence
  source identities. The request-local sampling/memory and component-delivery changes make those
  records historical controls rather than current promotion evidence. Rerun focused parity first,
  then the applicable canonical matrix after the shipping mode cutovers stabilize. Explicit quality
  runs remain independent from ordinary publishing and release packaging.
- Physical-iPhone telemetry-v8/evidence-v2 acceptance is complete for the canonical UI matrix,
  retained-memory qualification, and an exact-PID memory profile. The tracked records remain bound
  to their exact source, toolchain, model, and hardware identities; new product changes require
  proportionate fresh evidence rather than reuse of local raw artifacts.
- Pre-convergence owned-core evidence passes on both platforms: the two canonical 29-take UI matrices,
  typed user and memory-pressure cancellation, the two-take physical-iPhone Clone proof,
  redirect-enforced isolated iPhone delivery, the isolated post-catalog macOS/CLI delivery proof,
  Speech prerequisites, and the full 19-cell language run. Each result remains bound to its exact
  source or worktree fingerprint; the language run remains exploratory rather than a clean trend
  baseline. It must not be presented as validation of the staged convergence runtime. Fresh
  platform promotion QA remains pending and nonblocking for deterministic source publication,
  packaging, and release artifact preservation.

## Resume rule

Review `git status`, read the applicable role playbook, and run verification proportional to the
change. Do not rely on a dated local `.xcresult`, telemetry directory, or device state as proof for a
new checkout. A tracked record proves only its exact source/toolchain/model/hardware identities;
produce fresh evidence only when that acceptance surface is explicitly requested.
