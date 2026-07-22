# Testing runbook

Authority is `Sources/` → `project.yml` → repository scripts → this document. Deterministic checks
are the routine development, CI, and packaging contract. Interactive UI QA (agent-driven computer
use, [`interactive-ui-qa.md`](interactive-ui-qa.md)) is the app UI acceptance method and is
reserved for explicit frontend acceptance; it is advisory and never a gate.

## Routine development matrix

| Platform | Required for development/CI/release packaging | Explicit UI acceptance |
| --- | --- | --- |
| macOS | `scripts/macos_test.sh test` + `./scripts/build.sh build` | Interactive UI QA checklist against `./scripts/build.sh run` |
| iOS | `./scripts/check_project_inputs.sh` + `./scripts/build_foundation_targets.sh ios` | Interactive UI QA checklist through iPhone Mirroring on a paired physical iPhone |

No UI lane, model download, paired phone, or UI result is mandatory for ordinary development
publishing.

The no-phone iOS compile still requires matching iOS Platform Support/runtime availability in the
selected Xcode installation. `scripts/lib/ios_platform_preflight.py check` validates that external
toolchain prerequisite before package resolution and never runs or authorizes a Simulator. Repair
and interpretation are documented in [iOS physical-device testing](ios-device-testing.md#host-toolchain-prerequisite).

## Storage preflight and retention

Heavy commands read their host free-space floor from `config/build-output-policy.json` and stop
before starting another build, target, or evidence bundle when the floor is not met. The message
points to `python3 scripts/build_output_policy.py status` and one bounded cleanup command. This is a
capacity check for an explicitly selected lane, not a new development or publishing gate.

`scripts/clean_build_caches.sh --routine --dry-run` previews scratch and lifecycle-safe evidence
cleanup. `--prune-ui-results` keeps the latest pass and unresolved failure per platform/lane,
preserves exact publication-repair evidence, and compacts resolved failures. Use a selective
`--cache macos|ios|packages|runtime` only when that specific persistent cache must be rebuilt.
Cleanup never runs globally after an ordinary successful build, because another process may still
own a managed scratch/cache root.

## macOS

```sh
./scripts/check_project_inputs.sh
scripts/macos_test.sh test
./scripts/build.sh build

# Deterministic/runtime diagnostic; independent of interactive UI QA
scripts/macos_test.sh gate
```

For explicit frontend acceptance only, run the interactive UI QA checklist
([`interactive-ui-qa.md`](interactive-ui-qa.md)) against `./scripts/build.sh run`.

## iOS

```sh
./scripts/check_project_inputs.sh
./scripts/build_foundation_targets.sh ios

# Physical-device diagnostics; independent of interactive UI QA
scripts/ios_device.sh preflight
scripts/ios_device.sh gate
```

For explicit frontend acceptance only, run the interactive UI QA checklist
([`interactive-ui-qa.md`](interactive-ui-qa.md)) through iPhone Mirroring on the paired physical
iPhone; never Simulator. Engine benchmark evidence stays headless via `scripts/ios_device.sh bench`.

Model-delivery lifecycle observation (download, background/relaunch adoption, install verification,
and deletion through visible Settings controls) is an opt-in diagnostic, never routine CI or
release work. See [`model-delivery.md`](model-delivery.md).

## Model readiness

Interactive UI QA inspects Settings and requires Custom, Design, and Clone Speed to be ready,
Generate to be enabled, and any required clone voice to exist before a generation is exercised. On
macOS, use `scripts/macos_test.sh models ensure` or `scripts/macos_test.sh models install` only for
explicit repair/bootstrap after that visible check fails. On iOS, install or repair models only
through visible Settings → Model Downloads. Restart the affected QA session after either repair.

## Evidence

Interactive UI QA records per-item verdicts and untracked screenshots under
`build/artifacts/diagnostics/interactive-qa/<run-id>/`. Headless benchmark validators own exact
take counts/order plus matching telemetry, History/database, readable-WAV, and audio-QC proof, and
the deterministic runners own app/device identity and crash deltas.

## Fail-closed orchestration

The macOS gate and release-readiness command and the iOS gate write an
untracked `required-steps.json` beside their other run artifacts. The expected steps come from
`config/orchestration-contract.json`; final PASS is impossible while a required step is failed,
missing, duplicated, interrupted, or unknown. Optional retention cleanup cannot replace a failed
validator result.

The deterministic negative suite forces every declared required step to fail in isolation:

```sh
python3 -m unittest scripts.tests.test_required_step_ledger
```

Fault injection is test-only and requires both `QWENVOICE_TEST_ORCHESTRATION_FAULTS=1` and an exact
`QWENVOICE_TEST_FAIL_REQUIRED_STEP=<workflow>:<step>` selector. Normal workflows never enable it.

Release-candidate orchestration adds a stricter boundary. Its schema-v2 release evidence captures a
clean full-tree source identity, requires the platform steps to run as managed subprocesses in one
invocation using the command templates in `config/orchestration-contract.json`, and packages the
ledger plus step manifests into hashed `release-verification.json`. A successful substitute such as
`true` cannot mint a required-step result. Contract-declared step outputs are hashed when the managed
command completes and rechecked during evidence creation, so a verifier summary cannot be replaced
between verification and publication. The iOS candidate first runs `scripts/macos_test.sh gate`
and the generic physical-device SDK compile as its managed `platform-readiness` step, then requires
the archive/IPA identity and signing summary described in `ios-appstore-submission.md`.
The six-hour freshness rule applies when creating a candidate; offline verification of the copied
bundle rechecks identity, structure, outcomes, and digests without pretending the original clock is
still current.

For an inventory of direct tests, unsafe-concurrency annotations, canonical hardware evidence, and
path-based evidence freshness, generate the local project-health report:

```sh
python3 scripts/project_health.py report --output build/artifacts/project-health/current
```

The compact tracked snapshot is [`../project-health.md`](../project-health.md). It is an engineering
inventory, not a test result or release-readiness verdict; it never makes physical-device evidence
an ordinary development gate.

## CI and release

Ordinary CI builds app targets and runs deterministic checks; interactive UI QA never runs in CI.
Release packaging uses deterministic build, test, signing, identity, crash, entitlement, and artifact
checks. Interactive UI QA verdicts may accompany an explicit frontend review, but missing or stale
UI observations never block signing, notarization, a macOS package, or an iOS archive/TestFlight
build.

## Artifacts

Raw result bundles, exported screenshots, telemetry, databases, WAVs, and traces remain ignored
build artifacts. Compact benchmark summaries must contain no user data. A failed Instruments run
keeps the newest raw trace per platform/profile kind unless it is explicitly pinned; superseded
failures are reduced to the required retention metadata plus at most 8 MiB of allowlisted auxiliary
diagnostics, with individual logs capped at 1 MiB.
