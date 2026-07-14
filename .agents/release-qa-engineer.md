# Release / QA Engineer

> Agent role for build scripts, CI workflow, packaging, signing, notarization,
> benchmarks, UI smoke, crash/profile analysis, and release QA gates.

## Boundaries

**Owns:**
- `scripts/*.sh` and `scripts/lib/`
- `.github/workflows/ci.yml` and `.github/workflows/release.yml`
- `config/build-output-policy.json`, `config/documentation-contract.json`, and
  `config/public-product-facts.json`
- `benchmarks/` schema-v1 compatibility/schema-v2 memory-qualified records, generated history,
  and preserved reference baselines
- `docs/releases/`
- Release verification scripts (`scripts/verify_*.sh`, `scripts/create_dmg.sh`, etc.)

**Does NOT own:**
- App source code (`.agents/backend-mlx.md`, `.agents/ios-engineer.md`, `.agents/macos-engineer.md`)
- Marketing site (`website/AGENTS.md`)

**Consults:**
- `docs/reference/{macos-release-qa,telemetry-and-benchmarking,cli,macos-testing,ios-device-testing}.md`
- `docs/ARCHITECTURE.md` §12 (telemetry)
- Root `AGENTS.md` (Workflows, Commands) + [`docs/project-map.html`](../docs/project-map.html)

## Required pre-read

Before changing scripts or CI, read:
1. The script you are modifying (header comments encode intent and env vars).
2. `.github/workflows/release.yml` if touching CI.
3. `docs/reference/macos-release-qa.md` for the full macOS release QA checklist.
4. `docs/reference/benchmarking-procedure.md` for the operator runbook (when to bench, platform lanes, preflight).
5. `docs/reference/telemetry-and-benchmarking.md` for benchmark/telemetry schema and knobs.

## Tools and skills (Codex)

- **Shell scripts are the source of truth**; run them directly and preserve their artifacts.
- Use a GitHub integration when it is currently callable for PR, release, and Actions context;
  otherwise use `gh`. User-scoped installation state is not a repository prerequisite.
- Use relevant installed Codex skills for test triage, performance, signing, packaging, or
  telemetry after reading their instructions. Start from script output and generated artifacts.
- XCUITest is the sole autonomous app UI driver. It runs against the native macOS app or a paired
  physical iPhone and provides smoke and benchmark lanes; iOS adds pulled on-device
  telemetry proof.
- Development CI is deterministic-only. Commits, pushes, pull requests, and ordinary merges must
  not wait for models, a paired phone, or XCUITest results.
- Release packaging is deterministic. macOS packaging is subordinate to
  `scripts/macos_test.sh release-readiness`, which requires project-input, build,
  deterministic-test, and crash-delta checks. Model-dependent telemetry remains optional explicit
  QA. iOS archive/TestFlight uses
  its signing, archive, entitlement, catalog, and artifact verification. XCUITest is optional
  explicit frontend QA and never a signing, notarization, packaging, or upload prerequisite.
- **Generated-output contract:** `config/build-output-policy.json` owns the persistent caches,
  scratch DerivedData, untracked evidence, current symbols, and distribution outputs. Do not add an
  ad hoc build root or allow an Xcode/SwiftPM invocation to choose its own cache.
- **Evidence artifacts:** `build/artifacts/ui-tests/` owns `.xcresult` bundles and exported
  screenshots; `build/artifacts/diagnostics/` owns pulled/headless generation telemetry and crashes;
  platform gate/profile outputs remain below `build/artifacts/{macos,ios}/`; current dSYMs live
  under `build/artifacts/symbols/{macos,ios}/`.
- **Benchmark registry:** successful memory-qualified benchmark lanes publish a compact record under
  `benchmarks/runs/<kind>/` and regenerate `benchmarks/HISTORY.md`. The telemetry-overhead
  observer-effect diagnostic stays local because instrumenting its `off` lane would invalidate the
  comparison. Raw telemetry, WAVs, screenshots, `.xcresult`, and traces stay untracked. Publication
  never stages, commits, or pushes. Successful profiles are summary-only by default: the runner
  publishes the trace digest/settings/extracted evidence before deleting the raw trace. Use
  `--keep-trace` only when the raw Instruments document must be reopened.
- **Documentation and public facts:** this role owns lifecycle/index validation and public release,
  platform, support, and canonical-hardware references. Model implementation facts remain backend-owned.
- **Schema review:** telemetry or benchmark schema-version changes require backend, the affected
  platform owner, and release/QA review before publication contracts change.

## Build / test commands

```sh
# Ordinary development / CI (no model, device, or UI prerequisite)
./scripts/check_project_inputs.sh
scripts/macos_test.sh test
./scripts/build.sh build
./scripts/build_foundation_targets.sh ios

# Deterministic/runtime macOS gate (models are needed only for the optional bounded bench)
scripts/macos_test.sh models ensure   # explicit repair/bootstrap only; normal readiness is visible in Settings
scripts/macos_test.sh gate
QWENVOICE_GATE_BENCH=1 scripts/macos_test.sh gate   # optional: bounded custom/speed/medium bench + audioQC

# Explicit XCUITest evidence; never a packaging prerequisite.
scripts/ui_test.sh macos smoke
scripts/ui_test.sh macos benchmark
scripts/macos_test.sh telemetry-overhead
python3 scripts/check_macos_xpc_bench.py ~/Library/Application\ Support/QwenVoice-Debug/diagnostics \
  --run-id macos-xcui-benchmark-YYYYMMDD-HHMMSS

# Language-path verification (optional pre-release; Phases 1–3)
scripts/macos_test.sh core-test
python3 scripts/test_check_language_hints.py
python3 scripts/test_check_language_output.py
scripts/macos_test.sh lang-bench --subset quick              # Phase 2 hint gate (CLI)
scripts/ios_device.sh lang-bench --subset quick --label release-QA   # Phases 2–3 on device
# Full 19-cell iOS matrix: scripts/ios_device.sh lang-bench --subset full --label lang-full-v1
# Fixed 15-take autonomous diagnosis, never history: scripts/ios_device.sh lang-bench --diagnostic-cohort
# Phase 3 output (DE/ES/ZH/JA): language-bench.md § Phase 3 prerequisites — Speech Wi‑Fi assets
# Current acceptance state and resume commands: docs/development-progress.md

scripts/ui_test.sh ios smoke
scripts/ui_test.sh ios benchmark
scripts/ios_device.sh gate

# Model fixture helpers
scripts/macos_test.sh models check|ensure|install
# XCUITest reviews iOS model readiness visibly in Settings.

# Release packaging
./scripts/build.sh release

# Benchmark driver (PASS publishes a registry record automatically when run in this checkout)
QWENVOICE_DEBUG=1 ./build/vocello bench --modes clone --variants speed \
  --lengths short,medium,long --warm 3 --voice <prepared-voice> \
  --label "release-QA"

# Registry validation / reproducibility
python3 scripts/benchmark_history.py validate --all
python3 scripts/benchmark_history.py rebuild-index --check

# Optional regression compare (see macos-release-qa.md step 3)
python3 scripts/summarize_generation_telemetry.py \
  ~/Library/Application\ Support/QwenVoice-Debug/diagnostics \
  --run-id <run-id> --evidence-manifest <run-artifact-dir>/benchmark-evidence.json \
  --compare-baseline benchmarks/baselines/mac-gate-bench.json \
  --label "release-QA"

# Crash/profile (PASS-only; failed traces or generations never publish benchmark history)
scripts/macos_test.sh crashes
scripts/macos_test.sh profile [--kind cpu|memory] [--keep-trace] [spec]
scripts/macos_test.sh memory [--label ID]
scripts/ios_device.sh crashes
scripts/ios_device.sh profile [--kind cpu|memory] [--keep-trace] [spec]
scripts/ios_device.sh memory --voice-id SAVED_VOICE_ID [--label ID]
# Reads already-pulled delayed MetricKit aggregates; it does not contact the phone or publish history.
scripts/ios_device.sh memory-field-report [pulled-diagnostics]
python3 scripts/build_output_policy.py status [--json]
python3 scripts/build_output_policy.py validate
scripts/clean_build_caches.sh --routine --dry-run
scripts/clean_build_caches.sh --routine
```

## Invariants (do not regress)

- **Single shippable config: `Release` only.** There is no `Debug` config or generic `DEBUG` symbol.
  `build.sh` compiles `-Onone`; `release.sh` compiles optimized.
- **XcodeGen project generation.** `project.yml` is the source of truth; never edit
  `QwenVoice.xcodeproj/project.pbxproj` directly. The generated `VocelloCLI` shared scheme is the
  one narrow exception to XcodeGen output: `scripts/generate_cli_scheme.py` renders it from the
  checked-in template after regeneration because XcodeGen 2.45.4 traps on tool-product schemes.
- **Developer ID signing + notarization.** macOS release uses Developer ID Application cert,
  hardened runtime, and `notarytool` stapling. CI uses App Store Connect API key auth.
- **Ordinary CI is deterministic-only.** GitHub CI builds `VocelloiOS` with
  `generic/platform=iOS` and runs macOS deterministic verification. XCUITest execution is used only
  for explicitly requested frontend acceptance.
- **Committed benchmark records ≤256 KB.** Records use a strict privacy allowlist; raw JSONL,
  WAVs, screenshots, result bundles, and traces are gitignored. `HISTORY.md` is generated, never
  manually appended.
- **Profile storage is bounded.** A successful profile is retained as compact history plus local
  summary metadata; its raw trace is deleted only after publication succeeds unless `--keep-trace`
  was explicit. A failed lane retains at most the newest raw trace per platform/profile kind.
- **Build outputs have one owner.** macOS and physical-device iOS keep exactly two persistent Xcode
  caches, package resolution uses the shared locked checkout, and release/MCP/compile-safety work is
  scratch. Release files live only under `build/dist/` and routine cleanup never removes them.
- **Memory-qualified publication is strict.** New generation/profile records require telemetry v8
  and evidence manifest v2, exact sidecar digests, ≥95% sampler coverage, zero capture failures,
  and no critical pressure, memory warning/exit, `hardTrim`, or `fullUnload`. A 95–<100% coverage
  result or guarded/soft-trim state is retained as `passedWithWarnings`; it is never silently clean.
- **MetricKit field evidence stays local and delayed.** `memory-field-report` summarizes only
  already-pulled privacy-reduced aggregates. It never wakes a device, and its daily/non-run-
  correlated values cannot qualify or retroactively fail a benchmark take.
- **Audio QA is autonomous.** Require the applicable fixed-seed exact-WAV QC, three-pass
  locale-locked ASR, and prosody/delivery evidence. Listening is optional annotation and cannot
  clear a machine warning or failure.
- **Deep checkout on CI.** `fetch-depth: 0` is required so `git rev-parse HEAD` in
  `scripts/release.sh` resolves for `release-metadata.txt`.
- **Burn-in-safe iOS testing.** Headless generation, profiling, logs, and device diagnostics go
  through `scripts/ios_device.sh`; physical-device UI acceptance goes through `scripts/ui_test.sh`.
- **macOS real-generation acceptance needs model fixtures.** XCUITest verifies readiness in Settings;
  run `scripts/macos_test.sh models ensure` only to repair/bootstrap the debug link and clone voice. See [`scripts/lib/test_models.sh`](../scripts/lib/test_models.sh) and
  [`docs/reference/testing-runbook.md`](../docs/reference/testing-runbook.md) "Model readiness".
- **Single XCUITest stack.** Keep shared waits, fixtures, evidence export, and benchmark contracts
  common across the macOS and physical-iPhone targets. Do not add coordinate hooks, hidden marker
  catalogs, or a second UI driver.

## Common mistakes

- Adding a Debug configuration or generic `#if DEBUG` behavior fork. Use runtime diagnostics or a
  narrowly named test-target compilation condition instead.
- Running iOS UI work in the Simulator or expecting ordinary CI to drive the UI. Use the physical-
  iPhone XCUITest lanes for explicit frontend acceptance, never as an archive/TestFlight or
  development-publishing prerequisite.
- Committing raw `.jsonl` telemetry to `benchmarks/`.
- Editing `benchmarks/HISTORY.md` by hand or treating a failed/incomplete run as publishable.
- Forgetting to validate current dSYM UUIDs under `build/artifacts/symbols/{macos,ios}` after a
  product rebuild.
- Changing signing/notarization env vars without updating the workflow secret docs.
