# Vocello development checkpoint

> Current maintainer checkpoint. Confirm this summary against the checkout before acting; source,
> `project.yml`, and repository scripts remain authoritative.

## Current implementation

- Native app UI acceptance uses one shared XCUITest stack: `macos smoke|benchmark` on the native
  Mac host and `ios smoke|benchmark` on a paired physical iPhone.
- UI execution is explicit frontend QA. It is not required to commit, push, open or merge a pull
  request, run ordinary CI, package a release, or create an iOS archive.
- The ordinary iOS compile lane now typechecks both the app and a standalone app-host-free policy
  XCTest bundle for the generic physical-device SDK. It covers catalog/ledger, memory policy,
  cancellation, storage-path gating, and diagnostic redaction without a phone; execution through
  `scripts/ios_device.sh logic-test` remains explicit and physical-device-only.
- Generation ownership is now explicit across all hosts. Both platform streams are bounded
  (`bufferingNewest(256)` on macOS, `bufferingNewest(96)` on iOS) and every yield outcome is
  measured. `ActiveGenerationCoordinator` admits one active task, carries typed user,
  memory-pressure, superseded, or shutdown cancellation, and awaits the cancelled terminal barrier
  before trim, unload, ownership release, or persistence.
- Clone conditioning is typed as transcript-backed or genuine audio-only x-vector. Both apps expose
  the visible `voiceCloning_consentAcknowledgment`, persist the choice locally, and keep Generate
  disabled until consent is acknowledged. The two conditioning modes retain distinct cache and
  artifact identities.
- History persistence now fails closed with typed privacy-safe errors. An unavailable database is
  never presented as an empty library and destructive actions remain disabled; iOS exposes a Retry
  control, while macOS retries on reload or re-entry.
- Headless iOS generation, language, profiling, crash, and memory diagnostics use
  `IOSDeviceDiagnosticsRunner` through `scripts/ios_device.sh`. This is a non-UI diagnostic lane,
  not a second app driver.
- The iOS diagnostic Clone path requires the exact prepared voice ID. The canonical fixture is a
  transcript-backed Voice Design reference; a Custom Voice output is not an acceptable substitute.
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
  That proof predates the current redirect-policy enforcement and cannot be reused as live evidence
  for the new redirect boundary.
- iOS model cancellation now treats its ledger writes as authorization barriers. The coordinator
  durably records cancel intent and the deleted tombstone before task/staging destruction or a
  deleted UI state; a storage failure preserves recoverable state and cannot become a queued request
  after relaunch.
- The generated cross-platform production model catalog is complete for all six Speed/Quality
  artifacts, with exact pinned revisions, sizes, and per-file SHA-256 identities. macOS and CLI now
  use the bundled fail-closed `downloadFiles` route instead of live repository enumeration; iOS
  retains its one-session background lifecycle over the same exact artifact contract. Static
  validation passes, while fresh isolated Mac/iPhone post-cutover delivery evidence remains an
  explicit deferred quality task.
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
  contracts isolate application code from implementation modules. The legacy `MLXAudio` package,
  products, targets, modules, and public APIs remain available behind the facade for compatibility;
  synthesis behavior and persistent identities did not change. Immutable lineage, compatibility,
  ownership, and runtime-capability contracts replace patch-stack governance. Large-file
  decomposition remains separate follow-up work.
- The facade session's bounded event channel never suspends a producer on an absent consumer.
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
- A clean canonical macOS schema-v2 baseline exists, and so does the clean canonical iPhone
  schema-v2 baseline: the 29-take Mac mini M2 8 GB run at source commit `4e05f6fd…` and the
  29-take iPhone 17 Pro run at source commit `6ffdbfdd…` passed with the allowed
  `memory.pressure.soft_trim` warning and are preserved in the tracked registry. Earlier dirty
  schema-v2 records remain exploratory and are excluded from canonical trends.
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
- The 2026-07-14 attended Speech-asset bootstrap resolved and installed the supported DE/ES/JA/ZH
  DictationTranscriber modules, and fresh `SFSpeechRecognizer` instances passed Vocello's legacy
  on-device gate. The clean seven-cell EN/FR quick language record is tracked. The first post-asset
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
  history record, so it is non-authoritative local evidence and must not be resumed or published.
  A future session must start a fresh 19-cell, 18-output physical-iPhone acceptance run from the
  committed corpus at or after checkpoint `eaf9d751`.
- Clean canonical macOS and iPhone schema-v2 UI baselines are complete. Rerun either canonical
  matrix after a relevant engine, model, compiler, toolchain, or performance change rather than for
  documentation-only revisions. Explicit quality runs remain independent from ordinary publishing
  and release packaging.
- Physical-iPhone telemetry-v8/evidence-v2 acceptance is complete for the canonical UI matrix,
  retained-memory qualification, and an exact-PID memory profile. The tracked records remain bound
  to their exact source, toolchain, model, and hardware identities; new product changes require
  proportionate fresh evidence rather than reuse of local raw artifacts.
- The records above remain valid for their recorded commits; they do not prove the current runtime
  overhaul. Fresh physical-iPhone/live-model evidence remains deferred for typed cancellation
  (including memory-pressure cancellation), transcript-backed and audio-only clone conditioning,
  the redirect-enforced model route after catalog completion, and the fresh full 19-cell language
  run. These explicit quality tasks remain nonblocking for deterministic source publication,
  packaging, and release artifact preservation.

## Resume rule

Review `git status`, read the applicable role playbook, and run verification proportional to the
change. Do not rely on a dated local `.xcresult`, telemetry directory, or device state as proof for a
new checkout. A tracked record proves only its exact source/toolchain/model/hardware identities;
produce fresh evidence only when that acceptance surface is explicitly requested.
