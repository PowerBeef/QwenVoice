# macOS testing

Vocello separates routine deterministic development verification from explicit native-app UI
acceptance. Interactive UI acceptance is agent-driven computer use
([`interactive-ui-qa.md`](interactive-ui-qa.md)); the scripted XCUITest stack was retired
2026-07-22.

## Ordinary development

```sh
./scripts/check_project_inputs.sh
scripts/macos_test.sh test
./scripts/build.sh build
```

These checks are sufficient to commit, push, open a pull request, merge ordinary development, and
run ordinary CI. They do not require UI execution, installed generation models, or release
evidence.

## Interactive UI acceptance

Run only when frontend acceptance is explicitly requested, or as the recorded release-candidate
checklist: the agent-driven computer-use checklist in
[`interactive-ui-qa.md`](interactive-ui-qa.md) against `./scripts/build.sh run` — navigation and
visible readiness, one completed nonced generation asserted in History, mid-generation
cancellation with a clean reset and no History row, the virtual-microphone recording flow, and the
library surfaces. Screenshot evidence lands under the untracked interactive-QA artifacts tree with
a per-item verdict list.

## Model-dependent tests

Before generation, QA must visibly confirm that Custom, Design, and Clone Speed are ready,
Generate is enabled, and the prepared clone voice is present. Use
`scripts/macos_test.sh models ensure` only to repair/bootstrap fixtures, then begin a fresh QA
run. Do not download models implicitly during QA.

## Benchmark evidence (headless)

UI-driven benchmark lanes were retired with the XCUITest stack; the committed
`benchmarks/runs/ui-generation/` records remain immutable history. Engine benchmark evidence runs
headless:

```sh
QWENVOICE_DEBUG=1 ./build/vocello bench --modes clone --variants speed \
  --lengths short,medium,long --warm 3 --voice <prepared-voice> --label "release-QA"
```

A PASS publishes one privacy-safe record under `benchmarks/runs/` and regenerates
`benchmarks/HISTORY.md`. Raw telemetry and WAVs remain untracked; publication never stages,
commits, or pushes. New publishable generation runs use telemetry schema v8 and evidence manifest
v2 with the standing memory-qualification rules (exact sample sidecars, ≥95% sampler coverage, no
critical pressure/`hardTrim`/`fullUnload`; guarded states publish only as explicit warnings).

## Instruments profiles

```sh
# CPU/signpost profile (default)
scripts/macos_test.sh profile custom:speed:

# CPU + Allocations + VM Tracker + signposts
scripts/macos_test.sh profile --kind memory custom:speed:

# Explicit diagnostic exception: retain the raw Instruments document.
scripts/macos_test.sh profile --kind memory --keep-trace custom:speed:
```

The memory profile captures one cold long take so Allocations/VM Tracker include model-load and
sustained-generation peaks. It uses Apple's Allocations template, which contains both memory tracks
with automatic VM snapshots disabled; standalone VM Tracker auto-snapshots suspend the target and
would legitimately lower its 500 ms sampler coverage. Publication verifies that setting from the
captured trace and still enforces the unmodified 95% coverage floor. The default 180-second safety
cap accommodates a cold long take, while target exit ends recording early. `scripts/macos_test.sh
memory` owns the repeated retained-growth qualification.

Both commands build the exact CLI, suspend one owned process, attach Instruments to that exact PID,
resume it only after xctrace reports recording, and validate the exported trace table of contents.
The memory lane enables verbose per-sample telemetry and remains PASS-only. Headless CLI profiles
report the owning engine process; XPC UI benchmarks use the uptime-aligned app+engine aggregate.
The tracer stage requires at least 5 GiB free for CPU profiles and 15 GiB for memory profiles before
it launches the target. The prerequisite CLI build uses the shared 8 GiB development-build floor,
so a complete CPU-profile command effectively requires 8 GiB; memory remains 15 GiB. After
successful trace validation and history publication, the raw trace is
deleted by default; the record retains its digest, capture settings, extracted summary, original
ephemeral path, and retention status. `--keep-trace` is the explicit diagnostic exception. A
failure retains only the newest raw failure for that platform/profile kind. Sidecars and retained
diagnostics remain under `build/` and untracked.

Other heavy macOS lanes also use the manifest-owned build-storage preflight before creating output:
8 GiB for deterministic/runtime builds, 12 GiB for telemetry-overhead and UI smoke, and 15 GiB for
language, memory, and UI benchmark work. These are working-space floors, not cache quotas. Inspect
`python3 scripts/build_output_policy.py status` before applying its suggested bounded cleanup.

Retained-memory qualification is a distinct non-Instruments lane:

```sh
scripts/macos_test.sh memory --label retained-check
```

It runs the policy-owned Custom→Design→Clone Speed/medium sequence with three canonically named
`retained#0...2` takes per mode (plus the CLI's genuine Custom/Design cold takes) in one process.
Those retained takes still report their actual engine warm state. Policy
`retained-memory-v1` compares the first and last completed retained-take footprint within each mode;
the maximum positive growth must stay at or below 5% of physical RAM. Intended cross-mode model
residency is diagnostic and is not mislabeled as a leak. A PASS creates a
`memory-qualification` record; a generation, memory, QC, or retention failure leaves only local
artifacts.

## Generated-output ownership

macOS development and UI lanes reuse only `build/cache/xcode/macos/`; shared package checkouts live
under `build/cache/xcode/source-packages/`. Result bundles, diagnostics, profiles, and current dSYMs
are untracked artifacts under `build/artifacts/`, while release packaging is isolated under
`build/scratch/derived-data/release-macos/` and `build/dist/macos/`. `build/Vocello.app` and
`build/vocello` are public symlinks to current canonical products, not copied applications. See the
authoritative owner/lifetime table in [`privacy-storage.md`](privacy-storage.md).

## Release boundary

macOS signing, notarization, and packaging use deterministic release-readiness checks. Interactive
QA results are independent frontend acceptance artifacts and never a packaging prerequisite.

See also [`testing-runbook.md`](testing-runbook.md),
[`benchmarking-procedure.md`](benchmarking-procedure.md), and
[`macos-release-qa.md`](macos-release-qa.md).
