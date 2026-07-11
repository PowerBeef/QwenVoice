# Vocello development progress and resume checkpoint

> **Active maintainer checkpoint — 2026-07-11.** Read this after
> [`AGENTS.md`](../AGENTS.md). This is a development checkpoint, not a release-readiness claim.

## Completed objective

One native XCUITest stack now provides Vocello frontend acceptance:

- macOS tests drive the configured native Vocello test host;
- iOS tests drive a paired physical iPhone only;
- smoke and benchmark are the only explicit lanes on both platforms;
- Simulator, alternate UI drivers, and coordinate bridges are not supported.

XCUITest is not a prerequisite for commits, pushes, pull requests, ordinary merges, or ordinary
CI and release packaging. Those workflows use deterministic tests and compile checks. UI execution
is reserved for an explicit frontend request.

## Transition status

| Workstream | Status |
| --- | --- |
| Obsolete UI harness, scenario contracts, routing audit, and tracked UI attestations | Removed |
| Shared XCUITest support and macOS/iOS UI-test targets | Complete |
| macOS UI lanes | Smoke and full 29-take benchmark passed; native macOS only |
| iOS UI lanes | Smoke and full 29-take benchmark passed; paired physical iPhone only |
| Deterministic development checks | Remain the only routine publishing/CI requirement |
| Release packaging proof | Deterministic; independent of optional XCUITest results |

Historical transition diagnostics remain available in Git history and the upstream issue. They
are not active repository gates or setup instructions.

## Latest verified evidence

- macOS smoke: `build/ui-tests/macos/macos-xcui-smoke-20260711-023111`
- macOS full benchmark: `build/ui-tests/macos/macos-xcui-benchmark-20260711-034321` — 29/29
- iOS smoke: `build/ui-tests/ios/ios-xcui-smoke-20260711-120941`
- iOS full benchmark: `build/ui-tests/ios/ios-xcui-benchmark-20260711-114716` — 29/29
- iOS focused clone proof: `build/ui-tests/ios/ios-xcui-benchmark-20260711-114434`
- deterministic macOS tests: `build/macos/test-artifacts/mac-test-20260711-111007`

These local, untracked artifacts retain named screenshots and exact result bundles. Benchmark
validation passed exact telemetry count and ordering, unique generation IDs, readable atomic WAVs,
audio QC, and crash deltas. They are frontend evidence, not publishing or release prerequisites.

## Future resume sequence

1. Review the current checkout before changing it:

   ```sh
   git status --short --branch
   git rev-parse HEAD
   ```

2. Read the applicable role playbook under [`.agents/`](../.agents/) and confirm the installed
   plugin/skill inventory for optional assistance.
3. Run deterministic development verification:

   ```sh
   ./scripts/check_project_inputs.sh
   scripts/macos_test.sh test
   ./scripts/build.sh build
   ./scripts/build_foundation_targets.sh ios
   ```

4. Stop there for ordinary development publishing. Do not require a model download, paired phone,
   or UI test merely to preserve and share a change.
5. For explicit frontend acceptance, verify model/device prerequisites and run the applicable lanes:

   ```sh
   scripts/ui_test.sh macos smoke
   scripts/ui_test.sh macos benchmark

   scripts/ios_device.sh preflight
   scripts/ui_test.sh ios smoke
   scripts/ui_test.sh ios benchmark
   ```

## Acceptance boundaries

- Model-dependent generation tests first assert in the UI that Custom, Design, and Clone Speed are
  installed/ready, Generate is enabled, and the required clone voice exists.
- `models ensure` remains an explicit repair/bootstrap command, not a normal gate.
- XCUITest evidence never substitutes for deterministic history/database correlation, readable
  WAV validation, audio QC, typed backend/XPC telemetry, crash deltas, or state restoration.
- macOS and physical-iPhone results are independent frontend QA artifacts; neither is a packaging
  prerequisite.
- Smoke and benchmark tests attach named screenshots at important states and on failures.

## Completion checkpoint

The transition is complete: both isolated UI-test targets share common XCUITest support; smoke and
the full 29-take benchmark pass on native macOS and the paired physical iPhone; drift checks reject
the deleted harness, hidden hooks, coordinates, delays, duplicate UI stacks, and Simulator routes;
and development, CI, and release packaging remain publishable with deterministic verification alone.
