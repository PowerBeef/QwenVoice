# Testing runbook

Authority is `Sources/` → `project.yml` → repository scripts → this document. Deterministic checks
are the routine development, CI, and packaging contract. XCUITest is the sole autonomous app UI
driver and is reserved for explicit frontend acceptance.

## Routine development matrix

| Platform | Required for development/CI/release packaging | Explicit UI lanes |
| --- | --- | --- |
| macOS | `scripts/macos_test.sh test` + `./scripts/build.sh build` | `scripts/ui_test.sh macos smoke|benchmark` |
| iOS | `./scripts/check_project_inputs.sh` + `./scripts/build_foundation_targets.sh ios` | `scripts/ui_test.sh ios smoke|benchmark` on a paired physical iPhone |

No UI lane, model download, paired phone, or UI result is mandatory for ordinary development
publishing.

## macOS

```sh
./scripts/check_project_inputs.sh
scripts/macos_test.sh test
./scripts/build.sh build

# Deterministic/runtime diagnostic; independent of XCUITest
scripts/macos_test.sh gate

# Explicit frontend acceptance only
scripts/ui_test.sh macos smoke
scripts/ui_test.sh macos benchmark
# Filtered benchmark example
scripts/ui_test.sh macos benchmark --modes custom --lengths short --warm 1 --label "focused"
```

## iOS

```sh
./scripts/check_project_inputs.sh
./scripts/build_foundation_targets.sh ios

# Physical-device diagnostics; independent of XCUITest
scripts/ios_device.sh preflight
scripts/ios_device.sh gate

# Explicit frontend acceptance only; never Simulator
scripts/ui_test.sh ios smoke
scripts/ui_test.sh ios benchmark
# Filtered benchmark example
scripts/ui_test.sh ios benchmark --modes custom --lengths short --warm 1 --label "focused"

# Opt-in ~2.3 GB background-session restoration proof; isolated data, genuine Settings controls
scripts/ui_test.sh ios model-download
```

Both benchmark commands accept `--modes`, `--lengths`, `--warm`, and `--label`. Without filters,
each runs the canonical 29-take matrix. Filtered runs are targeted diagnostics, not substitutes for
the full matrix when full frontend benchmark acceptance is explicitly requested.

`ios model-download` is not a third routine UI lane. It selects one isolated physical-device test
directly, backgrounds and relaunches the app during transfer, checks adopted progress, verifies the
install, and deletes the isolated model through Settings. It never runs in ordinary CI or release.
See [`model-delivery.md`](model-delivery.md).

## Model readiness

Generation UI tests inspect Settings and require Custom, Design, and Clone Speed to be ready,
Generate to be enabled, and the benchmark clone voice to exist before a take begins. On macOS,
use `scripts/macos_test.sh models ensure` or `scripts/macos_test.sh models install` only for explicit
repair/bootstrap after that visible check fails. On iOS, install or repair models only through
visible Settings → Model Downloads. Restart the affected UI lane after either repair.

## Evidence

XCTest assertions, activities, attachments, and `.xcresult` bundles own UI truth. Benchmark
validators own exact take counts/order plus matching telemetry, History/database, readable-WAV, and
audio-QC proof. The runner owns app/device identity and crash deltas. Smoke intentionally stops at
its visible journey, History assertion, and crash check rather than claiming benchmark evidence.

## CI and release

Ordinary CI builds app targets and runs deterministic checks; it neither compiles nor executes the
isolated UI-test bundles.
Release packaging uses deterministic build, test, signing, identity, crash, entitlement, and artifact
checks. XCUITest results may accompany an explicit frontend review, but missing or stale UI results
never block signing, notarization, a macOS package, or an iOS archive/TestFlight build.

## Artifacts

Raw result bundles, exported screenshots, telemetry, databases, WAVs, and traces remain ignored
build artifacts. Compact benchmark summaries must contain no user data.
