# Release / QA domain rule

> Domain rule for build scripts, CI workflow, packaging, signing, notarization,
> benchmarks, interactive QA policy, crash/profile analysis, and release QA gates.

## Boundaries

**Owns:**
- `scripts/*.sh` and `scripts/lib/`
- `.github/workflows/ci.yml`, `.github/workflows/release.yml`, and
  `.github/workflows/security.yml`
- `config/build-output-policy.json`, `config/documentation-contract.json`,
  `config/codex-session-storage-policy.json`,
  `config/public-product-facts.json`, `config/toolchain.json`,
  `config/orchestration-contract.json`, `config/evidence-impact.json`,
  `config/project-health-contract.json`, and `config/release-evidence-contract.json`
- `benchmarks/` schema-v1 compatibility/schema-v2 memory-qualified records, generated history,
  and preserved reference baselines
- `docs/releases/`
- Release verification, evidence-impact, required-step, project-health, supply-chain, and packaging
  scripts (`scripts/verify_*.sh`, `scripts/release_evidence.py`, `scripts/required_step_ledger.py`,
  `scripts/project_health.py`, `scripts/supply_chain_contract.py`, `scripts/create_dmg.sh`, etc.)
- Codex task/session storage governance: `scripts/codex_session_storage.py`, its synthetic test,
  and `docs/reference/codex-session-storage.md`. Live user state remains operator-owned and outside
  repository evidence.
- Release-candidate evidence, SBOM/checksum generation, immutable Actions pins, and repository
  security/governance files
- Production-model-catalog reproducibility and activation gating. Backend owns artifact meaning and
  trusted receipts; Release/QA ensures staged state cannot become active until completeness,
  deterministic validation, and explicit delivery evidence pass.

**Does NOT own:**
- App source code (`.claude/rules/backend-mlx.md`, `.claude/rules/ios.md`, `.claude/rules/macos.md`)
- Marketing site (`website/CLAUDE.md`)

**Consults:**
- `docs/reference/{macos-release-qa,telemetry-and-benchmarking,cli,macos-testing,ios-device-testing}.md`
- `docs/ARCHITECTURE.md` §12 (telemetry)
- Root `CLAUDE.md` (Workflows, Commands) + [`docs/project-map.html`](../../docs/project-map.html)

## Required pre-read

Before changing scripts or CI, read:
1. The script you are modifying (header comments encode intent and env vars).
2. `.github/workflows/release.yml` if touching CI.
3. `docs/reference/macos-release-qa.md` for the full macOS release QA checklist.
4. `docs/reference/benchmarking-procedure.md` for the operator runbook (when to bench, platform lanes, preflight).
5. `docs/reference/telemetry-and-benchmarking.md` for benchmark/telemetry schema and knobs.

## Tools and skills

- **Shell scripts are the source of truth**; run them directly and preserve their artifacts.
- Use a GitHub integration when it is currently callable for PR, release, and Actions context;
  otherwise use `gh`. User-scoped installation state is not a repository prerequisite.
- Optional skills may assist with test triage, performance, signing, packaging, or
  telemetry after their instructions are read. Start from script output and generated artifacts.
- Interactive UI QA is agent-driven computer use (`docs/reference/interactive-ui-qa.md`): macOS
  directly, iOS through iPhone Mirroring on the paired physical iPhone; iOS engine evidence stays
  with the pulled on-device telemetry lanes.
- Development CI is deterministic-only. Commits, pushes, pull requests, and ordinary merges must
  not wait for models, a paired phone, or interactive QA results.
- Release packaging is deterministic. macOS packaging is subordinate to
  `scripts/macos_test.sh release-readiness`, which requires project-input, build,
  deterministic-test, and crash-delta checks. Model-dependent telemetry remains optional explicit
  QA. iOS archive/TestFlight first binds `scripts/macos_test.sh gate` and the generic physical-
  device SDK compile into the same release ledger, then uses its signing, archive, entitlement,
  catalog, and artifact verification. Interactive UI QA is optional
  explicit frontend acceptance and never a signing, notarization, packaging, or upload
  prerequisite. Exception to "optional" in cadence only: the interactive QA checklist is a
  standing per-candidate step — run it and record the per-item verdicts (or a deliberate skip) in
  the release notes; it still never blocks packaging
  (`docs/reference/macos-release-qa.md` step 2b).
- **Generated-output contract:** `config/build-output-policy.json` owns the persistent caches,
  scratch DerivedData, untracked evidence, current symbols, and distribution outputs. Do not add an
  ad hoc build root or allow an Xcode/SwiftPM invocation to choose its own cache. XcodeBuildMCP
  scratch trees (`build/scratch/derived-data/xcodebuildmcp/{macos,ios-device}`) stay scratch-class
  under that policy; they never become a third persistent cache or a release gate.
- **Codex task/session storage:** the separate `config/codex-session-storage-policy.json` governs
  an optional operator-local workflow. CI validates the contract and temporary fixtures only; it
  never reads or changes a real Codex home. Use the plain/compressed metadata-only inventory,
  temporary checksummed plan, exact approval, evolving non-target preservation baseline, supported
  CLI deletion, and verification sequence in
  `docs/reference/codex-session-storage.md`. This state is not repository build output.
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
QVOICE_GATES=quick ./scripts/check_project_inputs.sh   # local fast loop: self-tests skipped only while scripts/ + config/ are untouched
scripts/macos_test.sh test
./scripts/build.sh build
./scripts/build_foundation_targets.sh ios

# Deterministic/runtime macOS gate (models are needed only for the optional bounded bench)
scripts/macos_test.sh models ensure   # explicit repair/bootstrap only; normal readiness is visible in Settings
scripts/macos_test.sh gate
QWENVOICE_GATE_BENCH=1 scripts/macos_test.sh gate   # optional: bounded custom/speed/medium bench + audioQC

# Explicit interactive UI QA (docs/reference/interactive-ui-qa.md); never a packaging prerequisite.
scripts/macos_test.sh telemetry-overhead

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

scripts/ios_device.sh gate

# Model fixture helpers
scripts/macos_test.sh models check|ensure|install
# Interactive QA reviews iOS model readiness visibly in Settings.

# Release packaging
./scripts/build.sh release
python3 scripts/supply_chain_contract.py
python3 scripts/release_evidence.py validate --output-dir build/dist/macos

# Benchmark driver (PASS publishes a registry record automatically when run in this checkout)
QWENVOICE_DEBUG=1 ./build/vocello bench --modes clone --variants speed \
  --lengths short,medium,long --warm 3 --voice <prepared-voice> \
  --label "release-QA"

# Derived catalogs (inventories / indexes CI fail-closes on)
python3 scripts/refresh_derived_artifacts.py refresh
python3 scripts/refresh_derived_artifacts.py validate

# Registry validation / reproducibility
python3 scripts/benchmark_history.py validate --all
python3 scripts/benchmark_history.py rebuild-index --check
python3 scripts/model_catalog_contract.py rebuild --check
python3 scripts/model_catalog_contract.py validate

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
python3 scripts/codex_session_storage.py validate
python3 scripts/codex_session_storage.py status   # optional local aggregate; never CI/release input
scripts/clean_build_caches.sh --routine --dry-run
scripts/clean_build_caches.sh --routine
scripts/clean_build_caches.sh --prune-ui-results --dry-run
scripts/clean_build_caches.sh --cache macos --dry-run
scripts/clean_build_caches.sh --compact-profile-failure <run-id> --dry-run
```

## Invariants (do not regress)

- **Single shippable config: `Release` only.** There is no `Debug` config or generic `DEBUG` symbol.
  `build.sh` compiles `-Onone`; `release.sh` compiles optimized.
- **XcodeGen project generation.** `project.yml` is the source of truth; never edit
  `QwenVoice.xcodeproj/project.pbxproj` directly. There are two narrow post-XcodeGen scheme
  renderers: `scripts/generate_cli_scheme.py` for the tool product and
  `scripts/generate_ios_logic_scheme.py` for the app-host-free iOS policy bundle. Both bind
  checked-in templates to generated target IDs because XcodeGen 2.45.4 cannot render those schemes.
- **Developer ID signing + notarization.** macOS release uses Developer ID Application cert,
  hardened runtime, and `notarytool` stapling. CI uses App Store Connect API key auth.
- **Gate quick mode is local-only.** `QVOICE_GATES=quick` may skip the script self-test suite
  only while `scripts/` and `config/` have no pending changes; CI and release lanes never set it,
  so every push and package still runs the full suite. Do not widen the skip's scope.
- **Ordinary CI is deterministic-only.** GitHub CI compiles the `VocelloiOS` app and standalone
  `VocelloiOSLogicTests` bundle with `generic/platform=iOS`, runs macOS deterministic verification,
  and never executes app-UI automation. Xcode 26 cannot execute the app-host-free tool-hosted
  policy bundle on a physical-device destination, so it remains compile-only; device runtime proof
  uses the existing diagnostics lanes. Missing matching iOS Platform Support/runtime
  availability is classified as a host-toolchain readiness failure before package resolution, not
  as a source, phone, model, or UI failure. Repository automation never downloads that component.
- **Committed benchmark records ≤256 KB.** Records use a strict privacy allowlist; raw JSONL,
  WAVs, screenshots, result bundles, and traces are gitignored. `HISTORY.md` is generated, never
  manually appended.
- **Profile storage is bounded.** A successful profile is retained as compact history plus local
  summary metadata; its raw trace is deleted only after publication succeeds unless `--keep-trace`
  was explicit. A failed lane retains at most the newest raw trace per platform/profile kind and
  requires an exact run ID before manual compaction. Inventory distinguishes automatic, blocked,
  and explicit reclamation; never reinterpret all of `build/artifacts/` as disposable.
- **Build outputs have one owner.** macOS and physical-device iOS keep exactly two persistent Xcode
  caches, package resolution uses the shared locked checkout, and release/MCP/compile-safety work is
  scratch. Release files live only under `build/dist/` and routine cleanup never removes them.
  Heavy lanes use the manifest-owned free-space preflight before work starts. Prefer one selective
  `--cache` target over `--aggressive`; successful ordinary builds remain non-destructive.
- **Codex user state remains external.** The repository tracks only the policy, helper, runbook,
  and synthetic tests. A live manifest/journal stays mode 0600 in a system temporary directory and
  never enters Git, CI, release evidence, or benchmark history. Unknown and unrelated tasks are
  protected; no subagent may select or approve deletion; no workflow edits Codex SQLite or removes
  rollout JSONL directly.
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
- **Release publication is the final transaction.** A protected `v*` tag or explicit existing tag
  starts the workflow. Source/tag/version identity, signing, notarization, package verification,
  SPDX/CycloneDX generation, checksums, and provenance all pass before a draft Release exists.
  Schema-v2 release evidence accepts only a clean full-tree source identity and fresh same-invocation
  required-step manifests produced by the managed release subprocess. Every release step must match
  its `config/orchestration-contract.json` command template, and declared outputs are hashed at step
  completion and rechecked during evidence creation; handwritten, substituted-command, replaced-
  output, or stale PASS artifacts are never authoritative. iOS additionally requires
  `verify_ios_release_artifacts.py` to prove archive/IPA identity, entitlements, root privacy
  manifest, locally trusted and profile-authorized signing, and Mach-O UUID plus
  signature-normalized code continuity
  before evidence or attestation. Archive signing may be development or distribution; the exported
  IPA alone must satisfy the App Store distribution profile and `get-task-allow` policy.
  Reused drafts are emptied before upload, then their exact remote asset-name set and digests are
  verified before publication. Never restore a
  `release.published` trigger.
- **Action and toolchain identities are immutable inputs.** Every external Action uses the full SHA
  recorded in `config/toolchain.json`; native, release-publication, and website runners validate
  exact tool versions. The native deterministic-tool group includes NumPy because the bounded
  prosody analyzer and its mutation fixtures are part of project-input validation; this remains a
  development/QA dependency and is never shipped in Vocello. Keep publication-only tools out of
  compile/test jobs.
  Dependabot may propose updates, but the manifest and adjacent version comment change together.
- **Catalog activation is fail closed.** All six Speed/Quality identities are exact and the generated
  production catalog is complete. macOS/CLI use the bundled `downloadFiles` route; never restore
  live repository enumeration, infer a digest, or accept a partial catalog. Deterministic
  `model_catalog_contract.py validate --require-complete` and explicit post-change delivery evidence
  remain distinct proofs.
- **Burn-in-safe iOS testing.** Headless generation, profiling, logs, and device diagnostics go
  through `scripts/ios_device.sh`; physical-device UI acceptance is agent-driven interactive QA
  through iPhone Mirroring, kept to a handful of generations per session.
- **macOS real-generation acceptance needs model fixtures.** QA verifies readiness in Settings;
  run `scripts/macos_test.sh models ensure` only to repair/bootstrap the debug link and clone voice. See [`scripts/lib/test_models.sh`](../../scripts/lib/test_models.sh) and
  [`docs/reference/testing-runbook.md`](../../docs/reference/testing-runbook.md) "Model readiness".
- **No scripted UI-driver stack.** The XCUITest stack was retired 2026-07-22; the wiring gates
  fail closed on its artifacts. Interactive QA drives genuine visible controls with vision; do not
  add coordinate hooks, hidden marker catalogs, scenario configs, or attestation files (all
  previously retired forms).

## Common mistakes

- Adding a Debug configuration or generic `#if DEBUG` behavior fork. Use runtime diagnostics or a
  narrowly named test-target compilation condition instead.
- Running iOS UI work in the Simulator or expecting ordinary CI to drive the UI. Interactive QA
  through iPhone Mirroring is explicit frontend acceptance, never an archive/TestFlight or
  development-publishing prerequisite.
- Committing raw `.jsonl` telemetry to `benchmarks/`.
- Editing `benchmarks/HISTORY.md` by hand or treating a failed/incomplete run as publishable.
- Forgetting to validate current dSYM UUIDs under `build/artifacts/symbols/{macos,ios}` after a
  product rebuild.
- Changing signing/notarization env vars without updating the workflow secret docs.
