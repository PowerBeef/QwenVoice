# iOS physical-device testing

Vocello's iOS runtime and UI acceptance run on a paired physical iPhone. Simulator build, launch,
and UI automation are unsupported. XCUITest is the sole autonomous iOS app UI driver.

## Ordinary development

```sh
./scripts/check_project_inputs.sh
./scripts/build_foundation_targets.sh ios
```

The generic physical-device SDK compile requires no connected phone and is sufficient for routine
commits, pushes, pull requests, ordinary merges, and ordinary CI. Missing models, a phone, or UI
results must not block preserving and sharing development work.

## Device preparation

```sh
scripts/ios_device.sh preflight
scripts/ios_device.sh device-state
```

`preflight` and `device-state` verify the paired CoreDevice identity and reachability; preflight
also checks signing plus the existing app-build and dSYM readiness. `device-state` treats
reachability as its only blocker. The XCUITest runner independently rejects a phone that
CoreDevice reports as locked before invoking `xcodebuild`. Install or repair iOS models through the
visible Settings → Model Downloads UI; neither device scripts nor normal UI tests install them.

## Explicit XCUITest lanes

```sh
scripts/ui_test.sh ios smoke
scripts/ui_test.sh ios benchmark
# Filtered benchmark example:
scripts/ui_test.sh ios benchmark --modes custom --lengths short --warm 1 --label "focused"
```

The iPhone matrix keeps the shared short/medium/long ordering, but its long script is exactly the
production 150-character on-device boundary. macOS retains the extended >220-character long corpus;
the iPhone lane never bypasses its user-facing script limit.

| Lane | Scope |
| --- | --- |
| Smoke | Exact app launch, Studio mode and tab navigation, visible model and clone-reference readiness, one real Custom generation, completed player, and History |
| Benchmark | Ordered, configurable Studio matrix with pulled telemetry, readable audio, audio QC, thermal and timing evidence; the default is exactly 29 takes |

Every lane uses the paired physical-device destination. Tests use stable accessibility identifiers,
condition-based waits, XCTest activities, screenshots, and failure attachments. Coordinate tables,
OCR taps, alternate UI drivers, and fixed sleeps are not supported.

Benchmark accepts `--modes`, `--lengths`, `--warm`, and `--label`. Filters are explicit diagnostic
runs; invoking the command without filters is the canonical 29-take matrix on the tracked iPhone 17
Pro `iPhone18,1` profile. Dirty-source successes are exploratory even on that hardware.

## Headless device diagnostics

`bench`, `lang-bench`, `speech-assets`, `profile`, `memory`, and the deliberate crash diagnostic launch
`IOSDeviceDiagnosticsRunner` through purpose-specific `QVOICE_IOS_*` environment contracts.
Generation lanes write `device-diagnostics-done.json`; `speech-assets` writes its distinct
`speech-assets-done.json` completion barrier. The runner never drives or inspects the app UI. Clone
diagnostics require the exact prepared voice ID, and `--memory-profile` can apply a
smaller-device memory budget while retaining the connected phone's real GPU and thermals. These
operations are diagnostics, not a second frontend acceptance stack.

`speech-assets` is an explicit, non-generation bootstrap for the language-output prerequisite. It
resolves `de_DE`, `es_419`, `ja_JP`, and `zh_CN` through
`DictationTranscriber.supportedLocale(equivalentTo:)`, creates one module per resolved locale,
checks each status, performs one combined AssetInventory download/install request, and then requires
every module to report installed. Its local sentinel also records a fresh
`SFSpeechRecognizer.supportsOnDeviceRecognition` read and Vocello's deterministic legacy locale
selection. Modern installation and legacy readiness are separate verdicts; the command publishes no
benchmark history and performs no generation.

`lang-bench` declares an immutable one-based run plan before generation and passes an explicit
UInt64 seed plus sampling variation to every take. Its schema-v2 sentinel is published last and
binds the resolved language, prompt-assembly digest, exact output-WAV digest/metadata, generation
telemetry identity, and structured three-pass on-device Speech evidence. The collector retains only
those plan-selected rows and files. `--diagnostic-cohort` runs the fixed 15-take English-Design and
French pinned/Auto failure cohort without retries or history publication. Language acceptance is
fully autonomous; listening is optional annotation only. Its primary accuracy metric is WER for
word-delimited languages and CER for Chinese/Japanese, both at the versioned 0.15 threshold; the
Python validator and publisher recompute the edit evidence from the corpus rather than trusting the
app's aggregate score.

## Model readiness

Before generation, XCUITest visibly requires Custom, Design, and Clone Speed to report ready,
Generate to be enabled, and the required clone voice to exist. iOS has no command-line model
ensure/install path: repair missing models in visible Settings → Model Downloads, then restart the
UI lane. Device scripts retain headless engine diagnostics, but normal acceptance never substitutes
a headless inventory for the visible Settings state.

## Deterministic evidence retained

The benchmark result is joined with exact device/app identity, current-run engine and app telemetry,
History/database correlation, readable WAV validation, audio QC, crash deltas, thermal state,
matrix ordering, and take counts. The app mints the generation UUID across Custom, Design, and Clone
and writes its frontend row durably before only the matching run rows/verbose sidecars are mirrored.
The 150-character boundary case remains explicitly `long`; no prompt-length inference is used.
Smoke asserts visible completion and History plus the runner's device/crash checks; it
does not claim the benchmark's per-take telemetry matrix. Headless `bench`, `lang-bench`, `profile`,
`crashes`, logs, and console operations remain supported physical-device diagnostics.

Profile commands launch or attach to the exact target PID, record CPU Profiler and `os_signpost`
rows in one trace, require a successful tracer exit, and verify the trace using exported
table-of-contents data plus non-empty performance-row and correlated-signpost exports. Traces remain local; a successful profile
publishes only its digest, capture settings, CPU/data-row summary, and sanitized artifact reference as
an `instrument-profile` record. CoreDevice and Instruments use different runtime identifiers for the
same phone; the profile lane resolves the Instruments UDID from CoreDevice JSON and fails before
installing or launching the app unless `xcrun xctrace list devices` reports that phone in its online
`Devices` section. Tracer startup is bounded by xctrace's own `Starting recording` output rather than
the unreliable physical-device Darwin-notification callback. Any target suspended by a later failure
is terminated automatically.

For allocation and VM evidence, use the Instruments memory profile:

```sh
scripts/ios_device.sh profile --kind memory custom:speed:

# Retain the raw trace only when it must be reopened in Instruments.
scripts/ios_device.sh profile --kind memory --keep-trace custom:speed:
```

This keeps CPU Profiler and correlated `os_signpost` data while adding Allocations and VM Tracker in
the same exact-PID trace, and forces verbose run-scoped samples. New publishable device runs require
telemetry schema v8 and evidence manifest v2: exact start/periodic/boundary/stop sidecars, summary
agreement, zero capture failures, and at least 95% sampler coverage. Critical pressure, an app memory
warning/exit, `hardTrim`, or `fullUnload` fails publication; guarded pressure, `softTrim`, or 95–<100%
coverage is explicit warning evidence. The record retains footprint/resident start, end, delta, and
peak; compressed/GPU peaks; minimum headroom and peak process-budget utilization; sampler coverage;
and pressure/trim/warning/exit counters. iPhone admission is also strict: physical footprint ≥5.2
GB, minimum headroom <384 MB, or Metal working-set ratio ≥0.8 fails; footprint ≥4.5 GB or
headroom <768 MB warns. The lane requires 15 GiB free before device launch. After validation and
history publication, the raw trace is discarded by default while its digest/settings/extracted
summary and retention status remain in compact evidence; `--keep-trace` opts into local retention.
Raw traces and sample rows remain untracked.

Retained-memory qualification is separate from Instruments:

```sh
scripts/ios_device.sh memory --voice-id <exact-prepared-saved-voice-id> --label retained-check
```

One persistent app/engine process executes three medium Speed takes for Custom, then Design, then
Clone (nine total). The terminal sentinel is written only after all output/QC/telemetry proofs pass.
Policy `retained-memory-v1` compares first-to-last retained-take footprint growth within each mode and allows
at most 5% of physical RAM; cross-mode residency is diagnostic because different models are
intentionally loaded. A PASS creates `memory-qualification`, while any generation, memory,
retention, output, or crash failure leaves tracked history unchanged.

MetricKit supplies a complementary delayed field view, not per-take benchmark attribution. After a
normal explicit pull, summarize only the already-local privacy-reduced aggregate with:

```sh
scripts/ios_device.sh memory-field-report build/artifacts/diagnostics/ios
```

The command never resolves, wakes, pulls from, or otherwise contacts an iPhone. MetricKit delivery
may take a day or longer; no payload reports `notYetDelivered` with success status and cannot qualify
or retroactively fail a benchmark run.

The validator atomically writes an untracked `benchmark-evidence.json` with the exact ordered
generation IDs/cells and verdicts. A PASS publishes one privacy-safe record under
`benchmarks/runs/ui-generation/` and regenerates `benchmarks/HISTORY.md`. Raw pulled JSONL, WAVs,
screenshots, traces, and `.xcresult` stay untracked; publication never stages, commits, or pushes.

Physical-iPhone acceptance of telemetry v8/evidence v2 is complete for the clean canonical
[29-take UI matrix](../../benchmarks/runs/ui-generation/ios-xcui-benchmark-20260714-113139-3b4b6d6c.json),
[retained-memory qualification](../../benchmarks/runs/memory-qualification/ios-memory-qualification-20260714-112536-32554d95.json),
and the exact-PID [memory profile](../../benchmarks/runs/instrument-profile/ios-memory-profile-20260714-112759-9a573224.json).
Each record proves only its exact source, toolchain, model, and hardware identities; repository
contract tests and Simulator results never substitute for fresh physical-device evidence after a
relevant change.

## Generated-output ownership

Physical-device development and UI lanes reuse only `build/cache/xcode/ios-device/`; Xcode package
checkouts are shared under `build/cache/xcode/source-packages/`. Pulled diagnostics, UI results,
profiles, gates, and current UUID-matched symbols live under `build/artifacts/`, never inside the
incremental cache. Archive/export products live only under `build/dist/ios/`. Local release
DerivedData is isolated under `build/scratch/derived-data/release-ios/`; CI uses its
own `build/scratch/derived-data/ci/ios-archive/` leaf. See the authoritative owner/lifetime table in
[`privacy-storage.md`](privacy-storage.md).

## Release boundary

An iOS archive/TestFlight candidate uses deterministic signing, entitlement, catalog, archive, and
artifact checks. Physical-device smoke and benchmark results are independent frontend QA artifacts
and never an archive, upload, or Git-publishing prerequisite.

See also [`testing-runbook.md`](testing-runbook.md) and
[`benchmarking-procedure.md`](benchmarking-procedure.md).
