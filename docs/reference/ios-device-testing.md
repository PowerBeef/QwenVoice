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

The scripts verify pairing, developer mode, unlock/interference state, signing destination,
supported hardware, and device identity. Use explicit repair/bootstrap operations for missing
models; normal UI tests do not silently install them.

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
runs; invoking the command without filters is the canonical 29-take matrix.

## Model readiness

Before generation, XCUITest visibly requires Custom, Design, and Clone Speed to report ready,
Generate to be enabled, and the required clone voice to exist. Device scripts retain explicit model
repair/bootstrap commands and headless engine diagnostics, but normal acceptance never substitutes
a headless inventory for the visible Settings state.

## Deterministic evidence retained

The benchmark result is joined with exact device/app identity, pulled telemetry, History/database
correlation, readable WAV validation, audio QC, crash deltas, thermal state, matrix ordering, and
take counts. Smoke asserts visible completion and History plus the runner's device/crash checks; it
does not claim the benchmark's per-take telemetry matrix. Headless `bench`, `lang-bench`, `profile`,
`crashes`, logs, and console operations remain supported physical-device diagnostics.

## Release boundary

An iOS archive/TestFlight candidate uses deterministic signing, entitlement, catalog, archive, and
artifact checks. Physical-device smoke and benchmark results are independent frontend QA artifacts
and never an archive, upload, or Git-publishing prerequisite.

See also [`testing-runbook.md`](testing-runbook.md) and
[`benchmarking-procedure.md`](benchmarking-procedure.md).
