# macOS testing

Vocello separates routine deterministic development verification from explicit native-app UI
acceptance. XCUITest is the sole autonomous macOS app UI driver.

## Ordinary development

```sh
./scripts/check_project_inputs.sh
scripts/macos_test.sh test
./scripts/build.sh build
```

These checks are sufficient to commit, push, open a pull request, merge ordinary development, and
run ordinary CI. They do not require UI execution, installed generation models, or release
evidence.

## Explicit XCUITest lanes

Run only when frontend acceptance is explicitly requested:

```sh
scripts/ui_test.sh macos smoke
scripts/ui_test.sh macos benchmark
# Filtered benchmark example:
scripts/ui_test.sh macos benchmark --modes custom --lengths short --warm 1 --label "focused"
```

| Lane | Scope |
| --- | --- |
| Smoke | Exact app launch, sidebar navigation, visible model and clone-reference readiness, one real Custom generation, completed player, and History |
| Benchmark | Ordered, configurable Custom/Design/Clone matrix with cold/warm classification and per-take deterministic proof; the default is exactly 29 takes |

The runner targets the configured native Vocello test host. It establishes single-process
ownership, uses stable accessibility identifiers and condition waits, leaves preferences and saved
voices unchanged, terminates its owned app/service processes, and records failures as XCTest
activities and attachments. It never retries through a display name or alternate app path.

Benchmark accepts `--modes`, `--lengths`, `--warm`, and `--label`. Filters are explicit diagnostic
runs; invoking the command without filters is the canonical 29-take matrix.

## Model-dependent tests

Before generation, XCUITest must visibly confirm that Custom, Design, and Clone Speed are ready,
Generate is enabled, and the benchmark clone voice is present. Use
`scripts/macos_test.sh models ensure` only to repair/bootstrap fixtures, then begin a fresh test
run. Do not download models implicitly inside a normal UI lane.

## Deterministic evidence retained

The benchmark validator joins UI completion with:

- History/database correlation and a readable WAV;
- audio QC and typed frontend/XPC/backend telemetry by `generationID`;
- crash delta and XPC process lifecycle evidence;
- benchmark order, take count, cold/warm class, and timing.

Smoke is intentionally smaller: it asserts visible completion and History plus the runner's
single-process/crash-delta checks; it does not claim the benchmark's per-take telemetry matrix.

## Release boundary

macOS signing, notarization, and packaging use deterministic release-readiness checks. Smoke and
benchmark XCUITest results are independent frontend QA artifacts and never a packaging prerequisite.

See also [`testing-runbook.md`](testing-runbook.md),
[`benchmarking-procedure.md`](benchmarking-procedure.md), and
[`macos-release-qa.md`](macos-release-qa.md).
