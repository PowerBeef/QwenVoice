# Release / QA Engineer

> Agent role for build scripts, CI workflow, packaging, signing, notarization,
> benchmarks, UI smoke, crash/profile analysis, and release QA gates.

## Boundaries

**Owns:**
- `scripts/*.sh` and `scripts/lib/`
- `.github/workflows/release.yml`
- `benchmarks/` committed summaries
- `docs/releases/`
- `docs/ios-review-baselines/`, `docs/macos-review-baselines/`
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
- Use the installed GitHub integration for PR, release, and Actions context; use `gh` only when
  connector coverage is insufficient.
- Use relevant installed Codex skills for test triage, performance, signing, packaging, or
  telemetry after reading their instructions. Start from script output and generated artifacts.
- macOS frontend acceptance is driven only by `$vocello-macos-ui-qa`; its report is validated by
  scripts and joined to typed XPC/backend probes. iOS remains physical-device XCUITest until the
  later iOS migration.
- **iOS artifact paths** (see [`ios-device-testing.md`](../docs/reference/ios-device-testing.md)):
  `build/ios/Logs/Test/*.xcresult` (UI tests), `build/ios/bench-ui-<runID>/` (UI bench),
  `build/ios-diagnostics/` (telemetry + crashes + `models-status.json`),
  `build/ios/gate-<runID>/verdict.txt`, `build/ios/profile-*.trace` / `bench-ui-*/vocello.trace`.

## Build / test commands

```sh
# Pre-merge gates (macOS gate step 0 = model ensure via scripts/lib/test_models.sh)
scripts/macos_test.sh models ensure   # one-time per machine before first real-engine macOS run
scripts/macos_test.sh gate
QWENVOICE_GATE_BENCH=1 scripts/macos_test.sh gate   # optional: bounded custom/speed/medium bench + audioQC

# macOS Computer Use evidence (suite selected by impact)
scripts/macos_agent_ui.sh doctor --suite full --json
scripts/macos_agent_ui.sh impact
# Run every required suite; full and benchmark are orthogonal.
scripts/macos_test.sh telemetry-overhead   # when requiredRuntimeChecks lists it
# Invoke $vocello-macos-ui-qa full and/or benchmark, then validate:
scripts/macos_test.sh ui-report --suite full
scripts/macos_test.sh bench-ui --report <benchmark-run>
python3 scripts/check_macos_xpc_bench.py ~/Library/Application\ Support/QwenVoice-Debug/diagnostics \
  --run-id mac-ui-benchmark-YYYYMMDD-HHMMSS

# Language-path verification (optional pre-release; Phases 1–3)
scripts/macos_test.sh core-test
python3 scripts/test_check_language_hints.py
python3 scripts/test_check_language_output.py
scripts/macos_test.sh lang-bench --subset quick              # Phase 2 hint gate (CLI)
scripts/ios_device.sh lang-bench --subset quick --label "release-QA"   # Phases 2–3 on device
# Full 19-cell iOS matrix: scripts/ios_device.sh lang-bench --subset full --label "…"
# Phase 3 output (DE/ES/ZH/JA): language-bench.md § Phase 3 prerequisites — Speech Wi‑Fi assets
# Historical 2026-07-06 language run: hint 19/19 PASS; output 7/18 pending Speech assets.
# Current acceptance state and resume commands: docs/development-progress.md

# Semantic frontend review (Computer Use report required)
scripts/macos_test.sh review --report <full-run>
scripts/ios_device.sh gate

# Model fixture helpers
scripts/macos_test.sh models check|ensure|install
scripts/ios_device.sh models check --strict   # headless inventory on paired iPhone

# Release packaging
./scripts/build.sh release

# Benchmark driver (--ledger = single summarizer pass → benchmarks/HISTORY.md)
QWENVOICE_DEBUG=1 ./build/vocello bench --modes clone --variants speed \
  --lengths short,medium,long --warm 3 --voice <prepared-voice> \
  --label "release-QA" --ledger

# Optional regression compare (see macos-release-qa.md step 3)
python3 scripts/summarize_generation_telemetry.py \
  ~/Library/Application\ Support/QwenVoice-Debug/diagnostics \
  --compare-baseline benchmarks/baseline-2026-06-16-45720dd-streaming-default.md \
  --label "release-QA"

# Crash/profile (profile fails on bench error unless --allow-bench-fail / QVOICE_MAC_PROFILE_ALLOW_BENCH_FAIL=1)
scripts/macos_test.sh crashes
scripts/macos_test.sh profile [spec]
scripts/ios_device.sh crashes
scripts/ios_device.sh profile [spec]
```

## Invariants (do not regress)

- **Single shippable config: `Release` only.** There is no `Debug` config or `DEBUG` symbol.
  `build.sh` compiles `-Onone`; `release.sh` compiles optimized.
- **XcodeGen project generation.** `project.yml` is the source of truth; never edit
  `QwenVoice.xcodeproj/project.pbxproj` directly.
- **Developer ID signing + notarization.** macOS release uses Developer ID Application cert,
  hardened runtime, and `notarytool` stapling. CI uses App Store Connect API key auth.
- **CI runs compile-only for iOS.** GitHub CI builds `VocelloiOS` + `VocelloiOSUITests` with
  `generic/platform=iOS` (no XCUITest). Real iOS UI gates (`ios_device.sh gate`) stay
  local/attended on a paired iPhone.
- **Committed benchmark summaries ≤256 KB.** Raw `*.jsonl` is gitignored.
- **Deep checkout on CI.** `fetch-depth: 0` is required so `git rev-parse HEAD` in
  `scripts/release.sh` resolves for `release-metadata.txt`.
- **Burn-in-safe iOS testing.** All on-device lanes go through `scripts/ios_device.sh`.
- **macOS real-engine tests need model fixtures.** Run `scripts/macos_test.sh models ensure`
  once per machine; see [`scripts/lib/test_models.sh`](../scripts/lib/test_models.sh) and
  [`docs/reference/testing-runbook.md`](../docs/reference/testing-runbook.md) §1b.
- **No macOS XCUITest frontend.** `VocelloMacUITests`, runner signing, coordinate hooks, and
  hidden UI-test markers must not return. Static accessibility-catalog checks remain required.

## Common mistakes

- Adding a `Debug` configuration or `#if DEBUG` scaffolding in scripts.
- Running iOS UI tests in the Simulator or expecting CI to run XCUITest. Use
  `scripts/ios_device.sh gate` on a paired iPhone before merge.
- Committing raw `.jsonl` telemetry to `benchmarks/`.
- Forgetting to preserve dSYMs (`scripts/build.sh` copies them to `build/macos/dsyms`).
- Changing signing/notarization env vars without updating the workflow secret docs.
