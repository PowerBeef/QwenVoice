# Vocello development checkpoint

> Current maintainer checkpoint. Confirm this summary against the checkout before acting; source,
> `project.yml`, and repository scripts remain authoritative.

## Current implementation

- Native app UI acceptance uses one shared XCUITest stack: `macos smoke|benchmark` on the native
  Mac host and `ios smoke|benchmark` on a paired physical iPhone.
- UI execution is explicit frontend QA. It is not required to commit, push, open or merge a pull
  request, run ordinary CI, package a release, or create an iOS archive.
- Headless iOS generation, language, profiling, crash, and memory diagnostics use
  `IOSDeviceDiagnosticsRunner` through `scripts/ios_device.sh`. This is a non-UI diagnostic lane,
  not a second app driver.
- The iOS diagnostic Clone path requires the exact prepared voice ID. The canonical fixture is a
  transcript-backed Voice Design reference; a Custom Voice output is not an acceptable substitute.
- No preview/browser-mirror route, invisible accessibility state marker, alternate UI driver,
  coordinate bridge, or hidden UI bootstrap belongs in the shippable app.
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
  consensus; and offers a retry-free 15-take diagnostic cohort that never publishes history.

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
- The optional CI `archive-ios` lane is implemented. Public iOS distribution still requires
  maintainer-owned distribution credentials, the App Store Connect record and metadata, screenshots,
  and submission.
- The 2026-07-14 attended Speech-asset bootstrap resolved and installed the supported DE/ES/JA/ZH
  DictationTranscriber modules, and fresh `SFSpeechRecognizer` instances passed Vocello's legacy
  on-device gate. The clean seven-cell EN/FR quick language record is tracked; the full 19-cell,
  18-output multilingual matrix remains the next promotion run.
- Clean canonical macOS and iPhone schema-v2 UI baselines are complete. Rerun either canonical
  matrix after a relevant engine, model, compiler, toolchain, or performance change rather than for
  documentation-only revisions. Explicit quality runs remain independent from ordinary publishing
  and release packaging.
- Physical-iPhone telemetry-v8/evidence-v2 acceptance is complete for the canonical UI matrix,
  retained-memory qualification, and an exact-PID memory profile. The tracked records remain bound
  to their exact source, toolchain, model, and hardware identities; new product changes require
  proportionate fresh evidence rather than reuse of local raw artifacts.

## Resume rule

Review `git status`, read the applicable role playbook, and run verification proportional to the
change. Do not rely on a dated local `.xcresult`, telemetry directory, or device state as proof for a
new checkout. A tracked record proves only its exact source/toolchain/model/hardware identities;
produce fresh evidence only when that acceptance surface is explicitly requested.
